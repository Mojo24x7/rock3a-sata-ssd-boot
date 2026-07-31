#!/bin/sh
# verify-live.sh - check a RUNNING system's boot configuration is still intact.
#
#   sudo ./tools/verify-live.sh
#
# Run this AFTER a kernel upgrade, after `rsetup`, or after anything that regenerates
# the initramfs or the boot entry - and BEFORE you reboot. On a machine whose only boot
# medium is the disk this fix rescues, a broken initramfs means physical recovery.
#
# READ ONLY. Exits non-zero if something would stop the machine coming back.
#
# https://github.com/Mojo24x7/rock3a-sata-ssd-boot
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

pass=0; warn=0; fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; pass=$((pass+1)); }
wrn()  { printf '  \033[33mwarn\033[0m  %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
head_(){ printf '\n== %s\n' "$*"; }

EXT=/boot/extlinux/extlinux.conf
CL=/etc/kernel/cmdline
IT=/etc/initramfs-tools
ROOTDEV=$(findmnt -n -o SOURCE / 2>/dev/null)
ROOTUUID=$(blkid -s UUID -o value "$ROOTDEV" 2>/dev/null)

echo "running root : $ROOTDEV  (UUID=$ROOTUUID)"
echo "running kernel: $(uname -r)"

head_ "1. boot entry references the running root"
if [ -r "$EXT" ]; then
  if [ -n "$ROOTUUID" ] && grep -q "root=UUID=$ROOTUUID" "$EXT"; then
    ok "extlinux root= matches the running root UUID"
  elif grep -q "root=$ROOTDEV" "$EXT"; then
    wrn "extlinux uses root=$ROOTDEV (device name, not UUID) - fragile if disks reorder"
  else
    bad "extlinux does not reference the running root ($ROOTUUID)"
    grep -oE 'root=[^ ]+' "$EXT" | sort -u | sed 's/^/        found: /'
  fi
else
  bad "no $EXT - is this a u-boot-menu/extlinux system?"
fi

head_ "2. rootwait — the single load-bearing option"
n=$(grep -c 'rootwait' "$EXT" 2>/dev/null || echo 0)
[ "$n" -gt 0 ] && ok "rootwait present in $n boot entr$([ "$n" = 1 ] && echo y || echo ies)" \
               || bad "rootwait MISSING from the boot entry - a late-appearing disk will not be waited for"
if [ -r "$CL" ]; then
  grep -q 'rootwait' "$CL" && ok "rootwait in $CL (survives u-boot-update)" \
    || bad "rootwait NOT in $CL - the next regeneration will DROP it"
else
  wrn "no $CL - boot entry may be maintained by hand"
fi

head_ "3. every boot entry points at files that exist"
if [ -r "$EXT" ]; then
  for f in $(grep -oE '^[[:space:]]*linux[[:space:]]+[^ ]+' "$EXT" | awk '{print $2}' | sort -u); do
    [ -e "$f" ] && ok "kernel $f" || bad "kernel MISSING $f"
  done
  for f in $(grep -oE '^[[:space:]]*initrd[[:space:]]+[^ ]+' "$EXT" | awk '{print $2}' | sort -u); do
    [ -e "$f" ] && ok "initramfs $f" || bad "initramfs MISSING $f"
  done
  for d in $(grep -oE '^[[:space:]]*fdtdir[[:space:]]+[^ ]+' "$EXT" | awk '{print $2}' | sort -u); do
    [ -d "$d" ] && ok "fdtdir $d" || bad "fdtdir MISSING $d"
  done
  for f in $(grep -oE '/boot/dtbo/[^ ]+\.dtbo' "$EXT" | sort -u); do
    [ -e "$f" ] && ok "overlay $f" || bad "overlay MISSING $f - this WILL fail to boot"
  done
fi

head_ "4. the fix is installed and version-independent"
# tolerate both the packaged hook names and the original hand-written ones
LEGACY=no
[ -x "$IT/scripts/local-block/aa-rkrescan" ] && LEGACY=yes
if [ "$LEGACY" = yes ]; then
  wrn "legacy hook layout detected (aa-rkrescan/aa-rknet/zz-rkdiag) - works, but the"
  wrn "  packaged version cycles its recovery steps and is more reliable; consider install.sh"
  for f in scripts/local-block/aa-rkrescan; do
    [ -x "$IT/$f" ] && ok "$f (required)" || bad "$f missing"
  done
  for f in scripts/init-premount/aa-rknet scripts/panic/zz-rkdiag; do
    [ -x "$IT/$f" ] && ok "$f (optional)" || wrn "$f absent (diagnostics only)"
  done
else
  for f in scripts/local-block/pcie-sbr; do
    [ -x "$IT/$f" ] && ok "$f (required)" || bad "$f missing - run install.sh"
  done
  for f in scripts/init-premount/pcie-sbr-net scripts/panic/pcie-sbr-diag hooks/pcie-sbr; do
    [ -x "$IT/$f" ] && ok "$f" || wrn "$f absent (diagnostics/config only, not boot-critical)"
  done
fi
grep -q '^BUSYBOX=y' "$IT/initramfs.conf" 2>/dev/null && ok "BUSYBOX=y in initramfs.conf" \
  || bad "BUSYBOX=y not set - regenerating the initramfs will drop nc/od/udhcpc"

head_ "5. busybox is installed and not about to be removed"
if command -v busybox >/dev/null 2>&1; then
  ok "busybox present ($(busybox --help 2>&1 | head -1 | cut -c1-40))"
  if command -v apt-mark >/dev/null 2>&1; then
    apt-mark showhold 2>/dev/null | grep -qx busybox \
      && ok "busybox is held (apt cannot remove it silently)" \
      || wrn "busybox is not held - consider: sudo apt-mark hold busybox"
  fi
else
  bad "busybox NOT installed - the reset path needs 'od', which klibc does not provide"
fi

head_ "6. EVERY installed initramfs contains the fix"
# after a kernel upgrade there will be more than one; the newest is what boots
for img in /boot/initrd.img-*; do
  case "$img" in *.bak*|*WORKING*|*.old) continue ;; esac
  [ -e "$img" ] || continue
  miss=""
  for w in scripts/local-block/ bin/busybox bin/od bin/dd; do
    lsinitramfs "$img" 2>/dev/null | grep -q "$w" || miss="$miss $w"
  done
  # the hook may carry either name
  lsinitramfs "$img" 2>/dev/null | grep -qE 'local-block/(pcie-sbr|aa-rkrescan)' \
    || miss="$miss local-block/pcie-sbr"
  if [ -z "$miss" ]; then ok "$(basename "$img") complete"
  else bad "$(basename "$img") is MISSING:$miss"; fi
