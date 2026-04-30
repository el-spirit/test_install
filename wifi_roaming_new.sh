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

# ====================== ОПРЕДЕЛЕНИЕ РАДИО ======================
echo "[*] Определение радио-устройств..."

# Функция поиска радио через разные методы
find_radios() {
    # Метод 1: UCI конфигурация
    if [ -f /etc/config/wireless ]; then
        RADIOS_UCI=$(uci show wireless 2>/dev/null | grep "='radio'" | cut -d. -f2 | cut -d= -f1)
        if [ -n "$RADIOS_UCI" ]; then
            echo "[*] Найдено через UCI: $RADIOS_UCI"
            echo "$RADIOS_UCI"
            return 0
        fi
    fi
    
    # Метод 2: Физические устройства через iw
    if command -v iw >/dev/null 2>&1; then
        PHY_DEVICES=$(iw list 2>/dev/null | grep "Wiphy" | awk '{print $2}')
        if [ -n "$PHY_DEVICES" ]; then
            echo "[*] Найдено через iw: $PHY_DEVICES"
            for phy in $PHY_DEVICES; do
                echo "radio${phy}"
            done
            return 0
        fi
    fi
    
    # Метод 3: Поиск в sysfs
    if [ -d /sys/class/ieee80211 ]; then
        SYSFS_PHY=$(ls /sys/class/ieee80211/ 2>/dev/null)
        if [ -n "$SYSFS_PHY" ]; then
            echo "[*] Найдено через sysfs: $SYSFS_PHY"
            for phy in $SYSFS_PHY; do
                echo "${phy}"
            done
            return 0
        fi
    fi
    
    return 1
}

RADIOS=$(find_radios)

if [ -z "$RADIOS" ]; then
    echo "[!] Радио-устройства не найдены!"
    echo "[*] Пробуем создать через wifi config..."
    
    # Удаляем старую конфигурацию
    rm -f /etc/config/wireless
    
    # Создаем новую
    wifi config 2>/dev/null || true
    
    # Пробуем снова
    RADIOS=$(find_radios)
    
    if [ -z "$RADIOS" ]; then
        echo "[!] КРИТИЧЕСКАЯ ОШИБКА: Не удалось обнаружить WiFi устройства!"
        echo "    Проверьте:"
        echo "    1. Установлены ли драйверы WiFi"
        echo "    2. Работает ли WiFi модуль"
        echo "    3. Вывод команды: iw list"
        exit 1
    fi
fi

# Определяем 2.4GHz и 5GHz
RADIO_24=""
RADIO_5=""

for radio in $RADIOS; do
    # Проверяем band в UCI если есть
    band=$(uci get wireless.${radio}.band 2>/dev/null || echo "")
    
    if [ "$band" = "2g" ]; then
        RADIO_24="$radio"
    elif [ "$band" = "5g" ]; then
        RADIO_5="$radio"
    else
        # Определяем по физическим возможностям
        if command -v iw >/dev/null 2>&1; then
            phy_num=$(echo "$radio" | sed 's/radio//' | sed 's/phy//')
            bands=$(iw phy${phy_num} info 2>/dev/null | grep "Band [0-9]:" || echo "")
            
            if echo "$bands" | grep -q "Band 1:"; then
                RADIO_24="$radio"
                echo "[*] $radio поддерживает 2.4GHz (определено через iw)"
            fi
            if echo "$bands" | grep -q "Band 2:"; then
                RADIO_5="$radio"
                echo "[*] $radio поддерживает 5GHz (определено через iw)"
            fi
        fi
    fi
done

