#!/bin/sh
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OpenWrt WiFi Setup Wizard                     ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ====================== ВВОД ПАРАМЕТРОВ ======================
while true; do
    echo "1) Соло роутер"
    echo "2) Основной роутер R1 (роуминг)"
    echo "3) Точка доступа R2"
    read -r -p "Выбор [1-3]: " mode
    case "$mode" in
        1) TYPE="SOLO"; ROAMING=0; break ;;
        2) TYPE="R1";   ROAMING=1; break ;;
        3) TYPE="R2";   ROAMING=1; break ;;
        *) echo "[!] Неверный выбор" ;;
    esac
done

read -r -p "SSID: " SSID
read -r -p "Пароль (минимум 8): " PASSWORD

[ "$TYPE" = "R2" ] && { read -r -p "IP R1 [192.168.1.1]: " R1_IP; R1_IP=${R1_IP:-192.168.1.1}; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Режим: $TYPE | SSID: $SSID"
read -r -p "Продолжить? [Y/n]: " y
[ "$y" = "n" ] || [ "$y" = "N" ] && exit 0

# ====================== ПАКЕТЫ (исправлено) ======================
echo "[*] Установка пакетов..."

if command -v apk >/dev/null 2>&1; then
    echo "[*] Обновление репозиториев..."
    apk update
    
    echo "[*] Удаление урезанной версии wpad..."
    apk remove wpad-basic-mbedtls wpad-basic wpad-mini 2>/dev/null || true
    
    echo "[*] Установка полной версии wpad..."
    apk add --no-cache wpad-openssl || apk add --no-cache wpad
else
    opkg update
    opkg remove wpad-basic wpad-mini 2>/dev/null || true
    opkg install wpad-openssl || opkg install wpad
fi

echo "[✓] Пакеты успешно установлены"

# ====================== НАСТРОЙКА ======================
echo "[*] Настройка WiFi..."

# Очистка
while uci -q delete wireless.@wifi-iface[0]; do :; done

# Поиск радио
for r in $(uci show wireless 2>/dev/null | grep '=radio' | cut -d. -f1-2); do
    name=$(echo $r | cut -d. -f2)
    band=$(uci get ${r}.band 2>/dev/null)
    if [ "$band" = "2g" ]; then
        RADIO_24="$r"; NAME_24="$name"
    elif [ "$band" = "5g" ]; then
        RADIO_5="$r"; NAME_5="$name"
    fi
done

# 2.4 GHz
[ -n "$RADIO_24" ] && {
    uci set ${RADIO_24}.disabled='0'
    uci set ${RADIO_24}.country='RU'
    uci set ${RADIO_24}.channel='1'
    uci set ${RADIO_24}.htmode='HT20'
    uci add wireless wifi-iface >/dev/null
    i="wireless.@wifi-iface[-1]"
    uci set $i.device="$NAME_24"
    uci set $i.mode='ap'
    uci set $i.network='lan'
    uci set $i.ssid="$SSID"
    uci set $i.encryption='psk2'
    uci set $i.key="$PASSWORD"
}

# 5 GHz
[ -n "$RADIO_5" ] && {
    uci set ${RADIO_5}.disabled='0'
    uci set ${RADIO_5}.country='RU'
    uci set ${RADIO_5}.channel='36'
    uci set ${RADIO_5}.htmode='VHT80'
    uci add wireless wifi-iface >/dev/null
    i="wireless.@wifi-iface[-1]"
    uci set $i.device="$NAME_5"
    uci set $i.mode='ap'
    uci set $i.network='lan'
    uci set $i.ssid="$SSID"
    uci set $i.encryption='psk2'
    uci set $i.key="$PASSWORD"
}

uci commit wireless

# Сетевые настройки
if [ "$TYPE" = "R2" ]; then
    AP_IP=${AP_IP:-192.168.1.2}
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.gateway="$R1_IP"
    uci set dhcp.lan.ignore='1'
    uci commit network
else
    uci set network.lan.netmask='255.255.255.0'
    uci commit network
fi

wifi reload 2>/dev/null || wifi

echo ""
echo "✅ НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА"
echo "SSID: $SSID"
echo "Режим: $TYPE"
echo "Готово!"
