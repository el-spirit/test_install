#!/bin/sh
# OpenWrt 24.10.5
# Seamless Wi-Fi Roaming: R1 + 2–4 AP
# iPhone / Samsung TV safe

# ===== ОБЩИЕ НАСТРОЙКИ =====
SSID="ChikaWiFi"
PASSWORD="irdiS0066"
COUNTRY="RU"

NASID_24="ChikaWiFi_24G"
NASID_5="ChikaWiFi_5G"
MOBILITY_DOMAIN="abcd"

RSSI_24="-73"
RSSI_5="-70"

# ===== ВЫБОР РЕЖИМА =====
echo "Выберите режим устройства:"
echo "1) R1 — основной роутер (DHCP ВКЛ)"
echo "2) AP — точка доступа (DHCP ВЫКЛ)"
read -r MODE

case "$MODE" in
  1) DEVICE_MODE="R1" ;;
  2) DEVICE_MODE="AP" ;;
  *) echo "Неверный выбор"; exit 1 ;;
esac

# ===== ВЫБОР AP =====
if [ "$DEVICE_MODE" = "AP" ]; then
  echo "Выберите номер точки доступа:"
  echo "1) AP1 (1 / 36)"
  echo "2) AP2 (6 / 44)"
  echo "3) AP3 (11 / 149)"
  echo "4) AP4 (1 / 157)"
  read -r AP_NUM

  case "$AP_NUM" in
    1) CH24=1;  CH5=36 ;;
    2) CH24=6;  CH5=44 ;;
    3) CH24=11; CH5=149 ;;
    4) CH24=1;  CH5=157 ;;
    *) echo "Неверный номер AP"; exit 1 ;;
  esac
else
  CH24=1
  CH5=36
fi

# ===== WPAD =====
opkg update
opkg remove wpad-basic wpad-mini 2>/dev/null
opkg install wpad

# ===== 2.4 GHz =====
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country="$COUNTRY"
uci set wireless.radio0.channel="$CH24"

uci set wireless.@wifi-iface[0].device='radio0'
uci set wireless.@wifi-iface[0].mode='ap'
uci set wireless.@wifi-iface[0].network='lan'
uci set wireless.@wifi-iface[0].ssid="$SSID"
uci set wireless.@wifi-iface[0].encryption='psk2'
uci set wireless.@wifi-iface[0].key="$PASSWORD"

uci set wireless.@wifi-iface[0].ieee80211r='1'
uci set wireless.@wifi-iface[0].mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.@wifi-iface[0].ft_over_ds='1'
uci set wireless.@wifi-iface[0].ft_psk_generate_local='1'
uci set wireless.@wifi-iface[0].nasid="$NASID_24"

uci set wireless.@wifi-iface[0].ieee80211k='1'
uci set wireless.@wifi-iface[0].ieee80211v='1'
uci set wireless.@wifi-iface[0].rssi_min="$RSSI_24"
uci set wireless.@wifi-iface[0].disassoc_low_ack='1'

# ===== 5 GHz =====
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country="$COUNTRY"
uci set wireless.radio1.channel="$CH5"

uci set wireless.@wifi-iface[1].device='radio1'
uci set wireless.@wifi-iface[1].mode='ap'
uci set wireless.@wifi-iface[1].network='lan'
uci set wireless.@wifi-iface[1].ssid="$SSID"
uci set wireless.@wifi-iface[1].encryption='psk2'
uci set wireless.@wifi-iface[1].key="$PASSWORD"

uci set wireless.@wifi-iface[1].ieee80211r='1'
uci set wireless.@wifi-iface[1].mobility_domain="$MOBILITY_DOMAIN"
uci set wireless.@wifi-iface[1].ft_over_ds='1'
uci set wireless.@wifi-iface[1].ft_psk_generate_local='1'
uci set wireless.@wifi-iface[1].nasid="$NASID_5"

uci set wireless.@wifi-iface[1].ieee80211k='1'
uci set wireless.@wifi-iface[1].ieee80211v='1'
uci set wireless.@wifi-iface[1].rssi_min="$RSSI_5"
uci set wireless.@wifi-iface[1].disassoc_low_ack='1'

# ===== DHCP =====
if [ "$DEVICE_MODE" = "AP" ]; then
  echo "[*] Отключаем DHCP на AP"
  uci set dhcp.lan.ignore='1'
  uci commit dhcp
  /etc/init.d/dnsmasq restart
else
  echo "[*] R1 — DHCP оставлен включённым"
fi

# ===== APPLY =====
uci commit wireless
wifi reload

echo "================================="
echo "Готово!"
echo "Режим: $DEVICE_MODE"
[ "$DEVICE_MODE" = "AP" ] && echo "Точка доступа: AP$AP_NUM"
echo "SSID: $SSID"
echo "================================="
