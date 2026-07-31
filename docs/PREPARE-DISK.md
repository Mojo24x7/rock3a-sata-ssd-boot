# Preparing the SSD — complete walkthrough

From a blank disk to a board that boots with no microSD. Two routes:

* **Route A — fresh image** (recommended, cleanest). Write an official OS image to the SSD.
* **Route B — clone your running system** (keeps your existing setup, more steps, more ways
  to get it wrong).

Either way you must do **Step 0** first, and **Step 4** (install the boot fix) last.

Throughout: `/dev/sda` is the SSD on the HAT and `/dev/mmcblk1` is the microSD. **Check
yours with `lsblk` before typing anything** — these commands destroy data.

---

## Step 0 — bootloader in SPI flash (mandatory)

The RK3568 BootROM cannot read PCIe. The bootloader must live in SPI NOR (or eMMC/microSD),
and *it* then brings PCIe up to load the kernel. Without this, nothing else in this guide
matters.

Boot from the microSD and flash SPI using Radxa's own tooling:

```sh
sudo rsetup            #  System Maintenance  ->  Update SPI Bootloader
```

or directly from the installed package payload:

```sh
ls /usr/lib/u-boot/rock-3a/                     # idbloader.img, u-boot.itb, setup.sh
sudo /usr/lib/u-boot/rock-3a/setup.sh update_spinor /dev/mtd0
```

Verify afterwards — this reads SPI and tells you what the bootloader can boot from:

```sh
sudo python3 tools/uboot_caps.py
```

You want `ahci_pci PRESENT`, `pcie_dw_rockchip PRESENT`, and `scsi` in `boot_targets`.
If `scsi` is missing your U-Boot is too old — update the `u-boot-latest` /
`u-boot-rock-3a` packages and reflash.

> **Gotcha:** a `u-boot-latest` package upgrade can *remove* `/usr/lib/u-boot/rock-3a/`.
> If it's gone, reinstall the board package before trying to reflash.

---

## Route A — write a fresh OS image (recommended)

This is Radxa's documented method and it avoids every duplicate-identity problem, because
the image already contains correct, unique UUIDs.

1. Boot from the microSD, download an image for your board from Radxa's downloads page.
2. Write it to the SSD:

   ```sh
   lsblk                                        # confirm the SSD is /dev/sda
   sudo xzcat ~/rock-3a-debian.img.xz | sudo dd of=/dev/sda bs=4M status=progress conv=fsync
   sudo partprobe /dev/sda
   ```

3. Grow the root partition to fill the disk. The image is small (often 4 GB), so most of
   your SSD would be wasted otherwise. The root partition is the last one:

   ```sh
   sudo sgdisk -p /dev/sda                      # note partition 3's START sector
   sudo sgdisk -d 3 /dev/sda
   sudo sgdisk -a 2048 -n 3:<START>:0 -t 3:EF00 -c 3:rootfs /dev/sda
   sudo partprobe /dev/sda
   sudo e2fsck -f /dev/sda3
   sudo resize2fs /dev/sda3
   ```

   Keep the **same start sector** and the same type code as the image used, or the data
   already written there is lost.

4. Skip to **Step 3** (verify) then **Step 4** (install the fix).

Some images auto-expand the root filesystem on first boot, in which case step 3 above is
unnecessary — check `df -h /` after the first successful boot.

---

## Route B — clone the running microSD system

Use this if you have a configured system you want to keep. More steps, and the
identity-collision traps below are the reason people lose an evening.

### B1. Partition the SSD

Mirror the layout the image uses — on ROCK 3A that is a 16 MB `config`, a 300 MB `boot`
(FAT, usually empty), and root filling the rest:

```sh
sudo sgdisk -Z /dev/sda                                        # wipe (DESTRUCTIVE)
sudo sgdisk -a 2048 \
  -n 1:32768:65535   -t 1:0700 -c 1:config \
  -n 2:65536:679935  -t 2:EF00 -c 2:boot \
  -n 3:679936:0      -t 3:EF00 -c 3:rootfs /dev/sda
sudo partprobe /dev/sda
sudo sgdisk -p /dev/sda
```

### B2. Filesystems — with *unique* identifiers

★ **This is the trap.** If you copy filesystems from the microSD, both media end up with
the same ext4 UUID and the same FAT volume IDs. With both inserted, Linux resolves
`root=UUID=…` to whichever it finds first — so your "SSD boot" silently keeps running from
the microSD and you chase ghosts. Give the SSD its own identifiers from the start:

