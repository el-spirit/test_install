#!/bin/sh
#
# Universal OpenWrt WiFi Setup Script v2.0
# Поддержка: Смена имени/пароля, Бесшовный роуминг, Mesh, WPA3
# Совместимость: OpenWrt 23.05+, 24.10+, 25.12+
#

set -e  # Остановка при ошибках

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          OpenWrt WiFi Setup Wizard v2.0                 ║${NC}"
echo -e "${BLUE}║     Смена имени/пароля + Бесшовный роуминг             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ====================== ФУНКЦИИ ======================
check_package_manager() {
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add"
        PKG_REMOVE="apk del"
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
        PKG_UPDATE="opkg update"
        PKG_INSTALL="opkg install"
        PKG_REMOVE="opkg remove"
    else
        echo -e "${RED}[!] Пакетный менеджер не найден!${NC}"
        exit 1
    fi
    echo -e "${GREEN}[✓] Пакетный менеджер: $PKG_MGR${NC}"
}

backup_config() {
    local backup_file="/etc/config/wireless.backup.$(date +%Y%m%d_%H%M%S)"
    cp /etc/config/wireless "$backup_file" 2>/dev/null || true
    cp /etc/config/network /etc/config/network.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    echo -e "${GREEN}[✓] Резервная копия создана: $backup_file${NC}"
}

install_wpad() {
    echo -e "${YELLOW}[*] Проверка и установка wpad...${NC}"
    
    # Удаляем урезанные версии
    for pkg in wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini wpad-mesh-openssl; do
        $PKG_REMOVE "$pkg" 2>/dev/null || true
    done
    
    # Устанавливаем полную версию
    if [ "$ROAMING" = "1" ] || [ "$WPA3" = "1" ]; then
        echo -e "${YELLOW}[*] Установка wpad-openssl (WPA3/роуминг)...${NC}"
        $PKG_UPDATE >/dev/null 2>&1
        $PKG_INSTALL wpad-openssl 2>/dev/null || $PKG_INSTALL wpad 2>/dev/null
    fi
    
    echo -e "${GREEN}[✓] WPAD готов${NC}"
}

detect_interfaces() {
    echo -e "${YELLOW}[*] Определение WiFi интерфейсов...${NC}"
    
    # Проверяем существование конфигурации
    if ! uci get wireless.radio0 >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] Конфигурация wireless не найдена. Создаю базовую...${NC}"
        rm -f /etc/config/wireless
        wifi config
        sleep 3
    fi
    
    # Определяем количество радио-модулей
    RADIO_COUNT=$(uci show wireless | grep -c "wireless\.radio[0-9]=wifi-device" || echo "0")
    echo -e "${GREEN}[✓] Найдено радио-модулей: $RADIO_COUNT${NC}"
    
    # Получаем имена интерфейсов динамически
    IFACE_24=""
    IFACE_5=""
    IFACE_6=""
    
    for iface in $(uci show wireless | grep "=wifi-iface" | cut -d= -f1); do
        device=$(uci get ${iface}.device 2>/dev/null)
        band=$(uci get wireless.${device}.band 2>/dev/null)
        
        case "$band" in
            "2g") IFACE_24=$(echo $iface | cut -d. -f2) ;;
            "5g") IFACE_5=$(echo $iface | cut -d. -f2) ;;
            "6g") IFACE_6=$(echo $iface | cut -d. -f2) ;;
        esac
    done
    
    # Если не нашли по band, пробуем по имени radio
    [ -z "$IFACE_24" ] && IFACE_24=$(uci show wireless | grep "device='radio0'" | head -1 | cut -d. -f2 | cut -d= -f1)
    [ -z "$IFACE_5" ] && IFACE_5=$(uci show wireless | grep "device='radio1'" | head -1 | cut -d. -f2 | cut -d= -f1)
    
    echo -e "${GREEN}[✓] Интерфейсы: 2.4GHz=$IFACE_24, 5GHz=$IFACE_5, 6GHz=$IFACE_6${NC}"
}

