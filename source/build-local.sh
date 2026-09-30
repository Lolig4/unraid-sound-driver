#!/bin/bash
# Build the sound driver package on the Unraid server itself, against the
# running kernel, and place it where the plugin picks it up on boot.
#
# The kernel modules and ALSA are built inside a gcc container matching the
# compiler Unraid used, so this needs Docker and a few GB in WORK_DIR.
#
# Usage: build-local.sh [--install] [--wait-docker] [--notify]
#   --install      also swap the new modules into the running system; running
#                  containers that use /dev/snd are restarted around the swap
#   --wait-docker  wait until Docker is up (used by the plugin on boot)
#   --notify       report success/failure as Unraid notification
#
# Environment overrides: WORK_DIR, PKG_DIR, KEEP_WORK_DIR=1, KEEP_IMAGE=1
set -euo pipefail

UNAME="$(uname -r)"
KERNEL_V="${UNAME%%-*}"
UNRAID_SRC="/usr/src/linux-${UNAME}"
WORK_DIR="${WORK_DIR:-/tmp/sound-driver-build}"
PKG_DIR="${PKG_DIR:-/boot/config/plugins/sound-driver/packages/${KERNEL_V}}"
PKG_NAME="sound-$(date +'%Y%m%d')-${UNAME}-local.txz"
STATE="/boot/config/plugins/sound-driver/conf/asound.state"
NOTIFY_BIN="/usr/local/emhttp/plugins/dynamix/scripts/notify"
ALSA_LIB_V="1.2.16.1"
ALSA_UTILS_V="1.2.16"
ALSA_UCM_V="1.2.16.1"
INSTALL=0
WAIT_DOCKER=0
NOTIFY=0
for arg in "$@"; do
  case "${arg}" in
    --install) INSTALL=1 ;;
    --wait-docker) WAIT_DOCKER=1 ;;
    --notify) NOTIFY=1 ;;
    *) echo "Unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

STOPPED=""
notify() {
  [ "${NOTIFY}" = "1" ] && [ -x "${NOTIFY_BIN}" ] || return 0
  "${NOTIFY_BIN}" -e "Sound Driver" -s "Sound Driver" -d "$1" ${2:+-i "$2"}
}
start_stopped() {
  for c in ${STOPPED}; do
    docker start "${c}" >/dev/null || true
  done
}
die() {
  trap - ERR
  echo "ERROR: $*" >&2
  start_stopped
  notify "Build failed: $*" alert
  exit 1
}
trap 'die "command failed in line ${LINENO}, see /var/log/sound-driver-build.log"' ERR

# Running containers that have /dev/snd (or a device below it) passed in
snd_containers() {
  docker ps -q | while read -r id; do
    docker inspect --format '{{.Name}}{{range .HostConfig.Devices}} {{.PathOnHost}}{{end}}{{range .Mounts}} {{.Source}}{{end}}' "${id}"
  done | awk '{for (i = 2; i <= NF; i++) if ($i ~ /^\/dev\/snd/) {print substr($1, 2); break}}'
}

# Only one build at a time
exec 9>/var/run/sound-driver-build.lock
flock -n 9 || die "another build is already running"

[ -f "${UNRAID_SRC}/config" ] || die "${UNRAID_SRC}/config not found"
[ -f "${UNRAID_SRC}/System.map" ] || die "${UNRAID_SRC}/System.map not found"
command -v docker >/dev/null || die "Docker is required"
if [ "${WAIT_DOCKER}" = "1" ]; then
  until docker info >/dev/null 2>&1; do
    sleep 10
  done
fi
docker info >/dev/null 2>&1 || die "Docker is not running"

# Use the same gcc release Unraid built its kernel with
GCC_V="$(grep -oP '^CONFIG_CC_VERSION_TEXT="gcc \(GCC\) \K[0-9.]+' "${UNRAID_SRC}/config")"
GCC_IMAGE="gcc:${GCC_V}"
echo "---Pulling gcc ${GCC_V} image, this can take a while---"
docker pull -q "${GCC_IMAGE}" >/dev/null 2>&1 || GCC_IMAGE="gcc:${GCC_V%%.*}"

# kernel.org names x.y.0 releases linux-x.y
TARBALL_V="${KERNEL_V%.0}"
TARBALL="linux-${TARBALL_V}.tar.xz"

echo "---Downloading sources for ${UNAME} into ${WORK_DIR}---"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
wget -q -O "${TARBALL}" \
  "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_V%%.*}.x/${TARBALL}"
