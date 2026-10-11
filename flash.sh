#!/usr/bin/env bash
# Write a disk image to a USB stick. Refuses anything that is not a whole
# USB disk, and refuses the disk that backs /, /boot, /efi, or /home.
set -euo pipefail

export LC_ALL=C

die() {
  printf 'error: %s\n' "$*"
  exit 1
}

check=0
do_eject=0
cancel=""
image=""
device=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=1; shift ;;
    --eject) do_eject=1; shift ;;
    --cancel)
      [[ $# -ge 2 ]] || die "missing cancel file"
      cancel=$2
      shift 2
      ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)
      if [[ -z "$image" ]]; then
        image=$1
      elif [[ -z "$device" ]]; then
        device=$1
      else
        die "unexpected argument"
      fi
      shift
      ;;
  esac
done

[[ -n "$image" && -n "$device" ]] || die "usage: flash.sh [--check] <image> <device> [--eject] [--cancel file]"

if [[ -n "$cancel" ]]; then
  case "$cancel" in
    /tmp/isoflash-*.cancel|/run/user/*/isoflash-*.cancel) ;;
    *) die "refusing cancel file path" ;;
  esac
  [[ -L "$cancel" ]] && die "refusing symlink cancel file"
  [[ -f "$cancel" ]] || die "cancel file does not exist"
fi

[[ -e "$image" ]] || die "image does not exist"
[[ -f "$image" || -L "$image" ]] || die "image is not a regular file"
image=$(realpath -e -- "$image")
[[ -f "$image" && ! -b "$image" ]] || die "image is not a regular file"
case "$image" in
  /dev/*|/sys/*|/proc/*) die "refusing to read the image from $image" ;;
esac

[[ "$device" =~ ^/dev/(sd[a-z]|nvme[0-9]+n[0-9]+)$ ]] || die "refusing device path"
[[ -b "$device" && ! -L "$device" ]] || die "device is not a block device"
[[ "$(/usr/bin/lsblk -dno TYPE -- "$device")" == "disk" ]] || die "device is not a whole disk"
[[ "$(/usr/bin/lsblk -dno TRAN -- "$device")" == "usb" ]] || die "device is not a USB disk"
[[ "$(/usr/bin/lsblk -dno RO -- "$device")" == "0" ]] || die "device is read-only"

disk_name=$(basename -- "$device")

backs_system() {
  local target src cur pk seen
  for target in / /boot /efi /home; do
    src=$(/usr/bin/findmnt -nro SOURCE -T "$target" 2>/dev/null || true)
    [[ -z "$src" ]] && continue
    cur=${src%%\[*}
    cur=${cur%% *}
    seen=" "
    while [[ -n "$cur" && "$seen" != *" $cur "* ]]; do
      seen+="$cur "
      [[ "$(basename -- "$cur")" == "$disk_name" ]] && return 0
      # -d skips holders. Without it, lsblk also prints the child and the
      # first parent name can be the device itself, which loops forever.
      pk=$(/usr/bin/lsblk -dno PKNAME -- "$cur" 2>/dev/null | awk 'NR==1 { print; exit }')
      [[ -z "$pk" || "$pk" == "$(basename -- "$cur")" ]] && break
      cur="/dev/$pk"
    done
  done
  return 1
}

if backs_system; then
  die "refusing the disk that holds the running system"
fi

img_size=$(stat -c %s -- "$image")
dev_size=$(/usr/bin/lsblk -bdno SIZE -- "$device" | awk 'NR==1 { print; exit }')
[[ "$img_size" -gt 0 ]] || die "image is empty"
[[ "$dev_size" -gt 0 ]] || die "could not read device size"
[[ "$img_size" -le "$dev_size" ]] || die "image is larger than the device (${img_size} > ${dev_size})"

if [[ "$check" -eq 1 ]]; then
  printf 'ok %s %s\n' "$img_size" "$dev_size"
  exit 0
fi

[[ "$(id -u)" -eq 0 ]] || die "root privileges are required"

cancelled() {
  local flag
  [[ -n "$cancel" && -f "$cancel" ]] || return 1
  IFS= read -r flag < "$cancel" || return 1
  [[ "$flag" == "1" ]]
}

if cancelled; then
  die "write cancelled"
fi

printf 'phase unmount\n'

# Unmount by device node. Mount paths can contain spaces, and findmnt's raw
# output escapes those spaces, which makes umount look for the wrong path.
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  if /usr/bin/findmnt -n -S "$node" >/dev/null 2>&1; then
    /usr/bin/umount -- "$node" || die "could not unmount $node"
  fi
done < <(/usr/bin/lsblk -nrpo PATH -- "$device")

while read -r src _; do
  case "$src" in
    "$device"|"${device}"[0-9]*|"${device}"p[0-9]*)
      /usr/bin/swapoff -- "$src" || die "could not disable swap on $src"
      ;;
  esac
done < /proc/swaps

if /usr/bin/lsblk -nrpo MOUNTPOINTS -- "$device" | grep -q '[^[:space:]]'; then
  die "a filesystem on the device is still mounted"
fi

if cancelled; then
  die "write cancelled"
fi

printf 'phase write\n'

exec 3< "$image" || die "could not open the image"

emit_progress() {
  local chunk=$1 part
  while IFS= read -r part || [[ -n "$part" ]]; do
    [[ "$part" =~ ([0-9]+)[[:space:]]bytes.*copied,[[:space:]]([0-9.]+)[[:space:]]s,[[:space:]](.+) ]] || continue
    printf 'progress %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  done <<< "$chunk"
  return 0
}

fifo=$(mktemp -u /tmp/isoflash-progress.XXXXXX)
mkfifo -m 600 -- "$fifo"
ddpid=""
cleanup() {
  if [[ -n "${ddpid:-}" ]]; then
    kill -TERM "$ddpid" 2>/dev/null || true
    ddpid=""
  fi
  if [[ -n "${fifo:-}" ]]; then
    rm -f -- "$fifo"
    fifo=""
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' TERM INT

# Progress updates are carriage-return delimited, so dd has to be unbuffered.
/usr/bin/stdbuf -o0 -e0 /usr/bin/dd if=/dev/fd/3 "of=$device" bs=4M conv=fsync status=progress >"$fifo" 2>&1 &
ddpid=$!
exec 4<"$fifo"

rc=0
cancelled_write=0
line=""
read_status=0
while true; do
  line=""
  if IFS= read -r -t 0.3 -d $'\r' line <&4; then
    emit_progress "$line"
  else
    read_status=$?
    [[ -n "$line" ]] && emit_progress "$line"
    if [[ "$read_status" -lt 128 ]]; then
      break
    fi
  fi
  if cancelled; then
    cancelled_write=1
    kill -TERM "$ddpid" 2>/dev/null || true
    sleep 0.3
    kill -KILL "$ddpid" 2>/dev/null || true
    break
  fi
  if ! kill -0 "$ddpid" 2>/dev/null; then
    while IFS= read -r -t 0.2 -d $'\r' line <&4; do
      emit_progress "$line"
    done
    [[ -n "${line:-}" ]] && emit_progress "$line"
    break
  fi
done

set +e
wait "$ddpid"
rc=$?
set -e
ddpid=""
exec 3<&- || true
exec 4<&- || true

if [[ "$cancelled_write" -eq 1 ]]; then
  die "write cancelled. The stick is incomplete and should be rewritten."
fi
[[ "$rc" -eq 0 ]] || die "dd failed (exit $rc)"

printf 'phase sync\n'
/usr/bin/sync
/usr/bin/blockdev --flushbufs "$device" || true

if [[ "$do_eject" -eq 1 ]]; then
  printf 'phase eject\n'
  if ! /usr/bin/eject -- "$device"; then
    /usr/bin/udisksctl power-off -b "$device" || printf 'warn: write finished, but the stick could not be powered off\n'
  fi
fi

printf 'done\n'
exit 0
