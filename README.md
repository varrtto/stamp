# Stamp

Stamp writes a disk image to a USB stick. The whole stick is erased. Internal disks are not listed.

The window is a [Quickshell](https://quickshell.org/) app. It follows your current Omarchy theme. Writing goes through `pkexec`, so the window itself stays unprivileged.

Site: [varrtto.github.io/stamp](https://varrtto.github.io/stamp/)

## Requirements

- [Quickshell](https://quickshell.org/) (`qs`). Omarchy already includes it.
- `polkit`, for the authorization dialog.
- `file`, so the window can describe the image.
- `udisks2` is optional. Stamp uses it when powering the stick off needs a second try.

## Run from this directory

```sh
qs -p .
```

## Install on Arch

The `packaging` directory contains a `PKGBUILD`. It installs the `stamp-usb` command and a Stamp entry in the application menu.

```sh
cd packaging
makepkg -si
```

`makepkg` downloads the v0.1.0 source archive from GitHub and checks its hash before installing.

## How it is built

`shell.qml` is the window. It lists whole USB disks with `lsblk`, asks you to type the device name, and then starts the write.

`flash.sh` is the only part that opens the disk. It refuses anything that is not a whole writable USB disk, refuses the disk that holds `/`, `/boot`, `/efi`, or `/home`, and refuses an image larger than the stick. It then unmounts the stick, copies the image with `dd`, syncs, and can power the stick off.

## License

[MIT](LICENSE)
