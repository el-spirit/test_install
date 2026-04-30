#!/bin/sh
#
# OpenWrt WiFi Setup - Solo Router & Seamless Roaming
# Поддержка OpenWrt 24.10+ и 25.12+
# Протестировано на Routerich AX3000 (MediaTek Filogic)
#

# ====================== ВВОД ======================
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OpenWrt WiFi Setup Wizard                     ║"
echo "║     Соло роутер или Бесшовный роуминг                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

while true; do
    echo "Выберите режим работы:"
    echo "  1) Соло роутер (обычный WiFi)"
    echo "  2) Основной роутер R1 (роуминг + DHCP)"
    echo "  3) Точка доступа R2 (роуминг)"
    read -r -p "Ваш выбор [1-3]: " ROUTER_CHOICE
    
    case "$ROUTER_CHOICE" in
        1) ROUTER_TYPE="SOLO"; ROAMING=0; break ;;
        2) ROUTER_TYPE="R1";   ROAMING=1; break ;;
        3) ROUTER_TYPE="R2";   ROAMING=1; break ;;
        *) echo "[!] Неверный выбор! Попробуйте снова." ;;
    esac
done

echo ""
read -r -p "Введите имя WiFi сети (SSID): " SSID
read -r -p "Введите пароль WiFi (минимум 8 символов): " PASSWORD

if [ "$ROUTER_TYPE" = "R2" ]; then
    echo ""
    read -r -p "Введите IP основного роутера R1 [192.168.1.1]: " R1_IP
    R1_IP=${R1_IP:-192.168.1.1}
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Тип роутера: $ROUTER_TYPE"
echo "Роуминг: $([ "$ROAMING" = "1" ] && echo 'ВКЛЮЧЕН' || echo 'ОТКЛЮЧЕН')"
echo "SSID: $SSID"
echo "Пароль: $PASSWORD"
[ "$ROUTER_TYPE" = "R2" ] && echo "IP R1: $R1_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Всё верно? Продолжить? [Y/n]: " CONFIRM
[ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && exit 0

echo ""
echo "[*] Настройка $ROUTER_TYPE..."

# ====================== ПАКЕТЫ ======================
echo "[*] Проверка и установка wpad..."

if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null 2>&1
    
    # Удаляем все конфликтующие пакеты
    for pkg in wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini; do
        apk del "$pkg" 2>/dev/null || true
    done
    
    # Устанавливаем полный wpad
    apk add wpad-openssl 2>/dev/null || apk add wpad 2>/dev/null
    
elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null 2>&1
    
    for pkg in wpad-basic wpad-basic-mbedtls wpad-mini; do
        opkg remove "$pkg" 2>/dev/null || true
    done
    
    opkg install wpad-openssl 2>/dev/null || opkg install wpad 2>/dev/null
fi

echo "[✓] wpad установлен"

# ====================== ПАРАМЕТРЫ ======================
COUNTRY="RU"

if [ "$ROUTER_TYPE" = "R1" ]; then
    RADIO0_CH=1
    RADIO1_CH=36
    NASID_24="${SSID}_24G_R1"
    NASID_5="${SSID}_5G_R1"
    MOBILITY_DOMAIN="a1b2"
elif [ "$ROUTER_TYPE" = "R2" ]; then
    RADIO0_CH=6
    RADIO1_CH=40
    NASID_24="${SSID}_24G_R2"
    NASID_5="${SSID}_5G_R2"
    MOBILITY_DOMAIN="a1b2"
else
    RADIO0_CH=1
    RADIO1_CH=36
fi

# ====================== ОПРЕДЕЛЕНИЕ РАДИО ======================
echo "[*] Определение WiFi радио..."

# Определяем PHY устройства из sysfs
PHY_DEVICES=$(ls /sys/class/ieee80211/ 2>/dev/null | sort)

if [ -z "$PHY_DEVICES" ]; then
    echo "[!] WiFi устройства не найдены!"
    exit 1
fi

echo "[*] Найдены физические устройства: $PHY_DEVICES"

# Определяем индексы
RADIO0_IDX=""
RADIO1_IDX=""

for phy in $PHY_DEVICES; do
    phy_idx=$(echo "$phy" | sed 's/phy//')
    
    # Проверяем диапазоны
    BANDS=$(iw phy${phy_idx} info 2>/dev/null | grep "Band [0-9]:" | awk '{print $2}' | sed 's/://')
    
    if echo "$BANDS" | grep -q "^1$"; then
        RADIO0_IDX="$phy_idx"
        echo "  phy${phy_idx} → 2.4GHz"
    fi
    if echo "$BANDS" | grep -q "^2$"; then
        RADIO1_IDX="$phy_idx"
        echo "  phy${phy_idx} → 5GHz"
    fi
done

# Если один phy поддерживает оба диапазона (двухдиапазонный чип)
if [ "$RADIO0_IDX" = "$RADIO1_IDX" ] && [ -n "$RADIO0_IDX" ]; then
    echo "[*] Один чип с двумя диапазонами"
    # В OpenWrt 25.12 на Filogic часто phy0 = 2.4GHz, phy1 = 5GHz
    # Если только один phy, используем его для обоих диапазонов
    if [ "$(echo "$PHY_DEVICES" | wc -l)" -eq 1 ]; then
        echo "[*] Только один PHY, создаём radio0 и radio1 из phy${RADIO0_IDX}"
    fi
fi

# ====================== СОЗДАНИЕ КОНФИГУРАЦИИ ======================
echo "[*] Создание конфигурации WiFi..."

# Очищаем старую конфигурацию
rm -f /etc/config/wireless

# Создаём новую
cat > /etc/config/wireless << EOF

config wifi-device 'radio0'
        option type 'mac80211'
        option band '2g'
        option channel '${RADIO0_CH}'
        option htmode 'HT20'
        option country '${COUNTRY}'
        option disabled '0'
        option noscan '1'

config wifi-iface 'default_radio0'
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
cat << INNER
        option ieee80211r '1'
        option mobility_domain '${MOBILITY_DOMAIN}'
        option ft_over_ds '1'
        option ft_psk_generate_local '1'
        option pmk_r1_push '1'
        option nasid '${NASID_24}'
        option ieee80211k '1'
        option rrm_neighbor_report '1'
        option rrm_beacon_report '1'
        option ieee80211v '1'
        option bss_transition '1'
INNER
fi)

