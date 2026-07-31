#!/bin/bash
# install.sh - install the initramfs PCIe Secondary-Bus-Reset boot fix.
#
#   sudo ./install.sh                                   install onto the running system
#   sudo ./install.sh --root /mnt/ssdroot                install onto another root
#   sudo ./install.sh --root /mnt/ssdroot --kernel 5.10.160-12-rk356x
#   sudo ./install.sh --uninstall
#
# https://github.com/Mojo24x7/rock3a-sata-ssd-boot
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT=""
KVER=""
UNINSTALL=no

while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="${2%/}"; shift 2 ;;
    --kernel)    KVER="$2";     shift 2 ;;
    --uninstall) UNINSTALL=yes; shift ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" = "0" ] || { echo "must run as root" >&2; exit 1; }
[ -z "$KVER" ] && KVER="$(uname -r)"

IT="$ROOT/etc/initramfs-tools"
[ -d "$IT" ] || { echo "no $IT - is initramfs-tools installed on that root?" >&2; exit 1; }
[ -f "$ROOT/boot/vmlinuz-$KVER" ] || echo "warning: $ROOT/boot/vmlinuz-$KVER not found"

say(){ printf '\n== %s\n' "$*"; }

if [ "$UNINSTALL" = yes ]; then
  say "removing hooks"
  rm -fv "$IT/scripts/local-block/pcie-sbr" \
         "$IT/scripts/init-premount/pcie-sbr-net" \
         "$IT/scripts/panic/pcie-sbr-diag" \
         "$IT/hooks/pcie-sbr" || true
  say "regenerating initramfs for $KVER"
  if [ -n "$ROOT" ]; then chroot "$ROOT" update-initramfs -u -k "$KVER"
  else update-initramfs -u -k "$KVER"; fi
  echo
  echo "Removed. /etc/default/pcie-sbr-boot was left in place."
  echo "⚠️  If this machine relies on the SBR to find its root disk it will NOT boot now."
  exit 0
fi

say "1. busybox (provides nc / udhcpc / dd / a real shell inside the initramfs)"
if [ -n "$ROOT" ]; then
  if [ -x "$ROOT/usr/bin/busybox" ]; then echo "   already present on the target root"
  else echo "   ⚠️  busybox is NOT on the target root."
       echo "      Install it there first, e.g.:  chroot $ROOT apt-get install -y busybox"
  fi
else
  if command -v busybox >/dev/null 2>&1; then echo "   already installed"
  else apt-get install -y busybox; fi
fi

say "2. BUSYBOX=y in initramfs.conf"
if grep -q '^BUSYBOX=' "$IT/initramfs.conf"; then
  sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' "$IT/initramfs.conf"
else
  echo 'BUSYBOX=y' >> "$IT/initramfs.conf"
fi
grep '^BUSYBOX=' "$IT/initramfs.conf" | sed 's/^/   /'

say "3. hooks"
# Retire any earlier hand-rolled version. Renaming in place is NOT enough:
# initramfs-tools copies every file under scripts/<dir>/ into the image and runs it
# regardless of its name, so a *.superseded file would still execute. Move it right
# out of /etc/initramfs-tools.
SUPERSEDED="$ROOT/var/backups/pcie-sbr-superseded-hooks"
for old in scripts/local-block/aa-rkrescan scripts/init-premount/aa-rknet \
           scripts/panic/zz-rkdiag scripts/local-block/aa-rkrescan.superseded \
           scripts/init-premount/aa-rknet.superseded scripts/panic/zz-rkdiag.superseded; do
  if [ -e "$IT/$old" ]; then
    mkdir -p "$SUPERSEDED"
    mv -v "$IT/$old" "$SUPERSEDED/$(basename "$old")" 2>/dev/null || true
  fi
