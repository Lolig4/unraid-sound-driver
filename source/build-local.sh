#!/bin/bash
# Build the sound driver package on the Unraid server itself, against the
# running kernel, and place it where the plugin picks it up on boot.
#
# Needs Docker (the kernel is built inside a gcc container matching the
# compiler Unraid used) and a few GB of free space in WORK_DIR.
#
# Usage: build-local.sh [--install] [--wait-docker] [--notify]
#   --install      also swap the new modules into the running system
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

# Sound options enabled on top of the stock Unraid config. Everything else of
# the kernel config stays untouched, so the modules match the running vmlinux.
SND_OPTS=(
  SND_HDA_INTEL SND_HDA_CODEC_GENERIC
  SND_HDA_CODEC_REALTEK SND_HDA_CODEC_ALC260 SND_HDA_CODEC_ALC262
  SND_HDA_CODEC_ALC268 SND_HDA_CODEC_ALC269 SND_HDA_CODEC_ALC662
  SND_HDA_CODEC_ALC680 SND_HDA_CODEC_ALC861 SND_HDA_CODEC_ALC861VD
  SND_HDA_CODEC_ALC880 SND_HDA_CODEC_ALC882
  SND_HDA_CODEC_HDMI SND_HDA_CODEC_HDMI_GENERIC SND_HDA_CODEC_HDMI_INTEL
  SND_HDA_CODEC_CONEXANT SND_HDA_CODEC_CIRRUS SND_HDA_CODEC_VIA
  SND_HDA_CODEC_IDT SND_HDA_CODEC_CA0132 SND_HDA_CODEC_SIGMATEL
  SND_USB_AUDIO SND_ALOOP SND_DUMMY
)

notify() {
  [ "${NOTIFY}" = "1" ] && [ -x "${NOTIFY_BIN}" ] || return 0
  "${NOTIFY_BIN}" -e "Sound Driver" -s "Sound Driver" -d "$1" ${2:+-i "$2"}
}
die() { echo "ERROR: $*" >&2; notify "Build failed: $*" alert; exit 1; }
trap 'die "command failed in line ${LINENO}, see /var/log/sound-driver-build.log"' ERR

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
docker pull -q "${GCC_IMAGE}" >/dev/null 2>&1 || GCC_IMAGE="gcc:${GCC_V%%.*}"

# kernel.org names x.y.0 releases linux-x.y
TARBALL_V="${KERNEL_V%.0}"
TARBALL="linux-${TARBALL_V}.tar.xz"

echo "---Building sound modules for ${UNAME} with ${GCC_IMAGE} in ${WORK_DIR}---"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"
wget -q --show-progress -O "${TARBALL}" \
  "https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_V%%.*}.x/${TARBALL}"
tar xf "${TARBALL}"
rm "${TARBALL}"
mv "linux-${TARBALL_V}" linux
cd linux

