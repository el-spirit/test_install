#!/bin/sh
# RB2011 legacy AP (2.4 GHz)

SSID="ChikaWiFi"
PASSWORD="irdiS0066"
COUNTRY="RU"
CHANNEL="13"

opkg update
opkg remove wpad-basic wpad-mini 2>/dev/null
opkg install wpad

uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country="$COUNTRY"
uci set wireless.radio0.channel="$CHANNEL"
uci set wireless.radio0.hwmode='11ng'
uci set wireless.radio0.htmode='HT40'

uci delete wireless.@wifi-iface[0] 2>/dev/null  # удаляем старый
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio0'
uci set wireless.@wifi-iface[-1].mode='ap'
uci set wireless.@wifi-iface[-1].network='lan'
uci set wireless.@wifi-iface[-1].ssid="$SSID"
uci set wireless.@wifi-iface[-1].encryption='psk2'
uci set wireless.@wifi-iface[-1].key="$PASSWORD"
uci set wireless.@wifi-iface[-1].disassoc_low_ack='1'
uci commit wireless

uci set dhcp.lan.ignore='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

wifi reload
