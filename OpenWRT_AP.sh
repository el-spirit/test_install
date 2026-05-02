#!/bin/sh
#
# Universal OpenWrt WiFi + Access Point Setup Script v3.0
# Объединяет настройку WiFi, роуминга и точки доступа
# Совместимость: OpenWrt 23.05+, 24.10+, 25.12+
# Работает с любым железом, любым пакетным менеджером
#

# ====================== ЦВЕТА ======================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# ====================== ПЕРЕМЕННЫЕ ======================
SCRIPT_VERSION="3.0"
BACKUP_DIR="/etc/config/backup_$(date +%Y%m%d_%H%M%S)"
TMP_DIR="/tmp/wifi_ap_setup_$$"

# ====================== БАЗОВЫЕ ФУНКЦИИ ======================

# Очистка при выходе
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Создание временной директории
mkdir -p "$TMP_DIR" "$BACKUP_DIR"

# Функция паузы
pause() {
    echo ""
    read -r -p "Нажмите Enter для продолжения..." dummy
}

# Проверка root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[!] Скрипт должен запускаться от root!${NC}"
        exit 1
    fi
}

# ====================== ОПРЕДЕЛЕНИЕ СИСТЕМЫ ======================

detect_system() {
    echo -e "${YELLOW}[*] Определение системы...${NC}"
    
    # Определение версии OpenWrt
    if [ -f /etc/openwrt_release ]; then
        OWRT_VERSION=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d"'" -f2)
        OWRT_ARCH=$(grep DISTRIB_ARCH /etc/openwrt_release | cut -d"'" -f2)
        OWRT_TARGET=$(grep DISTRIB_TARGET /etc/openwrt_release | cut -d"'" -f2)
        echo -e "${GREEN}[✓] OpenWrt $OWRT_VERSION ($OWRT_ARCH)${NC}"
    else
        echo -e "${RED}[!] Система не является OpenWrt!${NC}"
        exit 1
    fi
    
    # Определение пакетного менеджера
    if command -v apk >/dev/null 2>&1; then
        PKG_MGR="apk"
        PKG_UPDATE="apk update"
        PKG_INSTALL="apk add --allow-untrusted"
        PKG_REMOVE="apk del"
        PKG_LIST="apk list -I 2>/dev/null"
        PKG_EXT="apk"
        IS_APK=1
    elif command -v opkg >/dev/null 2>&1; then
        PKG_MGR="opkg"
        PKG_UPDATE="opkg update"
        PKG_INSTALL="opkg install"
        PKG_REMOVE="opkg remove --force-depends"
        PKG_LIST="opkg list-installed 2>/dev/null"
        PKG_EXT="ipk"
        IS_APK=0
    else
        echo -e "${RED}[!] Пакетный менеджер не найден!${NC}"
        exit 1
    fi
    echo -e "${GREEN}[✓] Пакетный менеджер: $PKG_MGR${NC}"
}

# Проверка пакета
pkg_installed() {
    local pkg="$1"
    if [ "$IS_APK" -eq 1 ]; then
        apk info -e "$pkg" >/dev/null 2>&1
    else
        opkg list-installed | grep -q "^$pkg "
    fi
}

# ====================== ОПРЕДЕЛЕНИЕ СЕТЕВЫХ ИНТЕРФЕЙСОВ ======================