for src in "lib/alsa-lib-${ALSA_LIB_V}" "utils/alsa-utils-${ALSA_UTILS_V}" \
    "lib/alsa-ucm-conf-${ALSA_UCM_V}"; do
  wget -q "https://www.alsa-project.org/files/pub/${src}.tar.bz2"
done
tar xf "${TARBALL}"
rm "${TARBALL}"
mv "linux-${TARBALL_V}" linux
cd linux

# Apply Unraid's kernel patches and add its md driver
for p in "${UNRAID_SRC}"/*.patch; do
  patch -p1 -s < "$p"
done
if [ -d "${UNRAID_SRC}/drivers/md" ]; then
  cp -r "${UNRAID_SRC}/drivers/md/." drivers/md/
fi

# snd-intel-dspcfg selects ACPI_NHLT, which is built into vmlinux and not
# enabled in the Unraid kernel. With it the modules reference acpi_nhlt_*
# symbols that do not exist and snd-hda-intel fails to load. Without it the
# NHLT helpers fall back to the stubs in include/acpi/nhlt.h.
sed -i '/^config SND_INTEL_DSP_CONFIG/,/^config /{/select ACPI_NHLT if ACPI/d}' \
  sound/hda/core/Kconfig

cp "${UNRAID_SRC}/config" .config
cp "${UNRAID_SRC}/config" "${WORK_DIR}/unraid.config"
cp "${UNRAID_SRC}/System.map" System.map

cat > "${WORK_DIR}/sndconfig.py" <<'EOF'
#!/usr/bin/env python3
# Enable all sound drivers (except ASoC) as modules on top of Unraid's kernel
# config. Only the sound modules get built, so nothing outside of sound/ may
# change: drivers that would select something into vmlinux are disabled.
import glob, re, subprocess, sys

SKIP = re.compile(r"KUNIT|_TEST$|TEST_|DEBUG")
# Values that follow the toolchain, not the configuration
TOOLCHAIN = re.compile(r"_VERSION(_TEXT)?$|^(RUSTC|CC_HAS|CC_CAN|CC_IS|AS_HAS|AS_IS"
                       r"|LD_HAS|LD_CAN|LD_IS|PAHOLE|TOOLS_SUPPORT|GCC|CLANG)_")
END_BLOCK = {"menu", "endmenu", "choice", "endchoice", "if", "endif", "source",
             "comment", "mainmenu"}

def parse(path, syms):
    cur, help_indent = None, None
    for line in open(path, errors="replace"):
        text = line.strip()
        indent = len(line) - len(line.lstrip())
        if help_indent is not None:
            if not text or indent > help_indent:
                continue
            help_indent = None
        words = text.split()
        if not words:
            continue
        if words[0] in ("config", "menuconfig") and len(words) > 1:
            cur = syms.setdefault(words[1], {"type": None, "prompt": False,
                                             "menu": False, "selects": set(),
                                             "soc": False})
            cur["menu"] |= words[0] == "menuconfig"
            cur["soc"] |= path.startswith("sound/soc/")
        elif words[0] in END_BLOCK:
            cur = None
        elif cur is None:
            continue
        elif words[0] in ("tristate", "bool"):
            cur["type"] = words[0]
            cur["prompt"] |= len(words) > 1
        elif words[0] in ("def_tristate", "def_bool"):
            cur["type"] = words[0][4:]
        elif words[0] == "prompt":
            cur["prompt"] = True
        elif words[0] == "select" and len(words) > 1:
            cur["selects"].add(words[1])
        elif words[0] in ("help", "---help---"):
            help_indent = indent

def load(path):
    return dict(re.findall(r"^CONFIG_(\w+)=(.*)$", open(path).read(), re.M))

def run(*args):
    subprocess.run(args, check=True)

syms = {}
for path in sorted(glob.glob("sound/**/Kconfig*", recursive=True)):
    parse(path, syms)

args = []
for name, s in sorted(syms.items()):
    if s["soc"] or not s["prompt"] or SKIP.search(name):
        continue
    if s["type"] == "tristate":
        args += ["-m", name]
    elif s["type"] == "bool" and s["menu"]:
        args += ["-e", name]
run("./scripts/config", *args)

selectors = {}
for name, s in syms.items():
    for target in s["selects"]:
        selectors.setdefault(target, set()).add(name)

def selected_by(sym):
    found, todo = set(), [sym]
    while todo:
        for x in selectors.get(todo.pop(), ()):
            if x not in found:
                found.add(x)
                todo.append(x)
    return found