done
install -D -m 755 "$SRC/initramfs/scripts/local-block/pcie-sbr"        "$IT/scripts/local-block/pcie-sbr"
install -D -m 755 "$SRC/initramfs/scripts/init-premount/pcie-sbr-net"  "$IT/scripts/init-premount/pcie-sbr-net"
install -D -m 755 "$SRC/initramfs/scripts/panic/pcie-sbr-diag"         "$IT/scripts/panic/pcie-sbr-diag"
install -D -m 755 "$SRC/initramfs/hooks/pcie-sbr"                      "$IT/hooks/pcie-sbr"
ls -l "$IT/scripts/local-block/pcie-sbr" "$IT/scripts/init-premount/pcie-sbr-net" \
      "$IT/scripts/panic/pcie-sbr-diag"  "$IT/hooks/pcie-sbr" | sed 's/^/   /'

say "4. config"
if [ -f "$ROOT/etc/default/pcie-sbr-boot" ]; then
  echo "   keeping existing $ROOT/etc/default/pcie-sbr-boot"
else
  install -D -m 644 "$SRC/etc/default/pcie-sbr-boot" "$ROOT/etc/default/pcie-sbr-boot"
  echo "   installed $ROOT/etc/default/pcie-sbr-boot"
fi

say "5. rootwait on the kernel command line"
CL="$ROOT/etc/kernel/cmdline"
if [ -f "$CL" ]; then
  if grep -q 'rootwait' "$CL"; then echo "   already present"
  else
    cp -a "$CL" "$CL.bak.pcie-sbr"
    sed -i '1s/^/rootwait /' "$CL"
    echo "   added (backup: $CL.bak.pcie-sbr)"
    echo "   ⚠️  run 'u-boot-update' (or your bootloader's equivalent) so the boot entry"
    echo "      actually picks this up - editing cmdline alone is not enough."
  fi
else
  echo "   no $CL on this system; make sure your boot entry has 'rootwait'"
fi

say "6. back up the current initramfs and regenerate"
IMG="$ROOT/boot/initrd.img-$KVER"
[ -f "$IMG" ] && cp -a "$IMG" "$IMG.bak.pre-pcie-sbr" && echo "   backup: $IMG.bak.pre-pcie-sbr"
if [ -n "$ROOT" ]; then
  for m in dev dev/pts proc sys; do mount --bind "/$m" "$ROOT/$m" 2>/dev/null || true; done
  chroot "$ROOT" update-initramfs -u -k "$KVER"
  for m in sys proc dev/pts dev; do umount "$ROOT/$m" 2>/dev/null || true; done
else
  update-initramfs -u -k "$KVER"
fi

say "7. verify"
# NOTE: do not pipe lsinitramfs into `grep -q` here. grep exits on the first match and
# closes the pipe, lsinitramfs dies of SIGPIPE, and `set -o pipefail` then reports the
# whole pipeline as failed even though the match succeeded. Capture once, match in-shell.
listing=$(lsinitramfs "$IMG" 2>/dev/null || true)
ok=yes
if [ -z "$listing" ]; then
  echo "   could not list $IMG - cannot verify"
  ok=no
else
  for want in scripts/local-block/pcie-sbr scripts/init-premount/pcie-sbr-net \
              scripts/panic/pcie-sbr-diag etc/pcie-sbr-boot.conf bin/busybox bin/dd bin/od; do
    case "$listing" in
      *"$want"*) printf '   ok      %s\n' "$want" ;;
      *)         printf '   MISSING %s\n' "$want"; ok=no ;;
    esac
  done
fi

echo
if [ "$ok" = yes ]; then
  echo "Installed. Reboot to test."
  echo
  echo "After a successful boot, check which recovery step was needed:"
  echo "    cat /run/pcie-sbr.log"
  echo
  echo "★ Back up the working initramfs once it boots - especially if this machine has no"
  echo "  removable boot medium left:"
  echo "    cp /boot/initrd.img-$KVER{,.WORKING}"
else
  echo "Something is missing from the generated initramfs - do NOT rely on this yet."
  exit 1
fi
