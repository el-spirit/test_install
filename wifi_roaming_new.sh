#!/bin/sh
set -e

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OpenWrt WiFi Setup Wizard                     ║"
echo "║     Соло роутер или Бесшовный роуминг (Multi-AP)      ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ====================== ВВОД ======================
while true; do
    echo "1) Соло роутер"
    echo "2) Основной роутер R1 (роуминг)"
    echo "3) Точка доступа R2 (роуминг)"
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

if [ "$TYPE" = "R2" ]; then
    read -r -p "IP основного роутера R1 [192.168.1.1]: " R1_IP
    R1_IP=${R1_IP:-192.168.1.1}
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Режим: $TYPE"
echo "Роуминг: $([ "$ROAMING" = "1" ] && echo 'ВКЛЮЧЕН' || echo 'ОТКЛЮЧЕН')"
echo "SSID: $SSID"
[ "$TYPE" = "R2" ] && echo "IP R1: $R1_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -r -p "Продолжить? [Y/n]: " y
[ "$y" = "n" ] || [ "$y" = "N" ] && exit 0

# ====================== ПАКЕТЫ ======================
echo "[*] Установка пакетов..."

if command -v apk >/dev/null 2>&1; then
    apk update
    
    echo "[*] Удаляем конфликтующие пакеты wpad..."
    for pkg in wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini wpad; do
        apk del "$pkg" 2>/dev/null || true
    done
    
    echo "[*] Устанавливаем полную версию wpad..."
    apk add wpad-openssl 2>/dev/null || apk add wpad-mbedtls 2>/dev/null || apk add wpad 2>/dev/null || {
        echo "[!] Ошибка установки wpad"
        exit 1
    }
else
    opkg update
    
    echo "[*] Удаляем конфликтующие пакеты wpad..."
    for pkg in wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini wpad; do
        opkg remove "$pkg" 2>/dev/null || true
    done
    
    echo "[*] Устанавливаем полную версию wpad..."
    opkg install wpad-openssl 2>/dev/null || opkg install wpad-mbedtls 2>/dev/null || opkg install wpad 2>/dev/null || {
        echo "[!] Ошибка установки wpad"
        exit 1
    }
fi

echo "[✓] Пакеты установлены"

# ====================== НАСТРОЙКА WIFI ======================
echo "[*] Настройка WiFi..."

# Сохраняем радио-устройства, удаляем только интерфейсы
echo "[*] Удаление старых WiFi интерфейсов..."
while uci -q delete wireless.@wifi-iface[0] 2>/dev/null; do :; done

# Получаем список радио-устройств
echo "[*] Поиск радио-устройств..."
RADIOS=$(uci show wireless | grep "='radio'" | cut -d. -f2 | cut -d= -f1)

if [ -z "$RADIOS" ]; then
    echo "[!] Ошибка: радио-устройства не найдены!"
    echo "    Создаю базовую конфигурацию..."
    
    # Создаем базовую конфигурацию WiFi
    wifi config
    
    # Повторный поиск
    RADIOS=$(uci show wireless | grep "='radio'" | cut -d. -f2 | cut -d= -f1)
fi

echo "[✓] Найдены радио-устройства:"
for radio in $RADIOS; do
    band=$(uci get wireless.${radio}.band 2>/dev/null || echo "неизвестно")
    channel=$(uci get wireless.${radio}.channel 2>/dev/null || echo "auto")
    echo "    • $radio (band: $band, channel: $channel)"
done

# Разделяем на 2.4 и 5 GHz
RADIO_24=""
RADIO_5=""
for radio in $RADIOS; do
    band=$(uci get wireless.${radio}.band 2>/dev/null)
    if [ "$band" = "2g" ]; then
        RADIO_24="$radio"
        echo "[✓] 2.4GHz: $RADIO_24"
    elif [ "$band" = "5g" ]; then
        RADIO_5="$radio"
        echo "[✓] 5GHz: $RADIO_5"
    fi
done

# Если не определили по band, используем первый и второй
if [ -z "$RADIO_24" ] && [ -z "$RADIO_5" ]; then
    RADIO_24=$(echo "$RADIOS" | head -1)
    RADIO_5=$(echo "$RADIOS" | tail -1)
    echo "[!] Band не определен, используем: 2.4GHz=$RADIO_24, 5GHz=$RADIO_5"
fi

# Параметры в зависимости от типа
if [ "$TYPE" = "R1" ]; then
    CH24=1; CH5=36
    NAS24="${SSID}_24G_R1"; NAS5="${SSID}_5G_R1"
    MOB_DOMAIN="a1b2"
elif [ "$TYPE" = "R2" ]; then
    CH24=6; CH5=40
    NAS24="${SSID}_24G_R2"; NAS5="${SSID}_5G_R2"
    MOB_DOMAIN="a1b2"
else
    CH24=1; CH5=36
    NAS24=""; NAS5=""
    MOB_DOMAIN=""
fi