base = load("/work/unraid.config")
disabled = set()
for _ in range(50):
    run("make", "-s", "olddefconfig")
    new = load(".config")
    bad = sorted(s for s in set(base) | set(new)
                 if s not in syms and not TOOLCHAIN.search(s)
                 and new.get(s) != base.get(s))
    if not bad:
        break
    fix = set()
    for sym in bad:
        fix |= selected_by(sym) - disabled
    if not fix:
        sys.exit("ERROR: kernel config would change outside of sound: "
                 + ", ".join(f"{s}={new.get(s)} (Unraid: {base.get(s)})" for s in bad))
    print("Not building (would change vmlinux):", " ".join(sorted(fix)))
    disabled |= fix
    run("./scripts/config", *[a for s in sorted(fix) for a in ("-d", s)])
else:
    sys.exit("ERROR: kernel config did not settle")
EOF

cat > "${WORK_DIR}/sndcheck.py" <<'EOF'
#!/usr/bin/env python3
# Drop modules that need symbols neither the running kernel nor an installed
# non-sound module provides; they would fail to load anyway.
import glob, os, re, subprocess, sys

def nm(ko, *args):
    return subprocess.run(["nm", *args, "--format=just-symbols", ko],
                          capture_output=True, text=True, check=True).stdout

avail = set(re.findall(r"__ksymtab_(\S+)", open("System.map").read()))
for line in open("/hostmods/modules.symbols"):
    parts = line.split()
    if len(parts) == 3 and not re.match(r"snd|soundcore|ac97.bus", parts[2]):
        avail.add(parts[1].split(":", 1)[1])

mods = {}
for ko in glob.glob("sound/**/*.ko", recursive=True):
    exports = set(re.findall(r"^__ksymtab_(\S+)$", nm(ko), re.M))
    mods[ko] = (set(nm(ko, "-u").split()), exports)

skipped = {}
changed = True
while changed:
    changed = False
    provided = set().union(*(e for _, e in mods.values()))
    for ko, (undef, _) in list(mods.items()):
        missing = undef - provided - avail
        if missing:
            skipped[ko] = sorted(missing)
            del mods[ko]
            os.remove(ko)
            changed = True

for ko, missing in sorted(skipped.items()):
    print(f"Skipping {ko}: needs {', '.join(missing[:3])}")
for ko in ("sound/hda/controllers/snd-hda-intel.ko", "sound/usb/snd-usb-audio.ko"):
    if ko not in mods:
        sys.exit(f"ERROR: {ko} could not be built")
print(f"{len(mods)} modules built, {len(skipped)} skipped")
EOF

cat > "${WORK_DIR}/build.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get -qq update >/dev/null
apt-get -qq install -y bc bison flex libelf-dev libssl-dev xz-utils \
  pkg-config libncurses-dev >/dev/null

echo "---Configuring sound drivers---"
cd /work/linux
python3 /work/sndconfig.py

echo "---Compiling kernel modules---"
make -s -j"$(nproc)" modules_prepare
# Keep going if a single driver doesn't compile, the check below sorts it out
if ! make -s -k -j"$(nproc)" KBUILD_MODPOST_WARN=1 M=sound modules \
    > /work/modules.log 2>&1; then
  echo "Some modules failed to compile:"
  grep -E "error:" /work/modules.log | head -20 || true
fi
python3 /work/sndcheck.py

echo "---Compiling ALSA---"
cd /work
for f in alsa-*.tar.bz2; do
  tar xjf "${f}"
done
PKG=/work/pkg
cd /work/alsa-lib-*/
./configure -q --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc \
  --disable-static > /dev/null
make -s -j"$(nproc)" > /dev/null
# Once into the container for building alsa-utils, once into the package
make -s install > /dev/null
make -s DESTDIR="${PKG}" install > /dev/null
cd /work/alsa-utils-*/
PKG_CONFIG_PATH=/usr/lib64/pkgconfig LDFLAGS="-L/usr/lib64" \
  ./configure -q --prefix=/usr --libdir=/usr/lib64 --sysconfdir=/etc \
  --disable-alsaconf --disable-alsaloop --disable-bat --disable-xmlto \
  --disable-rst2man --with-udev-rules-dir=/tmp/drop \
  --with-systemdsystemunitdir=/tmp/drop > /dev/null
make -s -j"$(nproc)" > /dev/null
make -s DESTDIR="${PKG}" install > /dev/null
mkdir -p "${PKG}/usr/share/alsa"
cp -r /work/alsa-ucm-conf-*/ucm2 "${PKG}/usr/share/alsa/"

# Runtime files only
rm -rf "${PKG}/usr/include" "${PKG}/usr/lib64/pkgconfig" "${PKG}/usr/share/man" \
  "${PKG}/usr/share/doc" "${PKG}/usr/share/locale" "${PKG}/usr/share/aclocal" \
  "${PKG}/tmp"
