#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script (исправленная версия)
# OpenWrt 24.10.6 и 25.12+

set -e

# ----------------------------
# Определение версии OpenWrt
# ----------------------------
detect_openwrt_version() {
    if [ -f /etc/openwrt_release ]; then
        VERSION=$(grep "DISTRIB_RELEASE" /etc/openwrt_release | cut -d"'" -f2)
        echo "[*] OpenWrt: $VERSION"
        
        if command -v apk > /dev/null 2>&1; then
            PKG_MANAGER="apk"
            PKG_UPDATE="apk update"
            PKG_INSTALL="apk add"
            PKG_REMOVE="apk del"
            PKG_LIST="apk info"
        elif command -v opkg > /dev/null 2>&1; then
            PKG_MANAGER="opkg"
            PKG_UPDATE="opkg update"
            PKG_INSTALL="opkg install"
            PKG_REMOVE="opkg remove"
            PKG_LIST="opkg list-installed"
        else
            echo "[!] Нет менеджера пакетов"
            exit 1
        fi
    else
        echo "[!] Не OpenWrt"
        exit 1
    fi
}

# ----------------------------
# Интерактивный ввод
# ----------------------------
input_parameters() {
    clear
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║          OpenWrt WiFi Setup Wizard                     ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    
    while true; do
        echo "1) Соло роутер"
        echo "2) Основной роутер R1 (роуминг)"
        echo "3) Точка доступа R2"
        read -r -p "Выбор [1-3]: " ROUTER_CHOICE
        case "$ROUTER_CHOICE" in
            1) ROUTER_TYPE="SOLO"; ROAMING_ENABLED="0"; break ;;
            2) ROUTER_TYPE="R1";   ROAMING_ENABLED="1"; break ;;
            3) ROUTER_TYPE="R2";   ROAMING_ENABLED="1"; break ;;
            *) echo "[!] Неверный выбор" ;;
        esac
    done

    while true; do
        read -r -p "SSID: " SSID
        [ -n "$SSID" ] && [ ${#SSID} -le 32 ] && break
        echo "[!] Некорректный SSID"
    done

    while true; do
        read -r -p "Пароль (≥8 симв.): " PASSWORD
        [ ${#PASSWORD} -ge 8 ] && break
        echo "[!] Слишком короткий пароль"
    done

    if [ "$ROUTER_TYPE" = "R2" ]; then
        read -r -p "IP R1 [192.168.1.1]: " R1_IP
        R1_IP=${R1_IP:-192.168.1.1}
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Режим: $ROUTER_TYPE"
    echo "SSID: $SSID"
    echo "Роуминг: $([ "$ROAMING_ENABLED" = "1" ] && echo "ВКЛ" || echo "ВЫКЛ")"
    [ "$ROUTER_TYPE" = "R2" ] && echo "R1 IP: $R1_IP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -r -p "Продолжить? [Y/n]: " CONFIRM
    [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && exit 0
}

# ----------------------------
# Пакеты
# ----------------------------
setup_packages() {
    echo "[*] Установка пакетов..."
    $PKG_UPDATE > /dev/null 2>&1
    
    # Удаление урезанных wpad
    for pkg in $($PKG_LIST 2>/dev/null | grep -E '^wpad-' || true); do
        case "$pkg" in
            wpad-basic*|wpad-mini) $PKG_REMOVE "$pkg" > /dev/null 2>&1 || true ;;
        esac
    done

    for wpadv in wpad-openssl wpad-mbedtls wpad; do
        if $PKG_INSTALL "$wpadv" > /dev/null 2>&1; then
            echo "[✓] $wpadv"
            break
        fi
    done
}

# ----------------------------
# WiFi интерфейсы
# ----------------------------
detect_wifi_interfaces() {
    echo "[*] Поиск WiFi..."
    RADIO_24G="" RADIO_5G=""

    for radio in $(uci show wireless 2>/dev/null | grep '=radio' | cut -d. -f1-2 | sort -u); do
        name=$(echo "$radio" | cut -d. -f2)
        band=$(uci get ${radio}.band 2>/dev/null)
        if [ "$band" = "2g" ] || grep -qE '11g|11n' <<< "$(uci get ${radio}.hwmode 2>/dev/null)"; then
            [ -z "$RADIO_24G" ] && RADIO_24G="$radio" && RADIO_24G_NAME="$name"
        elif [ "$band" = "5g" ] || grep -qE '11a|11ac|11ax' <<< "$(uci get ${radio}.hwmode 2>/dev/null)"; then
            [ -z "$RADIO_5G" ] && RADIO_5G="$radio" && RADIO_5G_NAME="$name"
        fi
    done

    [ -z "$RADIO_24G" ] && [ -z "$RADIO_5G" ] && { echo "[!] WiFi не найдены"; exit 1; }
}

# ----------------------------
# Параметры
# ----------------------------
set_parameters() {
    if [ "$ROUTER_TYPE" = "SOLO" ] || [ "$ROUTER_TYPE" = "R1" ]; then
        RADIO_24G_CH=1
        RADIO_5G_CH=36
        ROUTER_IP="192.168.1.1"
    else
        RADIO_24G_CH=6
        RADIO_5G_CH=40
        ROUTER_IP=${R1_IP:-"192.168.1.1"}
    fi

    if [ "$ROAMING_ENABLED" = "1" ]; then
        MOBILITY_DOMAIN="a1b2"
        NASID_24="${SSID}_24G_${ROUTER_TYPE}"
        NASID_5="${SSID}_5G_${ROUTER_TYPE}"
    fi
}

# ----------------------------
# Настройка одной полосы
# ----------------------------
configure_wifi_band() {
    local RADIO_PATH="$1" RADIO_NAME="$2" CHANNEL="$3" NASID="$4" BAND="$5"

    echo "[*] Настройка $BAND ($RADIO_NAME)"

    uci set ${RADIO_PATH}.disabled='0'
    uci set ${RADIO_PATH}.country='RU'
    uci set ${RADIO_PATH}.channel="$CHANNEL"
    uci set ${RADIO_PATH}.htmode="$([ "$BAND" = "2.4GHz" ] && echo 'HT20' || echo 'VHT80')"
    uci set ${RADIO_PATH}.noscan='1'

    uci add wireless wifi-iface > /dev/null
    local IFACE="wireless.@wifi-iface[-1]"

    uci set ${IFACE}.device="$RADIO_NAME"
    uci set ${IFACE}.network='lan'
    uci set ${IFACE}.mode='ap'
    uci set ${IFACE}.ssid="$SSID"
    uci set ${IFACE}.encryption='psk2'
    uci set ${IFACE}.key="$PASSWORD"

    # Общие оптимизации
    uci set ${IFACE}.wmm='1'
    uci set ${IFACE}.wpa_group_rekey='3600'
    uci set ${IFACE}.isolate='0'
    uci set ${IFACE}.disassoc_low_ack='0'
    uci set ${IFACE}.beacon_int='100'
    uci set ${IFACE}.dtim_period='2'

    if [ "$ROAMING_ENABLED" = "1" ]; then
        uci set ${IFACE}.ieee80211r='1'
        uci set ${IFACE}.mobility_domain="$MOBILITY_DOMAIN"
        uci set ${IFACE}.ft_over_ds='1'
        uci set ${IFACE}.ft_psk_generate_local='1'
        uci set ${IFACE}.nasid="$NASID"
        uci set ${IFACE}.pmk_r1_push='1'

        uci set ${IFACE}.ieee80211k='1'
        uci set ${IFACE}.rrm_neighbor_report='1'
        uci set ${IFACE}.rrm_beacon_report='1'

        uci set ${IFACE}.ieee80211v='1'
        uci set ${IFACE}.bss_transition='1'
    fi
}

# ----------------------------
# DHCP (SOLO / R1)
# ----------------------------
configure_dhcp() {
    echo "[*] Настройка DHCP..."
    uci set network.lan.netmask='255.255.255.0'
    uci set dhcp.lan.start='100'
    uci set dhcp.lan.limit='150'
    uci set dhcp.lan.leasetime='12h'
    uci set dhcp.wan.ignore='1'
}

# ----------------------------
# AP Mode (R2)
# ----------------------------
configure_ap_mode() {
    echo "[*] Настройка AP режима..."
    DEFAULT_IP="192.168.1.2"
    read -r -p "IP этой точки [$DEFAULT_IP]: " AP_IP
    AP_IP=${AP_IP:-$DEFAULT_IP}

    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.gateway="$ROUTER_IP"
    uci set network.lan.dns="$ROUTER_IP"
    uci set dhcp.lan.ignore='1'

    /etc/init.d/dnsmasq disable 2>/dev/null && /etc/init.d/dnsmasq stop 2>/dev/null || true

    read -r -p "Отключить firewall? [Y/n]: " DISABLE_FW
    if [ "$DISABLE_FW" != "n" ] && [ "$DISABLE_FW" != "N" ]; then
        /etc/init.d/firewall disable 2>/dev/null && /etc/init.d/firewall stop 2>/dev/null || true
    fi
}

# ----------------------------
# Применение
# ----------------------------
apply_settings() {
    echo "[*] Применение..."
    uci commit wireless
    uci commit network
    [ "$ROUTER_TYPE" != "R2" ] && uci commit dhcp || true

    wifi reload 2>/dev/null || wifi
    [ "$ROUTER_TYPE" = "R2" ] && /etc/init.d/network restart 2>/dev/null || true
}

# ----------------------------
# Результат
# ----------------------------
show_results() {
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║               НАСТРОЙКА ЗАВЕРШЕНА                      ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "Режим: $ROUTER_TYPE | SSID: $SSID"
    echo "Роуминг: $([ "$ROAMING_ENABLED" = "1" ] && echo "ВКЛ (802.11r/k/v)" || echo "ВЫКЛ")"
}

# ============================
main() {
    detect_openwrt_version
    input_parameters
    setup_packages
    detect_wifi_interfaces
    set_parameters

    # Очистка
    while uci -q delete wireless.@wifi-iface[0]; do :; done

    [ -n "$RADIO_24G" ] && configure_wifi_band "$RADIO_24G" "$RADIO_24G_NAME" "$RADIO_24G_CH" "$NASID_24" "2.4GHz"
    [ -n "$RADIO_5G" ] && configure_wifi_band "$RADIO_5G" "$RADIO_5G_NAME" "$RADIO_5G_CH" "$NASID_5" "5GHz"

    if [ "$ROUTER_TYPE" = "SOLO" ] || [ "$ROUTER_TYPE" = "R1" ]; then
        configure_dhcp
    else
        configure_ap_mode
    fi

    apply_settings
    show_results
}

main "$@"
