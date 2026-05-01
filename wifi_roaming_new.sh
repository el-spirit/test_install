#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script (Fixed for Cudy/MTK)
# Поддержка OpenWrt 24.10+ и 25.12+
#

echo "╔══════════════════════════════════════════════════════════╗"
echo "║           OpenWrt WiFi Setup Wizard (v2.1)               ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ====================== ПРОВЕРКА ИНТЕРНЕТА ======================
echo "[*] Проверка связи с репозиторием..."
if ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
    echo "[!] ОШИБКА: Нет интернета! Пакеты wpad не смогут обновиться."
    echo "    Подключите WAN кабель и попробуйте снова."
    exit 1
fi

# ====================== ВЫБОР РЕЖИМА ======================
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
        *) echo "[!] Неверный выбор!" ;;
    esac
done

read -r -p "Введите SSID: " SSID
read -r -p "Введите пароль: " PASSWORD

if [ "$ROUTER_TYPE" = "R2" ]; then
    read -r -p "Введите IP основного роутера R1 [192.168.1.1]: " R1_IP
    R1_IP=${R1_IP:-192.168.1.1}
fi

# ====================== ОБНОВЛЕНИЕ WPAD ======================
echo "[*] Обновление компонентов WiFi (нужно для роуминга)..."

if command -v apk >/dev/null 2>&1; then
    apk update
    # Сначала пытаемся поставить полную версию, только потом удаляем старую (так безопаснее)
    apk add wpad-openssl && apk del wpad-basic wpad-basic-mbedtls wpad-mini
elif command -v opkg >/dev/null 2>&1; then
    opkg update
    opkg install wpad-openssl && opkg remove wpad-basic wpad-mini
fi

# ====================== ОПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ ======================
# Сброс конфига если он пустой
[ ! -f /etc/config/wireless ] && wifi config

# Авто-поиск секций интерфейсов
IFACE_24=$(uci show wireless | grep "device='radio0'" | head -1 | cut -d. -f2 | cut -d= -f1)
IFACE_5=$(uci show wireless | grep "device='radio1'" | head -1 | cut -d. -f2 | cut -d= -f1)

# Если интерфейсов нет - создаем их
[ -z "$IFACE_24" ] && { uci add wireless wifi-iface; IFACE_24="@wifi-iface[-1]"; }
[ -z "$IFACE_5" ] && { uci add wireless wifi-iface; IFACE_5="@wifi-iface[-1]"; }

# ====================== ПАРАМЕТРЫ РОУМИНГА ======================
COUNTRY="RU"
MOBILITY_DOMAIN="a1b2"

# ====================== ПРИМЕНЕНИЕ НАСТРОЕК ======================
configure_wifi() {
    local radio=$1
    local iface=$2
    local channel=$3
    local nasid=$4

    echo "[*] Настройка $radio..."
    uci set wireless.${radio}.disabled='0'
    uci set wireless.${radio}.channel='${channel}'
    uci set wireless.${radio}.country='${COUNTRY}'

    uci set wireless.${iface}.device='${radio}'
    uci set wireless.${iface}.mode='ap'
    uci set wireless.${iface}.network='lan'
    uci set wireless.${iface}.ssid='${SSID}'
    uci set wireless.${iface}.encryption='psk2'
    uci set wireless.${iface}.key='${PASSWORD}'
    uci set wireless.${iface}.disabled='0'  # КРИТИЧНО ДЛЯ CUDY
    uci set wireless.${iface}.wmm='1'

    if [ "$ROAMING" = "1" ]; then
        uci set wireless.${iface}.ieee80211r='1'
        uci set wireless.${iface}.mobility_domain='${MOBILITY_DOMAIN}'
        uci set wireless.${iface}.ft_over_ds='1'
        uci set wireless.${iface}.ft_psk_generate_local='1'
        uci set wireless.${iface}.nasid='${nasid}'
        uci set wireless.${iface}.ieee80211k='1'
        uci set wireless.${iface}.ieee80211v='1'
        uci set wireless.${iface}.bss_transition='1'
    fi
}

if [ "$ROUTER_TYPE" = "R1" ]; then
    configure_wifi "radio0" "$IFACE_24" "1" "${SSID}_24G_R1"
    configure_wifi "radio1" "$IFACE_5" "36" "${SSID}_5G_R1"
elif [ "$ROUTER_TYPE" = "R2" ]; then
    configure_wifi "radio0" "$IFACE_24" "6" "${SSID}_24G_R2"
    configure_wifi "radio1" "$IFACE_5" "44" "${SSID}_5G_R2"
else
    configure_wifi "radio0" "$IFACE_24" "auto" "SOLO_24"
    configure_wifi "radio1" "$IFACE_5" "auto" "SOLO_5"
fi

# ====================== СЕТЬ (ТОЛЬКО ДЛЯ R2) ======================
if [ "$ROUTER_TYPE" = "R2" ]; then
    read -r -p "IP для этого роутера (R2) [192.168.1.2]: " AP_IP
    AP_IP=${AP_IP:-192.168.1.2}
    
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.gateway="$R1_IP"
    uci set network.lan.dns="$R1_IP"
    uci set dhcp.lan.ignore='1'
    /etc/init.d/dnsmasq stop
    /etc/init.d/dnsmasq disable
fi

uci commit wireless
uci commit network
uci commit dhcp

echo "[*] Перезагрузка WiFi..."
wifi reload
echo "[✓] Готово! Проверьте сеть через iwinfo."
