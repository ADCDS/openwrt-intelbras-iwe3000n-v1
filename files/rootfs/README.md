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

`build.sh rootfs` replaces the two symlinks that login actually needs with real
files inside the squashfs. Content is copied verbatim from upstream's
`34-Userdata/skeleton/etc/`, so the credential is **the upstream default,
`root` / `root`** — not something invented here.

⚠ That is a published default password baked into a read-only image. It is fine
for a bench board with no radio and no routed network, and it must be changed
before M5 (hostapd/AP) puts this device on the air. Changing it means writing
`/userdata/etc/passwd` on the overlay, which then shadows nothing — the squashfs
copy is what `login` reads, so the symlink would have to come back for a
per-device password to take effect.

The other dangling symlinks (`TZ`, `hostname`, `motd`, `version`, `ntp.conf`,
`eth0.conf`, `dropbear`, …) are left alone deliberately: nothing so far needs
them, and each one replaced is a decision about where this board's state lives
that is better made when something actually reads it.
