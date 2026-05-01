#!/bin/sh
# Unified script for OpenWrt 24.10 + 25.12: RAM cache + ZRAM

echo "=== VFS cache & swappiness ==="
echo 50 > /proc/sys/vm/vfs_cache_pressure
echo 0 > /proc/sys/vm/swappiness

echo "=== Logs to RAM ==="
uci set system.@system[0].log_file='/tmp/system.log'
uci commit system
/etc/init.d/log restart

echo "=== APK cache in RAM ==="
mkdir -p /tmp/apk

echo "=== ZRAM Setup ==="
opkg update 2>/dev/null || true
apk update 2>/dev/null || true
apk add --no-cache kmod-zram zram-swap 2>/dev/null || echo "zram already installed"

ZRAM_SIZE_PERCENT=44
SWAP_PRIORITY=100
ZRAM_DEVICE="/dev/zram0"

if [ -e "$ZRAM_DEVICE" ]; then
    swapoff "$ZRAM_DEVICE" 2>/dev/null
    echo 0 > /sys/block/zram0/reset 2>/dev/null
fi

TOTAL_RAM=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
ZRAM_SIZE=$(( TOTAL_RAM * ZRAM_SIZE_PERCENT / 100 * 1024 ))
echo "$ZRAM_SIZE" > /sys/block/zram0/disksize
mkswap "$ZRAM_DEVICE"
swapon -p "$SWAP_PRIORITY" "$ZRAM_DEVICE"

echo "[*] Check:"
cat /proc/swaps
free -h
echo "ZRAM: ${ZRAM_SIZE_PERCENT}% RAM"

# Autostart
if ! grep -q "zram" /etc/rc.local 2>/dev/null; then
    sed -i '/^exit 0/i /etc/init.d/zram-swap restart' /etc/rc.local 2>/dev/null || true
fi

echo "=== Done for 24.10 / 25.12 ==="
