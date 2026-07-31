# Draft post for forum.radxa.com

Suggested title:

> **ROCK 3A: booting from an SSD on the Penta SATA HAT with no microSD — solved (PCIe warm-handoff / Secondary Bus Reset)**

Category: ROCK 3 series. Paste the body below, adjust anything that differs on your setup.

---

## Body

If you have tried to boot a ROCK 3A entirely from a disk on a PCIe SATA HAT and got this
with the microSD removed:

```
Gave up waiting for root file system device.
ALERT!  UUID=... does not exist.  Dropping to a shell!
(initramfs)
```

…while the same disk works perfectly when the microSD is inserted — here is what is
actually happening and how to fix it. I spent a long time on this, so hopefully this saves
someone else the trouble.

**Short version:** U-Boot has to bring the PCIe link up in order to read the kernel off
the disk. Linux's `rk-pcie` driver then checks `link_up()`, sees the link already up, and
**returns early without resetting or retraining the endpoint.** It goes on to enumerate an
empty bus, so the SATA controller never appears and there is no root device to wait for.

You can see it clearly in the two dmesg logs:

```
microSD boot (U-Boot never touches PCIe):
  rk-pcie: PCIe Linking... LTSSM is 0x210021       <- the driver trains the link
  rk-pcie: PCIe Link up,   LTSSM is 0x230011
  pci 0002:21:00.0: [197b:0585] class 0x010601     <- JMB585 found
  ata2: SATA link up 6.0 Gbps -> sda

SSD boot (U-Boot read the kernel over PCIe):
  rk-pcie: PCIe Link up,   LTSSM is 0x30011        <- no "Linking..." line at all
  pci_bus 0002:21: busn_res ... updated to 21      <- bus created, EMPTY
```

Note the missing `Linking...` line and the different LTSSM value.

**The fix:** issue a **Secondary Bus Reset** on the PCIe root port from inside the
initramfs, while it is still waiting for the root device. That is bit 6 of the Bridge
Control register at PCI config offset `0x3E`, and you can reach it from userspace:

```sh
BR=/sys/bus/pci/devices/0002:20:00.0/config
old=$(dd if=$BR bs=1 skip=62 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
printf "\\$(printf '%03o' $((old|64)))" | dd of=$BR bs=1 seek=62 count=1 conv=notrunc
sleep 1
printf "\\$(printf '%03o' $old)"        | dd of=$BR bs=1 seek=62 count=1 conv=notrunc
sleep 2
echo 1 > /sys/bus/pci/rescan
for h in /sys/class/scsi_host/host*; do echo "- - -" > $h/scan; done
```

After that the endpoint enumerates properly and the boot continues:

```
[26.690] pci 0002:21:00.0: [197b:0585] type 00 class 0x010601
[26.7  ] sd 1:0:0:0: [sda] Attached SCSI disk
```

I packaged this as an initramfs hook plus an installer here:
**https://github.com/Mojo24x7/rock3a-sata-ssd-boot**

```sh
git clone https://github.com/Mojo24x7/rock3a-sata-ssd-boot
cd rock3a-sata-ssd-boot
sudo ./install.sh
```

### Things that do NOT fix it

I tried all of these first, so you don't have to: `rootdelay=30`, `rootwait`,
`scsi_mod.scan=sync`, booting with no initrd, `root=/dev/sdaX` instead of `root=UUID=`,
re-flashing SPI, a pre-merged DTB via `fdt` instead of `fdtoverlays`, and making the ext4
and FAT UUIDs unique. The unique-UUID part is worth doing anyway if you cloned the microSD,
but none of it addresses the cause. The disk is **absent**, not late — so no amount of
waiting helps.

Also: `rock-3a-sata2.dtbo` is a red herring for this HAT. That overlay enables the SoC's
*own* SATA port, which is empty; the HAT's disk is on PCIe behind a JMB585. Check with
`ls -l /sys/block/sda` — if the path contains `.pcie/`, it's the HAT.

### Two side effects, in the interest of honesty

* The link renegotiates at **Gen1** after the hot reset — `4.000 Gb/s available PCIe
  bandwidth, limited by 2.5 GT/s PCIe x2 link`. For a single SATA SSD that's about
  500 MB/s and no real loss, but it would matter with several bays populated.
* Boot takes roughly 10 s longer (disk at ~t+26 s instead of ~t+16 s).

### The proper fix

This is a workaround. The right fix is in the kernel — `rk-pcie` should reset and retrain
on probe even when the link already reports up, or at least verify the endpoint answers
config reads before trusting it — or in U-Boot, which could put the link back in reset
before handing off. If someone who knows the Rockchip PCIe code wants to take that on, it
would help everyone booting from PCIe on these SoCs. Happy for this repo to become
obsolete.

### Bonus: debugging a headless board with no serial console

I had no USB-TTL adapter, and this fails before any filesystem is mounted, so there was no
way to see what was going on. Two things solved that, and they're generally useful:

1. **Ship `dmesg` over ethernet from the initramfs.** The kernel and initramfs are already
   in RAM and on these boards the ethernet driver is built in (`CONFIG_DWMAC_ROCKCHIP=y`),
   so you have a working network even with no disk. A script in
   `/etc/initramfs-tools/scripts/panic/` runs right before it drops you to a shell — bring
   `eth0` up with `ipconfig`/`udhcpc` and pipe `dmesg` plus the PCI/SCSI/block state to
   `busybox nc <host> <port>`. A 10-line Python listener on the other machine catches it.
2. **Run `busybox telnetd -l /bin/sh` inside the initramfs.** Put it in
   `scripts/init-premount/` so it starts while the boot is still retrying. Then you can
   telnet in and poke `/sys` by hand — effectively a serial console over the LAN. (It's an
   unauthenticated root shell, so debug-only; it dies at `switch_root`.)

Both are in the repo with the details in `docs/REMOTE-DEBUG.md`.

### My setup

* Radxa ROCK 3A (RK3568), 2 GB
* Radxa Penta SATA HAT — JMicron JMB585 (`197b:0585`), PCIe 3.0 x2
* 500 GB SATA SSD, single disk
* Radxa OS, Debian 11 bullseye, kernel `5.10.160-12-rk356x`
* `u-boot-latest 2023.07.02-3-b1eb2bde` flashed to the 16 MB SPI NOR

If you hit this on another board or with a different SATA/NVMe card, I'd be interested to
hear — the mechanism should be the same for any endpoint U-Boot initialises in order to
boot from it.
