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
if [ "$ROAMING" = "1" ]; then
    echo "Роуминг: ВКЛЮЧЕН (802.11r/k/v)"
else
    echo "Роуминг: ОТКЛЮЧЕН"
fi
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

# Очистка существующих интерфейсов
while uci -q delete wireless.@wifi-iface[0] 2>/dev/null; do :; done

# Поиск радио-интерфейсов
RADIO_24=""; RADIO_5=""
for r in $(uci show wireless 2>/dev/null | grep '=radio' | cut -d. -f1-2); do
    name=$(echo $r | cut -d. -f2)
    band=$(uci get ${r}.band 2>/dev/null)
    if [ "$band" = "2g" ]; then
        RADIO_24="$r"; NAME_24="$name"
    elif [ "$band" = "5g" ]; then
        RADIO_5="$r"; NAME_5="$name"
    fi
done

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

# Функция настройки диапазона
setup_band() {
    local radio_path="$1" radio_name="$2" channel="$3" nasid="$4" band_name="$5"
    
    echo "[*] Настройка $band_name ($radio_name)..."
    
    # Настройка радио
    uci set ${radio_path}.disabled='0'
    uci set ${radio_path}.country='RU'
    uci set ${radio_path}.channel="$channel"
    
    if [ "$band_name" = "2.4GHz" ]; then
        uci set ${radio_path}.htmode='HT20'
    else
        uci set ${radio_path}.htmode='VHT80'
    fi
    
    # Создание интерфейса
    uci add wireless wifi-iface >/dev/null
    local iface="wireless.@wifi-iface[-1]"
    
    # Базовые настройки
    uci set ${iface}.device="$radio_name"
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
    
    # Настройки роуминга (только если включен)
    if [ "$ROAMING" = "1" ] && [ -n "$nasid" ]; then
        echo "  [+] Включение протоколов роуминга..."
        
        # 802.11r Fast BSS Transition
        uci set ${iface}.ieee80211r='1'
        uci set ${iface}.mobility_domain="$MOB_DOMAIN"
        uci set ${iface}.ft_over_ds='1'
        uci set ${iface}.ft_psk_generate_local='1'
        uci set ${iface}.nasid="$nasid"
        uci set ${iface}.pmk_r1_push='1'
        
        # 802.11k Radio Resource Management
        uci set ${iface}.ieee80211k='1'
        uci set ${iface}.rrm_neighbor_report='1'
        uci set ${iface}.rrm_beacon_report='1'
        
        # 802.11v Wireless Network Management
        uci set ${iface}.ieee80211v='1'
        uci set ${iface}.bss_transition='1'
        
        echo "  [✓] Роуминг настроен (NASID: $nasid)"
    fi
    
    echo "[✓] $band_name готов"
}

# Настройка 2.4 GHz
[ -n "$RADIO_24" ] && setup_band "$RADIO_24" "$NAME_24" "$CH24" "$NAS24" "2.4GHz"

# Настройка 5 GHz
[ -n "$RADIO_5" ] && setup_band "$RADIO_5" "$NAME_5" "$CH5" "$NAS5" "5GHz"

uci commit wireless

# ====================== СЕТЬ ======================
echo "[*] Настройка сети..."

if [ "$TYPE" = "R2" ]; then
    # Точка доступа
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
    
    # Отключаем DHCP и firewall
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    /etc/init.d/firewall disable 2>/dev/null || true
    /etc/init.d/firewall stop 2>/dev/null || true
else
    # Соло или R1
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
wifi reload 2>/dev/null || wifi

if [ "$TYPE" = "R2" ]; then
    /etc/init.d/network restart 2>/dev/null || true
fi

# ====================== РЕЗУЛЬТАТ ======================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО                   ║"
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

if [ -n "$NAME_24" ]; then
    echo "║ 2.4GHz:          Канал: $CH24                              ║"
    [ -n "$NAS24" ] && echo "║                  NASID: $NAS24              ║"
fi
if [ -n "$NAME_5" ]; then
    echo "║ 5GHz:            Канал: $CH5                             ║"
    [ -n "$NAS5" ] && echo "║                  NASID: $NAS5               ║"
fi

echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "$TYPE" = "R2" ]; then
    echo "[!] ВАЖНО: Убедитесь, что точка доступа подключена к R1 через LAN порт"
    echo "    IP точки доступа: $AP_IP"
    echo "    IP основного роутера: $R1_IP"
fi

echo "[✓] Готово!"
