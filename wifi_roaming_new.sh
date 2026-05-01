#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script
# Solo Router + Seamless Roaming (R1/R2)
# Безопасно работает с существующей конфигурацией
# Поддержка OpenWrt 24.10+ и 25.12+
#

echo "╔══════════════════════════════════════════════════════════╗"
echo "║          OpenWrt WiFi Setup Wizard                     ║"
echo "║     Соло роутер или Бесшовный роуминг                  ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

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
if [ "$ROAMING" = "1" ]; then
    echo "Роуминг: ВКЛЮЧЕН (802.11r/k/v)"
else
    echo "Роуминг: ОТКЛЮЧЕН"
fi
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
    # OpenWrt 25.12+
    apk update >/dev/null 2>&1
    
    # Удаляем урезанные версии
    for pkg in wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini; do
        apk del "$pkg" 2>/dev/null || true
    done
    
    # Устанавливаем полный wpad (нужен для роуминга)
    if [ "$ROAMING" = "1" ]; then
        echo "[*] Установка wpad-openssl для поддержки роуминга..."
        apk add wpad-openssl 2>/dev/null || apk add wpad 2>/dev/null
    fi
elif command -v opkg >/dev/null 2>&1; then
    # OpenWrt 24.10 и ранее
    opkg update >/dev/null 2>&1
    
    for pkg in wpad-basic wpad-basic-mbedtls wpad-mini; do
        opkg remove "$pkg" 2>/dev/null || true
    done
    
    if [ "$ROAMING" = "1" ]; then
        echo "[*] Установка wpad-openssl для поддержки роуминга..."
        opkg install wpad-openssl 2>/dev/null || opkg install wpad 2>/dev/null
    fi
fi

echo "[✓] Пакеты готовы"

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
    # Соло режим - сохраняем текущие каналы или ставим默认ные
    RADIO0_CH=$(uci get wireless.radio0.channel 2>/dev/null || echo "1")
    RADIO1_CH=$(uci get wireless.radio1.channel 2>/dev/null || echo "36")
fi

# ====================== ОПРЕДЕЛЕНИЕ ИНТЕРФЕЙСОВ ======================
echo "[*] Определение WiFi интерфейсов..."

# Проверяем существование radio0 и radio1
if ! uci get wireless.radio0 >/dev/null 2>&1; then
    echo "[!] radio0 не найден! Создаю базовую конфигурацию..."
    rm -f /etc/config/wireless
    wifi config
    
    # Проверяем ещё раз
    if ! uci get wireless.radio0 >/dev/null 2>&1; then
        echo "[!] КРИТИЧЕСКАЯ ОШИБКА: Не удалось создать radio0!"
        echo "    Восстановите конфигурацию вручную:"
        echo "    rm -f /etc/config/wireless && wifi config"
        exit 1
    fi
fi

# Получаем имена интерфейсов (могут быть wifinet0/wifinet1 или default_radio0/default_radio1)
IFACE_24=$(uci show wireless | grep "device='radio0'" | head -1 | cut -d. -f2 | cut -d= -f1)
IFACE_5=$(uci show wireless | grep "device='radio1'" | head -1 | cut -d. -f2 | cut -d= -f1)

if [ -z "$IFACE_24" ]; then
    echo "[!] Интерфейс для radio0 не найден! Создаю..."
    uci add wireless wifi-iface >/dev/null
    uci set wireless.@wifi-iface[-1].device='radio0'
    uci set wireless.@wifi-iface[-1].mode='ap'
    uci set wireless.@wifi-iface[-1].network='lan'
    IFACE_24=$(uci show wireless | grep "device='radio0'" | head -1 | cut -d. -f2 | cut -d= -f1)
fi

if [ -z "$IFACE_5" ]; then
    echo "[!] Интерфейс для radio1 не найден! Создаю..."
    uci add wireless wifi-iface >/dev/null
    uci set wireless.@wifi-iface[-1].device='radio1'
    uci set wireless.@wifi-iface[-1].mode='ap'
    uci set wireless.@wifi-iface[-1].network='lan'
    IFACE_5=$(uci show wireless | grep "device='radio1'" | head -1 | cut -d. -f2 | cut -d= -f1)
fi

echo "[✓] Интерфейсы: $IFACE_24 (2.4GHz), $IFACE_5 (5GHz)"

# ====================== НАСТРОЙКА WiFi ======================
echo "[*] Настройка WiFi..."

# Настройка 2.4GHz
echo "[*] Настройка 2.4GHz..."
uci set wireless.radio0.channel="$RADIO0_CH"
uci set wireless.radio0.country="$COUNTRY"
uci set wireless.radio0.disabled='0'

uci set wireless.${IFACE_24}.ssid="$SSID"
uci set wireless.${IFACE_24}.encryption='psk2'
uci set wireless.${IFACE_24}.key="$PASSWORD"
uci set wireless.${IFACE_24}.wmm='1'