detect_network_interfaces() {
    echo -e "${YELLOW}[*] Определение сетевых интерфейсов...${NC}"
    
    # Все физические интерфейсы
    PHYS_DEVICES=""
    for dev in $(ls /sys/class/net/ 2>/dev/null); do
        # Пропускаем виртуальные интерфейсы
        case "$dev" in
            lo|br-*|bond*|dummy*|gre*|ifb*|ip6*|sit*|tap*|tun*|veth*|vlan*|wg*|wlan*|phy*|radio*|mon*)
                continue
                ;;
        esac
        
        # Проверяем что это физический интерфейс
        if [ -d "/sys/class/net/$dev/device" ] || [ -f "/sys/class/net/$dev/device/id" ]; then
            PHYS_DEVICES="$PHYS_DEVICES $dev"
        elif echo "$dev" | grep -qE '^(eth|enp|ens|eno)[0-9]'; then
            PHYS_DEVICES="$PHYS_DEVICES $dev"
        elif ethtool "$dev" 2>/dev/null | grep -q "Supported ports"; then
            PHYS_DEVICES="$PHYS_DEVICES $dev"
        fi
    done
    
    # Очистка от лишних пробелов
    PHYS_DEVICES=$(echo "$PHYS_DEVICES" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ *//;s/ *$//')
    
    # Если ничего не нашли, берем все eth* и en*
    if [ -z "$PHYS_DEVICES" ]; then
        PHYS_DEVICES=$(ls /sys/class/net/ 2>/dev/null | grep -E '^(eth|enp|ens|eno|lan|wan)[0-9]*$' | tr '\n' ' ' | sed 's/ *$//')
    fi
    
    echo -e "${GREEN}[✓] Физические порты: ${CYAN}$PHYS_DEVICES${NC}"
    PHYS_PORTS="$PHYS_DEVICES"
    
    # Текущий LAN
    CURRENT_LAN_DEV=""
    if uci get network.lan.device >/dev/null 2>&1; then
        CURRENT_LAN_DEV=$(uci get network.lan.device)
    fi
    echo -e "${YELLOW}[*] Текущий LAN: ${CYAN}$CURRENT_LAN_DEV${NC}"
    
    # Текущий WAN
    CURRENT_WAN_DEV=""
    CURRENT_WAN_IFACE=""
    if uci get network.wan >/dev/null 2>&1; then
        CURRENT_WAN_DEV=$(uci get network.wan.device 2>/dev/null || echo "")
        CURRENT_WAN_IFACE="wan"
    fi
    [ -n "$CURRENT_WAN_DEV" ] && echo -e "${YELLOW}[*] Текущий WAN: ${CYAN}$CURRENT_WAN_DEV${NC}"
    
    # Текущий IP
    CURRENT_IP=$(uci get network.lan.ipaddr 2>/dev/null | cut -d/ -f1 || ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$CURRENT_IP" ] && CURRENT_IP=$(ip -4 addr show lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$CURRENT_IP" ] && CURRENT_IP="192.168.1.1"
    echo -e "${YELLOW}[*] Текущий IP: ${CYAN}$CURRENT_IP${NC}"
}

# ====================== ОПРЕДЕЛЕНИЕ WiFi ИНТЕРФЕЙСОВ ======================

detect_wifi_interfaces() {
    echo -e "${YELLOW}[*] Определение WiFi интерфейсов...${NC}"
    
    # Проверяем существование конфигурации
    if ! uci get wireless.radio0 >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] Конфигурация wireless не найдена. Создаю...${NC}"
        wifi config 2>/dev/null || {
            echo -e "${RED}[!] Не удалось создать конфигурацию wireless${NC}"
            return 1
        }
        sleep 3
    fi
    
    # Определяем радио-модули
    RADIOS=""
    for radio in $(uci show wireless | grep "=wifi-device" | cut -d= -f1 | cut -d. -f2 | sort); do
        if uci get wireless.$radio >/dev/null 2>&1; then
            RADIOS="$RADIOS $radio"
        fi
    done
    RADIOS=$(echo "$RADIOS" | sed 's/^ *//')
    RADIO_COUNT=$(echo "$RADIOS" | wc -w)
    echo -e "${GREEN}[✓] Найдено радио-модулей: $RADIO_COUNT${NC}"
    
    # Определяем интерфейсы для каждого радио
    IFACE_24=""
    IFACE_5=""
    IFACE_6=""
    
    for radio in $RADIOS; do
        band=$(uci get wireless.$radio.band 2>/dev/null || echo "")
        # Получаем интерфейс привязанный к этому радио
        iface=$(uci show wireless | grep "device='$radio'" | head -1 | cut -d. -f2 | cut -d= -f1)
        
        case "$band" in
            "2g") 
                IFACE_24="$iface"
                echo -e "${GREEN}[✓] 2.4GHz: $radio → $iface${NC}"
                ;;
            "5g") 
                IFACE_5="$iface"
                echo -e "${GREEN}[✓] 5GHz: $radio → $iface${NC}"
                ;;
            "6g") 
                IFACE_6="$iface"
                echo -e "${GREEN}[✓] 6GHz: $radio → $iface${NC}"
                ;;
            *)
                # Пытаемся определить по номеру
                case "$radio" in
                    "radio0") 
                        IFACE_24="$iface"
                        echo -e "${YELLOW}[✓] radio0 (предположительно 2.4GHz): $iface${NC}"
                        ;;
                    "radio1") 
                        IFACE_5="$iface"
                        echo -e "${YELLOW}[✓] radio1 (предположительно 5GHz): $iface${NC}"
                        ;;
                    "radio2") 
                        IFACE_6="$iface"
                        echo -e "${YELLOW}[✓] radio2 (предположительно 6GHz): $iface${NC}"
                        ;;
                esac
                ;;
        esac
    done
    
    # Создаем недостающие интерфейсы
    if [ -n "$(echo "$RADIOS" | grep radio0)" ] && [ -z "$IFACE_24" ]; then
        echo -e "${YELLOW}[!] Создаю интерфейс для radio0...${NC}"
        uci add wireless wifi-iface >/dev/null
        uci set wireless.@wifi-iface[-1].device='radio0'
        uci set wireless.@wifi-iface[-1].mode='ap'
        uci set wireless.@wifi-iface[-1].network='lan'
        IFACE_24=$(uci show wireless | grep "device='radio0'" | tail -1 | cut -d. -f2 | cut -d= -f1)
    fi
    
    if [ -n "$(echo "$RADIOS" | grep radio1)" ] && [ -z "$IFACE_5" ]; then
        echo -e "${YELLOW}[!] Создаю интерфейс для radio1...${NC}"
        uci add wireless wifi-iface >/dev/null
        uci set wireless.@wifi-iface[-1].device='radio1'
        uci set wireless.@wifi-iface[-1].mode='ap'
        uci set wireless.@wifi-iface[-1].network='lan'
        IFACE_5=$(uci show wireless | grep "device='radio1'" | tail -1 | cut -d. -f2 | cut -d= -f1)
    fi
    
    uci commit wireless
}

