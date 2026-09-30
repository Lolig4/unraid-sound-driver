# Unraid Sound Driver plugin

This is the repository for the Sound Driver plugin.

Please use the issue tracker here on GitHub to report issues since this plugin is in development and has no Support Thread on the official Unraid Forums.

## Install

In the Unraid WebUI under **Plugins -> Install Plugin**, paste:

    https://raw.githubusercontent.com/Lolig4/unraid-sound-driver/master/sound-driver.plg

Or from a terminal:

    /usr/local/sbin/plugin install https://raw.githubusercontent.com/Lolig4/unraid-sound-driver/master/sound-driver.plg

Docker has to be enabled, the drivers are built in a container. The first build
starts right after the install and takes a few minutes; you get a notification
once the sound card is available. The output device can be picked under
**Utilities -> Sound-Driver**.

## How the drivers get built

The plugin builds the sound drivers on your server against the running Unraid
kernel (same kernel source, patches, config and gcc version as Unraid) instead of
downloading prebuilt packages. This needs Docker.

When no package exists for the current kernel yet (first install, or after an
Unraid update that changed the kernel), the build starts in the background as
soon as Docker is running. You get a notification when the drivers are loaded;
the log is in `/var/log/sound-driver-build.log`. The package is kept in
`/boot/config/plugins/sound-driver/packages/<kernel>/` and installed from there
on every boot.

To rebuild manually:

```
bash /boot/config/plugins/sound-driver/build-local-*.sh --install
```
