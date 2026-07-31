# rock3a-sata-ssd-boot

Boot a Radxa ROCK 3A from a SATA disk behind a PCIe card (e.g. the Penta SATA HAT), with no
microSD or eMMC present.

Tested on a ROCK 3A + Penta SATA HAT (JMicron JMB585), Radxa Debian 11, kernel
`5.10.160-12-rk356x`, U-Boot in SPI. The same fix should apply to any Rockchip board whose
vendor `rk-pcie` driver is used with a PCIe storage controller.

Result: root on `/dev/sda3`, no removable media, PCIe link at full **Gen3 (8.0 GT/s)**,
**~31 s** to userspace.

## The symptom

U-Boot finds the disk and loads the kernel from it, then the initramfs cannot:

```
Gave up waiting for root file system device
ALERT!  UUID=... does not exist.  Dropping to a shell!
(initramfs)
```

`lspci` inside the initramfs shows the PCIe **bridge** but not the storage controller behind
it, and there is no `/dev/sda`.

## The cause

U-Boot brings up the PCIe link in order to read the kernel off the disk, then hands off to
Linux with the link already trained:

```
rk-pcie 3c0800000.pcie: PCIe Link up, LTSSM is 0x30011
```

Rockchip's `rk_pcie_establish_link()` returns early when `dw_pcie_link_up()` is already true,
so Linux never **enumerates** the bus behind the bridge. The link itself is fine — reading the
root port's Link Status register shows `Data Link Layer Link Active = 1` — there is simply no
PCI device created for the endpoint, so no AHCI, no SCSI host, no disk.

Boot the same board from a microSD and the link comes up cold, Linux trains it itself
(`PCIe Linking... LTSSM is 0x210021`), and everything enumerates normally. That difference is
the whole bug.

## The fix

A `local-block` initramfs hook, which initramfs-tools runs while it waits for the root
device. It escalates least-invasive first:

| step | action | typical cost |
|---|---|---|
| 1 | wait for the link to report Data Link Layer Active, set **Retrain Link**, then **one PCI rescan** | ~0-7 s |
| 2 | retrain + rescan again | ~7 s |
| 3 | one Secondary Bus Reset → **10 s quiet** → retrain → rescan | ~20 s |
| 4 | remove the **endpoint** (not the bridge) → rescan → retrain | ~15 s |

Steps 3 and 4 then alternate until the device appears or the budget expires. On the tested
hardware **step 1 succeeds immediately** and nothing else runs:

```
[pcie-sbr #1] bridge: 0002:20:00.0  LinkStatus=0x3021 speed=1 width=x2 active=1
[pcie-sbr #1] step 1: plain rescan, NO reset (the link is usually already up)
[pcie-sbr #1]   link active after 0s
[pcie-sbr #1]   retrain 0002:20:00.0: 2.5 GT/s -> 8.0 GT/s (max 8.0)
[pcie-sbr #1] after step 1 (0s): pci=0002:20:00.0 0002:21:00.0 blk=/dev/sda
[pcie-sbr #1] *** TARGET PRESENT - step 1 worked at 0s ***
```

Three rules matter and are enforced in the hook:

* **Do not probe sooner than ~10 s after disturbing the link.** A rescan issued while the link
  is still training sees nothing, and re-resetting shortly afterwards destroys the link again.
* **Never assert a Secondary Bus Reset once a driver is bound to the endpoint.** It detaches
  the device under the driver (`ata2: failed to stop engine (-19)`) and produces transient
  read errors. The hook refuses if a disk node already exists.
* **Remove the endpoint, not the bridge.** Removing the endpoint and rescanning recovers the
  device while the link stays up; removing the bridge drops the link.

**Retrain Link** (bit 5 of Link Control in the PCIe capability) is what recovers full speed: a
hot reset leaves the link at Gen1 even though both ends advertise more and Link Control 2
already targets the maximum. On a multi-port SATA card that is the difference between ~500 MB/s
and ~2 GB/s shared across all ports.

## Install

On the target root filesystem:

```sh
git clone https://github.com/Mojo24x7/rock3a-sata-ssd-boot
cd rock3a-sata-ssd-boot
sudo ./install.sh                 # running system
sudo ./install.sh --root /mnt     # or another root, e.g. from a rescue boot
```

That installs the hooks, the config file, the systemd unit, and rebuilds the initramfs.

Requirements, all checked by `install.sh`:

| need | check |
|---|---|
| Rockchip NPU-era vendor kernel with `rk-pcie` | `dmesg \| grep rk-pcie` |
| `initramfs-tools` | `dpkg -l initramfs-tools` |
| `busybox` in the initramfs (`od`, `nc`) | `BUSYBOX=y` in `/etc/initramfs-tools/initramfs.conf` |
| bootloader in SPI able to read the disk | `strings /dev/mtd0 \| grep -i ahci` |
| `rootwait` and (optionally) `ip=dhcp` in the kernel command line | `/etc/kernel/cmdline` |

`apt-mark hold busybox` is worth setting: the hook reads PCI config space with `od`, which
klibc does not provide.

To prepare a disk from scratch — partitioning, copying the system, making it self-referential
— see **[docs/PREPARE-DISK.md](docs/PREPARE-DISK.md)**.

