# rootfs overlay

Upstream symlinks almost the whole of `/etc` into `/userdata` — the 12 MB
partition their boards carry at `0x400000`. **This board has no such
partition.** Its writable area is the 448 KiB `rootfs_data` overlay, which comes
up empty on a fresh flash, so every one of those symlinks dangles.

The visible symptom is that the board boots to `(none) login:` and no password
works, because `/etc/passwd -> /userdata/etc/passwd` does not exist. `rcS` says
so on the way up:

```
WARNING: /userdata/etc/init.d not found
/userdata mounted successfully
===== System ready =====
```

`build.sh rootfs` replaces the symlinks the image actually needs with real
files inside the squashfs: `passwd` and `group` (login), `hostname` (so the box
is `iwe3000n`, and `iwe3000n.local` over mDNS) and the `dropbear` directory
(which carries the shipped SSH host key — see `etc/dropbear/README.md`). Content is copied verbatim from upstream's
`34-Userdata/skeleton/etc/`, so the credential is **the upstream default,
`root` / `root`** — not something invented here.

⚠ That is a published default password baked into a read-only image, and since
M5 this device is on the air with a WPA2 passphrase that is also in this repo
(`etc/hostapd.conf`). Anyone who can join the AP can log in over dropbear.
Change both before this is anywhere real. Changing the password means writing
`/userdata/etc/passwd` on the overlay, which then shadows nothing — the squashfs
copy is what `login` reads, so the symlink would have to come back for a
per-device password to take effect.

The other dangling symlinks (`TZ`, `motd`, `version`, `ntp.conf`, `eth0.conf`,
…) are left alone deliberately: nothing so far needs them, and each one
replaced is a decision about where this board's state lives that is better made
when something actually reads it.

This directory also carries what the image runs beyond upstream's skeleton:
`sbin/` (hostapd, wpa_supplicant, the `led`/`wifi-mode` helpers, the mDNS
responder), `etc/init.d/` (`S50dropbear`, `S60button`, `S90wifi`, `S95mdns`),
the button handlers in `etc/button/`, and the AP/client/DHCP configs.