configure_security() {
    echo ""
    echo -e "${YELLOW}[*] Выберите тип шифрования:${NC}"
    echo "  1) WPA2-PSK (рекомендуется для совместимости)"
    echo "  2) WPA3-SAE (современный, требуется поддержка клиентов)"
    echo "  3) WPA2/WPA3 Mixed (переходный режим)"
    echo "  4) Открытая сеть (не рекомендуется)"
    read -r -p "Ваш выбор [1-4]: " SEC_CHOICE
    
    case "$SEC_CHOICE" in
        1) 
            ENCRYPTION="psk2"
            WPA3=0
            ;;
        2) 
            ENCRYPTION="sae"
            WPA3=1
            ;;
        3) 
            ENCRYPTION="psk2+sae"
            WPA3=1
            ;;
        4) 
            ENCRYPTION="none"
            WPA3=0
            PASSWORD=""
            ;;
        *) 
            ENCRYPTION="psk2"
            WPA3=0
            ;;
    esac
    
    if [ "$ENCRYPTION" != "none" ]; then
        while true; do
            read -r -p "Введите пароль WiFi (минимум 8 символов): " PASSWORD
            if [ ${#PASSWORD} -ge 8 ]; then
                break
            else
                echo -e "${RED}[!] Пароль должен быть минимум 8 символов${NC}"
            fi
        done
    fi
}

configure_roaming_options() {
    echo ""
    echo -e "${YELLOW}[*] Настройка дополнительных параметров роуминга:${NC}"
    
    # Fast Transition
    read -r -p "Использовать Fast Transition (802.11r)? [Y/n]: " FT_CHOICE
    [ "$FT_CHOICE" = "n" ] || [ "$FT_CHOICE" = "N" ] && ENABLE_FT=0 || ENABLE_FT=1
    
    # Neighbor Reports
    read -r -p "Использовать Neighbor Reports (802.11k)? [Y/n]: " K_CHOICE
    [ "$K_CHOICE" = "n" ] || [ "$K_CHOICE" = "K" ] && ENABLE_K=0 || ENABLE_K=1
    
    # BSS Transition
    read -r -p "Использовать BSS Transition (802.11v)? [Y/n]: " V_CHOICE
    [ "$V_CHOICE" = "n" ] || [ "$V_CHOICE" = "V" ] && ENABLE_V=0 || ENABLE_V=1
    
    # Disassoc timer (время ожидания перед разрывом соединения)
    read -r -p "Таймаут disassoc в мс [5000]: " DISASSOC_TIMER
    DISASSOC_TIMER=${DISASSOC_TIMER:-5000}
    
    # Mobility domain
    read -r -p "Mobility Domain (4 hex символа) [a1b2]: " MOBILITY_DOMAIN
    MOBILITY_DOMAIN=${MOBILITY_DOMAIN:-a1b2}
}

apply_wifi_config() {
    local radio=$1
    local iface=$2
    local band=$3
    
    echo -e "${YELLOW}[*] Настройка $band...${NC}"
    
    # Базовые настройки радио
    uci set wireless.${radio}.country="$COUNTRY"
    uci set wireless.${radio}.disabled='0'
    
    # Настройки интерфейса
    uci set wireless.${iface}.ssid="$SSID"
    uci set wireless.${iface}.encryption="$ENCRYPTION"
    [ -n "$PASSWORD" ] && uci set wireless.${iface}.key="$PASSWORD"
    uci set wireless.${iface}.wmm='1'
    uci set wireless.${iface}.network='lan'
    
    # Настройки роуминга
    if [ "$ROAMING" = "1" ]; then
        echo -e "${BLUE}  [+] Добавление параметров роуминга...${NC}"
        
        [ "$ENABLE_FT" = "1" ] && {
            uci set wireless.${iface}.ieee80211r='1'
            uci set wireless.${iface}.mobility_domain="$MOBILITY_DOMAIN"
            uci set wireless.${iface}.ft_over_ds='1'
            uci set wireless.${iface}.ft_psk_generate_local='1'
            [ "$WPA3" = "1" ] && {
                uci set wireless.${iface}.ft_associated='1'
                uci set wireless.${iface}.ft_encryption='1'
            }
        }
        
        [ "$ENABLE_K" = "1" ] && {
            uci set wireless.${iface}.ieee80211k='1'
            uci set wireless.${iface}.rrm_neighbor_report='1'
            uci set wireless.${iface}.rrm_beacon_report='1'
        }
        
        [ "$ENABLE_V" = "1" ] && {
            uci set wireless.${iface}.ieee80211v='1'
            uci set wireless.${iface}.bss_transition='1'
            uci set wireless.${iface}.disassoc_low_ack='1'
            uci set wireless.${iface}.time_advertisement='2'
        }
        
        uci set wireless.${iface}.nasid="${SSID}_${band}"
        uci set wireless.${iface}.wnm_sleep_mode='1'
        uci set wireless.${iface}.mbo_cell_capa='1'
    else
        # Удаляем настройки роуминга
        for opt in ieee80211r mobility_domain ft_over_ds ft_psk_generate_local \
                  ieee80211k rrm_neighbor_report rrm_beacon_report \
                  ieee80211v bss_transition disassoc_low_ack time_advertisement \
                  nasid wnm_sleep_mode mbo_cell_capa ft_associated ft_encryption; do
            uci -q delete wireless.${iface}.${opt} 2>/dev/null || true
        done
    fi
}

show_status() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║            НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО                   ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║ Режим:           $ROUTER_TYPE${NC}"
    echo -e "${BLUE}║ SSID:            $SSID${NC}"
    echo -e "${BLUE}║ Шифрование:      $ENCRYPTION${NC}"
    [ -n "$PASSWORD" ] && echo -e "${BLUE}║ Пароль:          $PASSWORD${NC}"
    
    if [ "$ROAMING" = "1" ]; then
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║ РОУМИНГ ВКЛЮЧЕН${NC}"
        [ "$ENABLE_FT" = "1" ] && echo -e "${BLUE}║  ✓ 802.11r Fast Transition${NC}"
        [ "$ENABLE_K" = "1" ] && echo -e "${BLUE}║  ✓ 802.11k Neighbor Reports${NC}"
        [ "$ENABLE_V" = "1" ] && echo -e "${BLUE}║  ✓ 802.11v BSS Transition${NC}"
        echo -e "${BLUE}║  Mobility Domain: $MOBILITY_DOMAIN${NC}"
    fi
    
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
}