find "${PKG}" -name '*.la' -delete
find "${PKG}/usr/bin" "${PKG}/usr/sbin" "${PKG}/usr/lib64" -type f \
  -exec strip --strip-unneeded {} + 2>/dev/null || true
EOF

echo "---Building in ${GCC_IMAGE}---"
docker run --rm \
  -v "${WORK_DIR}:/work" \
  -v "/lib/modules/${UNAME}:/hostmods:ro" \
  "${GCC_IMAGE}" bash /work/build.sh

grep -q '^CONFIG_ACPI_NHLT=y' .config && die "ACPI_NHLT got enabled, modules would not load"

# Assemble the package: kernel modules plus ALSA (already in pkg/)
PKG_ROOT="${WORK_DIR}/pkg"
MOD_DIR="${PKG_ROOT}/lib/modules/${UNAME}/kernel"
mkdir -p "${MOD_DIR}" "${PKG_ROOT}/install"
find sound -name '*.ko' | while read -r ko; do
  mkdir -p "${MOD_DIR}/$(dirname "${ko}")"
  xz --check=crc32 -c "${ko}" > "${MOD_DIR}/${ko}.xz"
done

cat > "${PKG_ROOT}/install/slack-desc" <<EOF
     |-----handy-ruler------------------------------------------------------|
sound: sound drivers
sound:
sound: Sound drivers for Unraid Kernel v${KERNEL_V} and ALSA ${ALSA_LIB_V},
sound: built locally by build-local.sh.
sound:
EOF

cd "${PKG_ROOT}"
makepkg -l n -c n "${WORK_DIR}/${PKG_NAME}" >/dev/null 2>&1 \
  || die "makepkg failed"

# The plugin only installs sound*-local.txz from PKG_DIR, keep just this one
mkdir -p "${PKG_DIR}"
rm -f "${PKG_DIR}"/sound*.txz "${PKG_DIR}"/sound*.txz.md5
cp "${WORK_DIR}/${PKG_NAME}" "${PKG_DIR}/"
md5sum "${PKG_DIR}/${PKG_NAME}" | awk '{print $1}' > "${PKG_DIR}/${PKG_NAME}.md5"
echo "---Package written to ${PKG_DIR}/${PKG_NAME}---"

RESULT="built"
if [ "${INSTALL}" = "1" ]; then
  echo "---Installing into the running system---"
  # Containers only see the sound devices that existed when they started, and
  # they may keep the old ones open: stop them for the swap, start them after
  STOPPED="$(snd_containers | tr '\n' ' ')"
  for c in ${STOPPED}; do
    echo "Stopping container ${c}"
    docker stop -t 10 "${c}" >/dev/null
  done
  for pkg in /var/log/packages/sound-*; do
    [ -e "${pkg}" ] && removepkg "$(basename "${pkg}")" >/dev/null
  done
  # Unload old modules; repeat since dependents have to go first
  for _ in 1 2 3 4 5; do
    for m in $(lsmod | awk '$1 ~ /^snd|^soundcore$/ {print $1}'); do
      rmmod "${m}" 2>/dev/null || true
    done
  done
  if lsmod | grep -qE '^(snd|soundcore)'; then
    die "sound modules are still in use by a process on the host"
  fi
  rm -rf "/lib/modules/${UNAME}/kernel/sound"
  installpkg "${PKG_DIR}/${PKG_NAME}" >/dev/null
  depmod -a
  udevadm control --reload
  udevadm trigger --action=add
  udevadm settle
  sleep 2
  # Reloading the modules resets the mixer, bring back the saved levels
  mkdir -p "$(dirname "${STATE}")"
  if [ -f "${STATE}" ]; then
    alsactl restore -f "${STATE}" 2>/dev/null || true
  else
    alsactl init 2>/dev/null || true
    alsactl store -f "${STATE}" 2>/dev/null || true
  fi
  # Output list for the plugin's settings page
  echo -n "$(aplay -L | grep "CARD")" > /tmp/sound_outputs
  cat /proc/asound/cards
  start_stopped
  RESULT="built and loaded"
  if [ -n "${STOPPED}" ]; then
    RESULT+=", restarted containers: ${STOPPED% }"
  fi
fi

cd /
[ "${KEEP_WORK_DIR:-0}" = "1" ] || rm -rf "${WORK_DIR}"
# The gcc image is only needed once per kernel, don't let it fill docker.img
[ "${KEEP_IMAGE:-0}" = "1" ] || docker rmi "${GCC_IMAGE}" >/dev/null 2>&1 || true
notify "Sound drivers for kernel ${UNAME} ${RESULT}."
echo "---Done---"