# Apply Unraid's kernel patches and add its md driver
for p in "${UNRAID_SRC}"/*.patch; do
  patch -p1 -s < "$p"
done
[ -d "${UNRAID_SRC}/drivers/md" ] && cp -r "${UNRAID_SRC}/drivers/md/." drivers/md/

# snd-intel-dspcfg selects ACPI_NHLT, which is built into vmlinux and not
# enabled in the Unraid kernel. With it the modules reference acpi_nhlt_*
# symbols that do not exist and snd-hda-intel fails to load. Without it the
# NHLT helpers fall back to the stubs in include/acpi/nhlt.h.
sed -i '/^config SND_INTEL_DSP_CONFIG/,/^config /{/select ACPI_NHLT if ACPI/d}' \
  sound/hda/core/Kconfig

cp "${UNRAID_SRC}/config" .config
cp "${UNRAID_SRC}/System.map" System.map
CONFIG_ARGS=""
for opt in "${SND_OPTS[@]}"; do
  CONFIG_ARGS+=" -m ${opt}"
done

docker run --rm \
  -v "${WORK_DIR}/linux:/linux" \
  -v "/lib/modules/${UNAME}:/hostmods:ro" \
  -w /linux "${GCC_IMAGE}" bash -euo pipefail -c "
    apt-get -qq update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get -qq install -y bc bison flex libelf-dev libssl-dev xz-utils >/dev/null
    ./scripts/config ${CONFIG_ARGS}
    make -s olddefconfig
    make -s -j\$(nproc) modules_prepare
    make -s -j\$(nproc) KBUILD_MODPOST_WARN=1 M=sound modules 2>&1 | grep -v 'undefined!' || true
    [ -f sound/hda/controllers/snd-hda-intel.ko ]

    # Every symbol the modules need must be exported by the running kernel
    # or by a non-sound module that is already installed on Unraid.
    find sound -name '*.ko' | xargs nm -u --format=just-symbols | sort -u > /tmp/undef
    find sound -name '*.ko' | xargs nm --defined-only --format=just-symbols | sort -u > /tmp/def
    { grep -oP '__ksymtab_\K\S+' System.map
      grep -vE ' (snd[_-]|soundcore)' /hostmods/modules.symbols | awk '{sub(\"symbol:\", \"\", \$2); print \$2}'
    } | sort -u > /tmp/avail
    comm -23 /tmp/undef /tmp/def | comm -23 - /tmp/avail > /tmp/missing
    if [ -s /tmp/missing ]; then
      echo 'Unresolved symbols:'; cat /tmp/missing; exit 1
    fi

    chown -R $(id -u):$(id -g) sound
  "

grep -q '^CONFIG_ACPI_NHLT=y' .config && die "ACPI_NHLT got enabled, modules would not load"

# Assemble the package: our modules plus the prebuilt ALSA userland
PKG_ROOT="${WORK_DIR}/pkg"
MOD_DIR="${PKG_ROOT}/lib/modules/${UNAME}/kernel"
mkdir -p "${MOD_DIR}" "${PKG_ROOT}/install"
find sound -name '*.ko' | while read -r ko; do
  mkdir -p "${MOD_DIR}/$(dirname "${ko}")"
  xz --check=crc32 -c "${ko}" > "${MOD_DIR}/${ko}.xz"
done

# Source: https://github.com/ich777/alsa-custom
ALSA_V="$(curl -s https://api.github.com/repos/ich777/alsa-custom/releases/latest | jq -r '.tag_name')"
wget -q -O "${WORK_DIR}/alsa.tar.gz" \
  "https://github.com/ich777/alsa-custom/releases/download/${ALSA_V}/alsa-${ALSA_V}.tar.gz"
tar -C "${PKG_ROOT}" -xf "${WORK_DIR}/alsa.tar.gz"

cat > "${PKG_ROOT}/install/slack-desc" <<EOF
     |-----handy-ruler------------------------------------------------------|
sound: sound drivers
sound:
sound: Sound driver package for Unraid Kernel v${KERNEL_V},
sound: built locally by build-local.sh.
sound:
EOF

cd "${PKG_ROOT}"
makepkg -l n -c n "${WORK_DIR}/${PKG_NAME}" >/dev/null 2>&1 \
  || die "makepkg failed"

# The plugin installs every sound*.txz in PKG_DIR, so keep only ours
mkdir -p "${PKG_DIR}"
rm -f "${PKG_DIR}"/sound*.txz "${PKG_DIR}"/sound*.txz.md5
cp "${WORK_DIR}/${PKG_NAME}" "${PKG_DIR}/"
md5sum "${PKG_DIR}/${PKG_NAME}" | awk '{print $1}' > "${PKG_DIR}/${PKG_NAME}.md5"
echo "---Package written to ${PKG_DIR}/${PKG_NAME}---"

if [ "${INSTALL}" = "1" ]; then
  echo "---Installing into the running system---"
  for pkg in /var/log/packages/sound-*; do
    [ -e "${pkg}" ] && removepkg "$(basename "${pkg}")" >/dev/null
  done
  # Unload old modules; repeat since dependents have to go first
  for _ in 1 2 3 4 5; do
    for m in $(lsmod | awk '$1 ~ /^snd|^soundcore$/ {print $1}'); do
      rmmod "${m}" 2>/dev/null || true
    done
  done
  lsmod | grep -qE '^(snd|soundcore)' && die "sound modules still in use (stop containers using /dev/snd first)"
  rm -rf "/lib/modules/${UNAME}/kernel/sound"
  installpkg "${PKG_DIR}/${PKG_NAME}" >/dev/null
  depmod -a
  udevadm control --reload
  udevadm trigger --action=add
  sleep 3
  # Reloading the modules resets the mixer, bring back the saved levels
  if [ -f "${STATE}" ]; then
    alsactl restore -f "${STATE}" 2>/dev/null || true
  else
    mkdir -p "$(dirname "${STATE}")"
    alsactl store -f "${STATE}" 2>/dev/null || true
  fi
  # Output list for the plugin's settings page
  echo -n "$(aplay -L | grep "CARD")" > /tmp/sound_outputs
  cat /proc/asound/cards
fi

cd /
[ "${KEEP_WORK_DIR:-0}" = "1" ] || rm -rf "${WORK_DIR}"
# The gcc image is only needed once per kernel, don't let it fill docker.img
[ "${KEEP_IMAGE:-0}" = "1" ] || docker rmi "${GCC_IMAGE}" >/dev/null 2>&1 || true
notify "Sound drivers for kernel ${UNAME} built$( [ "${INSTALL}" = "1" ] && echo " and loaded")."
echo "---Done---"
