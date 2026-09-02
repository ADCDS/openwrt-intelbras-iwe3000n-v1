# Shipped SSH host key — a bench credential

`dropbear_ed25519_host_key` is a **fixed, shared** dropbear host key baked into
the image. It is here because the rootfs is read-only and this board's RNG does
not seed on an idle headless boot, so generating a key at boot either blocks
forever or never starts SSH. A shipped key makes SSH come up instantly and
gives a stable host identity (no client warnings on every boot).

The cost: **every unit running a released image has the same SSH host key**, so
it grants no protection against a man-in-the-middle who has the image (and the
image is public). This is the same posture as the default root password and the
WPA2 passphrase — a bench convenience, not security. **Regenerate it before
this is anywhere real:**

```sh
dropbearkey -t ed25519 -f dropbear_ed25519_host_key   # on any box with entropy
```

then rebuild the rootfs.
