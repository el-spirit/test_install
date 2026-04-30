#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script
# Поддержка: OpenWrt 24.10.6 и 25.12+
# Режимы: Соло роутер или Бесшовный роуминг с точками доступа
#

set -e

# ----------------------------
# Определение версии OpenWrt
# ----------------------------
detect_openwrt_version() {
    if [ -f /etc/openwrt_release ]; then
        VERSION=$(grep "DISTRIB_RELEASE" /etc/openwrt_release | cut -d"'" -f2)
        echo "[*] Определена версия OpenWrt: $VERSION"
        
        if command -v apk > /dev/null 2>&1; then
            PKG_MANAGER="apk"
            PKG_UPDATE="apk update"
            PKG_INSTALL="apk add"
            PKG_REMOVE="apk del"
            PKG_LIST="apk info"
            echo "[*] Менеджер пакетов: apk (OpenWrt 25.12+)"
        elif command -v opkg > /dev/null 2>&1; then
            PKG_MANAGER="opkg"
            PKG_UPDATE="opkg update"
            PKG_INSTALL="opkg install"
            PKG_REMOVE="opkg remove"
            PKG_LIST="opkg list-installed"
            echo "[*] Менеджер пакетов: opkg (OpenWrt 24.10 и ранее)"
        else
            echo "[!] Ошибка: не найден менеджер пакетов"
            exit 1
        fi
    else
        echo "[!] Ошибка: не удалось определить версию OpenWrt"
        exit 1
    fi
}

