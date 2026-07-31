#!/bin/sh
# pcie-relink.sh - recover full PCIe link speed AFTER the system is up.
#
#   sudo ./tools/pcie-relink.sh            # report only
#   sudo ./tools/pcie-relink.sh --apply    # actually retrain
#
# WHY THIS IS NOT IN THE INITRAMFS
# A Secondary Bus Reset leaves the link at Gen1: both ends advertise more and Link
# Control 2 already targets the maximum, but nothing performs the rate change. Setting
# the Retrain Link bit fixes that - but doing it from the initramfs, before the root
# filesystem is mounted, was measured to STALL THE BOOT on a ROCK 3A: the link goes
# down during the retrain and the machine never recovers, with no console and no logs.
#
# Run it here instead. If the retrain misbehaves you still have a running system, logs
# and SSH, and a restart puts you back to a working (if Gen1) state.
#
# ⚠️ It still resets the link your disks are on. Quiesce them first: stop services,
#    unmount what you can, `sync`. Do not run this on a busy array.
#
# https://github.com/Mojo24x7/rock3a-sata-ssd-boot
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

APPLY=no
[ "${1:-}" = "--apply" ] && APPLY=yes
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }

rdb(){ dd if="$1" bs=1 skip="$2" count=1 2>/dev/null | od -An -tu1 | tr -d ' \n'; }
wrb(){ printf "\\$(printf '%03o' "$3")" | dd of="$1" bs=1 seek="$2" count=1 conv=notrunc 2>/dev/null; }

pcie_cap(){
  cfg=/sys/bus/pci/devices/$1/config
  [ -r "$cfg" ] || return 1
  sr=$(rdb "$cfg" 6); case "$sr" in ''|*[!0-9]*) return 1 ;; esac
  [ $((sr & 16)) -ne 0 ] || return 1
  ptr=$(rdb "$cfg" 52); case "$ptr" in ''|*[!0-9]*) return 1 ;; esac
  ptr=$((ptr & 252)); i=0
  while [ "$ptr" -gt 0 ] && [ "$ptr" -ne 255 ] && [ "$i" -lt 48 ]; do
    cid=$(rdb "$cfg" "$ptr"); case "$cid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$cid" -eq 16 ] && { echo "$ptr"; return 0; }
    nx=$(rdb "$cfg" $((ptr + 1))); case "$nx" in ''|*[!0-9]*) return 1 ;; esac
    ptr=$((nx & 252)); i=$((i + 1))
  done
  return 1
}

echo "=== current link state"
degraded=""
for d in /sys/bus/pci/devices/*; do
  cur=$(cat "$d/current_link_speed" 2>/dev/null) || continue
  max=$(cat "$d/max_link_speed" 2>/dev/null)
  w=$(cat "$d/current_link_width" 2>/dev/null)
  b=$(basename "$d")
  cls=$(cat "$d/class" 2>/dev/null)
  if [ "$cur" = "$max" ]; then
    printf "  %s  %s x%s  (at max)\n" "$b" "$cur" "$w"
  else
    printf "  %s  %s x%s  (max %s)  <- DEGRADED  class=%s\n" "$b" "$cur" "$w" "$max" "$cls"
    case "$cls" in 0x0604*) degraded="$degraded $b" ;; esac      # only bridges can retrain
  fi
done

if [ -z "$degraded" ]; then
  echo; echo "Nothing to do - no degraded bridge found."
  exit 0
fi

echo
echo "=== bridges that would be retrained:$degraded"
for b in $degraded; do
  cap=$(pcie_cap "$b") || { echo "  $b: no PCIe capability"; continue; }
  cfg=/sys/bus/pci/devices/$b/config
  lc=$((cap + 16))
  printf "  %s  cap=0x%02X  LinkCtl=0x%02X  current value=%s\n" "$b" "$cap" "$lc" "$(rdb "$cfg" "$lc")"
done

if [ "$APPLY" != yes ]; then
  echo
  echo "Report only. Re-run with --apply to retrain."
  echo "⚠️  This resets the link your disks sit on. Quiesce them first."
  exit 0
fi

echo
echo "=== applying (sync first)"
sync
for b in $degraded; do
  cap=$(pcie_cap "$b") || continue
  cfg=/sys/bus/pci/devices/$b/config
  lc=$((cap + 16))
  cur=$(rdb "$cfg" "$lc")
  case "$cur" in ''|*[!0-9]*) echo "  $b: LinkControl unreadable, skipping"; continue ;; esac
  echo "  $b: setting Retrain Link (bit 5)"
  wrb "$cfg" "$lc" $((cur | 32))
  sleep 3
  echo "  $b: now $(cat "/sys/bus/pci/devices/$b/current_link_speed" 2>/dev/null)"
done

echo
echo "=== after"
for d in /sys/bus/pci/devices/*; do
  cur=$(cat "$d/current_link_speed" 2>/dev/null) || continue
  max=$(cat "$d/max_link_speed" 2>/dev/null)
  printf "  %s  %s  (max %s)  %s\n" "$(basename "$d")" "$cur" "$max" \
    "$([ "$cur" = "$max" ] && echo '*** AT MAX ***' || echo 'still degraded')"
done
echo
echo "Check your disks are still healthy:  lsblk ; dmesg | tail -20"