```sh
sudo mkfs.ext4 -L rootfs -U $(uuidgen) /dev/sda3
sudo mkfs.vfat -i 8A6C1F21 -n config /dev/sda1      #  -i sets the FAT volume ID
sudo mkfs.vfat -i 8A6C1F22 -n boot   /dev/sda2
blkid /dev/sda1 /dev/sda2 /dev/sda3 /dev/mmcblk1p1 /dev/mmcblk1p2 /dev/mmcblk1p3
```

Every UUID in that last command's output must be distinct. Also randomise the GPT GUIDs so
they don't collide either:

```sh
sudo sgdisk -G /dev/sda
```

Note the new root UUID — you need it twice below.

> The ext4 *feature set* does not need special handling. U-Boot reads a filesystem made by
> a current `mkfs.ext4` fine; we verified `dumpe2fs -h` output is equivalent to the
> factory image's. Don't waste time on `-O ^metadata_csum` and friends.

### B3. Copy the system

`rsync` may not be installed on a fresh Radxa image; `tar` always is.

```sh
sudo mkdir -p /mnt/ssdroot
sudo mount /dev/sda3 /mnt/ssdroot
```

With `rsync`:

```sh
sudo rsync -aHAXx --numeric-ids \
    --exclude='/tmp/*' --exclude='/var/tmp/*' \
    --exclude='/var/cache/apt/archives/*' --exclude='/var/log/journal/*' \
    / /mnt/ssdroot/
```

With `tar` (note the **single** `sudo` wrapping the whole pipeline — see gotchas):

```sh
sudo sh -c "tar -C / --one-file-system --numeric-owner --xattrs --acls \
      --exclude='./tmp/*' --exclude='./var/tmp/*' \
      --exclude='./var/cache/apt/archives/*' --exclude='./var/log/journal/*' \
      -cf - . | tar -C /mnt/ssdroot --numeric-owner --xattrs --acls -xf -"
```

`--one-file-system` / `-x` is important: it skips `/proc`, `/sys`, `/dev`, `/run` and other
mounts, leaving them as the empty mountpoints they should be.

Then the small FAT partition:

```sh
sudo mkdir -p /mnt/ssdcfg && sudo mount /dev/sda1 /mnt/ssdcfg
sudo cp -a /config/. /mnt/ssdcfg/ && sudo umount /mnt/ssdcfg
```

### B4. Point the copy at itself

Both files still name the microSD's UUIDs. Fix them on the **SSD copy** only — leave the
microSD untouched so it stays a working rescue system.

```sh
SSD_ROOT=$(sudo blkid -s UUID -o value /dev/sda3)
SSD_CFG=$(sudo  blkid -s UUID -o value /dev/sda1)
SSD_EFI=$(sudo  blkid -s UUID -o value /dev/sda2)
SD_ROOT=$(sudo  blkid -s UUID -o value /dev/mmcblk1p3)
SD_CFG=$(sudo   blkid -s UUID -o value /dev/mmcblk1p1)
SD_EFI=$(sudo   blkid -s UUID -o value /dev/mmcblk1p2)

sudo cp -a /mnt/ssdroot/etc/fstab /mnt/ssdroot/etc/fstab.bak
sudo sed -i -e "s|$SD_ROOT|$SSD_ROOT|g" -e "s|$SD_CFG|$SSD_CFG|g" -e "s|$SD_EFI|$SSD_EFI|g" \
        /mnt/ssdroot/etc/fstab

sudo cp -a /mnt/ssdroot/boot/extlinux/extlinux.conf /mnt/ssdroot/boot/extlinux/extlinux.conf.bak
sudo sed -i "s|root=UUID=$SD_ROOT|root=UUID=$SSD_ROOT rootwait|g" \
        /mnt/ssdroot/boot/extlinux/extlinux.conf
```

★ **`/boot` is on the ext4 root on these images**, not on the FAT partition — `/boot/efi`
is empty and unused. U-Boot reads `/boot/extlinux/extlinux.conf` from the ext4 partition,
which is why editing it there is what matters.

### B5. Make `rootwait` durable

`rootwait` is essential: the disk appears ~16 s into boot, far later than an SD card. But
`/boot/extlinux/extlinux.conf` is **generated** from `/etc/kernel/cmdline` by
`u-boot-update`, so if you only edit the generated file, the next kernel upgrade silently
drops `rootwait` and the machine stops booting.