done

head_ "7. which recovery step the last boot needed (informational)"
if [ -r /run/pcie-sbr.log ]; then
  grep -E 'SECONDARY BUS RESET|TARGET PRESENT|step' /run/pcie-sbr.log | tail -5 | sed 's/^/        /'
  grep -q 'TARGET PRESENT' /run/pcie-sbr.log \
    && ok "the fix was exercised on this boot and worked" \
    || wrn "no 'TARGET PRESENT' line - the disk may have appeared without help"
elif [ -r /run/rkdiag.log ]; then
  grep -E 'SECONDARY BUS RESET|TARGET NOW EXISTS|step' /run/rkdiag.log | tail -5 | sed 's/^/        /'
  ok "legacy log present (/run/rkdiag.log)"
else
  wrn "no /run/pcie-sbr.log - either the hook did not run, or the disk needed no help"
fi

head_ "8. rescue paths"
n=0
for img in /boot/initrd.img-*WORKING*; do [ -e "$img" ] && { ok "known-good initramfs kept: $(basename "$img")"; n=$((n+1)); }; done
[ "$n" -gt 0 ] || wrn "no *WORKING* initramfs backup - consider: cp /boot/initrd.img-\$(uname -r){,.WORKING}"
for img in /boot/initrd.img-*.bak*; do
  [ -e "$img" ] || continue
  wrn "$(basename "$img") is an OLD backup - it may PREDATE the fix and not boot"
done
if lsblk -no NAME 2>/dev/null | grep -q mmcblk; then
  ok "an SD/eMMC device is present - possible fallback boot medium"
else
  wrn "no SD/eMMC present - this disk is the ONLY boot medium, so do not reboot on a FAIL"
fi

printf '\n===== %d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
if [ "$fail" -gt 0 ]; then
  echo "DO NOT REBOOT until these are fixed - the machine may not come back."
  exit 1
fi
[ "$warn" -gt 0 ] && echo "Safe to reboot, but review the warnings." || echo "Safe to reboot."
exit 0
