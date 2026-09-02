# iwe3000n: rootfs init scripts (openwrt-intelbras-iwe3000n-v1 build.sh).
# This board has no /userdata worth relying on; run /etc/init.d/S??* too.
[ -f /etc/hostname ] && hostname -F /etc/hostname 2>/dev/null
for i in /etc/init.d/S??*; do
    [ -x "$i" ] && "$i" start
done