# ====================== УСТАНОВКА ПАКЕТОВ ======================

install_wpad() {
    echo -e "${YELLOW}[*] Установка wpad для роуминга/WPA3...${NC}"
    
    # Удаляем урезанные версии
    for pkg in wpad-basic wpad-basic-mbedtls wpad-basic-openssl wpad-mini wpad-mesh-openssl; do
        if pkg_installed "$pkg"; then
            echo -e "${YELLOW}[*] Удаление $pkg...${NC}"
            $PKG_REMOVE "$pkg" 2>/dev/null || true
        fi
    done
    
    # Обновляем список пакетов
    $PKG_UPDATE >/dev/null 2>&1 || {
        echo -e "${YELLOW}[!] Предупреждение: не удалось обновить список пакетов${NC}"
    }
    
    # Устанавливаем полную версию
    if ! pkg_installed "wpad-openssl"; then
        echo -e "${YELLOW}[*] Установка wpad-openssl...${NC}"
        if ! $PKG_INSTALL wpad-openssl >/dev/null 2>&1; then
            echo -e "${YELLOW}[!] wpad-openssl не установился, пробую wpad...${NC}"
            $PKG_INSTALL wpad >/dev/null 2>&1 || echo -e "${RED}[!] Не удалось установить wpad${NC}"
        fi
    fi
    
    echo -e "${GREEN}[✓] WPAD готов${NC}"
}

# ====================== РЕЗЕРВНОЕ КОПИРОВАНИЕ ======================

backup_configs() {
    echo -e "${YELLOW}[*] Создание резервных копий...${NC}"
    
    mkdir -p "$BACKUP_DIR"
    
    for config in wireless network dhcp firewall dropbear system; do
        [ -f "/etc/config/$config" ] && cp "/etc/config/$config" "$BACKUP_DIR/$config" 2>/dev/null
    done
    
    echo -e "${GREEN}[✓] Резервные копии в: $BACKUP_DIR${NC}"
}

# ====================== НАСТРОЙКА WiFi ======================