# Роуминг для 2.4GHz
if [ "$ROAMING" = "1" ]; then
    echo "  [+] Добавление 802.11r/k/v..."
    uci set wireless.${IFACE_24}.ieee80211r='1'
    uci set wireless.${IFACE_24}.mobility_domain="$MOBILITY_DOMAIN"
    uci set wireless.${IFACE_24}.ft_over_ds='1'
    uci set wireless.${IFACE_24}.ft_psk_generate_local='1'
    uci set wireless.${IFACE_24}.nasid="$NASID_24"
    uci set wireless.${IFACE_24}.ieee80211k='1'
    uci set wireless.${IFACE_24}.rrm_neighbor_report='1'
    uci set wireless.${IFACE_24}.ieee80211v='1'
    uci set wireless.${IFACE_24}.bss_transition='1'
else
    # Удаляем настройки роуминга если есть
    for opt in ieee80211r mobility_domain ft_over_ds ft_psk_generate_local nasid ieee80211k rrm_neighbor_report ieee80211v bss_transition; do
        uci -q delete wireless.${IFACE_24}.${opt} 2>/dev/null || true
    done
fi

# Настройка 5GHz
echo "[*] Настройка 5GHz..."
uci set wireless.radio1.channel="$RADIO1_CH"
uci set wireless.radio1.country="$COUNTRY"
uci set wireless.radio1.disabled='0'

uci set wireless.${IFACE_5}.ssid="$SSID"
uci set wireless.${IFACE_5}.encryption='psk2'
uci set wireless.${IFACE_5}.key="$PASSWORD"
uci set wireless.${IFACE_5}.wmm='1'

# Роуминг для 5GHz
if [ "$ROAMING" = "1" ]; then
    echo "  [+] Добавление 802.11r/k/v..."
    uci set wireless.${IFACE_5}.ieee80211r='1'
    uci set wireless.${IFACE_5}.mobility_domain="$MOBILITY_DOMAIN"
    uci set wireless.${IFACE_5}.ft_over_ds='1'
    uci set wireless.${IFACE_5}.ft_psk_generate_local='1'
    uci set wireless.${IFACE_5}.nasid="$NASID_5"
    uci set wireless.${IFACE_5}.ieee80211k='1'
    uci set wireless.${IFACE_5}.rrm_neighbor_report='1'
    uci set wireless.${IFACE_5}.ieee80211v='1'
    uci set wireless.${IFACE_5}.bss_transition='1'
else
    # Удаляем настройки роуминга если есть
    for opt in ieee80211r mobility_domain ft_over_ds ft_psk_generate_local nasid ieee80211k rrm_neighbor_report ieee80211v bss_transition; do
        uci -q delete wireless.${IFACE_5}.${opt} 2>/dev/null || true
    done
fi

# Сохраняем WiFi
uci commit wireless

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
    uci set dhcp.lan.ignore='1'
    uci commit network
    uci commit dhcp
    
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    
    echo "[✓] Точка доступа (IP: $AP_IP, шлюз: $R1_IP)"
fi

# ====================== ПРИМЕНЕНИЕ ======================
echo "[*] Применение настроек..."
wifi reload

sleep 3

# ====================== РЕЗУЛЬТАТ ======================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Режим:           $ROUTER_TYPE                                       ║"
echo "║ SSID:            $SSID                                ║"
echo "║ Шифрование:      WPA2-PSK                              ║"
echo "║ Пароль:          $PASSWORD                        ║"
echo "╠══════════════════════════════════════════════════════════╣"

if [ "$ROAMING" = "1" ]; then
    echo "║ РОУМИНГ ВКЛЮЧЕН:                                      ║"
    echo "║  ✓ 802.11r (Fast BSS Transition)                       ║"
    echo "║  ✓ 802.11k (Neighbor Reports)                          ║"
    echo "║  ✓ 802.11v (BSS Transition)                            ║"
    echo "║  Mobility Domain: $MOBILITY_DOMAIN                                    ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║ 2.4GHz NASID: $NASID_24              ║"
    echo "║ 5GHz NASID:   $NASID_5               ║"
else
    echo "║ Режим:           Стандартный WiFi                       ║"
fi

echo "╠══════════════════════════════════════════════════════════╣"
echo "║ 2.4GHz канал: $RADIO0_CH                                      ║"
echo "║ 5GHz канал:   $RADIO1_CH                                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# Проверка статуса
echo "[*] Статус WiFi:"
iwinfo 2>/dev/null | grep -E "ESSID|Channel" || echo "  Выполните: iwinfo"

echo ""
if [ "$ROUTER_TYPE" = "R2" ]; then
    echo "[!] ВАЖНО: Подключите точку доступа к R1 через LAN порт"
    echo "    Точка доступа: $AP_IP"
    echo "    Основной роутер: $R1_IP"
elif [ "$ROUTER_TYPE" = "R1" ]; then
    echo "[*] Для добавления точки доступа R2:"
    echo "    1. Подключите R2 к этому роутеру через LAN"
    echo "    2. Запустите скрипт на R2 и выберите режим 3"
    echo "    3. Используйте тот же SSID и пароль"
fi
echo ""
echo "[✓] Готово!"
