#!/bin/bash

function update_output(){
if [ "${1}" == "none" ]; then
  sed -i "/primary_audio_device=/c\primary_audio_device=empty" "/boot/config/plugins/sound-driver/settings.cfg"
  echo -n "# ALSA system-wide config file" > /etc/asound.conf
else
  sed -i "/primary_audio_device=/c\primary_audio_device=${1}" "/boot/config/plugins/sound-driver/settings.cfg"
  sleep 1
  echo -n "pcm."\!"default $(cat /boot/config/plugins/sound-driver/settings.cfg | cut -d '=' -f2 | cut -d ':' -f1):$(cat /boot/config/plugins/sound-driver/settings.cfg | cut -d '=' -f3 | cut -d ',' -f1)" > /etc/asound.conf
fi
}

function get_selected_output(){
echo -n "$(cat /boot/config/plugins/sound-driver/settings.cfg | grep "primary_audio_device" | cut -d '=' -f2-)"
}

$@