config wifi-device 'radio1'
        option type 'mac80211'
        option band '5g'
        option channel '${RADIO1_CH}'
        option htmode 'VHT80'
        option country '${COUNTRY}'
        option disabled '0'
        option noscan '1'

config wifi-iface 'default_radio1'
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
cat << INNER
        option ieee80211r '1'
        option mobility_domain '${MOBILITY_DOMAIN}'
        option ft_over_ds '1'
        option ft_psk_generate_local '1'
        option pmk_r1_push '1'
        option nasid '${NASID_5}'
        option ieee80211k '1'
        option rrm_neighbor_report '1'
        option rrm_beacon_report '1'
        option ieee80211v '1'
        option bss_transition '1'
INNER
fi)

EOF

echo "[✓] Конфигурация создана"

# ====================== СЕТЕВЫЕ НАСТРОЙКИ ======================
echo "[*] Настройка сети..."

if [ "$ROUTER_TYPE" = "R2" ]; then
    AP_IP=${AP_IP:-192.168.1.2}
    read -r -p "IP для этой точки доступа [$AP_IP]: " input_ip
    AP_IP=${input_ip:-$AP_IP}
    
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.netmask='255.255.255.0'
    uci set network.lan.gateway="$R1_IP"
    uci set network.lan.dns="$R1_IP"
    uci set dhcp.lan.ignore='1'
    
    uci commit network
    uci commit dhcp
    
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    /etc/init.d/firewall disable 2>/dev/null || true
    /etc/init.d/firewall stop 2>/dev/null || true
    
    echo "[✓] Настроена точка доступа"
fi

# ====================== ПРИМЕНЕНИЕ ======================
echo "[*] Применение настроек WiFi..."

# Загружаем модули WiFi если нужно
wifi down 2>/dev/null || true
sleep 2
wifi up 2>/dev/null || wifi 2>/dev/null

sleep 3

# Проверяем результат
echo ""
echo "[*] Статус WiFi после применения:"

if command -v iwinfo >/dev/null 2>&1; then
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep wlan); do
        INFO=$(iwinfo $iface info 2>/dev/null)
        if [ -n "$INFO" ]; then
            echo "  $iface: $(echo "$INFO" | grep -E "ESSID|Channel|Mode" | tr '\n' ' ')"
        fi
    done
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Режим:           $ROUTER_TYPE                                       ║"
echo "║ SSID:            $SSID                                ║"
echo "║ Шифрование:      WPA2-PSK                              ║"
echo "║ Пароль:          $PASSWORD                        ║"
if [ "$ROAMING" = "1" ]; then
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║ РОУМИНГ ВКЛЮЧЕН:                                      ║"
    echo "║  2.4GHz NASID: $NASID_24          ║"
    echo "║  5GHz NASID:   $NASID_5           ║"
    echo "║  Mobility Domain: $MOBILITY_DOMAIN                                ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "[✓] Готово!"
echo ""
echo "[*] Если WiFi не появился, выполните вручную:"
echo "    wifi down && wifi up"
echo ""
echo "[*] Для проверки:"
echo "    iwinfo"
echo "    uci show wireless"
