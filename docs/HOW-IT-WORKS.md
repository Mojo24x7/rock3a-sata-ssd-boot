# How it works

## Why the disk is missing

U-Boot must bring up the PCIe link to read the kernel from the disk. It then hands off to Linux
with the link already trained:

```
rk-pcie 3c0800000.pcie: PCIe Link up, LTSSM is 0x30011
```

Rockchip's vendor driver:

```c
static int rk_pcie_establish_link(struct dw_pcie *pci)
{
    ...
    if (dw_pcie_link_up(pci) && !rk_pcie->hp_no_link) {
        dev_err(pci->dev, "link is already up\n");
        return 0;
    }
```

It returns before doing anything, so the PCI bus behind the bridge is never enumerated. The
bridge exists in `/sys/bus/pci/devices/`; the endpoint does not. No endpoint means no AHCI
driver, no SCSI host, no `/dev/sda`.

The link is not broken. Reading the root port's Link Status register (offset 0x12 in the PCIe
capability) shows:

```
LinkStatus=0x3021  speed=1  width=x2  active=1
                                      ^^^^^^^^ Data Link Layer Link Active
```

Booting the same board from a microSD, U-Boot never touches PCIe, Linux trains the link itself
(`PCIe Linking... LTSSM is 0x210021`) and everything enumerates. That is the whole difference.

## What the hook does

`scripts/local-block/pcie-sbr` runs while initramfs-tools waits for the root device.

```
step 1  wait for Data Link Layer Active  ->  set Retrain Link  ->  one PCI rescan
step 2  retrain + rescan
step 3  one Secondary Bus Reset  ->  POST_RESET_S quiet  ->  retrain  ->  rescan
step 4  remove the ENDPOINT (link stays up)  ->  rescan  ->  retrain
        3 and 4 alternate until the device appears or LOOP_BUDGET_S expires
```

On the tested hardware step 1 succeeds at 0 s and nothing else runs.

`Retrain Link` is bit 5 of Link Control, at `pcie_cap + 0x10`. Setting it makes the downstream
port renegotiate, which both completes training and recovers full speed — the link otherwise
sits at Gen1 (2.5 GT/s) even though Link Control 2 already targets the maximum.

Secondary Bus Reset is bit 6 of Bridge Control, at PCI config offset `0x3E`. It hot-resets
everything behind the bridge. It is a last resort here, not a first move: asserting it destroys
a working link, and a rescan issued too soon afterwards sees nothing.

## Constraints the hook respects

* **Probe no sooner than `POST_RESET_S` after disturbing the link.** This is the single most
  important timing in the whole hook.
* **No Secondary Bus Reset once a driver is bound to the endpoint.** It detaches the device
  (`ata2: failed to stop engine (-19)`) and causes transient read errors. The hook refuses when
  a disk node already exists.
* **Remove the endpoint, never the bridge.** Endpoint removal plus a rescan recovers the device
  with the link intact; bridge removal drops the link.
* **Do not retrain from the initramfs before the root filesystem is mounted** unless you accept
  the risk — an in-flight retrain can stall the boot with no console and no logs. That is why
  `RETRAIN` is applied around a rescan and the standalone recovery lives in
  `systemd/pcie-relink.service`, which runs after `local-fs.target`.

## initramfs-tools details worth knowing

* `local-block` scripts are called repeatedly, but only for about **30 seconds of wall clock**
  (`slumber=30` in `/usr/share/initramfs-tools/scripts/local`). The hook therefore loops
  internally rather than relying on being called again.
* **`rootwait` does not extend that.** In an initramfs boot the initramfs does the waiting and
  `init` parses only `rootdelay=`. `rootdelay=N` also inserts an unconditional `sleep N` before
  any scanning, so it costs N seconds on every boot including successful ones.
* `resolve_device()` uses `blkid`, not the `/dev/disk/by-uuid` symlink.
* The root device is passed to `local-block` scripts as `UUID=...`, not a path, so a bare
  `[ -e "$1" ]` test can never be true.
* Everything under `scripts/<dir>/` is copied into the image and executed **regardless of
  filename** — a `.bak` copy left there becomes a second active hook. Keep backups elsewhere.
* Processes started in `init-premount` are not reliably reaped by `switch_root`; shut them down
  in `init-bottom`.
