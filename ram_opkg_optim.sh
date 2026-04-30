#!/bin/sh
# Оптимизированный скрипт под OpenWrt 25.12 (apk + zram-swap)

echo "=== Настройка VFS cache и swappiness ==="
echo 50 > /proc/sys/vm/vfs_cache_pressure
echo 0 > /proc/sys/vm/swappiness

echo "=== Логи в RAM ==="
uci set system.@system[0].log_file='/tmp/system.log'
uci commit system
/etc/init.d/log restart

echo "=== Установка ZRAM ==="
apk update
apk add --no-cache kmod-zram zram-swap

echo "=== Настройка размера ZRAM ==="
# Отключаем текущий zram-swap
/etc/init.d/zram-swap stop 2>/dev/null

# Устанавливаем нужный размер (44%)
uci set zram-swap.@zram_swap[0].size_mb='242'   # подкорректируй при необходимости
uci commit zram-swap

# Запускаем заново
/etc/init.d/zram-swap enable
/etc/init.d/zram-swap start

echo "=== Проверка ==="
cat /proc/swaps
free -h

echo "=== Готово ==="
echo "ZRAM ~44%, кэш усилен, логи в RAM"
