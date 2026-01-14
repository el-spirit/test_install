#!/bin/sh
# RB2011 как простая точка доступа + свитч
# OpenWrt 19.07.x / 24.x

# ---------- СЕТЬ ----------
# Создаем LAN мост через все порты
uci set network.lan=interface
uci set network.lan.type='bridge'
uci set network.lan.ifname='eth0.0 eth0.1 eth0.2 eth0.3 eth0.4 eth0.5 eth1.1 eth1.2 eth1.3 eth1.4 eth1.5'
uci set network.lan.proto='static'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='172.16.0.20'   # статический адрес в твоей сети
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='172.16.0.1'       # шлюз
uci set network.lan.dns='172.16.0.1'     # DNS-сервер
uci commit network

# ---------- DHCP ----------
# Выключаем DHCP, чтобы основной роутер раздавал адреса
uci set dhcp.lan.ignore='1'
uci commit dhcp
/etc/init.d/dnsmasq restart

# ---------- ФИНАЛ ----------
echo "RB2011 настроен как простая точка доступа"
