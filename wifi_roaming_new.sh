#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script
# Поддержка: OpenWrt 24.10 и 25.12+
# Режимы: Соло / R1 (роуминг) / R2 (точка доступа)

set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OpenWrt WiFi Setup Wizard                     ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ====================== ВВОД ПАРАМЕТРОВ ======================
while true; do
    echo "1) Соло роутер"
    echo "2) Основной роутер R1 (с роумингом)"
    echo "3) Дополнительная точка R2"
    read -r -p "Выбор [1-3]: " mode
    case "$mode" in
        1) TYPE="SOLO"; ROAMING=0; break ;;
        2) TYPE="R1";   ROAMING=1; break ;;
        3) TYPE="R2";   ROAMING=1; break ;;
        *) echo "[!] Неверный выбор" ;;
    esac
done

read -r -p "SSID: " SSID
while [ -z "$SSID" ] || [ ${#SSID} -gt 32 ]; do
    echo "[!] Некорректный SSID"
    read -r -p "SSID: " SSID
done

read -r -p "Пароль (минимум 8 символов): " PASSWORD
while [ ${#PASSWORD} -lt 8 ]; do
    echo "[!] Пароль слишком короткий"
    read -r -p "Пароль: " PASSWORD
done

if [ "$TYPE" = "R2" ]; then
    read -r -p "IP основного роутера [192.168.1.1]: " R1_IP
    R1_IP=${R1_IP:-192.168.1.1}
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Режим: $TYPE"
echo "SSID: $SSID"
echo "Роуминг: $([ $ROAMING -eq 1 ] && echo "ВКЛ (802.11r/k/v)" || echo "ВЫКЛ")"
[ "$TYPE" = "R2" ] && echo "IP R1: $R1_IP"
read -r -p "Всё верно? [Y/n]: " confirm
[ "$confirm" = "n" ] || [ "$confirm" = "N" ] && exit 0

# ====================== ПАКЕТЫ ======================
echo "[*] Установка пакетов..."
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk add --no-cache wpad-openssl >/dev/null 2>&1 || apk add wpad >/dev/null 2>&1
else
    opkg update >/dev/null 2>&1
    opkg remove wpad-basic wpad-mini 2>/dev/null || true
    opkg install wpad-openssl >/dev/null 2>&1 || opkg install wpad >/dev/null 2>&1
fi

# ====================== ОПРЕДЕЛЕНИЕ РАДИО ======================
echo "[*] Поиск WiFi интерфейсов..."
RADIO_24G="" RADIO_5G="" RADIO_24G_NAME="" RADIO_5G_NAME=""

for radio in $(uci show wireless 2>/dev/null | grep '=radio' | cut -d. -f1-2 | sort -u); do
    name=$(echo "$radio" | cut -d. -f2)
    band=$(uci get ${radio}.band 2>/dev/null)
    hwmode=$(uci get ${radio}.hwmode 2>/dev/null)

    if [ "$band" = "2g" ] || echo "$hwmode" | grep -qE '11g|11n'; then
        [ -z "$RADIO_24G" ] && RADIO_24G="$radio" && RADIO_24G_NAME="$name"
    elif [ "$band" = "5g" ] || echo "$hwmode" | grep -qE '11a|11ac|11ax'; then
        [ -z "$RADIO_5G" ] && RADIO_5G="$radio" && RADIO_5G_NAME="$name"
    fi
done

[ -z "$RADIO_24G" ] && [ -z "$RADIO_5G" ] && { echo "[!] WiFi не найдены!"; exit 1; }

# ====================== НАСТРОЙКИ ======================
echo "[*] Применение настроек WiFi..."

# Очистка старых интерфейсов
while uci -q delete wireless.@wifi-iface[0]; do :; done

# 2.4 ГГц
if [ -n "$RADIO_24G" ]; then
    uci set ${RADIO_24G}.disabled='0'
    uci set ${RADIO_24G}.country='RU'
    uci set ${RADIO_24G}.channel='1'
    uci set ${RADIO_24G}.htmode='HT20'
    uci set ${RADIO_24G}.noscan='1'

    uci add wireless wifi-iface >/dev/null
    iface="wireless.@wifi-iface[-1]"
    uci set $iface.device="$RADIO_24G_NAME"
    uci set $iface.network='lan'
    uci set $iface.mode='ap'
    uci set $iface.ssid="$SSID"
    uci set $iface.encryption='psk2'
    uci set $iface.key="$PASSWORD"
    uci set $iface.wmm='1'
    uci set $iface.disassoc_low_ack='0'
    
    if [ $ROAMING -eq 1 ]; then
        uci set $iface.ieee80211r='1'
        uci set $iface.mobility_domain='a1b2'
        uci set $iface.ft_over_ds='1'
        uci set $iface.ft_psk_generate_local='1'
        uci set $iface.nasid="${SSID}_24G_${TYPE}"
        uci set $iface.ieee80211k='1'
        uci set $iface.ieee80211v='1'
        uci set $iface.bss_transition='1'
    fi
fi

# 5 ГГц
if [ -n "$RADIO_5G" ]; then
    uci set ${RADIO_5G}.disabled='0'
    uci set ${RADIO_5G}.country='RU'
    uci set ${RADIO_5G}.channel='36'
    uci set ${RADIO_5G}.htmode='VHT80'
    uci set ${RADIO_5G}.noscan='1'

    uci add wireless wifi-iface >/dev/null
    iface="wireless.@wifi-iface[-1]"
    uci set $iface.device="$RADIO_5G_NAME"
    uci set $iface.network='lan'
    uci set $iface.mode='ap'
    uci set $iface.ssid="$SSID"
    uci set $iface.encryption='psk2'
    uci set $iface.key="$PASSWORD"
    uci set $iface.wmm='1'
    uci set $iface.disassoc_low_ack='0'
    
    if [ $ROAMING -eq 1 ]; then
        uci set $iface.ieee80211r='1'
        uci set $iface.mobility_domain='a1b2'
        uci set $iface.ft_over_ds='1'
        uci set $iface.ft_psk_generate_local='1'
        uci set $iface.nasid="${SSID}_5G_${TYPE}"
        uci set $iface.ieee80211k='1'
        uci set $iface.ieee80211v='1'
        uci set $iface.bss_transition='1'
    fi
fi

# ====================== СЕТЕВЫЕ НАСТРОЙКИ ======================
uci commit wireless

if [ "$TYPE" = "R2" ]; then
    # Режим точки доступа
    read -r -p "IP этой точки доступа [192.168.1.2]: " AP_IP
    AP_IP=${AP_IP:-192.168.1.2}
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.gateway="$R1_IP"
    uci set network.lan.dns="$R1_IP"
    uci set dhcp.lan.ignore='1'
    uci commit network
    /etc/init.d/dnsmasq disable >/dev/null 2>&1 && /etc/init.d/dnsmasq stop >/dev/null 2>&1 || true
else
    # Соло или R1
    uci set network.lan.netmask='255.255.255.0'
    uci set dhcp.lan.start='100'
    uci set dhcp.lan.limit='150'
    uci set dhcp.lan.leasetime='12h'
    uci commit network
    uci commit dhcp
fi

# ====================== ПРИМЕНЕНИЕ ======================
wifi reload 2>/dev/null || wifi
[ "$TYPE" = "R2" ] && /etc/init.d/network restart 2>/dev/null || true

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║               НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА               ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo "Режим: $TYPE | SSID: $SSID"
[ $ROAMING -eq 1 ] && echo "Роуминг 802.11r/k/v включён"
echo ""
echo "Готово!"

exit 0