# Если не определили - используем первый как 2.4, второй как 5
if [ -z "$RADIO_24" ] && [ -z "$RADIO_5" ]; then
    COUNT=0
    for radio in $RADIOS; do
        COUNT=$((COUNT + 1))
    done
    
    if [ "$COUNT" -ge 2 ]; then
        RADIO_24=$(echo "$RADIOS" | head -1)
        RADIO_5=$(echo "$RADIOS" | tail -1)
        echo "[*] Используем $RADIO_24 как 2.4GHz, $RADIO_5 как 5GHz"
    elif [ "$COUNT" -eq 1 ]; then
        RADIO_24=$(echo "$RADIOS" | head -1)
        echo "[*] Найдено только одно радио: $RADIO_24"
        echo "[*] Проверяем поддержку диапазонов..."
        
        # Пробуем определить какой это диапазон
        if command -v iw >/dev/null 2>&1; then
            phy_num=$(echo "$RADIO_24" | sed 's/radio//' | sed 's/phy//')
            if iw phy${phy_num} info 2>/dev/null | grep -q "Band 2:"; then
                RADIO_5="$RADIO_24"
                echo "[*] $RADIO_24 будет использован для 5GHz"
            else
                echo "[*] $RADIO_24 будет использован для 2.4GHz"
            fi
        fi
    fi
fi

echo "[✓] Итоговая конфигурация:"
echo "    2.4GHz: ${RADIO_24:-не найден}"
echo "    5GHz: ${RADIO_5:-не найден}"

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

# ====================== НАСТРОЙКА РАДИО ======================
echo "[*] Настройка радио и создание интерфейсов..."

setup_radio() {
    local radio="$1" channel="$2" nasid="$3" htmode="$4" band_name="$5"
    
    if [ -z "$radio" ]; then
        echo "[!] Пропускаем $band_name - радио не указано"
        return 1
    fi
    
    echo "[*] Настройка $band_name ($radio)..."
    
    # Проверяем существование радио в UCI
    if ! uci get wireless.${radio} >/dev/null 2>&1; then
        echo "[*] Создаем запись для $radio в UCI..."
        uci set wireless.${radio}=wifi-device
        uci set wireless.${radio}.type='mac80211'
    fi
    
    # Настройка радио
    uci set wireless.${radio}.disabled='0'
    uci set wireless.${radio}.country='RU'
    uci set wireless.${radio}.channel="$channel"
    uci set wireless.${radio}.htmode="$htmode"
    uci set wireless.${radio}.noscan='1'
    
    # Удаляем старые интерфейсы для этого радио
    while uci -q delete wireless.@wifi-iface[$(uci show wireless | grep "device='${radio}'" | head -1 | cut -d[ -f2 | cut -d] -f1)] 2>/dev/null; do
        :
    done
    
    # Создаем новый интерфейс
    uci add wireless wifi-iface
    local iface="wireless.@wifi-iface[-1]"
    
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
setup_radio "$RADIO_24" "$CH24" "$NAS24" "HT20" "2.4GHz"
setup_radio "$RADIO_5" "$CH5" "$NAS5" "VHT80" "5GHz"

# Сохраняем
echo "[*] Сохранение конфигурации..."
uci commit wireless

# Проверка результата
echo "[*] Проверка созданной конфигурации:"
echo "--- Радио ---"
uci show wireless | grep "='radio'" || echo "  НЕТ РАДИО!"
echo "--- Интерфейсы ---"
uci show wireless | grep "='wifi-iface'" || echo "  НЕТ ИНТЕРФЕЙСОВ!"

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
wifi reload 2>&1 || wifi up 2>&1

sleep 3

echo ""
echo "[*] Статус WiFi:"
if command -v iwinfo >/dev/null 2>&1; then
    for iface in $(iwinfo 2>/dev/null | grep -o "wlan[0-9]" | sort -u); do
        echo "  $iface: $(iwinfo $iface info 2>/dev/null | grep -E "ESSID|Channel|Mode" | tr '\n' ' ')"
    done
else
    echo "  (iwinfo не установлен)"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    НАСТРОЙКА ЗАВЕРШЕНА                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ SSID:            $SSID                                ║"
echo "║ Режим:           $TYPE                                       ║"
echo "║ Роуминг:         $([ "$ROAMING" = "1" ] && echo 'ВКЛЮЧЕН' || echo 'ОТКЛЮЧЕН')                              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "[✓] Готово!"
