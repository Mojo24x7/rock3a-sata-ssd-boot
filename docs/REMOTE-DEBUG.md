# Getting a shell inside the initramfs

If the root device does not appear, the initramfs drops to a rescue shell on the console. On a
headless board with no serial adapter that is unreachable, so arrange remote access *before*
you need it. Two options.

## 1. dropbear-initramfs — real SSH, key authentication (recommended)

```sh
sudo apt install dropbear-initramfs
sudo install -m 600 ~/.ssh/id_ed25519.pub /etc/dropbear-initramfs/authorized_keys
echo 'DROPBEAR_OPTIONS="-p 2222 -s -j -k"' | sudo tee -a /etc/dropbear-initramfs/config
sudo update-initramfs -u
```

* `-p 2222` keeps dropbear's host key from clashing with the real sshd on port 22, so you do
  not get host-key warnings after the system boots.
* `-s` disables password authentication, `-j -k` disable port forwarding.
* Networking must be configured in the initramfs: add `ip=dhcp` to `/etc/kernel/cmdline` and
  run `sudo u-boot-update`.

Verify it is actually in the image before relying on it:

```sh
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'dropbear|authorized_keys'
```

Then during a failed boot:

```sh
ssh -p 2222 -i ~/.ssh/id_ed25519 root@<board-ip>
cat /run/pcie-sbr.log          # what the recovery hook has tried
ls /sys/bus/pci/devices/       # is the endpoint enumerated?
ls /dev/sd*                    # is there a disk?
```

dropbear starts in `init-premount`, before the wait for the root device, and is shut down at
`init-bottom`, so it covers exactly the window you need.

## 2. ENABLE_TELNET — an nc root shell (debugging only)

Set `ENABLE_TELNET=yes` in `/etc/default/pcie-sbr-boot` and `update-initramfs -u`. This starts
an **unauthenticated root shell** on port 23 (`TELNET_PORT`). Use it only on a trusted network
and turn it off afterwards.

Debian's busybox is built without the `telnetd` applet, so `nc -ll -e /bin/sh` is used. Check
your own build if you are adapting this:

```sh
busybox --list | grep -x telnetd    # empty on Debian
busybox --list | grep -x nc         # present
```

## Automatic failure reports

Set `DIAG_HOST` (and optionally `DIAG_PORT`, default 9999) in `/etc/default/pcie-sbr-boot`.
When the initramfs gives up, `scripts/panic/pcie-sbr-diag` ships `/proc/cmdline`, the PCI and
SCSI and block device state, the recovery hook log and full `dmesg` over raw TCP.

On the receiving machine:

```sh
python3 tools/diag_listener.py            # writes /tmp/rk3a-diag-<timestamp>-<n>.txt
```

Raw TCP is used deliberately so it does not depend on which `wget` or `nc` variant busybox
provides. Test the path before trusting it:

```sh
busybox nc <host> 9999          # from the target
```

## Cleanup at handover

`scripts/init-bottom/pcie-sbr-shell-off` kills the `nc` shell before `switch_root`. This is
required, not optional: initramfs processes are not reliably reaped, and without it the
listener survives into the booted system as a permanent unauthenticated root shell. Confirm
after a boot:

```sh
sudo ss -lntp | grep -E ':23 |:2222 '     # expect no output
```

## Notes on the initramfs environment

* `PATH` in a dropbear session is minimal — use absolute paths (`/sbin/blkid`).
* `resolve_device()` uses `blkid`, not the `/dev/disk/by-uuid` symlink.
* The rescue shell is `sh -i` with stdin on the console; it ignores `SIGTERM`.
* After giving up, `scripts/local` loops `while ! resolve_device ...; do panic ...; done`, so
  exiting the rescue shell re-checks and continues the boot if the device has since appeared.
* `/run` is a tmpfs — `/run/pcie-sbr.log` is lost on power cycle but survives into the booted
  system on a successful boot.
