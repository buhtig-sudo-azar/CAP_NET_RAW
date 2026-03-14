#!/bin/bash
# =====================================================================
# MODULE: 06_tor.sh - Tor onion service with system Tor handling
# Author: Charlie
# Version: 7.0 - User-provided bridges (March 2026)
# =====================================================================
# IMPORTANT: If bridges stop working, get fresh ones from:
# - https://bridges.torproject.org/
# - Telegram: @gettor_bot
# - Email: bridges@torproject.org
# =====================================================================

# --------------------------------------------------------------
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# --------------------------------------------------------------
# ВСЁ в RAM — никакого мусора на диске
TOR_BASE_DIR="/dev/shm/tor_module"
TOR_DATA_DIR="$TOR_BASE_DIR/data"
TOR_CONFIG_FILE="$TOR_BASE_DIR/torrc"
TOR_ONION_DIR="$TOR_BASE_DIR/onion"
BRIDGES_CACHE_FILE="$TOR_BASE_DIR/bridges.json"

# API Tor для получения мостов (на случай если захотим автоматику)
BRIDGE_API="https://bridges.torproject.org/moat/circumvention/settings"
COUNTRY="ru"

# Флаги для отслеживания состояния
SYSTEM_TOR_WAS_RUNNING=0
SYSTEM_TOR_STOPPED_BY_US=0
OUR_TOR_PID=""

# --------------------------------------------------------------
# МОСТЫ (АКТУАЛЬНЫЕ НА МАРТ 2026)
# --------------------------------------------------------------
# Предоставлены пользователем
# --------------------------------------------------------------
BRIDGES_USER_PROVIDED=(
    # obfs4 bridges
    "Bridge obfs4 51.38.220.35:42954 B84BDFE3724928B06FC178FF50D5852E5AB7942A cert=6tpTDdnOaRl2elQqdxSmrJ5Gt9JkWcbquznpxx/lqVjRKv/bVecFnXie96KoblCWfvVjYA iat-mode=0"
    "Bridge obfs4 57.129.117.251:61919 85F9547D13078145C9D894AFB981BA6E4B880B61 cert=TZc+BzJg7PNIxRt0uXt3aYVmALDwV3y0UeYAioxrPfjS3Fz9lE5oTOzoX2ShaCxVtuA+UQ iat-mode=0"
    
    # webtunnel bridges (IPv6)
    "Bridge webtunnel [2001:db8:d0f2:6cd4:8630:8185:18d2:a5c]:443 5A94C0CDB0ED58681BDAA8FDBC53F5C9E32058F8 url=https://beefstrognoff.com/xRiEjTMRdkc9l7vrlASBmOus ver=0.0.2"
    "Bridge webtunnel [2001:db8:43cc:d277:5ba1:dcd1:516e:d983]:443 AD62C15FAC9C8695F41F4BB5D1F16373F906177F url=https://mitch.pmvl.eu/r9mZqSFwOHSQATtQoPWwZQk9 ver=0.0.1"
)

