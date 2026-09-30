#!/bin/bash
CFG="/boot/config/plugins/sound-driver/settings.cfg"

# Write /etc/asound.conf for the output selected on the settings page. The
# device is used as a whole (e.g. hdmi:CARD=PCH,DEV=1) behind a plug so any
# sample format and channel count works.
function apply_output(){
DEVICE="$(grep "^primary_audio_device=" "${CFG}" 2>/dev/null | cut -d '=' -f2-)"
if [ -z "${DEVICE}" ] || [ "${DEVICE}" == "empty" ]; then
  echo "# ALSA system-wide config file" > /etc/asound.conf
  return
fi
CARD="$(echo "${DEVICE}" | grep -oP 'CARD=\K[^,]+')"
cat > /etc/asound.conf <<EOF
# ALSA system-wide config file, written by the Sound Driver plugin
pcm.!default {
  type plug
  slave.pcm "${DEVICE}"
}
EOF
if [ -n "${CARD}" ]; then
  printf 'ctl.!default {\n  type hw\n  card %s\n}\n' "${CARD}" >> /etc/asound.conf
fi
}

function update_output(){
if [[ ! "${1}" =~ ^[A-Za-z0-9:=,._-]+$ ]]; then
  echo "Invalid device name: ${1}" >&2
  exit 1
fi
if [ "${1}" == "none" ]; then
  sed -i "/primary_audio_device=/c\primary_audio_device=empty" "${CFG}"
else
  sed -i "/primary_audio_device=/c\primary_audio_device=${1}" "${CFG}"
fi
apply_output
}

function get_selected_output(){
echo -n "$(grep "^primary_audio_device=" "${CFG}" | cut -d '=' -f2-)"
}

case "${1}" in
  apply_output|update_output|get_selected_output) "$@" ;;
  *) echo "Usage: $0 apply_output|update_output <device>|get_selected_output" >&2; exit 1 ;;
esac