```sh
sudo sed -i '1s/^/rootwait /' /mnt/ssdroot/etc/kernel/cmdline
cat /mnt/ssdroot/etc/kernel/cmdline
```

Optional but useful: drop `quiet splash` and raise `loglevel` so a failure is readable on
HDMI.

Also confirm device-tree overlays will survive regeneration:

```sh
grep U_BOOT_FDT_OVERLAYS /mnt/ssdroot/etc/default/u-boot
```

---

## Step 3 — verify before you pull the microSD

There is a script for this. It only reads:

```sh
sudo ./tools/check-target.sh /mnt/ssdroot
```

It checks that the target's `fstab` and boot entry name the target's *own* UUIDs, that no
source UUID is left behind, that `rootwait` is present in both the boot entry and
`/etc/kernel/cmdline`, that the kernel, initramfs, device tree and overlays exist, that
`/proc`, `/sys`, `/dev` are empty mountpoints, that SSH keys came across, and that the
boot fix is installed.

Fix anything it flags. A failure here is five minutes; a failure after you've pulled the
card can mean a card reader and another machine.

---

## Step 4 — install the boot fix

Without this the board reaches the initramfs and stops with
`ALERT! UUID=… does not exist` — see the [README](../README.md) for why.

From the running microSD system, installing onto the SSD:

```sh
sudo ./install.sh --root /mnt/ssdroot --kernel $(uname -r)
```

Then unmount cleanly and check the filesystem:

```sh
sync && sudo umount /mnt/ssdroot
sudo e2fsck -f -p /dev/sda3
```

---

## Step 5 — first SD-less boot

1. Power off.
2. Remove the microSD. **Keep it** — it is your rescue path, and it should still be a
   complete working system if you followed the guide.
3. Power on and allow **~90 seconds**. U-Boot walks the HAT's empty SATA ports, each
   costing a link timeout, and the fix adds ~10 s.
4. Confirm:

   ```sh
   findmnt -n -o SOURCE,TARGET /      # /dev/sda3 /
   df -h /                            # full disk size
   cat /run/pcie-sbr.log              # which recovery step was needed
   ```

★ Back up the initramfs that just worked, because it is now the only one on the machine
that boots:

```sh
sudo cp /boot/initrd.img-$(uname -r){,.WORKING}
```

**If it does not boot:** put the microSD back in and power on — you are exactly where you
started. Then set `DIAG_HOST` (and optionally `ENABLE_TELNET=yes`) in
`/etc/default/pcie-sbr-boot` on the SSD, `update-initramfs -u`, and try again with
`tools/diag_listener.py` running on another machine. See
[REMOTE-DEBUG.md](REMOTE-DEBUG.md).

---

## Gotchas that cost real time

* **Two piped `sudo -S` commands clobber each other's stdin.** `sudo tar -cf - . | sudo tar -xf -`
  feeds the password to the first `sudo` only; the second's prompt lands *inside the tar
  stream* and you get `tar: This does not look like a tar archive`. Wrap the whole pipeline
  in **one** `sudo sh -c "…"`.
* **`fs.protected_regular` blocks even root** from writing a pre-existing file it does not
  own in a sticky world-writable directory like `/tmp`. If a script fails with
  `Permission denied` on a `/tmp` log file it created in an earlier run as another user,
  put helper files under `/root` or delete them first.
* **`sgdisk`, `partprobe`, `blkid`, `e2fsck` look "missing"** as a normal user — Debian
  excludes `/sbin` from a non-root `PATH`. They work under `sudo`. Set
  `PATH=/usr/sbin:/sbin:/usr/bin:/bin` in scripts.
* **`update-initramfs -u` does not regenerate `extlinux.conf`.** Editing
  `/etc/kernel/cmdline` alone is not enough — run `u-boot-update` and then actually look at
  the boot entry.
* **Don't grep a script's output through a filter that strips the `sudo` prompt line.** The
  prompt appears inline on the same line as your output, so `grep -v "password for"`
  deletes the very lines you wanted to read. Verify file contents in a separate call.
* **Confirm the board is powered on** before concluding a boot failed. Obvious, and it
  still wasted twenty minutes.
* **The native SATA port is a red herring on a PCIe HAT.** `rock-3a-sata2.dtbo` enables the
  SoC's own SATA controller, which is empty. Check with `ls -l /sys/block/sda` — if the
  path contains `.pcie/`, your disk is on the HAT and that overlay is irrelevant.