# --------------------------------------------------------------
# ФУНКЦИЯ: Проверка зависимостей
# --------------------------------------------------------------
check_deps() {
    local deps=("tor" "curl" "sed" "grep" "jq" "systemctl" "pgrep" "pkill")
    local missing=()
    
    echo "[*] Checking dependencies..."
    
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "[!] Missing dependencies: ${missing[*]}"
        echo "[*] Install with: sudo apt install ${missing[*]}"
        return 1
    fi
    
    echo "[✓] All dependencies satisfied"
    return 0
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Проверка статуса системного Tor
# --------------------------------------------------------------
check_system_tor() {
    echo "[*] Checking system Tor status..."
    
    if systemctl is-active --quiet tor 2>/dev/null; then
        SYSTEM_TOR_WAS_RUNNING=1
        local tor_pid=$(pgrep -f '^/usr/bin/tor' | head -1)
        echo "[✓] System Tor is running (PID: ${tor_pid:-unknown})"
        return 0
    else
        echo "[!] System Tor is not running"
        SYSTEM_TOR_WAS_RUNNING=0
        return 1
    fi
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Остановка системного Tor
# --------------------------------------------------------------
stop_system_tor() {
    if [ $SYSTEM_TOR_WAS_RUNNING -eq 1 ] && [ $SYSTEM_TOR_STOPPED_BY_US -eq 0 ]; then
        echo "[*] Stopping system Tor for our experiment..."
        
        # Останавливаем через systemctl
        sudo systemctl stop tor
        
        # Даем время на остановку
        sleep 2
        
        # Проверяем, что остановился
        if systemctl is-active --quiet tor 2>/dev/null; then
            echo "[!] Failed to stop system Tor via systemctl, trying force kill..."
            sudo pkill -f '^/usr/bin/tor'
            sleep 1
        fi
        
        # Финальная проверка
        if pgrep -f '^/usr/bin/tor' >/dev/null; then
            echo "[!] System Tor still running! Continuing anyway..."
        else
            SYSTEM_TOR_STOPPED_BY_US=1
            echo "[✓] System Tor stopped"
        fi
    else
        echo "[*] System Tor not running or already stopped by us"
    fi
    return 0
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Подготовка директорий в RAM
# --------------------------------------------------------------
prepare_dirs() {
    echo "[*] Preparing directories in RAM..."
    mkdir -p "$TOR_DATA_DIR"
    mkdir -p "$TOR_ONION_DIR"
    
    # Tor требует права 700 на onion-директорию
    chmod 700 "$TOR_ONION_DIR"
    echo "[*] Set permissions 700 on $TOR_ONION_DIR"
    
    if [ -d "$TOR_BASE_DIR" ] && [ -d "$TOR_DATA_DIR" ] && [ -d "$TOR_ONION_DIR" ]; then
        echo "[✓] Directories created: $TOR_BASE_DIR"
        return 0
    else
        echo "[!] Failed to create directories"
        return 1
    fi
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Выбор типа мостов
# --------------------------------------------------------------
select_bridge_type() {
    echo ""
    echo "[?] Select bridge type:"
    echo "    1) obfs4 (stable, recommended)"
    echo "    2) webtunnel (HTTPS masquerade, IPv6)"
    echo "    3) both (use all available bridges)"
    read -r bridge_choice
    
    # Очищаем массив
    BRIDGES=()
    
    case "$bridge_choice" in
        1)
            echo "[*] Using obfs4 bridges only"
            for bridge in "${BRIDGES_USER_PROVIDED[@]}"; do
                if [[ "$bridge" == *"obfs4"* ]]; then
                    BRIDGES+=("$bridge")
                fi
            done
            ;;
        2)
            echo "[*] Using webtunnel bridges only"
            for bridge in "${BRIDGES_USER_PROVIDED[@]}"; do
                if [[ "$bridge" == *"webtunnel"* ]]; then
                    BRIDGES+=("$bridge")
                fi
            done
            ;;
        3)
            echo "[*] Using all bridges (obfs4 + webtunnel)"
            BRIDGES=("${BRIDGES_USER_PROVIDED[@]}")
            ;;
        *)
            echo "[!] Invalid choice, using obfs4 only"
            for bridge in "${BRIDGES_USER_PROVIDED[@]}"; do
                if [[ "$bridge" == *"obfs4"* ]]; then
                    BRIDGES+=("$bridge")
                fi
            done
            ;;
    esac
    
    echo "[✓] Selected ${#BRIDGES[@]} bridges"
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Генерация конфига Tor
# --------------------------------------------------------------
generate_config() {
    local use_bridges=${1:-"no"}
    
    echo "[*] Generating Tor config..."
    
    # Базовый конфиг
    cat > "$TOR_CONFIG_FILE" <<-EOF
# Tor config generated by hack_kit module 06
SOCKSPort 9050
SOCKSPolicy accept 127.0.0.1
DataDirectory $TOR_DATA_DIR
SafeLogging 1
Log notice file $TOR_BASE_DIR/notice.log
Log warn file $TOR_BASE_DIR/warn.log

# Onion service configuration
HiddenServiceDir $TOR_ONION_DIR
HiddenServicePort 80 127.0.0.1:8000
EOF

    # Если нужны мосты — добавляем
    if [ "$use_bridges" = "yes" ]; then
        echo "UseBridges 1" >> "$TOR_CONFIG_FILE"
        echo "ClientTransportPlugin obfs4 exec /usr/bin/obfs4proxy" >> "$TOR_CONFIG_FILE"
        echo "ClientTransportPlugin webtunnel exec /usr/bin/webtunnel" >> "$TOR_CONFIG_FILE"
        
        for bridge in "${BRIDGES[@]}"; do
            echo "$bridge" >> "$TOR_CONFIG_FILE"
        done
        echo "[+] Added ${#BRIDGES[@]} bridges to config"
    fi
    
    # Проверяем конфиг
    if tor --verify-config -f "$TOR_CONFIG_FILE" &>/dev/null; then
        echo "[✓] Config is valid"
        return 0
    else
        echo "[!] Config validation failed"
        tor --verify-config -f "$TOR_CONFIG_FILE"
        return 1
    fi
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Запуск нашего Tor
# --------------------------------------------------------------
start_our_tor() {
    echo "[*] Starting our Tor process..."
    
    # Убиваем старый процесс нашего Tor, если висит
    pkill -f "tor -f $TOR_CONFIG_FILE" 2>/dev/null || true
    
    # Запускаем новый
    tor -f "$TOR_CONFIG_FILE" --quiet &
    OUR_TOR_PID=$!
    
    echo "[*] Our Tor started with PID: $OUR_TOR_PID"
    
    # Ждём генерации onion-адреса (до 30 секунд)
    local wait_time=0
    echo "[*] Waiting for onion address generation..."
    while [ ! -f "$TOR_ONION_DIR/hostname" ] && [ $wait_time -lt 30 ]; do
        sleep 1
        echo -n "."
        wait_time=$((wait_time + 1))
    done
    echo ""
    
    if [ -f "$TOR_ONION_DIR/hostname" ]; then
        local onion_addr=$(cat "$TOR_ONION_DIR/hostname")
        echo "[+] =========================================="
        echo "[✅] ONION ADDRESS: $onion_addr"
        echo "[+] =========================================="
        return 0
    else
        echo "[!] Onion address not generated within 30 seconds"
        return 1
    fi
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Проверка соединения через наш Tor
# --------------------------------------------------------------
test_connection() {
    echo "[*] Giving Tor 30 seconds to bootstrap..."
    sleep 30
    
    echo "[*] Testing our Tor connection..."
    
    local result
    result=$(curl --socks5-hostname localhost:9050 \
            --max-time 10 \
            --silent \
            https://check.torproject.org/api/ip)
    
    if echo "$result" | grep -q '"IsTor": true'; then
        local ip=$(echo "$result" | jq -r '.IP')
        echo "[✓] Our Tor connection working (IP: $ip)"
        return 0
    else
        echo "[!] Our Tor connection failed"
        echo "[*] Last 20 lines of Tor log:"
        tail -20 "$TOR_BASE_DIR/notice.log" 2>/dev/null || echo "No log file"
        return 1
    fi
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Восстановление системного Tor (ВЫЗЫВАЕТСЯ ПРИ ВЫХОДЕ)
# --------------------------------------------------------------
restore_system_tor() {
    echo ""
    echo "[*] Restoring system Tor..."
    
    # Убиваем наш процесс Tor
    if [ -n "$OUR_TOR_PID" ] && kill -0 "$OUR_TOR_PID" 2>/dev/null; then
        echo "[*] Killing our Tor (PID: $OUR_TOR_PID)"
        kill "$OUR_TOR_PID" 2>/dev/null
        sleep 2
        
        # Если не умер — добиваем
        if kill -0 "$OUR_TOR_PID" 2>/dev/null; then
            echo "[!] Our Tor still running, forcing kill..."
            kill -9 "$OUR_TOR_PID" 2>/dev/null
        fi
    fi
    
    # Если мы останавливали системный Tor — запускаем обратно
    if [ $SYSTEM_TOR_STOPPED_BY_US -eq 1 ]; then
        echo "[*] Restarting system Tor..."
        sudo systemctl start tor
        
        # Проверяем, что запустился
        sleep 2
        if systemctl is-active --quiet tor 2>/dev/null; then
            echo "[✓] System Tor restored"
        else
            echo "[!] Failed to restore system Tor via systemctl, trying direct..."
            sudo tor --quiet &
        fi
    else
        echo "[*] System Tor was not touched, nothing to restore"
    fi
    
    # Чистим RAM
    if [ -d "$TOR_BASE_DIR" ]; then
        echo "[*] Cleaning up $TOR_BASE_DIR"
        rm -rf "$TOR_BASE_DIR"
    fi
    
    echo "[✓] Cleanup complete"
}

# --------------------------------------------------------------
# ФУНКЦИЯ: Проверка транспортов
# --------------------------------------------------------------
check_transports() {
    echo "[*] Checking pluggable transports..."
    
    # Проверяем obfs4proxy
    if ! command -v obfs4proxy &>/dev/null; then
        echo "[!] obfs4proxy not found, installing..."
        sudo apt update && sudo apt install -y obfs4proxy
    fi
    
    # Проверяем webtunnel (если есть в репах)
    if ! command -v webtunnel &>/dev/null; then
        echo "[!] webtunnel not found, trying to install..."
        sudo apt update && sudo apt install -y webtunnel 2>/dev/null || echo "[*] webtunnel not in repos, will use tor's built-in"
    fi
    
    echo "[✓] Transports checked"
}

# --------------------------------------------------------------
# ОСНОВНАЯ ФУНКЦИЯ
# --------------------------------------------------------------
run() {
    echo "========================================="
    echo "MODULE 06: Tor Onion Service"
    echo "========================================="
    
    # Перехватываем сигналы для гарантированной очистки
    trap restore_system_tor EXIT INT TERM HUP
    
    # Шаг 1: Проверяем зависимости
    check_deps || exit 1
    
    # Шаг 2: Проверяем транспорты
    check_transports
    
    # Шаг 3: Проверяем статус системного Tor (только для информации)
    check_system_tor
    
    # Шаг 4: Создаём директории в RAM
    prepare_dirs || exit 1
    
    # Шаг 5: Выбираем тип мостов
    select_bridge_type
    
    # Шаг 6: Останавливаем системный Tor (ЕСЛИ ОН БЫЛ ЗАПУЩЕН)
    if [ $SYSTEM_TOR_WAS_RUNNING -eq 1 ]; then
        stop_system_tor || exit 1
    fi
    
    # Шаг 7: Генерируем конфиг
    generate_config "yes" || exit 1
    
    # Шаг 8: Запускаем наш Tor
    start_our_tor || exit 1
    
    # Шаг 9: Проверяем соединение
    echo ""
    test_connection
    
    echo ""
    echo "[✓] Module 06 completed successfully"
    echo "[*] Our Tor is running (PID: $OUR_TOR_PID)"
    echo "[*] Onion service in RAM: $TOR_ONION_DIR"
    echo "[*] Press Ctrl+C to stop experiment and restore system Tor"
    echo "========================================="
    
    # Бесконечное ожидание (скрипт висит, Tor работает)
    while true; do
        sleep 5
    done
}

# Запуск
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run
fi