# Настройка радио и создание интерфейса
setup_radio() {
    local radio="$1" channel="$2" nasid="$3" htmode="$4" band_name="$5"
    
    echo "[*] Настройка $band_name ($radio)..."
    
    # Включаем радио
    uci set wireless.${radio}.disabled='0'
    uci set wireless.${radio}.country='RU'
    uci set wireless.${radio}.channel="$channel"
    uci set wireless.${radio}.htmode="$htmode"
    uci set wireless.${radio}.noscan='1'
    
    # Создаем новый интерфейс
    uci add wireless wifi-iface
    local iface="wireless.@wifi-iface[-1]"
    
    # Привязываем к радио
    uci set ${iface}.device="$radio"
    uci set ${iface}.mode='ap'
    uci set ${iface}.network='lan'
    uci set ${iface}.ssid="$SSID"
    uci set ${iface}.encryption='psk2'
    uci set ${iface}.key="$PASSWORD"
    
    # Оптимизации
    uci set ${iface}.wmm='1'
    uci set ${iface}.wpa_group_rekey='3600'
    uci set ${iface}.isolate='0'
    uci set ${iface}.disassoc_low_ack='0'
    uci set ${iface}.beacon_int='100'
    uci set ${iface}.dtim_period='2'
    
    # Роуминг
    if [ "$ROAMING" = "1" ] && [ -n "$nasid" ]; then
        echo "  [+] Включение роуминга (NASID: $nasid)..."
        
        uci set ${iface}.ieee80211r='1'
        uci set ${iface}.mobility_domain="$MOB_DOMAIN"
        uci set ${iface}.ft_over_ds='1'
        uci set ${iface}.ft_psk_generate_local='1'
        uci set ${iface}.nasid="$nasid"
        uci set ${iface}.pmk_r1_push='1'
        
        uci set ${iface}.ieee80211k='1'
        uci set ${iface}.rrm_neighbor_report='1'
        uci set ${iface}.rrm_beacon_report='1'
        
        uci set ${iface}.ieee80211v='1'
        uci set ${iface}.bss_transition='1'
    fi
    
    echo "  [✓] $band_name настроен (канал: $channel, htmode: $htmode)"
}

# Настройка диапазонов
if [ -n "$RADIO_24" ]; then
    setup_radio "$RADIO_24" "$CH24" "$NAS24" "HT20" "2.4GHz"
else
    echo "[!] 2.4GHz радио не найдено"
fi

if [ -n "$RADIO_5" ]; then
    setup_radio "$RADIO_5" "$CH5" "$NAS5" "VHT80" "5GHz"
else
    echo "[!] 5GHz радио не найдено"
fi

# Сохраняем WiFi конфигурацию
echo "[*] Сохранение WiFi конфигурации..."
uci commit wireless

# Проверка созданных интерфейсов
echo "[*] Проверка конфигурации:"
echo "    Радио:"
uci show wireless | grep "='radio'" | while read line; do
    echo "      $line"
done
echo "    Интерфейсы:"
uci show wireless | grep "='wifi-iface'" | while read line; do
    echo "      $line"
done

# ====================== СЕТЬ ======================
echo "[*] Настройка сети..."

if [ "$TYPE" = "R2" ]; then
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
else
    uci set network.lan.netmask='255.255.255.0'
    uci set dhcp.lan.start='100'
    uci set dhcp.lan.limit='150'
    uci set dhcp.lan.leasetime='12h'
    uci set dhcp.wan.ignore='1'
    uci commit network
    uci commit dhcp
fi

# ====================== ПРИМЕНЕНИЕ ======================
echo "[*] Применение настроек..."

# Перезагружаем WiFi
echo "[*] Перезагрузка WiFi..."
wifi reload 2>&1 || wifi up 2>&1

# Проверка статуса
sleep 3
echo ""
echo "[*] Статус WiFi после применения:"
if command -v iwinfo >/dev/null 2>&1; then
    iwinfo 2>/dev/null | grep -E "ESSID|Channel|Mode|Quality" || echo "    (iwinfo не показал интерфейсы)"
else
    echo "    (iwinfo не установлен, проверьте визуально)"
fi

if [ "$TYPE" = "R2" ]; then
    /etc/init.d/network restart 2>/dev/null || true
fi

# ====================== РЕЗУЛЬТАТ ======================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            НАСТРОЙКА ЗАВЕРШЕНА                           ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Режим:           $TYPE                                       ║"
echo "║ SSID:            $SSID                                ║"
echo "║ Шифрование:      WPA2-PSK                              ║"
echo "║ Пароль:          $PASSWORD                        ║"
echo "╠══════════════════════════════════════════════════════════╣"

if [ "$ROAMING" = "1" ]; then
    echo "║ РОУМИНГ ВКЛЮЧЕН:                                      ║"
    echo "║  ✓ 802.11r (Fast BSS Transition)                       ║"
    echo "║  ✓ 802.11k (Neighbor Reports)                          ║"
    echo "║  ✓ 802.11v (BSS Transition)                            ║"
    echo "║  Mobility Domain: $MOB_DOMAIN                                    ║"
else
    echo "║ Режим:           Стандартный WiFi                       ║"
fi

echo "╠══════════════════════════════════════════════════════════╣"

if [ -n "$RADIO_24" ]; then
    echo "║ 2.4GHz:          Канал: $CH24                              ║"
    [ -n "$NAS24" ] && echo "║                  NASID: $NAS24              ║"
fi
if [ -n "$RADIO_5" ]; then
    echo "║ 5GHz:            Канал: $CH5                             ║"
    [ -n "$NAS5" ] && echo "║                  NASID: $NAS5               ║"
fi

echo "╚══════════════════════════════════════════════════════════╝"
echo ""

echo "[✓] Готово!"
echo ""
echo "[*] Для проверки выполните:"
echo "    uci show wireless"
echo "    iwinfo"
