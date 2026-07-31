# Debugging a headless SBC that won't boot — with no serial console

Two techniques that turned a four-session dead end into a one-boot diagnosis. Neither
needs a USB-TTL adapter, a keyboard, or a monitor. Both work when the **root filesystem
never mounts** — which is exactly when you have no other way in.

The trick both rely on: **the initramfs is already in RAM, and on most SBCs the ethernet
driver is built into the kernel.** So by the time the boot fails, you have a working
network stack and no need for any disk at all.

---

## 0. Check the one prerequisite

The NIC driver must be **built in** (`=y`), not a module — otherwise it isn't available
before the root filesystem is mounted.

```sh
grep -E '^CONFIG_(STMMAC_ETH|STMMAC_PLATFORM|DWMAC_ROCKCHIP|PHYLIB)=' /boot/config-$(uname -r)
```

```
CONFIG_STMMAC_ETH=y
CONFIG_STMMAC_PLATFORM=y
CONFIG_DWMAC_ROCKCHIP=y      <- built in, good
CONFIG_PHYLIB=y
```

If those say `=m`, add the modules to `/etc/initramfs-tools/modules` instead.

You also want a real toolbox in the initramfs. Debian's default initramfs is **klibc
only** — it has `ipconfig`, `nfsmount`, `dmesg`, `cat`, `dd` but **no `wget` and no `nc`**:

```sh
sudo apt install busybox
sudo sed -i 's/^BUSYBOX=.*/BUSYBOX=y/' /etc/initramfs-tools/initramfs.conf
sudo update-initramfs -u
```

---

## 1. The network bridge — ship `dmesg` off a machine that won't boot

Put a script in `/etc/initramfs-tools/scripts/panic/`. initramfs-tools runs that
directory **when it is about to drop you to a rescue shell** — i.e. exactly at the moment
you would otherwise need a console.

The script gathers state, brings up ethernet, and sends everything over **raw TCP**:

```sh
ip link set eth0 up
ipconfig -t 20 eth0 || udhcpc -i eth0 -n -q -t 6      # klibc first, busybox fallback
nc "$DIAG_HOST" "$DIAG_PORT" < /run/report.txt
```

Raw TCP deliberately, not HTTP: `busybox wget`'s `--post-file` support varies by build,
and you do not want your only diagnostic channel to depend on that.

Receiving end, on any other machine on the LAN:

```sh
python3 tools/diag_listener.py          # listens on 0.0.0.0:9999, writes each dump to /tmp
```

Worth collecting in the report — this set answered the question in one boot:

| what | why |
|---|---|
| `cat /proc/cmdline` | proves which entry actually booted |
| `ls -l /dev/sd* /dev/nvme* /dev/mmcblk*`, `ls /sys/block` | is the disk there *at all*? |
| `ls -l /dev/disk/by-uuid/` | device present but UUID missing = different problem |
| per-device `vendor` `device` `class` `driver` from `/sys/bus/pci/devices/*` | which endpoints enumerated |
| `cat /proc/bus/pci/devices` | raw, in case sysfs is incomplete |
| `ls /sys/class/scsi_host/`, each `proc_name` | which controllers bound |
| **full `dmesg`** | the actual answer, usually |

### ★ Test the channel before you rely on it

From the working system, before you ever need it:

```sh
printf 'test\n' | busybox nc <listener-host> 9999
```

An untested diagnostic channel is worse than none — you will misread its silence as a
finding.

---

## 2. The telnet rescue shell — an interactive console over ethernet

The network bridge gives you one snapshot per boot. A shell lets you try twenty things per
boot. Put this in `/etc/initramfs-tools/scripts/init-premount/` so it runs **early**,
while the boot is still retrying, not only after it gives up:

```sh
ip link set eth0 up
ipconfig -t 20 eth0 || udhcpc -i eth0 -n -q -t 6
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts    # telnetd needs a pty
busybox telnetd -l /bin/sh -p 23 &
```

Then from another machine: `telnet <board-ip>`. You land in the initramfs with busybox,
and you can poke `/sys` directly:

```sh
ls /sys/bus/pci/devices/                       # what enumerated
cat /sys/bus/pci/devices/*/class               # what kind of device
echo 1 > /sys/bus/pci/rescan                   # re-enumerate
echo "- - -" > /sys/class/scsi_host/host0/scan # rescan a SCSI bus
dmesg | tail -50
```

### ⚠️ This is an unauthenticated root shell

It only exists inside the initramfs and **dies at `switch_root`** — verify with
`nc -z <board> 23` after a successful boot; it should be refused. But it is wide open
while it lives. Keep it **off by default**, enable it only while actively debugging, and
never on an untrusted network.

---

## 3. Reading raw flash without a serial console

A related trick: you can often answer "can this board even boot that way?" by reading the
bootloader straight out of SPI and looking at what drivers and boot targets it contains —
no console needed.

```sh
sudo python3 tools/uboot_caps.py
```

It reads `/dev/mtd0` and reports whether U-Boot has `ahci_pci` (PCI AHCI), `nvme`,
`pcie_dw_rockchip`, and what `boot_targets` says. That converts hours of trial-and-error
into one command. Example output from a ROCK 3A:

```
boot_targets=mmc1 mmc0 nvme scsi usb pxe dhcp spi
ahci_pci          PRESENT   <- can drive a PCIe AHCI card
dwc_ahci          absent    <- cannot drive the SoC's own SATA port
pcie_dw_rockchip  PRESENT
```

(Use Python rather than `dd` if your shell environment restricts raw-device reads.)

---

## 4. Practical notes

* **Escalate, don't guess.** `/etc/initramfs-tools/scripts/local-block/` is run
  **repeatedly** while initramfs waits for the root device. Keep a counter in
  `/run` and do something different on each retry. You get many attempts per boot.
* **`/run` survives into the booted system.** Log your hook's actions to
  `/run/something.log` — if a recovery step works and the machine boots, that log tells
  you *which* step worked. Otherwise you fix it and never learn why.
* **`rootwait` makes initramfs wait forever**, so a `panic/` hook may never fire. If you
  are relying on the panic hook for diagnostics, either drop `rootwait` for that test or
  put the reporting in `local-block` as well.
* **Back up the working initramfs** the moment you have one, especially on a machine with
  no removable boot medium left. `cp /boot/initrd.img-$(uname -r){,.WORKING}`.
* Hooks in `/etc/initramfs-tools/scripts/` are re-included on every
  `update-initramfs`, so they survive kernel upgrades. `BUSYBOX=y` persists too.
* `update-initramfs -u` does **not** necessarily regenerate your bootloader config. On
  Radxa/u-boot-menu systems, `/boot/extlinux/extlinux.conf` is built from
  `/etc/kernel/cmdline` by `u-boot-update` — edit the former and run the latter, and
  verify the change actually reached the boot entry.
