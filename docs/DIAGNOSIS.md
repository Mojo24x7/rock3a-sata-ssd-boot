# Diagnosis — the full evidence trail

Kept because the wrong turns are as useful as the answer: if your symptoms differ
slightly, the eliminations below tell you where *not* to spend time. Every claim here is
from a command output, not inference.

Board: Radxa ROCK 3A (RK3568), Radxa OS bullseye, kernel `5.10.160-12-rk356x`,
Radxa Penta SATA HAT (JMicron JMB585) in the M.2 slot, one SATA SSD.

---

## 1. Establish which controller the disk is actually on

Easy to get wrong, and it wasted an earlier attempt entirely. The board has **two**
AHCI-capable paths: the SoC's own SATA port and the HAT's PCIe bridge.

```
$ ls -l /sys/block/sda
../devices/platform/3c0800000.pcie/pci0002:20/0002:20:00.0/0002:21:00.0/ata2/host1/...

$ for h in /sys/class/scsi_host/host*; do printf "%s -> " $(basename $h); readlink -f $h; done
host0 -> platform/fc800000.sata/ata1/host0                          <- SoC native SATA
host1..host5 -> platform/3c0800000.pcie/.../0002:21:00.0/ata2..ata6 <- JMB585, 5 ports

$ dmesg | grep 'link'
ata1: SATA link down (SStatus 0 SControl 300)      <- native port is EMPTY
ata2: SATA link up 6.0 Gbps                        <- the SSD
```

So the disk is behind **PCIe**, and `rock-3a-sata2.dtbo` — which enables the SoC's native
SATA port — is irrelevant to it. Chasing that overlay is a dead end.

## 2. Confirm U-Boot can read the disk at all

The failure message is the important clue:

```
Gave up waiting for root file system device.
ALERT!  UUID=… does not exist.  Dropping to a shell!
(initramfs)
```

Reaching `(initramfs)` means U-Boot **did** load `vmlinuz` and `initrd` from the SSD over
PCIe. So the bootloader is not the problem — the failure is entirely Linux-side.

Confirmed independently by reading the bootloader out of SPI (`tools/uboot_caps.py`):

```
boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi
ahci_pci          PRESENT
scsi_bootdev      PRESENT      + compatible "u-boot,bootdev-scsi"
pcie_dw_rockchip  PRESENT      + compatible "rockchip,rk3568-pcie"
rockchip_pcie3phy PRESENT
dwc_ahci          absent       <- so `scsi` can ONLY mean the HAT on this board
"scanning bus for devices" / "SATA link %d timeout" / "AHCI ..."   PRESENT
```

## 3. Get the failing boot's `dmesg` without a serial console

This is the step that unlocked everything — see
[REMOTE-DEBUG.md](REMOTE-DEBUG.md). Result, from the failing boot:

```
--- PCI devices
0002:20:00.0  vendor=0x1d87 device=0x3566 class=0x060400 driver=pcieport
                                    ^^^ ONLY the root port. No 0002:21:00.0.

--- SCSI hosts
host0  proc_name=ahci            <- the empty native port only

--- /sys/block
loop0..loop7  mtdblock0  ram0    <- no sda at all
```

The JMB585 is **absent**, not late. That immediately kills every timing theory.

## 4. The decisive comparison

```
WORKS (microSD boot — U-Boot never touched PCIe)
  rk-pcie: PCIe Linking... LTSSM is 0x210021
  naneng-combphy fe830000.phy: wait phy status ready timeout
  rk-pcie: PCIe Link up,   LTSSM is 0x230011
  pci 0002:21:00.0: [197b:0585] type 00 class 0x010601

FAILS (SSD boot — U-Boot read the kernel over PCIe)
  rk-pcie: PCIe Link up,   LTSSM is 0x30011
  pci_bus 0002:21: busn_res: [bus 21-2f] end is updated to 21
```

Two things:

* **The failing boot has no `Linking...` line.** Rockchip's driver checks `link_up()`
  first and returns early when the link already reports up. U-Boot had trained it, so
  Linux skipped its own reset-and-train and went straight to enumerating an endpoint it
  had never reset.
* **LTSSM differs by `0x200000`** (`0x30011` vs `0x230011`). Both have the SMLH/RDLH
  link-up bits (`0x30000`), which is why the driver was satisfied.

Also note `naneng-combphy fe830000.phy: wait phy status ready timeout` appears in **both**
boots — it belongs to the empty native SATA port and is unrelated noise. Worth checking
rather than chasing.