configure_wifi() {
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                НАСТРОЙКА WiFi                            ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Режим работы
    while true; do
        echo -e "${YELLOW}Выберите режим WiFi:${NC}"
        echo "  1) Обычный WiFi (без роуминга)"
        echo "  2) Основной роутер с роумингом (R1, DHCP сервер)"
        echo "  3) Точка доступа с роумингом (R2, без DHCP)"
        echo "  4) Mesh узел (802.11s)"
        read -r -p "Ваш выбор [1-4]: " WIFI_MODE
        
        case "$WIFI_MODE" in
            1) ROUTER_TYPE="SOLO"; ROAMING=0; NEED_WPAD=0; break ;;
            2) ROUTER_TYPE="R1"; ROAMING=1; NEED_WPAD=1; break ;;
            3) ROUTER_TYPE="R2"; ROAMING=1; NEED_WPAD=1; break ;;
            4) ROUTER_TYPE="MESH"; ROAMING=1; NEED_WPAD=1; break ;;
            *) echo -e "${RED}[!] Неверный выбор!${NC}" ;;
        esac
    done
    
    # SSID и пароль
    echo ""
    read -r -p "Введите имя WiFi сети (SSID): " SSID
    
    # Тип шифрования
    echo ""
    echo -e "${YELLOW}Выберите тип шифрования:${NC}"
    echo "  1) WPA2-PSK (рекомендуется)"
    echo "  2) WPA3-SAE (современный)"
    echo "  3) WPA2/WPA3 Mixed"
    echo "  4) Открытая сеть (не рекомендуется)"
    read -r -p "Ваш выбор [1-4]: " SEC_CHOICE
    
    case "$SEC_CHOICE" in
        1) ENCRYPTION="psk2"; WPA3=0 ;;
        2) ENCRYPTION="sae"; WPA3=1; NEED_WPAD=1 ;;
        3) ENCRYPTION="psk2+sae"; WPA3=1; NEED_WPAD=1 ;;
        4) ENCRYPTION="none"; WPA3=0; PASSWORD="" ;;
        *) ENCRYPTION="psk2"; WPA3=0 ;;
    esac
    
    if [ "$ENCRYPTION" != "none" ]; then
        while true; do
            read -r -p "Введите пароль WiFi (минимум 8 символов): " PASSWORD
            if [ -z "$PASSWORD" ]; then
                echo -e "${RED}[!] Пароль не может быть пустым${NC}"
            elif [ ${#PASSWORD} -lt 8 ]; then
                echo -e "${RED}[!] Пароль должен быть минимум 8 символов${NC}"
            else
                break
            fi
        done
    fi
    
    # Настройка роуминга
    if [ "$ROAMING" = "1" ]; then
        echo ""
        echo -e "${YELLOW}Настройка параметров роуминга:${NC}"
        
        read -r -p "Использовать Fast Transition 802.11r? [Y/n]: " FT_CH
        [ "$FT_CH" = "n" ] || [ "$FT_CH" = "N" ] && ENABLE_FT=0 || ENABLE_FT=1
        
        read -r -p "Использовать Neighbor Reports 802.11k? [Y/n]: " K_CH
        [ "$K_CH" = "n" ] || [ "$K_CH" = "N" ] && ENABLE_K=0 || ENABLE_K=1
        
        read -r -p "Использовать BSS Transition 802.11v? [Y/n]: " V_CH
        [ "$V_CH" = "n" ] || [ "$V_CH" = "N" ] && ENABLE_V=0 || ENABLE_V=1
        
        read -r -p "Mobility Domain (4 hex) [a1b2]: " MOBILITY_DOMAIN
        MOBILITY_DOMAIN=${MOBILITY_DOMAIN:-a1b2}
    fi
    
    # Для R2/Mesh запрашиваем IP основного роутера
    if [ "$ROUTER_TYPE" = "R2" ] || [ "$ROUTER_TYPE" = "MESH" ]; then
        read -r -p "Введите IP основного роутера [192.168.1.1]: " R1_IP
        R1_IP=${R1_IP:-192.168.1.1}
    fi
    
    # Установка wpad если нужен
    [ "$NEED_WPAD" = "1" ] && install_wpad
    
    # Применяем настройки WiFi
    apply_wifi_settings
}

apply_wifi_settings() {
    echo ""
    echo -e "${YELLOW}[*] Применение настроек WiFi...${NC}"
    
    COUNTRY="${COUNTRY:-RU}"
    
    # Настройка 2.4GHz
    if [ -n "$IFACE_24" ]; then
        echo -e "${YELLOW}[*] Настройка 2.4GHz ($IFACE_24)...${NC}"
        
        uci set wireless.radio0.country="$COUNTRY"
        uci set wireless.radio0.disabled='0'
        [ -n "$CHANNEL_24" ] && uci set wireless.radio0.channel="$CHANNEL_24"
        
        uci set wireless.${IFACE_24}.ssid="$SSID"
        uci set wireless.${IFACE_24}.encryption="$ENCRYPTION"
        [ -n "$PASSWORD" ] && uci set wireless.${IFACE_24}.key="$PASSWORD"
        uci set wireless.${IFACE_24}.wmm='1'
        uci set wireless.${IFACE_24}.network='lan'
        
        apply_roaming_settings "$IFACE_24" "2.4GHz"
    fi
    
    # Настройка 5GHz
    if [ -n "$IFACE_5" ]; then
        echo -e "${YELLOW}[*] Настройка 5GHz ($IFACE_5)...${NC}"
        
        uci set wireless.radio1.country="$COUNTRY"
        uci set wireless.radio1.disabled='0'
        [ -n "$CHANNEL_5" ] && uci set wireless.radio1.channel="$CHANNEL_5"
        
        uci set wireless.${IFACE_5}.ssid="$SSID"
        uci set wireless.${IFACE_5}.encryption="$ENCRYPTION"
        [ -n "$PASSWORD" ] && uci set wireless.${IFACE_5}.key="$PASSWORD"
        uci set wireless.${IFACE_5}.wmm='1'
        uci set wireless.${IFACE_5}.network='lan'
        
        apply_roaming_settings "$IFACE_5" "5GHz"
    fi
    
    # Настройка 6GHz (если есть)
    if [ -n "$IFACE_6" ]; then
        echo -e "${YELLOW}[*] Настройка 6GHz ($IFACE_6)...${NC}"
        
        uci set wireless.radio2.country="$COUNTRY"
        uci set wireless.radio2.disabled='0'
        
        uci set wireless.${IFACE_6}.ssid="$SSID"
        uci set wireless.${IFACE_6}.encryption="$ENCRYPTION"
        [ -n "$PASSWORD" ] && uci set wireless.${IFACE_6}.key="$PASSWORD"
        uci set wireless.${IFACE_6}.wmm='1'
        uci set wireless.${IFACE_6}.network='lan'
        
        apply_roaming_settings "$IFACE_6" "6GHz"
    fi
    
    uci commit wireless
    echo -e "${GREEN}[✓] WiFi настройки применены${NC}"
}

apply_roaming_settings() {
    local iface="$1"
    local band="$2"
    
    if [ "$ROAMING" = "1" ]; then
        echo -e "${BLUE}  [+] Настройка роуминга для $band...${NC}"
        
        # Удаляем старые настройки
        for opt in ieee80211r ieee80211k ieee80211v mobility_domain ft_over_ds \
                  ft_psk_generate_local nasid rrm_neighbor_report rrm_beacon_report \
                  bss_transition disassoc_low_ack time_advertisement wnm_sleep_mode \
                  mbo_cell_capa ft_associated ft_encryption; do
            uci -q delete wireless.${iface}.${opt} 2>/dev/null || true
        done
        
        # Fast Transition 802.11r
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
        
        # Neighbor Reports 802.11k
        [ "$ENABLE_K" = "1" ] && {
            uci set wireless.${iface}.ieee80211k='1'
            uci set wireless.${iface}.rrm_neighbor_report='1'
            uci set wireless.${iface}.rrm_beacon_report='1'
        }
        
        # BSS Transition 802.11v
        [ "$ENABLE_V" = "1" ] && {
            uci set wireless.${iface}.ieee80211v='1'
            uci set wireless.${iface}.bss_transition='1'
            uci set wireless.${iface}.disassoc_low_ack='1'
            uci set wireless.${iface}.time_advertisement='2'
        }
        
        # Общие настройки роуминга
        uci set wireless.${iface}.nasid="${SSID}_${band}"
        uci set wireless.${iface}.wnm_sleep_mode='1'
        uci set wireless.${iface}.mbo_cell_capa='1'
    else
        # Удаляем все настройки роуминга
        for opt in ieee80211r ieee80211k ieee80211v mobility_domain ft_over_ds \
                  ft_psk_generate_local nasid rrm_neighbor_report rrm_beacon_report \
                  bss_transition disassoc_low_ack time_advertisement wnm_sleep_mode \
                  mbo_cell_capa ft_associated ft_encryption; do
            uci -q delete wireless.${iface}.${opt} 2>/dev/null || true
        done
    fi
}

# ====================== НАСТРОЙКА ТОЧКИ ДОСТУПА ======================

configure_access_point() {
    echo ""
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║            НАСТРОЙКА ТОЧКИ ДОСТУПА                       ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Запрос IP адреса
    local default_ip="172.16.0.10"
    [ "$ROUTER_TYPE" = "R2" ] && [ -n "$R1_IP" ] && default_ip=$(echo "$R1_IP" | sed 's/\.[0-9]*$/.10/')
    
    read -r -p "Введите IP для этой точки доступа [$default_ip]: " input_ip
    AP_IP=${input_ip:-$default_ip}
    
    # Определение подсети
    local default_mask="255.255.255.0"
    read -r -p "Введите маску подсети [$default_mask]: " input_mask
    AP_NETMASK=${input_mask:-$default_mask}
    
    # Определение шлюза
    local default_gw="172.16.0.1"
    [ "$ROUTER_TYPE" = "R2" ] && [ -n "$R1_IP" ] && default_gw="$R1_IP"
    read -r -p "Введите IP шлюза [$default_gw]: " input_gw
    GATEWAY_IP=${input_gw:-$default_gw}
    
    # Настройка DNS
    echo ""
    echo -e "${YELLOW}Настройка DNS:${NC}"
    echo "  1) Использовать шлюз ($GATEWAY_IP)"
    echo "  2) Google DNS (8.8.8.8, 8.8.4.4)"
    echo "  3) Cloudflare DNS (1.1.1.1, 1.0.0.1)"
    echo "  4) Quad9 DNS (9.9.9.9)"
    echo "  5) Свой вариант"
    read -r -p "Выберите DNS [1-5]: " DNS_CHOICE
    
    case "$DNS_CHOICE" in
        1) DNS_SERVERS="$GATEWAY_IP" ;;
        2) DNS_SERVERS="8.8.8.8 8.8.4.4" ;;
        3) DNS_SERVERS="1.1.1.1 1.0.0.1" ;;
        4) DNS_SERVERS="9.9.9.9 149.112.112.112" ;;
        5) read -r -p "Введите DNS серверы через пробел: " DNS_SERVERS ;;
        *) DNS_SERVERS="$GATEWAY_IP" ;;
    esac
    
    # Настройка IPv6
    echo ""
    echo -e "${YELLOW}Настройка IPv6:${NC}"
    echo "  1) Включить IPv6 relay"
    echo "  2) Включить IPv6 SLAAC"
    echo "  3) Отключить IPv6"
    read -r -p "Выберите режим [1-3]: " IPV6_CHOICE
    
    # Применяем настройки точки доступа
    apply_ap_settings
}

