#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script
# Solo Router + Seamless Roaming (R1/R2)
# ИСПРАВЛЕНО: принудительная установка wpad, активация интерфейсов
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

# Определяем пакетный менеджер
PKG_MGR=""
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MGR="opkg"
else
    echo "[!] Пакетный менеджер не найден!"
    exit 1
fi

echo "[*] Используется: $PKG_MGR"

if [ "$ROAMING" = "1" ]; then
    echo "[*] Роуминг включен - требуется полный wpad (openssl)"
    
    if [ "$PKG_MGR" = "apk" ]; then
        # OpenWrt 25.12+
        echo "[*] Обновление списка пакетов..."
        apk update
        
        echo "[*] Удаление wpad-basic/mini..."
        apk del wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini 2>/dev/null || true
        
        echo "[*] Установка wpad-openssl..."
        apk add wpad-openssl || apk add wpad || {
            echo "[!] НЕ УДАЛОСЬ УСТАНОВИТЬ wpad-openssl!"
            echo "[*] Пробую wpad-wolfssl..."
            apk add wpad-wolfssl || {
                echo "[!] КРИТИЧЕСКАЯ ОШИБКА: wpad не установлен!"
                echo "    Установите вручную: apk add wpad-openssl"
                exit 1
            }
        }
    else
        # OpenWrt 24.10 и ранее (opkg)
        echo "[*] Обновление списка пакетов..."
        opkg update
        
        echo "[*] Удаление wpad-basic/mini..."
        opkg remove wpad-basic wpad-basic-mbedtls wpad-mini 2>/dev/null || true
        
        echo "[*] Установка wpad-openssl..."
        opkg install wpad-openssl || opkg install wpad || {
            echo "[!] НЕ УДАЛОСЬ УСТАНОВИТЬ wpad-openssl!"
            echo "[*] Пробую wpad-wolfssl..."
            opkg install wpad-wolfssl || {
                echo "[!] КРИТИЧЕСКАЯ ОШИБКА: wpad не установлен!"
                echo "    Установите вручную: opkg install wpad-openssl"
                exit 1
            }
        }
    fi
    
    # Проверяем что wpad реально установился
    echo "[*] Проверка установки wpad..."
    if [ "$PKG_MGR" = "apk" ]; then
        apk list --installed | grep -q "wpad" || {
            echo "[!] wpad не обнаружен после установки!"
            exit 1
        }
    else
        opkg list-installed | grep -q "wpad" || {
            echo "[!] wpad не обнаружен после установки!"
            exit 1
        }
    fi
    
    echo "[✓] wpad успешно установлен"
else
    echo "[*] Соло режим - wpad не требуется, оставляем как есть"
fi

echo "[✓] Пакеты готовы"

# ====================== СТАРЫЕ ИНТЕРФЕЙСЫ ======================
echo "[*] Поиск существующих WiFi интерфейсов..."

# Очищаем старые интерфейсы если они есть (кроме default_radio*)
echo "[*] Удаление старых WiFi интерфейсов..."
while uci -q delete wireless.@wifi-iface[0] 2>/dev/null; do : ; done

# Создаём интерфейсы заново
echo "[*] Создание новых интерфейсов..."

# Интерфейс для 2.4GHz
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio0'
uci set wireless.@wifi-iface[-1].network='lan'
uci set wireless.@wifi-iface[-1].mode='ap'

# Интерфейс для 5GHz
uci add wireless wifi-iface
uci set wireless.@wifi-iface[-1].device='radio1'
uci set wireless.@wifi-iface[-1].network='lan'
uci set wireless.@wifi-iface[-1].mode='ap'

echo "[✓] Интерфейсы созданы"

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

# ====================== НАСТРОЙКА WiFi ======================
echo "[*] Настройка WiFi устройств..."

# Radio0 (2.4GHz)
uci set wireless.radio0.channel="$RADIO0_CH"
uci set wireless.radio0.country="$COUNTRY"
uci set wireless.radio0.disabled='0'
uci set wireless.radio0.band='2g'
uci set wireless.radio0.htmode='HE20'

# Radio1 (5GHz)
uci set wireless.radio1.channel="$RADIO1_CH"
uci set wireless.radio1.country="$COUNTRY"  
uci set wireless.radio1.disabled='0'
uci set wireless.radio1.band='5g'
uci set wireless.radio1.htmode='HE80'

echo "[*] Настройка 2.4GHz интерфейса..."
# Находим первый wifi-iface (для radio0)
IFACE_24=$(uci show wireless | grep "device='radio0'" | head -1 | cut -d. -f2 | cut -d= -f1)

uci set wireless.${IFACE_24}.ssid="$SSID"
uci set wireless.${IFACE_24}.encryption='psk2'
uci set wireless.${IFACE_24}.key="$PASSWORD"
uci set wireless.${IFACE_24}.wmm='1'
uci set wireless.${IFACE_24}.disabled='0'

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
fi

echo "[*] Настройка 5GHz интерфейса..."
# Находим второй wifi-iface (для radio1)
IFACE_5=$(uci show wireless | grep "device='radio1'" | head -1 | cut -d. -f2 | cut -d= -f1)

uci set wireless.${IFACE_5}.ssid="$SSID"
uci set wireless.${IFACE_5}.encryption='psk2'
uci set wireless.${IFACE_5}.key="$PASSWORD"
uci set wireless.${IFACE_5}.wmm='1'
uci set wireless.${IFACE_5}.disabled='0'

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
fi

echo "[✓] Настройки WiFi применены"

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
    
    echo "[✓] Точка доступа (IP: $AP_IP, шлюз: $R1_IP)"
fi

# ====================== СОХРАНЕНИЕ И ПРИМЕНЕНИЕ ======================
echo "[*] Сохранение конфигурации..."
uci commit wireless
uci commit network
uci commit dhcp 2>/dev/null || true

echo "[*] Полный перезапуск WiFi..."
wifi down
sleep 3
wifi up
sleep 5

# ====================== ПРОВЕРКА ======================
echo ""
echo "[*] Проверка статуса WiFi..."
wifi status | grep -E '"ssid"|"disabled"|"up"'

# ====================== РЕЗУЛЬТАТ ======================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║            НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Режим:           $ROUTER_TYPE                                            ║"
echo "║ SSID:            $SSID                                     ║"
echo "║ Шифрование:      WPA2-PSK                                   ║"
echo "║ Пароль:          $PASSWORD                             ║"

if [ "$ROAMING" = "1" ]; then
echo "╠══════════════════════════════════════════════════════════╣"
echo "║ РОУМИНГ ВКЛЮЧЕН                                           ║"
echo "║  ✓ 802.11r (Fast BSS Transition)                          ║"
echo "║  ✓ 802.11k (Neighbor Reports)                             ║"
echo "║  ✓ 802.11v (BSS Transition)                               ║"
echo "║  Mobility Domain: $MOBILITY_DOMAIN                                         ║"
echo "║  NASID 2.4GHz:    $NASID_24           ║"
echo "║  NASID 5GHz:      $NASID_5            ║"
fi

echo "╠══════════════════════════════════════════════════════════╣"
echo "║ Канал 2.4GHz:     $RADIO0_CH                                          ║"
echo "║ Канал 5GHz:       $RADIO1_CH                                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "$ROUTER_TYPE" = "R2" ]; then
    echo "[!] ВАЖНО: Подключите точку доступа к R1 через LAN порт"
elif [ "$ROUTER_TYPE" = "R1" ]; then
    echo "[*] Для добавления R2 запустите этот скрипт на втором роутере"
fi

echo ""
echo "[✓] Готово! WiFi должен быть активен"
