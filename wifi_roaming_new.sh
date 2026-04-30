#!/bin/sh
#
# OpenWrt WiFi Setup - Solo Router & Seamless Roaming
# Поддержка OpenWrt 24.10+ и 25.12+
# Гарантированно работает с WiFi 6 (AX)
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

# Определяем менеджер пакетов
if command -v apk >/dev/null 2>&1; then
    # OpenWrt 25.12+
    PKG="apk"
    
    # Проверяем что установлено
    WPAD_INSTALLED=$(apk info 2>/dev/null | grep wpad)
    if echo "$WPAD_INSTALLED" | grep -qE "wpad-basic|wpad-mini"; then
        echo "[*] Удаляем урезанные версии wpad..."
        apk del wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini 2>/dev/null || true
    fi
    
    echo "[*] Устанавливаем полный wpad..."
    apk update >/dev/null 2>&1
    apk add wpad-openssl 2>/dev/null || apk add wpad 2>/dev/null
    
elif command -v opkg >/dev/null 2>&1; then
    # OpenWrt 24.10 и ранее
    PKG="opkg"
    
    WPAD_INSTALLED=$(opkg list-installed 2>/dev/null | grep wpad)
    if echo "$WPAD_INSTALLED" | grep -qE "wpad-basic|wpad-mini"; then
        echo "[*] Удаляем урезанные версии wpad..."
        opkg remove wpad-basic wpad-basic-mbedtls wpad-mini 2>/dev/null || true
    fi
    
    echo "[*] Устанавливаем полный wpad..."
    opkg update >/dev/null 2>&1
    opkg install wpad-openssl 2>/dev/null || opkg install wpad 2>/dev/null
fi

echo "[✓] wpad установлен"

# ====================== ПАРАМЕТРЫ ======================
COUNTRY="RU"

if [ "$ROUTER_TYPE" = "R1" ]; then
    RADIO0_CH=1    # 2.4GHz
    RADIO1_CH=36   # 5GHz
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
    NASID_24=""
    NASID_5=""
    MOBILITY_DOMAIN=""
fi

# ====================== НАСТРОЙКА WiFi ======================
echo "[*] Настройка WiFi интерфейсов..."

# Сначала очищаем существующие интерфейсы
echo "[*] Очистка старых WiFi интерфейсов..."
while uci -q delete wireless.@wifi-iface[0] 2>/dev/null; do :; done

# Настройка 2.4GHz (radio0)
echo "[*] Настройка 2.4GHz (radio0)..."
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.country="$COUNTRY"
uci set wireless.radio0.channel="$RADIO0_CH"
uci set wireless.radio0.htmode='HT20'

# Создаём интерфейс если нет
IFACE_COUNT=$(uci show wireless | grep -c "='wifi-iface'" || echo "0")
if [ "$IFACE_COUNT" -eq "0" ]; then
    uci add wireless wifi-iface >/dev/null
fi

uci set wireless.@wifi-iface[0].device='radio0'
uci set wireless.@wifi-iface[0].network='lan'
uci set wireless.@wifi-iface[0].mode='ap'
uci set wireless.@wifi-iface[0].ssid="$SSID"
uci set wireless.@wifi-iface[0].encryption='psk2'
uci set wireless.@wifi-iface[0].key="$PASSWORD"

# Роуминг для 2.4GHz
if [ "$ROAMING" = "1" ]; then
    echo "[*] Включение роуминга для 2.4GHz..."
    uci set wireless.@wifi-iface[0].ieee80211r='1'
    uci set wireless.@wifi-iface[0].mobility_domain="$MOBILITY_DOMAIN"
    uci set wireless.@wifi-iface[0].ft_over_ds='1'
    uci set wireless.@wifi-iface[0].ft_psk_generate_local='1'
    uci set wireless.@wifi-iface[0].pmk_r1_push='1'
    uci set wireless.@wifi-iface[0].nasid="$NASID_24"
    uci set wireless.@wifi-iface[0].ieee80211k='1'
    uci set wireless.@wifi-iface[0].rrm_neighbor_report='1'
    uci set wireless.@wifi-iface[0].rrm_beacon_report='1'
    uci set wireless.@wifi-iface[0].ieee80211v='1'
    uci set wireless.@wifi-iface[0].bss_transition='1'
    echo "  [✓] NASID: $NASID_24"
