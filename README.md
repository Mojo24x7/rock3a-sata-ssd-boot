# rock3a-sata-ssd-boot

**Boot a Radxa ROCK 3A entirely from an SSD on a PCIe SATA HAT — no microSD card.**

Also: two techniques for debugging a headless single-board computer that won't boot,
**without a serial console** — an initramfs "network bridge" that ships `dmesg` to
another machine, and a telnet rescue shell inside the initramfs.

---

## The symptom

You install the system on an SSD behind a PCIe→SATA HAT (Radxa Penta SATA HAT, or any
JMicron JMB58x card), flash U-Boot to SPI, pull the microSD, and boot. You get:

```
Gave up waiting for root file system device.
ALERT!  UUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx does not exist.  Dropping to a shell!
(initramfs)
```

With the microSD inserted, the *same* SSD works perfectly — `/dev/sda` enumerates,
`ata2: SATA link up 6.0 Gbps`, you can mount it, read it, write it.

Things that do **not** fix it (all tested):

| attempted | result |
|---|---|
| `rootdelay=30`, `rootwait` | no change — the disk never appears at all, it isn't late |
| `scsi_mod.scan=sync` | no change |
| booting with no initrd | fails earlier, no change in kind |
| `root=/dev/sda3` instead of `root=UUID=` | no change — it isn't UUID resolution |
| unique ext4/FAT UUIDs, unique GPT GUIDs | necessary hygiene, but not the cause |
| a pre-merged DTB via `fdt` instead of `fdtoverlays` | no change |
| re-flashing SPI, newer/older U-Boot | no change |

## The cause

Compare the PCIe link bring-up in the two cases:

```
WORKS  (booted from microSD — U-Boot never touched PCIe)
  rk-pcie 3c0800000.pcie: PCIe Linking... LTSSM is 0x210021     <- the driver TRAINS the link
  rk-pcie 3c0800000.pcie: PCIe Link up,   LTSSM is 0x230011
  pci 0002:21:00.0: [197b:0585] type 00 class 0x010601          <- JMB585 found
  ata2: SATA link up 6.0 Gbps  ->  sd 1:0:0:0: [sda] Attached SCSI disk

FAILS  (booted from the SSD — U-Boot read the kernel over PCIe first)
  rk-pcie 3c0800000.pcie: PCIe Link up,   LTSSM is 0x30011      <- NO "Linking..." line
  pci_bus 0002:21: busn_res: [bus 21-2f] end is updated to 21   <- bus created, EMPTY
  (no endpoint, no ata2, no sda)
```

To load the kernel off the SSD, **U-Boot must bring the PCIe link up itself**. Linux then
probes `rk-pcie`, which checks `link_up()` **first** and returns early when the link
already reports up — so it **never resets or retrains the endpoint**. It goes straight to
enumerating a bus behind a device that was left in U-Boot's state, config reads return
nothing, and you get an empty bus.

This is a **warm-handoff** bug. It is not specific to SATA: any PCIe endpoint that U-Boot
initialises in order to boot from it can hit the same thing.

## The fix

Issue a **Secondary Bus Reset** on the PCIe root port from the initramfs, while it is
still waiting for the root device. SBR is bit 6 of the Bridge Control register at PCI
config offset `0x3E`, and it is reachable from userspace through
`/sys/bus/pci/devices/<bridge>/config`:

```
BridgeControl 0x3E:  2 -> 66   (assert SBR)      # bit 6 set
                                sleep 1
BridgeControl 0x3E: 66 -> 2    (release SBR)
echo 1 > /sys/bus/pci/rescan
for h in /sys/class/scsi_host/host*; do echo "- - -" > $h/scan; done
```

That hot-resets everything behind the bridge. The endpoint comes back up clean and Linux
enumerates it properly:

```
[15.245] rk-pcie: PCIe Link up, LTSSM is 0x30011        <- warm handoff, as before
[15.289] pci_bus 0002:21: busn_res ... updated to 21    <- still empty
   ... SBR ...
[26.690] pci 0002:21:00.0: [197b:0585] class 0x010601   <- endpoint appears
[26.7  ] sd 1:0:0:0: [sda] Attached SCSI disk           -> root mounts, boot continues
```

### ⚠️ The reset is not reliably effective on the first attempt

Measured on the same board across two boots:

| boot | what worked | disk appeared |
|---|---|---|
| 1 | the **first** SBR | t+26 s |
| 2 | the **third** SBR, issued after a bridge remove + re-enumerate | t+56 s |