# ----------------------------
# Интерактивный ввод параметров
# ----------------------------
input_parameters() {
    clear
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║           OpenWrt WiFi Setup Wizard                      ║"
    echo "║     Соло роутер или Бесшовный роуминг (Multi-AP)        ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    # Выбор режима работы
    while true; do
        echo "Выберите режим работы:"
        echo "  1) Соло роутер (один роутер, без точек доступа)"
        echo "  2) Основной роутер R1 (будет работать с точками доступа)"
        echo "  3) Точка доступа R2 (дополнительная точка для роуминга)"
        read -r -p "Ваш выбор [1-3]: " ROUTER_CHOICE
        case "$ROUTER_CHOICE" in
            1) 
                ROUTER_TYPE="SOLO"
                ROAMING_ENABLED="0"
                break
                ;;
            2) 
                ROUTER_TYPE="R1"
                ROAMING_ENABLED="1"
                break
                ;;
            3) 
                ROUTER_TYPE="R2"
                ROAMING_ENABLED="1"
                break
                ;;
            *) echo "[!] Неверный выбор! Попробуйте снова.";;
        esac
    done
    echo ""
    
    # Ввод имени WiFi сети
    while true; do
        read -r -p "Введите имя WiFi сети (SSID): " SSID
        if [ -z "$SSID" ]; then
            echo "[!] SSID не может быть пустым!"
        elif [ ${#SSID} -gt 32 ]; then
            echo "[!] SSID не может быть длиннее 32 символов!"
        else
            break
        fi
    done
    echo ""
    
    # Ввод пароля WiFi
    while true; do
        read -r -p "Введите пароль WiFi сети (минимум 8 символов): " PASSWORD
        if [ -z "$PASSWORD" ]; then
            echo "[!] Пароль не может быть пустым!"
        elif [ ${#PASSWORD} -lt 8 ]; then
            echo "[!] Пароль должен содержать минимум 8 символов!"
        else
            break
        fi
    done
    echo ""
    
    # Интерактивный ввод данных о других точках доступа
    if [ "$ROUTER_TYPE" = "R2" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Для точки доступа нужны данные об основном роутере (R1)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        read -r -p "Введите IP адрес основного роутера [192.168.1.1]: " R1_IP
        R1_IP=${R1_IP:-192.168.1.1}
        echo ""
    fi
    
    # Подтверждение параметров
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Проверьте введенные параметры:"
    echo "  Режим: $ROUTER_TYPE"
    if [ "$ROAMING_ENABLED" = "1" ]; then
        echo "  Роуминг: ВКЛЮЧЕН (802.11r/k/v)"
    else
        echo "  Роуминг: ОТКЛЮЧЕН (стандартный WiFi)"
    fi
    echo "  SSID: $SSID"
    echo "  Пароль: $PASSWORD"
    if [ "$ROUTER_TYPE" = "R2" ]; then
        echo "  IP основного роутера: $R1_IP"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    read -r -p "Всё верно? Продолжить? [Y/n]: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        echo "[*] Отмена. Запустите скрипт заново."
        exit 0
    fi
    echo ""
}

# ----------------------------
# Проверка и установка необходимых пакетов
# ----------------------------
setup_packages() {
    echo "[*] Настройка пакетов для WiFi..."
    
    $PKG_UPDATE > /dev/null 2>&1
    
    # Удаление урезанных версий wpad
    WPAD_PACKAGES=$($PKG_LIST 2>/dev/null | grep -E "^wpad-" || true)
    if [ -n "$WPAD_PACKAGES" ]; then
        for pkg in $WPAD_PACKAGES; do
            case "$pkg" in
                wpad-basic|wpad-basic-openssl|wpad-basic-mbedtls|wpad-mini)
                    echo "[*] Удаление устаревшего пакета: $pkg"
                    $PKG_REMOVE "$pkg" > /dev/null 2>&1 || true
                    ;;
            esac
        done
    fi
    
    # Установка полного wpad
    echo "[*] Установка wpad (полная поддержка WiFi)..."
    for wpadv in wpad-openssl wpad-mbedtls wpad; do
        if $PKG_INSTALL "$wpadv" > /dev/null 2>&1; then
            echo "[✓] Установлен $wpadv"
            break
        fi
    done
    
    # Проверка установки
    if ! $PKG_LIST 2>/dev/null | grep -qE "^wpad-"; then
        echo "[!] Критическая ошибка: не удалось установить wpad"
        exit 1
    fi
    
    echo "[✓] Пакеты установлены"
}

# ----------------------------
# Определение WiFi интерфейсов
# ----------------------------
detect_wifi_interfaces() {
    echo "[*] Обнаружение WiFi интерфейсов..."
    
    RADIO_24G=""
    RADIO_5G=""
    
    # Поиск через UCI
    for radio_path in $(uci show wireless 2>/dev/null | grep "='radio'" | cut -d. -f1-2 | sort -u); do
        radio_name=$(echo "$radio_path" | cut -d. -f2)
        band=$(uci get ${radio_path}.band 2>/dev/null || echo "")
        hwmode=$(uci get ${radio_path}.hwmode 2>/dev/null || echo "")
        
        if [ "$band" = "2g" ] || [ "$hwmode" = "11g" ] || [ "$hwmode" = "11n" ]; then
            if [ -z "$RADIO_24G" ]; then
                RADIO_24G="$radio_path"
                RADIO_24G_NAME="$radio_name"
                echo "[✓] Найден 2.4GHz: $radio_name"
            fi
        elif [ "$band" = "5g" ] || [ "$hwmode" = "11a" ] || [ "$hwmode" = "11ac" ] || [ "$hwmode" = "11ax" ]; then
            if [ -z "$RADIO_5G" ]; then
                RADIO_5G="$radio_path"
                RADIO_5G_NAME="$radio_name"
                echo "[✓] Найден 5GHz: $radio_name"
            fi
        fi
    done
    
    # Резервный поиск через iw
    if [ -z "$RADIO_24G" ] || [ -z "$RADIO_5G" ]; then
        for phy in $(iw list 2>/dev/null | grep "Wiphy" | awk '{print $2}'); do
            bands=$(iw phy "$phy" info 2>/dev/null | grep "Band [0-9]:" | awk '{print $2}')
            
            for band in $bands; do
                if echo "$band" | grep -q "^2"; then
                    if [ -z "$RADIO_24G" ]; then
                        RADIO_24G="wireless.${phy}"
                        RADIO_24G_NAME="$phy"
                        echo "[✓] Найден 2.4GHz через iw: $phy"
                    fi
                elif echo "$band" | grep -q "^5"; then
                    if [ -z "$RADIO_5G" ]; then
                        RADIO_5G="wireless.${phy}"
                        RADIO_5G_NAME="$phy"
                        echo "[✓] Найден 5GHz через iw: $phy"
                    fi
                fi
            done
        done
    fi
    
    if [ -z "$RADIO_24G" ] && [ -z "$RADIO_5G" ]; then
        echo "[!] Ошибка: не найдено ни одного WiFi интерфейса"
        exit 1
    fi
}

# ----------------------------
# Настройка параметров
# ----------------------------
set_parameters() {
    # Каналы и идентификаторы
    if [ "$ROUTER_TYPE" = "SOLO" ] || [ "$ROUTER_TYPE" = "R1" ]; then
        RADIO_24G_CH=1
        RADIO_5G_CH=36
        if [ "$ROAMING_ENABLED" = "1" ]; then
            NASID_24="${SSID}_24G_R1"
            NASID_5="${SSID}_5G_R1"
            MOBILITY_DOMAIN="a1b2"
        fi
        ROUTER_IP="192.168.1.1"
    else
        RADIO_24G_CH=6
        RADIO_5G_CH=40
        NASID_24="${SSID}_24G_R2"
        NASID_5="${SSID}_5G_R2"
        MOBILITY_DOMAIN="a1b2"
        ROUTER_IP=${R1_IP:-"192.168.1.1"}
    fi
}

# ----------------------------
# Настройка WiFi интерфейса
# ----------------------------
configure_wifi_band() {
    local RADIO_PATH="$1"
    local RADIO_NAME="$2"
    local CHANNEL="$3"
    local NASID="$4"
    local BAND_NAME="$5"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[*] Настройка $BAND_NAME ($RADIO_NAME)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Настройка радио
    uci set ${RADIO_PATH}.disabled='0'
    uci set ${RADIO_PATH}.country='RU'
    uci set ${RADIO_PATH}.channel="$CHANNEL"
    uci set ${RADIO_PATH}.htmode="$([ "$BAND_NAME" = "2.4GHz" ] && echo 'HT20' || echo 'VHT80')"
    uci set ${RADIO_PATH}.noscan='1'
    
    # Создание нового WiFi интерфейса
    uci add wireless wifi-iface > /dev/null
    local IFACE="wireless.@wifi-iface[-1]"
    
    # Базовая настройка (работает всегда)
    uci set ${IFACE}.device="$RADIO_NAME"
    uci set ${IFACE}.network='lan'
    uci set ${IFACE}.mode='ap'
    uci set ${IFACE}.ssid="$SSID"
    uci set ${IFACE}.encryption='psk2'
    uci set ${IFACE}.key="$PASSWORD"
    
    # Оптимизации (работают всегда, независимо от роуминга)
    uci set ${IFACE}.wmm='1'                    # WiFi Multimedia
    uci set ${IFACE}.wpa_group_rekey='3600'     # Перегенерация ключей
    uci set ${IFACE}.isolate='0'                # Клиенты видят друг друга
    uci set ${IFACE}.disassoc_low_ack='0'       # Не отключать при слабом сигнале
    uci set ${IFACE}.beacon_int='100'           # Интервал beacon
    uci set ${IFACE}.dtim_period='2'            # DTIM период
    
    # Настройки роуминга (ТОЛЬКО если роуминг включен)
    if [ "$ROAMING_ENABLED" = "1" ]; then
        echo "[*] Включение протоколов роуминга для $BAND_NAME..."
        
        # 802.11r Fast BSS Transition
        uci set ${IFACE}.ieee80211r='1'
        uci set ${IFACE}.mobility_domain="$MOBILITY_DOMAIN"
        uci set ${IFACE}.ft_over_ds='1'
        uci set ${IFACE}.ft_psk_generate_local='1'
        uci set ${IFACE}.nasid="$NASID"
        uci set ${IFACE}.pmk_r1_push='1'
        
        # 802.11k Radio Resource Management
        uci set ${IFACE}.ieee80211k='1'
        uci set ${IFACE}.rrm_neighbor_report='1'
        uci set ${IFACE}.rrm_beacon_report='1'
        
        # 802.11v Wireless Network Management
        uci set ${IFACE}.ieee80211v='1'
        uci set ${IFACE}.bss_transition='1'
        
        echo "[✓] Роуминг включен для $BAND_NAME"
    else
        echo "[✓] Стандартный WiFi для $BAND_NAME"
    fi
}

# ----------------------------
# Настройка DHCP сервера (для SOLO и R1)
# ----------------------------
configure_dhcp() {
    echo ""
    echo "[*] Настройка DHCP сервера..."
    
    CURRENT_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
    echo "[*] Текущий IP роутера: $CURRENT_IP"
    
    read -r -p "Изменить IP? [y/N]: " CHANGE_IP
    if [ "$CHANGE_IP" = "y" ] || [ "$CHANGE_IP" = "Y" ]; then
        read -r -p "Введите новый IP [192.168.1.1]: " NEW_IP
        NEW_IP=${NEW_IP:-192.168.1.1}
        uci set network.lan.ipaddr="$NEW_IP"
    fi
    
    uci set network.lan.netmask='255.255.255.0'
    uci set dhcp.lan.start='100'
    uci set dhcp.lan.limit='150'
    uci set dhcp.lan.leasetime='12h'
    uci set dhcp.wan.ignore='1'
    
    echo "[✓] DHCP сервер настроен"
}

# ----------------------------
# Настройка точки доступа (для R2)
# ----------------------------
configure_ap_mode() {
    echo ""
    echo "[*] Настройка точки доступа..."
    
    DEFAULT_IP="192.168.1.2"
    read -r -p "Введите IP для этой точки доступа [$DEFAULT_IP]: " AP_IP
    AP_IP=${AP_IP:-$DEFAULT_IP}
    
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.netmask='255.255.255.0'
    uci set network.lan.gateway="$ROUTER_IP"
    uci set network.lan.dns="$ROUTER_IP"
    
    # Отключаем DHCP
    uci set dhcp.lan.ignore='1'
    
    # Останавливаем DHCP сервер
    if [ -f /etc/init.d/dnsmasq ]; then
        /etc/init.d/dnsmasq disable > /dev/null 2>&1
        /etc/init.d/dnsmasq stop > /dev/null 2>&1
    fi
    
    # Отключаем firewall для pure AP
    read -r -p "Отключить firewall? (рекомендуется для AP) [Y/n]: " DISABLE_FW
    if [ "$DISABLE_FW" != "n" ] && [ "$DISABLE_FW" != "N" ]; then
        if [ -f /etc/init.d/firewall ]; then
            /etc/init.d/firewall disable > /dev/null 2>&1
            /etc/init.d/firewall stop > /dev/null 2>&1
            echo "[✓] Firewall отключен"
        fi
    fi
    
    echo "[✓] Режим точки доступа настроен (IP: $AP_IP)"
}

# ----------------------------
# Применение настроек
# ----------------------------
apply_settings() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "[*] Применение настроек..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Сохранение конфигурации
    uci commit wireless
    
    if [ "$ROUTER_TYPE" = "SOLO" ] || [ "$ROUTER_TYPE" = "R1" ]; then
        uci commit network
        uci commit dhcp
    else
        uci commit network
        uci commit dhcp
    fi
    
    # Перезагрузка WiFi
    echo "[*] Перезагрузка WiFi интерфейсов..."
    wifi reload > /dev/null 2>&1 || wifi
    
    # Перезапуск сети для AP
    if [ "$ROUTER_TYPE" = "R2" ]; then
        echo "[*] Перезапуск сетевых сервисов..."
        /etc/init.d/network restart > /dev/null 2>&1
    fi
    
    echo "[✓] Настройки применены"
}

# ----------------------------
# Вывод результатов
# ----------------------------
show_results() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║            НАСТРОЙКА WiFi ЗАВЕРШЕНА УСПЕШНО               ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║ Режим:           $ROUTER_TYPE                                       ║"
    echo "║ SSID:            $SSID                                ║"
    echo "║ Шифрование:      WPA2-PSK                              ║"
    echo "║ Пароль:          $PASSWORD                        ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    
    if [ "$ROAMING_ENABLED" = "1" ]; then
        echo "║ РОУМИНГ:         ВКЛЮЧЕН                               ║"
        echo "║ Mobility Domain: $MOBILITY_DOMAIN                                    ║"
        echo "║ Протоколы:       802.11r + 802.11k + 802.11v           ║"
        echo "╠══════════════════════════════════════════════════════════╣"
    else
        echo "║ РОУМИНГ:         ОТКЛЮЧЕН                              ║"
        echo "║ Режим:           Стандартный WiFi                       ║"
        echo "╠══════════════════════════════════════════════════════════╣"
    fi
    
    if [ -n "$RADIO_24G_NAME" ]; then
        echo "║ 2.4GHz:          Канал: $RADIO_24G_CH                              ║"
        if [ "$ROAMING_ENABLED" = "1" ]; then
            echo "║                  NASID: $NASID_24              ║"
        fi
    fi
    if [ -n "$RADIO_5G_NAME" ]; then
        echo "║ 5GHz:            Канал: $RADIO_5G_CH                             ║"
        if [ "$ROAMING_ENABLED" = "1" ]; then
            echo "║                  NASID: $NASID_5               ║"
        fi
    fi
    
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ "$ROUTER_TYPE" = "SOLO" ]; then
        echo "[✓] Роутер настроен как самостоятельное устройство"
        echo "    • WiFi работает в стандартном режиме"
        echo "    • Все клиенты могут подключаться"
        echo "    • DHCP сервер активен"
        echo "    • IP роутера: 192.168.1.1"
        echo ""
        echo "[*] Если в будущем захотите добавить точки доступа:"
        echo "    1. Запустите этот скрипт заново"
        echo "    2. Выберите режим 'Основной роутер R1'"
        echo "    3. Используйте те же SSID и пароль"
        echo "    4. На дополнительных точках выберите 'Точка доступа R2'"
        
    elif [ "$ROUTER_TYPE" = "R1" ]; then
        echo "[✓] Основной роутер настроен с поддержкой роуминга"
        echo "    • WiFi работает с 802.11r/k/v"
        echo "    • Можно добавлять точки доступа"
        echo "    • DHCP сервер активен"
        echo "    • IP роутера: 192.168.1.1"
        echo ""
        echo "[*] Для добавления точки доступа:"
        echo "    1. Подключите новую точку к этому роутеру через LAN"
        echo "    2. Запустите этот скрипт на новой точке"
        echo "    3. Выберите 'Точка доступа R2'"
        echo "    4. Используйте ТОЧНО такие же SSID и пароль"
        
    else
        echo "[✓] Точка доступа настроена для бесшовного роуминга"
        echo "    • WiFi работает с 802.11r/k/v"
        echo "    • Подключена к основному роутеру $ROUTER_IP"
        echo "    • DHCP сервер отключен"
        echo "    • IP точки доступа: $AP_IP"
        echo ""
        echo "[!] ВАЖНО: Убедитесь, что:"
        echo "    • Точка подключена к R1 через LAN порт"
        echo "    • SSID и пароль совпадают с R1"
        echo "    • Основной роутер доступен по IP $ROUTER_IP"
    fi
    
    echo ""
    echo "[*] Полезные команды:"
    echo "  • Статус WiFi: iwinfo"
    echo "  • Список клиентов: iwinfo wlan0 assoclist"
    if [ "$ROAMING_ENABLED" = "1" ]; then
        echo "  • Логи роуминга: logread | grep -E 'roam|FT|WNM'"
    fi
    echo ""
}

# ----------------------------
# Главная функция
# ----------------------------
main() {
    echo "[*] Запуск настройки WiFi..."
    echo ""
    
    detect_openwrt_version
    input_parameters
    setup_packages
    detect_wifi_interfaces
    set_parameters
    
    # Очистка существующей WiFi конфигурации
    echo "[*] Очистка существующей WiFi конфигурации..."
    while uci -q delete wireless.@wifi-iface[0] 2>/dev/null; do :; done
    
    # Настройка WiFi диапазонов
    if [ -n "$RADIO_24G" ]; then
        configure_wifi_band "$RADIO_24G" "$RADIO_24G_NAME" "$RADIO_24G_CH" "$NASID_24" "2.4GHz"
    fi
    
    if [ -n "$RADIO_5G" ]; then
        configure_wifi_band "$RADIO_5G" "$RADIO_5G_NAME" "$RADIO_5G_CH" "$NASID_5" "5GHz"
    fi
    
    # Настройка в зависимости от типа роутера
    if [ "$ROUTER_TYPE" = "SOLO" ] || [ "$ROUTER_TYPE" = "R1" ]; then
        configure_dhcp
    else
        configure_ap_mode
    fi
    
    apply_settings
    show_results
}

# Запуск
main "$@"
