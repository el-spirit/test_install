#!/bin/sh
# OpenWrt 24.10 / 25.12 Safe Edition
# Seamless Wi-Fi Roaming: R1 + APs

# ===== ОБЩИЕ НАСТРОЙКИ =====
SSID="ChikaWiFi"
PASSWORD="irdiS0066"
COUNTRY="RU"
MOBILITY_DOMAIN="abcd"
RSSI_24="-73"
RSSI_5="-70"

# ===== ПРОВЕРКА ИНТЕРНЕТА И ПАКЕТОВ =====
echo "[*] Проверка пакетного менеджера..."
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
    UPDATE="apk update"
    INSTALL="apk add"
    REMOVE="apk del"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
    UPDATE="opkg update"
    INSTALL="opkg install"
    REMOVE="opkg remove"
else
    echo "[!] Пакетный менеджер не найден!"; exit 1
fi

echo "[*] Обновление wpad (необходимо для 802.11r)..."
if ! ping -c 1 8.8.8.8 >/dev/null 2>&1; then
    echo "[!] Нет интернета! Пропускаю установку пакетов."
else
    $UPDATE
    # Устанавливаем полный wpad, затем удаляем огрызки
    $INSTALL wpad-openssl && $REMOVE wpad-basic wpad-basic-mbedtls wpad-mini 2>/dev/null
fi

# ===== ВЫБОР РЕЖИМА =====
echo "Выберите режим устройства:"
echo "1) R1 — основной роутер (DHCP ВКЛ)"
echo "2) AP — точка доступа (DHCP ВЫКЛ)"
read -r MODE

case "$MODE" in
  1) DEVICE_MODE="R1"; CH24=1; CH5=36 ;;
  2) 
    DEVICE_MODE="AP"
    echo "Выберите номер точки доступа (для разноса каналов):"
    echo "1) AP1 (каналы 1 / 36)"
    echo "2) AP2 (каналы 6 / 44)"
    echo "3) AP3 (каналы 11 / 52)"
    echo "4) AP4 (каналы 1 / 149)"
    read -r AP_NUM
    case "$AP_NUM" in
      1) CH24=1;  CH5=36 ;;
      2) CH24=6;  CH5=44 ;;
      3) CH24=11; CH5=52 ;;
      4) CH24=1;  CH5=149 ;;
      *) echo "Ошибка"; exit 1 ;;
    esac
    ;;
  *) echo "Ошибка"; exit 1 ;;
esac

# ===== ПОИСК ИНТЕРФЕЙСОВ (Безопасный метод) =====
# На Cudy интерфейсы могут называться не [0] и [1], поэтому ищем их по привязке к радио
IFACE24=$(uci show wireless | grep "device='radio0'" | head -1 | cut -d. -f2 | cut -d= -f1)
IFACE5=$(uci show wireless | grep "device='radio1'" | head -1 | cut -d. -f2 | cut -d= -f1)

# ===== ФУНКЦИЯ НАСТРОЙКИ =====
set_wifi() {
    local RADIO=$1
    local IFACE=$2
    local CH=$3
    local NASID=$4
    local RSSI=$5

    echo "[*] Настройка $RADIO ($IFACE)..."
    uci set wireless.${RADIO}.disabled='0'
    uci set wireless.${RADIO}.country="$COUNTRY"
    uci set wireless.${RADIO}.channel="$CH"
    uci set wireless.${RADIO}.band='$(echo $RADIO | grep -q 0 && echo "2g" || echo "5g")'

    uci set wireless.${IFACE}.ssid="$SSID"
    uci set wireless.${IFACE}.encryption='psk2'
    uci set wireless.${IFACE}.key="$PASSWORD"
    uci set wireless.${IFACE}.disabled='0'  # Явно включаем интерфейс

    # Роуминг
    uci set wireless.${IFACE}.ieee80211r='1'
    uci set wireless.${IFACE}.mobility_domain="$MOBILITY_DOMAIN"
    uci set wireless.${IFACE}.ft_over_ds='1'
    uci set wireless.${IFACE}.ft_psk_generate_local='1'
    uci set wireless.${IFACE}.nasid="${NASID}_${DEVICE_MODE}"
    uci set wireless.${IFACE}.ieee80211k='1'
    uci set wireless.${IFACE}.ieee80211v='1'
    uci set wireless.${IFACE}.bss_transition='1'
    
    # Агрессивный кик при плохом сигнале
    uci set wireless.${IFACE}.rssi_min="$RSSI"
    uci set wireless.${IFACE}.disassoc_low_ack='1'
}

# Применяем
set_wifi "radio0" "$IFACE24" "$CH24" "Chika24" "$RSSI_24"
set_wifi "radio1" "$IFACE5" "$CH5" "Chika5" "$RSSI_5"

# ===== DHCP И СЕТЬ ДЛЯ AP =====
if [ "$DEVICE_MODE" = "AP" ]; then
    echo "[*] Настройка сетевого моста для AP..."
    uci set dhcp.lan.ignore='1'
    uci commit dhcp
    
    # В режиме AP лучше сразу предложить сменить IP, чтобы не было конфликта с R1
    echo "Введите IP для этой точки доступа (например 192.168.1.2):"
    read -r NEW_IP
    if [ -n "$NEW_IP" ]; then
        uci set network.lan.ipaddr="$NEW_IP"
        uci commit network
    fi
fi

uci commit wireless
echo "[*] Перезагрузка WiFi..."
wifi reload

echo "================================="
echo "Успешно настроено как $DEVICE_MODE"
echo "SSID: $SSID"
echo "================================="