## Configuration

`/etc/default/pcie-sbr-boot`, copied into the initramfs at build time. Run
`sudo update-initramfs -u` after changing it.

| key | default | meaning |
|---|---|---|
| `SETTLE_S` | `15` | max seconds to wait for Data Link Layer Active. Polled once a second and exits as soon as the link is up, so a healthy boot pays only what it needs. |
| `POST_RESET_S` | `10` | quiet time after anything that disturbs the link, before probing. Below ~10 s the probe lands mid-training and sees nothing. |
| `RETRAIN` | `yes` | set Retrain Link after a reset, recovering full link speed. |
| `SBR_HOLD` | `1` | seconds to hold Secondary Bus Reset. |
| `LOOP_BUDGET_S` | `150` | how long the hook keeps retrying inside one invocation. |
| `DIAG_HOST` | *(empty)* | if set, ship dmesg + PCI/SCSI/block state here over raw TCP when the boot fails. Receiver: `tools/diag_listener.py`. |
| `ENABLE_TELNET` | `no` | start an **unauthenticated root shell** (`nc`) inside the initramfs. Debugging only. |
| `TELNET_PORT` | `23` | port for that shell. |

The hook owns its own retry budget because initramfs-tools gives `local-block` only about
30 seconds of wall clock (`slumber=30` in `/usr/share/initramfs-tools/scripts/local`). Note
that `rootwait` does **not** extend this — in an initramfs boot the initramfs does the waiting
and `init` parses only `rootdelay=`, and `rootdelay=N` adds an unconditional sleep to every
boot including successful ones.

## Recovering full link speed after boot

`systemd/pcie-relink.service` runs `tools/pcie-relink.sh --apply` once the root filesystem is
mounted, and sets Retrain Link on any bridge whose link is below its maximum. With
`RETRAIN=yes` in the initramfs this is usually redundant, and it is harmless when there is
nothing to do. Run it by hand to inspect without changing anything:

```sh
sudo tools/pcie-relink.sh            # report only
sudo tools/pcie-relink.sh --apply    # retrain
```

Do **not** do this from the initramfs: retraining before the root filesystem is mounted can
stall the boot with no console and no logs.

## Getting a shell inside the initramfs

If a boot fails you need a way in. Two options, both documented in
**[docs/REMOTE-DEBUG.md](docs/REMOTE-DEBUG.md)**:

* **`dropbear-initramfs`** — real SSH, key authentication. Recommended.
  ```sh
  sudo apt install dropbear-initramfs
  sudo install -m 600 ~/.ssh/id_ed25519.pub /etc/dropbear-initramfs/authorized_keys
  echo 'DROPBEAR_OPTIONS="-p 2222 -s -j -k"' | sudo tee -a /etc/dropbear-initramfs/config
  sudo update-initramfs -u
  ```
  Port 2222 keeps its host key from clashing with the real sshd on 22. Add `ip=dhcp` to
  `/etc/kernel/cmdline` and run `sudo u-boot-update`.

* **`ENABLE_TELNET=yes`** — an `nc` root shell on port 23, no authentication. Debugging only.
  Note Debian's busybox has no `telnetd` applet, so `nc -ll -e` is used instead.

Both are shut down by `scripts/init-bottom/pcie-sbr-shell-off` before `switch_root`, because
initramfs processes are not reliably reaped and an `nc` listener will otherwise survive into
the booted system as an unauthenticated root shell.

## Verifying

```sh
sudo tools/check-target.sh /mnt   # a prepared root, before you remove the old boot medium
sudo tools/verify-live.sh         # a running system, before you restart it
```

`verify-live.sh` also reports which recovery step the last boot needed, from
`/run/pcie-sbr.log`.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `ALERT! UUID=... does not exist` | the hook is not in the image. `lsinitramfs /boot/initrd.img-$(uname -r) \| grep pcie-sbr` |
| hook runs but nothing appears | raise `POST_RESET_S`. Probing too soon after a reset is the most common cause. |
| link comes up at 2.5 GT/s | `RETRAIN=yes`, or run `tools/pcie-relink.sh --apply` after boot. |
| transient read errors, `failed to stop engine (-19)` | something reset the bus while a driver held the endpoint. Do not run resets by hand once the disk is in use. |
| boot works from microSD but not without it | expected before this fix; the microSD path trains the link cold. |
| `od: not found` in the initramfs | `BUSYBOX=y` in `initramfs.conf`, then `update-initramfs -u`. |
| overlays vanish after an upgrade | `U_BOOT_FDT_OVERLAYS` in `/etc/default/u-boot`, or let `rsetup` manage `/boot/dtbo/*.dtbo` and leave that variable unset. |
| `rootwait` missing after an upgrade | keep it in `/etc/kernel/cmdline`; `u-boot-update` regenerates the boot entry from there. |

## The proper fix

This is a workaround in userspace. The right fix is in the kernel: `rk_pcie_establish_link()`
should not return early merely because the link is already up — it should still enumerate, or
reset and retrain as it does on a cold boot. Alternatively U-Boot could leave the controller in
reset when handing over.

## Licence

MIT. See [LICENSE](LICENSE).
