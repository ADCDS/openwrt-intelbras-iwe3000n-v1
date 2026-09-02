# iwe3000n: rootfs init scripts (openwrt-intelbras-iwe3000n-v1 build.sh).
# This board has no /userdata worth relying on; run /etc/init.d/S??* too.
for i in /etc/init.d/S??*; do
    [ -x "$i" ] && "$i" start
done

