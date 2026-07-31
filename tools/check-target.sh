#!/bin/sh
# check-target.sh - pre-flight a prepared root filesystem before you pull the boot medium.
#
#   sudo ./tools/check-target.sh /mnt/ssdroot
#
# READ ONLY. Checks the things that, if wrong, mean the machine will not come back:
# self-consistent UUIDs, rootwait in both places, kernel/initramfs/DTB present, clean
# mountpoints, SSH access, and whether the PCIe boot fix is installed.
#
# https://github.com/Mojo24x7/rock3a-sata-ssd-boot
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

T="${1:-}"
[ -n "$T" ] || { echo "usage: $0 /path/to/mounted/target/root" >&2; exit 2; }
# strip a trailing slash, but never turn "/" into ""
[ "$T" != "/" ] && T="${T%/}"
[ -d "$T" ] || { echo "$T is not a directory" >&2; exit 2; }
mountpoint -q "$T" || echo "note: $T is not a mountpoint - is the target actually mounted?"

pass=0; warn=0; fail=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; pass=$((pass+1)); }
wrn()  { printf '  \033[33mwarn\033[0m  %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=$((fail+1)); }
head_(){ printf '\n== %s\n' "$*"; }

SRC_DEV=$(findmnt -n -o SOURCE / 2>/dev/null)
TGT_DEV=$(findmnt -n -o SOURCE --target "$T" 2>/dev/null)
echo "target root : $T  ($TGT_DEV)"
echo "running from: $SRC_DEV"
[ "$SRC_DEV" = "$TGT_DEV" ] && { echo; bad "target is the running root - nothing to check"; exit 1; }

TGT_UUID=$(blkid -s UUID -o value "$TGT_DEV" 2>/dev/null)
SRC_UUID=$(blkid -s UUID -o value "$SRC_DEV" 2>/dev/null)

head_ "1. filesystem identity"
if [ -n "$TGT_UUID" ] && [ "$TGT_UUID" != "$SRC_UUID" ]; then
  ok "target root UUID is unique ($TGT_UUID)"
else
  bad "target root UUID missing or identical to the source - root= will be ambiguous"
fi

head_ "2. /etc/fstab names the target's own devices"
FSTAB="$T/etc/fstab"
if [ -r "$FSTAB" ]; then
  if grep -q "$TGT_UUID" "$FSTAB"; then ok "fstab references the target root UUID"
  else bad "fstab does NOT reference $TGT_UUID"; fi
  if [ -n "$SRC_UUID" ] && grep -q "$SRC_UUID" "$FSTAB"; then
    bad "fstab still references the SOURCE root UUID $SRC_UUID"
  else ok "no source root UUID left in fstab"; fi
  # every UUID in fstab must exist somewhere
  for u in $(grep -oE 'UUID=[-0-9A-Fa-f]+' "$FSTAB" | cut -d= -f2); do
    if blkid -U "$u" >/dev/null 2>&1 || blkid | grep -qi "\"$u\""; then ok "fstab UUID $u resolves"
    else bad "fstab UUID $u does not exist on any attached device"; fi
  done
else
  bad "no $FSTAB"
fi

head_ "3. boot entry"
EXT="$T/boot/extlinux/extlinux.conf"
if [ -r "$EXT" ]; then
  grep -q "root=UUID=$TGT_UUID" "$EXT" && ok "extlinux root= is the target UUID" \
    || bad "extlinux root= is not $TGT_UUID"
  [ -n "$SRC_UUID" ] && grep -q "$SRC_UUID" "$EXT" \
    && bad "extlinux still references the SOURCE UUID" \
    || ok "no source UUID in extlinux"
  grep -q 'rootwait' "$EXT" && ok "rootwait present in the boot entry" \
    || bad "rootwait MISSING from the boot entry - a late disk will not be waited for"
  L=$(grep -oE 'linux +[^ ]+' "$EXT" | head -1 | awk '{print $2}')
  I=$(grep -oE 'initrd +[^ ]+' "$EXT" | head -1 | awk '{print $2}')
  D=$(grep -oE 'fdtdir +[^ ]+' "$EXT" | head -1 | awk '{print $2}')
  [ -n "$L" ] && { [ -e "$T$L" ] && ok "kernel exists: $L" || bad "kernel MISSING: $L"; }
  [ -n "$I" ] && { [ -e "$T$I" ] && ok "initramfs exists: $I" || bad "initramfs MISSING: $I"; }
  if [ -n "$D" ]; then
    [ -d "$T$D" ] && ok "fdtdir exists: $D" || bad "fdtdir MISSING: $D"
    ls "$T$D"/*/*.dtb >/dev/null 2>&1 && ok "device trees present under fdtdir" \
      || wrn "no .dtb found under $D"
  fi
  for o in $(grep -oE 'fdtoverlays +.*' "$EXT" | head -1 | sed 's/fdtoverlays *//'); do
    [ -e "$T$o" ] && ok "overlay exists: $o" || bad "overlay MISSING: $o"
  done
else
  bad "no $EXT"
fi

head_ "4. rootwait is durable (survives u-boot-update)"
CL="$T/etc/kernel/cmdline"
if [ -r "$CL" ]; then
  grep -q 'rootwait' "$CL" && ok "rootwait in /etc/kernel/cmdline" \
    || bad "rootwait NOT in /etc/kernel/cmdline - a kernel upgrade will drop it and the machine will stop booting"
  grep -q 'root=' "$CL" && wrn "root= is hardcoded in /etc/kernel/cmdline (u-boot-update normally derives it)" \
    || ok "no hardcoded root= in cmdline"
else
  wrn "no $CL - your bootloader config may be maintained by hand"
fi
UB="$T/etc/default/u-boot"
[ -r "$UB" ] && { grep -q '^U_BOOT_FDT_OVERLAYS' "$UB" \
  && ok "U_BOOT_FDT_OVERLAYS set (overlays survive regeneration)" \
  || wrn "U_BOOT_FDT_OVERLAYS not set - regenerating the boot entry may drop your overlays"; }

head_ "5. clean mountpoints (a copy that included /proc etc. will misbehave)"
for d in proc sys dev run tmp; do
  if [ -d "$T/$d" ]; then
    n=$(ls -A "$T/$d" 2>/dev/null | wc -l)
    [ "$n" -eq 0 ] && ok "/$d is an empty mountpoint" || wrn "/$d contains $n entries"
  else
    bad "/$d does not exist on the target"
  fi
done

head_ "6. you will be able to log in"
K=0
for f in "$T"/home/*/.ssh/authorized_keys "$T/root/.ssh/authorized_keys"; do
  [ -r "$f" ] || continue
  c=$(grep -c '^ssh-' "$f" 2>/dev/null || echo 0)
  [ "$c" -gt 0 ] && { ok "$c SSH key(s) in ${f#$T}"; K=$((K+c)); }
done
[ "$K" -gt 0 ] || wrn "no SSH authorized_keys found - make sure you can log in some other way"
[ -e "$T/etc/systemd/system/multi-user.target.wants/ssh.service" ] \
  || [ -e "$T/etc/systemd/system/sshd.service" ] \
  && ok "ssh enabled at boot" || wrn "ssh may not be enabled at boot"

head_ "7. PCIe boot fix installed"
IT="$T/etc/initramfs-tools"
for f in scripts/local-block/pcie-sbr scripts/init-premount/pcie-sbr-net \
         scripts/panic/pcie-sbr-diag hooks/pcie-sbr; do
  [ -x "$IT/$f" ] && ok "$f" || bad "$f missing (run install.sh --root $T)"
done
[ -r "$T/etc/default/pcie-sbr-boot" ] && ok "config present" || wrn "no /etc/default/pcie-sbr-boot"
grep -q '^BUSYBOX=y' "$IT/initramfs.conf" 2>/dev/null && ok "BUSYBOX=y" \
  || bad "BUSYBOX=y not set - the initramfs will lack nc/dd/udhcpc"
if [ -n "${I:-}" ] && [ -e "$T$I" ] && command -v lsinitramfs >/dev/null 2>&1; then
  for w in scripts/local-block/pcie-sbr etc/pcie-sbr-boot.conf bin/busybox bin/dd; do
    lsinitramfs "$T$I" 2>/dev/null | grep -q "$w" && ok "in initramfs: $w" \
      || bad "NOT in initramfs: $w - regenerate it"
  done
fi

head_ "8. disk sizing"
if [ -n "$TGT_DEV" ]; then
  sz=$(df -h "$T" | tail -1 | awk '{print $2}')
  ok "target root filesystem size: $sz"
  case "$TGT_DEV" in
    *[0-9]) base=$(echo "$TGT_DEV" | sed 's/[0-9]*$//') ;;
    *) base="$TGT_DEV" ;;
  esac
  if [ -b "$base" ]; then
    free=$(sgdisk -p "$base" 2>/dev/null | grep -i 'free space' | head -1)
    [ -n "$free" ] && echo "        $free"
  fi
fi

printf '\n===== %d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
if [ "$fail" -gt 0 ]; then
  echo "Fix the failures before removing your current boot medium."
  exit 1
fi
[ "$warn" -gt 0 ] && echo "No blockers, but review the warnings." || echo "Looks ready."
exit 0
