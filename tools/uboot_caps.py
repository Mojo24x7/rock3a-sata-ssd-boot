#!/usr/bin/env python3
"""uboot_caps.py - what can the U-Boot in your SPI flash actually boot from?

Reads the raw SPI NOR (default /dev/mtd0) and reports the driver names, boot targets
and runtime message strings compiled into U-Boot. Answers "can this board even boot
that way?" in seconds, with no serial console and no reboot.

    sudo python3 uboot_caps.py [/dev/mtd0]

Example on a Radxa ROCK 3A (u-boot-latest 2023.07.02-3):

    boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi
    ahci_pci          PRESENT    <- can drive a PCIe AHCI card (SATA HAT)
    dwc_ahci          absent     <- cannot drive the SoC's own SATA port
    nvme / nvme-blk   PRESENT
    pcie_dw_rockchip  PRESENT    <- RK3568 PCIe host controller
    rockchip_pcie3phy PRESENT

Uses Python rather than dd so it works in restricted shells, and never writes.
"""
import sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/dev/mtd0"

try:
    with open(PATH, "rb") as f:
        blob = f.read()
except PermissionError:
    sys.exit("need root to read %s" % PATH)
except FileNotFoundError:
    sys.exit("%s not found - does this board have SPI NOR? check /proc/mtd" % PATH)

print("read %d bytes from %s" % (len(blob), PATH))
nonblank = sum(1 for b in blob[:1 << 20] if b not in (0x00, 0xFF))
print("first 1 MiB non-blank bytes: %d -> %s\n"
      % (nonblank, "PROGRAMMED" if nonblank > 1000 else "BLANK / NOT FLASHED"))


def strings(buf, minlen=6):
    out, cur = [], bytearray()
    for ch in buf:
        if 32 <= ch < 127:
            cur.append(ch)
        else:
            if len(cur) >= minlen:
                out.append(cur.decode())
            cur = bytearray()
    if len(cur) >= minlen:
        out.append(cur.decode())
    return out


S = strings(blob)

print("=== identity")
for s in S:
    if s.startswith("U-Boot SPL") or s.startswith("U-Boot 20"):
        print("  " + s[:120])

print("\n=== environment (compiled defaults)")
for key in ("bootcmd=", "boot_targets=", "bootdelay=", "fdtfile="):
    for s in S:
        if s.startswith(key):
            print("  " + s[:200])
            break

print("\n=== block / bus drivers")
DRIVERS = [
    ("ahci_pci",          "generic PCI AHCI  <- needed for a PCIe SATA card (JMB58x etc.)"),
    ("dwc_ahci",          "SoC-integrated SATA controller"),
    ("ahci_scsi",         "AHCI/SCSI glue"),
    ("scsi_blk",          "SCSI block layer"),
    ("scsi_bootdev",      "bootstd: can boot from SCSI"),
    ("nvme-blk",          "NVMe block"),
    ("nvme_bootdev",      "bootstd: can boot from NVMe"),
    ("mmc_bootdev",       "bootstd: can boot from MMC/SD"),
    ("usb_bootdev",       "bootstd: can boot from USB"),
    ("pcie_dw_rockchip",  "Rockchip DesignWare PCIe host"),
    ("rockchip_pcie3phy", "RK3568/RK3588 PCIe 3.0 PHY"),
    ("naneng-combphy",    "Rockchip combo PHY (SATA/USB3/PCIe2)"),
]
for name, why in DRIVERS:
    n = blob.count(name.encode())
    print("  %-19s %-8s %s" % (name, "PRESENT" if n else "absent", why))

print("\n=== runtime messages present (what it would print)")
for pat in ("scanning bus for devices", "Target spinup took", "SATA link", "AHCI ",
            "extlinux/extlinux.conf", "bootflow", "Boot failed"):
    n = blob.count(pat.encode())
    print("  %-26s %s" % (pat, "PRESENT" if n else "absent"))

print("\n=== verdict")
has_pci_ahci = blob.count(b"ahci_pci") > 0
has_nvme = blob.count(b"nvme-blk") > 0
has_pcie = blob.count(b"pcie_dw_rockchip") > 0
tgt = next((s for s in S if s.startswith("boot_targets=")), "")
print("  PCIe host driver     : %s" % ("yes" if has_pcie else "NO"))
print("  PCI AHCI (SATA card) : %s" % ("yes" if has_pci_ahci else "NO"))
print("  NVMe                 : %s" % ("yes" if has_nvme else "NO"))
print("  'scsi' in boot_targets: %s" % ("yes" if "scsi" in tgt else "NO"))
if has_pcie and has_pci_ahci and "scsi" in tgt:
    print("  -> booting from a PCIe SATA card is possible with this bootloader")
elif has_pcie and has_nvme:
    print("  -> NVMe boot possible; a SATA card is NOT (no PCI AHCI or no scsi target)")
else:
    print("  -> this bootloader cannot boot from PCIe at all")
print("\nNote: none of this says the *kernel* will enumerate the device after handoff.")
print("That is a separate problem - see the README.")