apply_ap_settings() {
    echo ""
    echo -e "${YELLOW}[*] Настройка точки доступа...${NC}"
    
    # Отключаем сервисы
    echo -e "${YELLOW}[*] Отключение сервисов...${NC}"
    
    # DHCP сервер
    uci set dhcp.lan.ignore='1'
    /etc/init.d/dnsmasq stop 2>/dev/null || true
    /etc/init.d/dnsmasq disable 2>/dev/null || true
    
    # Firewall
    /etc/init.d/firewall stop 2>/dev/null || true
    /etc/init.d/firewall disable 2>/dev/null || true
    
    # odhcpd
    if [ -f /etc/init.d/odhcpd ]; then
        /etc/init.d/odhcpd stop 2>/dev/null || true
        /etc/init.d/odhcpd disable 2>/dev/null || true
    fi
    
    # Удаляем WAN интерфейсы
    echo -e "${YELLOW}[*] Удаление WAN интерфейсов...${NC}"
    for wan in wan wan6; do
        uci delete network.$wan 2>/dev/null || true
    done
    
    # Настройка бриджа
    echo -e "${YELLOW}[*] Настройка бриджа LAN...${NC}"
    
    # Определяем порты для бриджа
    BRIDGE_PORTS=""
    for port in $PHYS_PORTS; do
        # Исключаем CPU порты
        if echo "$port" | grep -qE '^(eth0|cpu)'; then
            continue
        fi
        BRIDGE_PORTS="$BRIDGE_PORTS $port"
    done
    
    # Если портов нет, используем все физические порты
    [ -z "$BRIDGE_PORTS" ] && BRIDGE_PORTS="$PHYS_PORTS"
    BRIDGE_PORTS=$(echo "$BRIDGE_PORTS" | sed 's/^ *//;s/ *$//')
    
    echo -e "${YELLOW}[*] Порты бриджа: ${CYAN}$BRIDGE_PORTS${NC}"
    
    # Настройка device секции
    # Удаляем старые device секции
    while uci get network.@device[0] >/dev/null 2>&1; do
        uci delete network.@device[0] 2>/dev/null || true
    done
    
    # Создаем новую device секцию
    uci add network device >/dev/null
    uci set network.@device[-1].type='bridge'
    uci set network.@device[-1].name='br-lan'
    
    for port in $BRIDGE_PORTS; do
        uci add_list network.@device[-1].ports="$port"
    done
    
    # Настройка LAN интерфейса
    uci set network.lan.device='br-lan'
    uci set network.lan.proto='static'
    uci set network.lan.ipaddr="$AP_IP"
    uci set network.lan.netmask="$AP_NETMASK"
    uci set network.lan.gateway="$GATEWAY_IP"
    
    # DNS серверы
    uci delete network.lan.dns 2>/dev/null || true
    for dns in $DNS_SERVERS; do
        uci add_list network.lan.dns="$dns"
    done
    
    # Настройка IPv6
    case "$IPV6_CHOICE" in
        1)
            uci set network.lan.ip6assign='64'
            uci set network.lan.delegate='1'
            uci set dhcp.lan.ra='relay'
            uci set dhcp.lan.dhcpv6='relay'
            uci set dhcp.lan.ndp='relay'
            ;;
        2)
            uci set network.lan.ip6assign='64'
            uci set network.lan.delegate='1'
            uci set dhcp.lan.ra='server'
            uci set dhcp.lan.dhcpv6='disabled'
            ;;
        3)
            uci delete network.lan.ip6assign 2>/dev/null || true
            uci delete network.lan.delegate 2>/dev/null || true
            uci set dhcp.lan.ra='disabled'
            uci set dhcp.lan.dhcpv6='disabled'
            ;;
    esac
    
    # Сохраняем
    uci commit network
    uci commit dhcp
    
    echo -e "${GREEN}[✓] Настройки точки доступа применены${NC}"
}