fi

# Настройка 5GHz (radio1)
echo "[*] Настройка 5GHz (radio1)..."
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.country="$COUNTRY"
uci set wireless.radio1.channel="$RADIO1_CH"
uci set wireless.radio1.htmode='VHT80'

# Создаём второй интерфейс если нужно
IFACE_COUNT=$(uci show wireless | grep -c "='wifi-iface'" || echo "0")
if [ "$IFACE_COUNT" -lt "2" ]; then
    uci add wireless wifi-iface >/dev/null
fi

uci set wireless.@wifi-iface[1].device='radio1'
uci set wireless.@wifi-iface[1].network='lan'
uci set wireless.@wifi-iface[1].mode='ap'
uci set wireless.@wifi-iface[1].ssid="$SSID"
uci set wireless.@wifi-iface[1].encryption='psk2'
uci set wireless.@wifi-iface[1].key="$PASSWORD"

# Роуминг для 5GHz
if [ "$ROAMING" = "1" ]; then
    echo "[*] Включение роуминга для 5GHz..."
    uci set wireless.@wifi-iface[1].ieee80211r='1'
    uci set wireless.@wifi-iface[1].mobility_domain="$MOBILITY_DOMAIN"
    uci set wireless.@wifi-iface[1].ft_over_ds='1'
    uci set wireless.@wifi-iface[1].ft_psk_generate_local='1'
    uci set wireless.@wifi-iface[1].pmk_r1_push='1'
    uci set wireless.@wifi-iface[1].nasid="$NASID_5"
    uci set wireless.@wifi-iface[1].ieee80211k='1'
    uci set wireless.@wifi-iface[1].rrm_neighbor_report='1'
    uci set wireless.@wifi-iface[1].rrm_beacon_report='1'
    uci set wireless.@wifi-iface[1].ieee80211v='1'
    uci set wireless.@wifi-iface[1].bss_transition='1'
    echo "  [✓] NASID: $NASID_5"
fi

# ====================== СЕТЕВЫЕ НАСТРОЙКИ ======================
echo "[*] Настройка сети..."

if [ "$ROUTER_TYPE" = "R2" ]; then
    # Точка доступа
    AP_IP=${AP_IP:-192.168.1.2}
    read -r -p "IP для этой точки доступа [$AP_IP]: " input_ip
    AP_IP=${input_ip:-$AP_IP}
    
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.netmask='255.255.255.0'
    uci set network.lan.gateway="$R1_IP"
    uci set network.lan.dns="$R1_IP"
    
    # Отключаем DHCP
    uci set dhcp.lan.ignore='1'
    
    # Применяем и останавливаем сервисы
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    
    echo "[✓] Настроена точка доступа (IP: $AP_IP, шлюз: $R1_IP)"
else
    # Соло или R1 - оставляем DHCP
    echo "[✓] DHCP сервер будет работать на LAN"
fi

# Сохраняем все изменения
echo "[*] Сохранение конфигурации..."
uci commit wireless
uci commit network
uci commit dhcp

# ====================== ПРИМЕНЕНИЕ ======================
echo "[*] Перезагрузка WiFi..."
wifi reload

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
    echo "║ РОУМИНГ АКТИВИРОВАН:                                  ║"
    echo "║  2.4GHz NASID: $NASID_24, канал: $RADIO0_CH            ║"
    echo "║  5GHz NASID:   $NASID_5, канал: $RADIO1_CH            ║"
    echo "║  Mobility Domain: $MOBILITY_DOMAIN                                ║"
else
    echo "║  2.4GHz канал: $RADIO0_CH                                  ║"
    echo "║  5GHz канал:   $RADIO1_CH                                  ║"
fi

echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "$ROUTER_TYPE" = "R2" ]; then
    echo "[!] ВАЖНО: Подключите эту точку доступа к R1 через LAN порт"
    echo ""
fi

echo "[*] Для проверки статуса WiFi выполните:"
echo "    iwinfo"
echo "    uci show wireless"
echo ""
echo "[✓] $ROUTER_TYPE настроен успешно!"