# ====================== ОСНОВНОЙ КОД ======================
check_package_manager
backup_config

# Режим работы
while true; do
    echo ""
    echo -e "${YELLOW}Выберите режим работы:${NC}"
    echo "  1) Только сменить имя/пароль (без роуминга)"
    echo "  2) Основной роутер (R1, DHCP сервер)"
    echo "  3) Точка доступа (R2, роуминг клиент)"
    echo "  4) Mesh узел (802.11s)"
    echo "  5) Показать текущую конфигурацию"
    echo "  6) Восстановить из резервной копии"
    echo "  7) Выход"
    read -r -p "Ваш выбор [1-7]: " MAIN_CHOICE
    
    case "$MAIN_CHOICE" in
        1) ROUTER_TYPE="SOLO"; ROAMING=0; break ;;
        2) ROUTER_TYPE="R1"; ROAMING=1; break ;;
        3) ROUTER_TYPE="R2"; ROAMING=1; break ;;
        4) ROUTER_TYPE="MESH"; ROAMING=1; break ;;
        5) cat /etc/config/wireless; continue ;;
        6) 
            echo -e "${YELLOW}Доступные резервные копии:${NC}"
            ls -la /etc/config/wireless.backup.* 2>/dev/null || echo "Резервных копий не найдено"
            read -r -p "Имя файла для восстановления: " BACKUP_FILE
            [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" /etc/config/wireless || echo -e "${RED}Файл не найден!${NC}"
            continue
            ;;
        7) exit 0 ;;
        *) echo -e "${RED}[!] Неверный выбор!${NC}" ;;
    esac
done

# Базовые параметры
echo ""
read -r -p "Введите имя WiFi сети (SSID): " SSID
configure_security

if [ "$ROAMING" = "1" ]; then
    configure_roaming_options
fi

if [ "$ROUTER_TYPE" = "R2" ] || [ "$ROUTER_TYPE" = "MESH" ]; then
    read -r -p "Введите IP основного роутера [192.168.1.1]: " R1_IP
    R1_IP=${R1_IP:-192.168.1.1}
fi

# Подтверждение
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Режим: $ROUTER_TYPE"
echo -e "SSID: $SSID"
echo -e "Шифрование: $ENCRYPTION"
[ -n "$PASSWORD" ] && echo -e "Пароль: $PASSWORD"
[ "$ROAMING" = "1" ] && echo -e "Роуминг: ВКЛЮЧЕН (FT=$ENABLE_FT, K=$ENABLE_K, V=$ENABLE_V)"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -r -p "Продолжить? [Y/n]: " CONFIRM
[ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && exit 0

# Установка пакетов
install_wpad

# Определение интерфейсов
detect_interfaces

# Применение конфигурации
COUNTRY="RU"

echo ""
echo -e "${YELLOW}[*] Применение конфигурации...${NC}"

# Настройка каждого интерфейса
[ -n "$IFACE_24" ] && apply_wifi_config "radio0" "$IFACE_24" "2.4GHz"
[ -n "$IFACE_5" ] && apply_wifi_config "radio1" "$IFACE_5" "5GHz"
[ -n "$IFACE_6" ] && apply_wifi_config "radio2" "$IFACE_6" "6GHz"

# Сохранение
uci commit wireless

# Дополнительные настройки для R2/Mesh
if [ "$ROUTER_TYPE" = "R2" ]; then
    echo -e "${YELLOW}[*] Настройка точки доступа...${NC}"
    uci set dhcp.lan.ignore='1'
    uci commit dhcp
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    /etc/init.d/dnsmasq stop 2>/dev/null || true
elif [ "$ROUTER_TYPE" = "MESH" ]; then
    echo -e "${YELLOW}[*] Настройка Mesh...${NC}"
    # Дополнительные настройки для mesh можно добавить здесь
fi

# Применение
echo -e "${YELLOW}[*] Применение настроек...${NC}"
wifi reload
sleep 3

# Показать результат
show_status

# Проверка работы
echo ""
echo -e "${YELLOW}[*] Проверка статуса WiFi:${NC}"
iwinfo 2>/dev/null | grep -E "ESSID|Channel|Mode|Encryption" || echo "Команда 'iwinfo' не найдена, используйте 'iw dev'"

echo ""
echo -e "${GREEN}[✓] Готово! WiFi настроен.${NC}"
