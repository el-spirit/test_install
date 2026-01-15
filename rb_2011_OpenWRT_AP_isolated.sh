#!/bin/sh
#
# RB2011 UiAS-2HnD — умная точка доступа + VLAN изоляция 100Мбит портов
#

# ----------------------------
# Параметры
# ----------------------------

# Основная LAN (гигабит)
LAN_PORTS_GIGA="eth0.0 eth0.1 eth0.2 eth0.3 eth0.4 eth0.5"

# Подсеть для 100Мбит портов
LAN100_PORTS="eth1.1 eth1.2 eth1.3 eth1.4"
LAN100_SUBNET="192.168.10.1"
LAN100_MASK="255.255.255.0"

# ----------------------------
# Удаляем старые интерфейсы и DHCP
# ----------------------------
uci delete network.lan 2>/dev/null
uci delete network.lan100 2>/dev/null
uci delete dhcp.lan100 2>/dev/null
uci commit network
uci commit dhcp

# ----------------------------
# Настройка основной LAN (гигабит)
# ----------------------------
uci set network.lan=interface
uci set network.lan.type='bridge'
uci set network.lan.ifname="$LAN_PORTS_GIGA"
uci set network.lan.proto='static'
uci set network.lan.ipaddr='172.16.0.20'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='172.16.0.1'
uci set network.lan.dns='172.16.0.1'
uci commit network

# ----------------------------
# Настройка подсети 100Мбит
# ----------------------------
uci set network.lan100=interface
uci set network.lan100.proto='static'
uci set network.lan100.type='bridge'
uci set network.lan100.ifname="$LAN100_PORTS"
uci set network.lan100.ipaddr="$LAN100_SUBNET"
uci set network.lan100.netmask="$LAN100_MASK"
uci commit network

# ----------------------------
# DHCP для LAN100
# ----------------------------
uci set dhcp.lan100=dhcp
uci set dhcp.lan100.interface='lan100'
uci set dhcp.lan100.start='100'
uci set dhcp.lan100.limit='50'
uci set dhcp.lan100.leasetime='12h'
uci commit dhcp

# ----------------------------
# Firewall для LAN100 (NAT + форвардинг)
# ----------------------------
uci add firewall zone
uci set firewall.@zone[-1].name='lan100'
uci set firewall.@zone[-1].network='lan100'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci set firewall.@zone[-1].masq='1'
uci commit firewall

# Разрешаем LAN100 ходить в LAN
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan100'
uci set firewall.@forwarding[-1].dest='lan'
uci commit firewall

# ----------------------------
# Применяем настройки
# ----------------------------
/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
wifi reload

echo "=== Умная точка доступа готова ==="
echo "LAN (гигaбит) IP: 172.16.0.20"
echo "LAN100 (100Мбит) IP: $LAN100_SUBNET"