# ====================== ПРИМЕНЕНИЕ И ПЕРЕЗАПУСК ======================

apply_all() {
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  Проверьте настройки перед применением${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Режим WiFi:        ${CYAN}$ROUTER_TYPE${NC}"
    echo -e "SSID:              ${CYAN}$SSID${NC}"
    echo -e "Шифрование:        ${CYAN}$ENCRYPTION${NC}"
    [ -n "$PASSWORD" ] && echo -e "Пароль:            ${CYAN}$PASSWORD${NC}"
    [ "$ROAMING" = "1" ] && echo -e "Роуминг:           ${CYAN}FT=$ENABLE_FT K=$ENABLE_K V=$ENABLE_V${NC}"
    [ "$AP_MODE" = "1" ] && {
        echo -e "IP точки доступа:  ${CYAN}$AP_IP${NC}"
        echo -e "Шлюз:              ${CYAN}$GATEWAY_IP${NC}"
        echo -e "DNS:               ${CYAN}$DNS_SERVERS${NC}"
    }
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -r -p "Применить настройки? [Y/n]: " CONFIRM
    [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ] && {
        echo -e "${YELLOW}[!] Настройки отменены${NC}"
        exit 0
    }
    
    # Применяем WiFi
    echo ""
    echo -e "${YELLOW}[*] Применение WiFi...${NC}"
    wifi reload 2>/dev/null || wifi up 2>/dev/null
    sleep 2
    
    # Применяем сеть если нужно
    if [ "$AP_MODE" = "1" ]; then
        echo -e "${YELLOW}[*] Перезапуск сети...${NC}"
        echo -e "${YELLOW}[!] ВНИМАНИЕ: Новый IP адрес: $AP_IP${NC}"
        echo -e "${YELLOW}[!] Соединение может прерваться!${NC}"
        /etc/init.d/network restart 2>/dev/null || {
            echo -e "${YELLOW}[!] Пробуем ifup...${NC}"
            ifup br-lan 2>/dev/null || ifup lan 2>/dev/null || true
        }
    fi
    
    # Показываем результат
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            НАСТРОЙКА ЗАВЕРШЕНА                           ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║ WiFi SSID:       $SSID${NC}"
    echo -e "${GREEN}║ Шифрование:      $ENCRYPTION${NC}"
    [ "$ROAMING" = "1" ] && echo -e "${GREEN}║ Роуминг:         ВКЛЮЧЕН${NC}"
    if [ "$AP_MODE" = "1" ]; then
        echo -e "${GREEN}║ IP адрес:        $AP_IP${NC}"
        echo -e "${GREEN}║ Режим:           ТОЧКА ДОСТУПА${NC}"
    fi
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║ Резервная копия: $BACKUP_DIR${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Статус WiFi
    echo -e "${YELLOW}[*] Статус WiFi:${NC}"
    iwinfo 2>/dev/null | grep -E "ESSID|Channel|Mode|Encryption" | head -8 || {
        iw dev 2>/dev/null | grep -E "ssid|channel|type" | head -8 || echo "Используйте: iw dev"
    }
    echo ""
    
    # Статус сети если AP
    if [ "$AP_MODE" = "1" ]; then
        echo -e "${YELLOW}[*] Сетевые интерфейсы:${NC}"
        ip -4 addr show br-lan 2>/dev/null || ip -4 addr show lan 2>/dev/null || ip a | grep -E "inet |br-|eth|lan"
        echo ""
    fi
    
    echo -e "${GREEN}[✓] Готово!${NC}"
}

# ====================== ОТМЕНА ИЗМЕНЕНИЙ ======================

restore_backup() {
    echo ""
    echo -e "${YELLOW}[*] Восстановление из резервной копии...${NC}"
    
    if [ -d "$BACKUP_DIR" ]; then
        for config in wireless network dhcp firewall; do
            [ -f "$BACKUP_DIR/$config" ] && cp "$BACKUP_DIR/$config" "/etc/config/$config" 2>/dev/null && \
                echo -e "${GREEN}[✓] Восстановлен $config${NC}"
        done
        
        wifi reload 2>/dev/null || true
        /etc/init.d/network restart 2>/dev/null || true
        
        echo -e "${GREEN}[✓] Конфигурация восстановлена${NC}"
    else
        echo -e "${RED}[!] Резервная копия не найдена${NC}"
    fi
}

# ====================== ГЛАВНОЕ МЕНЮ ======================

show_main_menu() {
    while true; do
        clear
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║     Universal OpenWrt WiFi + AP Setup v$SCRIPT_VERSION           ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║ 1) Настроить WiFi + Точку доступа (полная настройка)    ║${NC}"
        echo -e "${BLUE}║ 2) Только настроить WiFi (роуминг, смена имени/пароля)  ║${NC}"
        echo -e "${BLUE}║ 3) Только превратить в точку доступа (без WiFi)         ║${NC}"
        echo -e "${BLUE}║ 4) Показать текущую конфигурацию                        ║${NC}"
        echo -e "${BLUE}║ 5) Восстановить из резервной копии                       ║${NC}"
        echo -e "${BLUE}║ 6) Системная информация                                 ║${NC}"
        echo -e "${BLUE}║ 7) Выход                                                ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        
        # Показываем текущий статус
        [ -n "$CURRENT_IP" ] && echo -e "${YELLOW}Текущий IP: ${CYAN}$CURRENT_IP${NC}"
        [ -n "$PHYS_PORTS" ] && echo -e "${YELLOW}Порты: ${CYAN}$PHYS_PORTS${NC}"
        echo -e "${YELLOW}Пакетный менеджер: ${CYAN}$PKG_MGR${NC}"
        echo ""
        
        read -r -p "Выберите пункт [1-7]: " MENU_CHOICE
        
        case "$MENU_CHOICE" in
            1)
                # Полная настройка WiFi + AP
                configure_wifi
                AP_MODE=1
                configure_access_point
                apply_all
                pause
                ;;
            2)
                # Только WiFi
                configure_wifi
                AP_MODE=0
                apply_all
                pause
                ;;
            3)
                # Только точка доступа
                ROUTER_TYPE="AP"
                ROAMING=0
                AP_MODE=1
                configure_access_point
                apply_all
                pause
                ;;
            4)
                # Показать конфигурацию
                echo ""
                echo -e "${CYAN}=== /etc/config/wireless ===${NC}"
                cat /etc/config/wireless 2>/dev/null || echo "Файл не найден"
                echo ""
                echo -e "${CYAN}=== /etc/config/network ===${NC}"
                cat /etc/config/network 2>/dev/null || echo "Файл не найден"
                echo ""
                echo -e "${CYAN}=== /etc/config/dhcp ===${NC}"
                grep -E "(ignore|ra|dhcpv6)" /etc/config/dhcp 2>/dev/null || echo "Нет данных"
                pause
                ;;
            5)
                restore_backup
                pause
                ;;
            6)
                # Системная информация
                echo ""
                echo -e "${CYAN}=== Система ===${NC}"
                echo "OpenWrt: $OWRT_VERSION"
                echo "Архитектура: $OWRT_ARCH"
                echo "Target: $OWRT_TARGET"
                echo ""
                echo -e "${CYAN}=== Сеть ===${NC}"
                ip -4 addr show 2>/dev/null | grep -E "inet |br-|eth|lan|wan" | head -10
                echo ""
                echo -e "${CYAN}=== WiFi ===${NC}"
                iwinfo 2>/dev/null | grep -E "ESSID|Channel|Mode" | head -8 || echo "Нет данных"
                echo ""
                echo -e "${CYAN}=== Пакеты ===${NC}"
                $PKG_LIST | grep -E "wpad|hostapd|dnsmasq|firewall" 2>/dev/null || echo "Нет данных"
                pause
                ;;
            7)
                echo ""
                echo -e "${GREEN}До свидания!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Неверный выбор!${NC}"
                sleep 1
                ;;
        esac
    done
}

# ====================== ЗАПУСК ======================

# Проверки
check_root

# Определение системы
detect_system

# Определение интерфейсов
detect_network_interfaces
detect_wifi_interfaces

# Создание резервной копии
backup_configs

# Показать меню
show_main_menu
