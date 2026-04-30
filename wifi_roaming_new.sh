#!/bin/sh
#
# OpenWrt WiFi Setup - Final Working Version
# Протестировано на Routerich AX3000 (MediaTek Filogic)
# OpenWrt 25.12
#

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OpenWrt WiFi Setup Wizard                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Выбор режима
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
read -r -p "Пароль (мин. 8 символов): " PASSWORD
[ "$TYPE" = "R2" ] && { read -r -p "IP основного роутера [192.168.1.1]: " R1_IP; R1_IP=${R1_IP:-192.168.1.1}; }

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Режим: $TYPE | SSID: $SSID"
[ "$ROAMING" = "1" ] && echo "Роуминг: ВКЛЮЧЕН" || echo "Роуминг: ОТКЛЮЧЕН"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Продолжить? [Y/n]: " y
[ "$y" = "n" ] || [ "$y" = "N" ] && exit 0

# Пакеты
echo "[*] Установка wpad..."
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    apk del wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini 2>/dev/null || true
    apk add wpad-openssl 2>/dev/null || apk add wpad 2>/dev/null
else
    opkg update >/dev/null 2>&1
    opkg remove wpad-basic wpad-mini 2>/dev/null || true
    opkg install wpad-openssl 2>/dev/null || opkg install wpad 2>/dev/null
fi
echo "[✓] wpad установлен"

# Определяем PHY и path
echo "[*] Определение WiFi устройства..."

# Ищем path из sysfs
WIFI_PATH=""
WIFI_PATH_5G=""

for phy in phy0 phy1; do
    if [ -L "/sys/class/ieee80211/$phy" ]; then
        FULL_PATH=$(readlink -f /sys/class/ieee80211/$phy)
        # Извлекаем часть после /devices/
        DEV_PATH=$(echo "$FULL_PATH" | sed 's/.*\/devices\///' | sed 's/\/ieee80211\/.*//')
        
        BAND=$(iw $phy info 2>/dev/null | grep "Band [0-9]" | head -1 | awk '{print $2}')
        
        if [ "$BAND" = "1:" ]; then
            WIFI_PATH="$DEV_PATH"
            echo "  phy0 → 2.4GHz → $WIFI_PATH"
        elif [ "$BAND" = "2:" ]; then
            WIFI_PATH_5G="$DEV_PATH"
            echo "  phy1 → 5GHz → $WIFI_PATH_5G"
        fi
    fi
done

# Fallback если не определили path
if [ -z "$WIFI_PATH" ]; then
    # Пробуем найти через platform
    WIFI_PATH=$(find /sys/devices/platform -name "ieee80211" -type d 2>/dev/null | head -1 | sed 's/\/ieee80211//' | sed 's/.*\/devices\///')
fi

echo "[✓] Path: $WIFI_PATH"

# Параметры
COUNTRY="RU"
if [ "$TYPE" = "R1" ]; then
    CH24=1; CH5=36; NAS24="${SSID}_24G_R1"; NAS5="${SSID}_5G_R1"; MD="a1b2"
elif [ "$TYPE" = "R2" ]; then
    CH24=6; CH5=40; NAS24="${SSID}_24G_R2"; NAS5="${SSID}_5G_R2"; MD="a1b2"
else
    CH24=1; CH5=36
fi

# Создаём конфигурацию
echo "[*] Создание конфигурации..."
rm -f /etc/config/wireless

cat > /etc/config/wireless << EOF

config wifi-device 'radio0'
        option type 'mac80211'
        option path '${WIFI_PATH}'
        option band '2g'
        option channel '${CH24}'
        option htmode 'HE20'
        option country '${COUNTRY}'
        option disabled '0'
        option noscan '1'

config wifi-iface 'wifinet0'
        option device 'radio0'
        option mode 'ap'
        option network 'lan'
        option ssid '${SSID}'
        option encryption 'psk2'
        option key '${PASSWORD}'
        option wmm '1'
        option wpa_group_rekey '3600'
        option isolate '0'
        option disassoc_low_ack '0'
$(if [ "$ROAMING" = "1" ]; then
echo "        option ieee80211r '1'"
echo "        option mobility_domain '${MD}'"
echo "        option ft_over_ds '1'"
echo "        option ft_psk_generate_local '1'"
echo "        option nasid '${NAS24}'"
echo "        option ieee80211k '1'"
echo "        option rrm_neighbor_report '1'"
echo "        option ieee80211v '1'"
echo "        option bss_transition '1'"
fi)

config wifi-device 'radio1'
        option type 'mac80211'
        option path '${WIFI_PATH_5G:-${WIFI_PATH}+1}'
        option band '5g'
        option channel '${CH5}'
        option htmode 'HE80'
        option country '${COUNTRY}'
        option disabled '0'
        option noscan '1'

config wifi-iface 'wifinet1'
        option device 'radio1'
        option mode 'ap'
        option network 'lan'
        option ssid '${SSID}'
        option encryption 'psk2'
        option key '${PASSWORD}'
        option wmm '1'
        option wpa_group_rekey '3600'
        option isolate '0'
        option disassoc_low_ack '0'
$(if [ "$ROAMING" = "1" ]; then
echo "        option ieee80211r '1'"
echo "        option mobility_domain '${MD}'"
echo "        option ft_over_ds '1'"
echo "        option ft_psk_generate_local '1'"
echo "        option nasid '${NAS5}'"
echo "        option ieee80211k '1'"
echo "        option rrm_neighbor_report '1'"
echo "        option ieee80211v '1'"
echo "        option bss_transition '1'"
fi)
EOF

echo "[✓] Конфигурация создана"

# Сеть для R2
if [ "$TYPE" = "R2" ]; then
    AP_IP=${AP_IP:-192.168.1.2}
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.gateway="$R1_IP"
    uci set network.lan.dns="$R1_IP"
    uci set dhcp.lan.ignore='1'
    uci commit network
    uci commit dhcp
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
fi

# Применяем
echo "[*] Применение..."
wifi down 2>/dev/null
sleep 2
wifi up 2>/dev/null
sleep 5

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                 НАСТРОЙКА ЗАВЕРШЕНА                      ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ SSID:            $SSID                                ║"
echo "║ Режим:           $TYPE                                       ║"
echo "║ Роуминг:         $([ "$ROAMING" = "1" ] && echo 'ВКЛЮЧЕН' || echo 'ОТКЛЮЧЕН')                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "[✓] Готово!"
echo ""
echo "Проверка:"
iwinfo 2>/dev/null | grep -E "wlan|ESSID" || echo "Выполните: iwinfo"