On the second boot the first two SBRs did nothing, and `BridgeControl` read back `0`
instead of `2` between attempts — the register state is not clean between tries. The reset
that worked was the one issued on a **freshly re-enumerated** bridge.

So the hook does not climb a ladder and give up. It **cycles** through six phases and keeps
going for as long as `rootwait` keeps initramfs retrying:

| phase | action |
|---|---|
| 1 | SBR, short hold |
| 2 | SBR, longer hold |
| 3 | **remove bridge → re-enumerate → SBR** ← the combination that works most often |
| 4 | plain PCI rescan |
| 5 | unbind/rebind the storage driver |
| 6 | remove bridge → re-enumerate → SBR, longer hold |

Each cycle costs a few seconds, so expect boot to take **20-60 seconds longer** than a
microSD boot rather than a fixed amount. `/run/pcie-sbr.log` records which cycle and phase
succeeded — worth reading after a successful boot.

### Why the obvious approaches don't work

* **You cannot re-probe the host controller.** `/sys/bus/platform/drivers/rk-pcie/` has no
  `bind`/`unbind` — the driver sets `suppress_bind_attrs`.
* **You cannot toggle PERST# from userspace.** `reset-gpios` is claimed by the driver, so
  `/sys/class/gpio` export fails with `EBUSY`.
* **PCI-level pokes are not enough.** SCSI host rescan, `echo 1 > /sys/bus/pci/rescan`,
  `<bridge>/remove` + rescan, and `ahci` unbind/rebind all leave the PHY and the link
  untouched. Only SBR actually resets the endpoint.

### The proper fix belongs upstream

This repository is a **working userspace workaround**, not the right long-term fix. The
real fix is one of:

1. **Kernel** — `rk-pcie` should reset and retrain the link on probe even when it already
   reports up, or at least verify the endpoint responds to config reads before trusting it.
2. **U-Boot** — put the link back in reset (or issue SBR itself) before handing off to
   the kernel.

If you know the Rockchip PCIe code, either fix would help a lot of people. Patches
welcome; this repo will happily become obsolete.

## Side effects, honestly

* **The link renegotiates at Gen1 after the reset.**
  `4.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x2 link (capable of
  15.752 Gb/s with 8.0 GT/s)`. For a single SATA SSD (~500 MB/s) this is effectively no
  loss. If you populate several bays on a 5-port HAT it will matter.
* **Boot takes ~20-60 seconds longer.** The disk appeared at t+26 s on one boot and t+56 s
  on another, because the reset needs a variable number of attempts (see above).
* U-Boot also walks the HAT's empty SATA ports, each costing a link timeout, so first
  light is slower than a microSD boot regardless of this fix.

## Complete guide — blank disk to SD-less boot

If you are starting from scratch, follow **[docs/PREPARE-DISK.md](docs/PREPARE-DISK.md)**.
It covers the whole path:

| step | what |
|---|---|
| 0 | flash U-Boot to **SPI** (mandatory — the BootROM cannot read PCIe) and verify it |
| 1 | prepare the SSD — either write a fresh OS image, or clone your running microSD system |
| 2 | give the SSD **unique** UUIDs and point its `fstab` / boot entry at itself |
| 3 | **verify** with `tools/check-target.sh` before you pull the card |
| 4 | install this fix (`install.sh --root /mnt/ssdroot`) |
| 5 | remove the microSD and boot |

The guide also lists the traps that cost the most time — duplicate UUIDs between media,
`rootwait` being dropped by `u-boot-update`, `/boot` living on the ext4 root rather than the
FAT partition, and a few shell footguns.

