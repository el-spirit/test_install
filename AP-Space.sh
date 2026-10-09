#!/bin/sh
# Скрипт удаления ppp и firewall для OpenWrt 25.12.5 (apk)

echo "=== Удаление пакетов ppp и firewall ==="

# Удаляем firewall4 (а также связанные пакеты, если они есть)
for pkg in firewall4 firewall nftables; do
    if apk info -e "$pkg" >/dev/null 2>&1; then
        echo "Удаляем: $pkg"
        apk del "$pkg"
    else
        echo "Пропускаем (не установлен): $pkg"
    fi
done

# Удаляем пакеты ppp
for pkg in ppp ppp-mod-pppoe ppp-mod-pppol2tp ppp-mod-pptp; do
    if apk info -e "$pkg" >/dev/null 2>&1; then
        echo "Удаляем: $pkg"
        apk del "$pkg"
    else
        echo "Пропускаем (не установлен): $pkg"
    fi
done

echo "=== Готово ==="
