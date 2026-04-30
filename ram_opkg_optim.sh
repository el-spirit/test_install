#!/bin/sh
# Скрипт для OpenWrt 25.12: RAM cache + ZRAM

echo "=== Настройка VFS cache и swappiness ==="
echo 50 > /proc/sys/vm/vfs_cache_pressure
echo 0 > /proc/sys/vm/swappiness

echo "=== Перенос логов в RAM ==="
uci set system.@system[0].log_file='/tmp/system.log'
uci commit system
/etc/init.d/log restart

echo "=== APK в RAM (tmpfs) ==="
# apk по умолчанию использует /tmp, но усиливаем
mkdir -p /tmp/apk

echo "=== ZRAM Setup ==="
opkg update 2>/dev/null || true  # если ещё есть
apk update
apk add --no-cache kmod-zram zram-swap || echo "zram уже установлен"

ZRAM_DEVICES=1
ZRAM_SIZE_PERCENT=44
SWAP_PRIORITY=100
ZRAM_DEVICE="/dev/zram0"

# Настройка ZRAM
if [ -e "$ZRAM_DEVICE" ]; then
    swapoff "$ZRAM_DEVICE" 2>/dev/null
    echo 0 > /sys/block/zram0/reset
fi

TOTAL_RAM=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
ZRAM_SIZE=$(( TOTAL_RAM * ZRAM_SIZE_PERCENT / 100 * 1024 ))

echo "$ZRAM_SIZE" > /sys/block/zram0/disksize
mkswap "$ZRAM_DEVICE"
swapon -p "$SWAP_PRIORITY" "$ZRAM_DEVICE"

echo "[*] Проверка:"
cat /proc/swaps
free -h
echo "ZRAM настроен: ${ZRAM_SIZE_PERCENT}% от RAM"

# Автозагрузка
if ! grep -q "zram" /etc/rc.local 2>/dev/null; then
    sed -i '/^exit 0/i /etc/init.d/zram-swap restart' /etc/rc.local 2>/dev/null || true
fi

echo "=== Готово для 25.12 ==="
echo "Кэш в RAM, логи в RAM, ZRAM активен."