If you **already have a bootable system on the disk** and only need the PCIe fix, skip
straight to [Install](#install).

## Install

```sh
git clone https://github.com/Mojo24x7/rock3a-sata-ssd-boot
cd rock3a-sata-ssd-boot
sudo ./install.sh
```

`install.sh` will:

1. install `busybox` (needed inside the initramfs for `nc`/`dd`/`udhcpc`) and set
   `BUSYBOX=y` in `/etc/initramfs-tools/initramfs.conf`,
2. install the three initramfs hooks,
3. write a config file at `/etc/default/pcie-sbr-boot`,
4. add `rootwait` to `/etc/kernel/cmdline` if missing,
5. back up your current initramfs and regenerate it.

To install onto a *different* root (e.g. preparing the SSD from a running microSD system):

```sh
sudo ./install.sh --root /mnt/ssdroot --kernel 5.10.160-12-rk356x
```

Then verify before you reboot:

```sh
sudo lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'pcie-sbr|busybox|bin/dd'
```

### Configuration — `/etc/default/pcie-sbr-boot`

```sh
SBR_HOLD=1              # seconds to hold Secondary Bus Reset
SBR_FIRST_ATTEMPT=1     # which local-block retry issues the SBR
DIAG_HOST=              # IP to ship diagnostics to on failure (empty = disabled)
DIAG_PORT=9999
ENABLE_TELNET=no        # yes = root telnet shell in initramfs while waiting (DEBUG ONLY)
TELNET_PORT=23
```

`ENABLE_TELNET` defaults to **no** on purpose: it is an unauthenticated root shell. It
only exists inside the initramfs and dies at `switch_root`, but turn it on only while
you are actively debugging.

## Prerequisites

* Bootloader in **SPI flash** — the RK3568 BootROM cannot read PCIe, so U-Boot must live
  in SPI (or eMMC/microSD). See Radxa's *Install the system to NVME* guide; the SPI step
  is the same for a SATA HAT.
* A U-Boot with **PCI AHCI + SCSI support and `scsi` in `boot_targets`**. Check yours:

  ```sh
  sudo python3 tools/uboot_caps.py          # reads /dev/mtd0, needs no serial console
  ```

  You want to see `ahci_pci`, `scsi_bootdev`, `pcie_dw_rockchip` present and `scsi` in
  `boot_targets`. Radxa's `u-boot-latest 2023.07.02-3` for ROCK 3A has all of it.
* Your SSD's root must have **unique** ext4/FAT UUIDs and GPT GUIDs if it was cloned from
  the microSD, otherwise Linux may resolve `root=` to the wrong medium while both are
  present. (Not the cause of this bug, but it will confuse your testing.)

## Tested on

| | |
|---|---|
| board | Radxa ROCK 3A (RK3568), 2 GB |
| HAT | Radxa Penta SATA HAT — JMicron JMB585 (`197b:0585`) on PCIe 3.0 x2 |
| disk | 500 GB SATA SSD on port 1 |
| OS | Radxa OS, Debian 11 bullseye, kernel `5.10.160-12-rk356x` |
| U-Boot | `u-boot-latest 2023.07.02-3-b1eb2bde` in 16 MB SPI NOR |

Should apply unchanged to other RK3568/RK3588 boards booting from a PCIe device where
U-Boot loads the kernel over that same link. Reports welcome.

## Also in this repo

* **[docs/PREPARE-DISK.md](docs/PREPARE-DISK.md)** — the complete walkthrough: SPI
  bootloader, partitioning, writing an image or cloning your running system, unique UUIDs,
  `fstab`/boot-entry edits, verification, first boot, rollback, and the gotchas.
* **[tools/check-target.sh](tools/check-target.sh)** — read-only pre-flight on a prepared
  root. Checks self-consistent UUIDs, `rootwait` in *both* places, kernel/initramfs/DTB/
  overlays present, clean mountpoints, SSH keys, and that this fix is actually in the
  generated initramfs. **Run it before you pull your boot medium** — a failure here costs
  five minutes, a failure afterwards costs a card reader and another machine.
* **[tools/verify-live.sh](tools/verify-live.sh)** — run this on a *running* system
  **after a kernel upgrade or `rsetup`, before you reboot.** Checks that the boot entry
  still names the running root, that `rootwait` is in both the entry and
  `/etc/kernel/cmdline`, that every referenced kernel/initramfs/DTB/overlay exists, that
  **every** installed initramfs still contains the fix and busybox, and which recovery
  phase the last boot needed. Exits non-zero if a reboot would be unsafe.
* **[docs/REMOTE-DEBUG.md](docs/REMOTE-DEBUG.md)** — how to debug a headless board that
  won't boot **with no serial console**: get `dmesg` off it over ethernet, and get an
  interactive shell inside the initramfs. This is the part that made the diagnosis
  possible and it generalises to any boot problem.
* **[docs/DIAGNOSIS.md](docs/DIAGNOSIS.md)** — the full evidence trail, including every
  wrong hypothesis and how it was eliminated. Useful if your symptoms differ slightly.
* **[docs/RADXA-FORUM-POST.md](docs/RADXA-FORUM-POST.md)** — a write-up you can paste to a
  forum, if you want to help the next person find this.
* **[tools/uboot_caps.py](tools/uboot_caps.py)** — dump what your SPI U-Boot can actually
  boot from, by reading `/dev/mtd0`. Answers "can this board even boot that way?" in
  seconds, with no serial cable.
* **[tools/diag_listener.py](tools/diag_listener.py)** — the receiving end of the network
  bridge.

## License

MIT. See [LICENSE](LICENSE).