## 5. Why the obvious recovery routes are unavailable

```
$ ls /sys/bus/platform/drivers/rk-pcie/
3c0800000.pcie   uevent                 <- no bind / unbind: suppress_bind_attrs

$ od -An -tx4 /proc/device-tree/pcie@fe280000/reset-gpios
  b6000000 1e000000 00000000            <- <&gpio2 30>, i.e. global GPIO 94
$ sudo cat /sys/kernel/debug/gpio | grep 94
 gpio-94  (  |reset  ) out hi           <- claimed by the driver; cannot export
```

So the host controller cannot be re-probed and PERST# cannot be toggled from userspace.

Measured, all ineffective (the recovery hook logs each attempt):

```
step A: rescan SCSI hosts                  -> pci=0002:20:00.0   sd=(none)
step: full PCI rescan                      -> unchanged
step: unbind/rebind ahci                   -> no 0x010601 device to bind
step: remove bridge + rescan               -> bridge returns, still empty
```

None of those reset the PHY or retrain the link.

## 6. The fix, and the proof

```
[pcie-sbr #2] SECONDARY BUS RESET
                BridgeControl 0x3E: 2 -> 66 (assert SBR), hold 1s
                BridgeControl 0x3E: 66 -> 2 (release SBR)
              after: pci=0002:20:00.0 0002:21:00.0  blk=/dev/sda /dev/sda1 /dev/sda2 /dev/sda3
```

```
[15.245] rk-pcie: PCIe Link up, LTSSM is 0x30011
[15.289] pci_bus 0002:21: busn_res ... updated to 21          <- still empty
[26.690] pci 0002:21:00.0: [197b:0585] type 00 class 0x010601 <- after SBR
[26.691] 4.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x2 link
         (capable of 15.752 Gb/s with 8.0 GT/s PCIe x2 link)  <- Gen1 after hot reset
```

Boots to `root: /dev/sda3`, full-size root, no microSD present.

## Eliminated hypotheses, with the evidence

| hypothesis | how it was killed |
|---|---|
| ext4 features too modern for U-Boot | `dumpe2fs -h` on both roots: **identical** feature lists, same inode size 256, block 4096, `crc32c`, same journal features |
| GPT type codes / attribute flags wrong | `sgdisk -i` on all partitions of both disks: identical |
| extlinux is not really the boot path | `/proc/cmdline` matches the `append` line byte for byte |
| initramfs missing storage modules | every driver is `=y`, not a module: `SATA_AHCI`, `BLK_DEV_SD`, `SCSI_MOD`, `ATA`, `PCIE_DW_ROCKCHIP`, `PHY_ROCKCHIP_SNPS_PCIE3`; `MODULES=most` anyway |
| duplicate UUIDs between media | made unique (necessary hygiene) — did not change the standalone failure |
| disk arriving late | `rootdelay=30`, `rootwait`, `scsi_mod.scan=sync` all no change; and the endpoint is *absent*, not slow |
| the combphy PHY timeout | appears in the **working** boot too |
| wrong device tree on the target root | base DTB is byte-identical (`md5sum`) on both roots; `pcie@fe280000 status=okay` in both |
| `rock-3a-sata2.dtbo` missing/needed | it enables the SoC's native SATA port, which is **empty**; the disk is on PCIe |

## Useful details in passing

* `/boot` lives on the **ext4 root** on these images; `/boot/efi` (300 MB FAT) is empty and
  unused. U-Boot reads `/boot/extlinux/extlinux.conf` from the ext4 partition.
* This U-Boot has **no writable environment** — `Saving Environment to` and `SPIFlash`
  strings are absent, `nowhere` is present, and every env string lives inside
  `u-boot.itb`. So `fw_setenv` cannot work, and creating `/etc/fw_env.config` would make
  it write to an invented offset and corrupt the bootloader. Don't.
* `/boot/uEnv.txt` is retired on current Radxa images; the file says so itself. Kernel
  arguments come from `/etc/kernel/cmdline` + `u-boot-update`; overlays from `rsetup` or
  `U_BOOT_FDT_OVERLAYS` in `/etc/default/u-boot`. **Boot device order is compiled into
  `u-boot.itb`** and is not changeable from Linux.
* `update-initramfs -u` does not regenerate `extlinux.conf`. Editing
  `/etc/kernel/cmdline` is not enough on its own — run `u-boot-update` and verify the
  boot entry actually changed.
