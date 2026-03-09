#!/bin/bash
# modules/04_ssh_tunnel.sh — SSH-туннель как SOCKS-прокси

run() {
    # ------------------------------------------------------------
    # 1. ИНИЦИАЛИЗАЦИЯ
    # ------------------------------------------------------------
    if [ -z "$HACK_KIT_ROOT" ]; then
        export HACK_KIT_ROOT="$HOME/TOR/hack_kit"
    fi

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    echo -e "${YELLOW}[*] Запуск модуля SSH-туннель (SOCKS-прокси)${NC}"
    echo ""

    # Проверка Podman
    if ! command -v podman &> /dev/null; then
        echo -e "${RED}[✗] Podman не установлен!${NC}"
        return 1
    fi

    # ------------------------------------------------------------
    # 2. НАСТРОЙКИ
    # ------------------------------------------------------------
    local SSH_PORT="2222"
    local SOCKS_PORT="1080"
    
    read -p "Порт SSH-сервера [${SSH_PORT}]: " input_port
    SSH_PORT=${input_port:-$SSH_PORT}
    
    read -p "Порт SOCKS-прокси на локальной машине [${SOCKS_PORT}]: " input_socks
    SOCKS_PORT=${input_socks:-$SOCKS_PORT}

    # ------------------------------------------------------------
    # 3. ПРОВЕРКА ПОРТОВ
    # ------------------------------------------------------------
    echo -e "${YELLOW}[*] Проверяем порты...${NC}"
    
    if ss -tln | grep -q ":$SSH_PORT "; then
        echo -e "${RED}[✗] Порт $SSH_PORT уже занят${NC}"
        return 1
    fi
    
    if ss -tln | grep -q ":$SOCKS_PORT "; then
        echo -e "${RED}[✗] Порт $SOCKS_PORT уже занят${NC}"
        return 1
    fi
    
    echo -e "${GREEN}[✓] Порты свободны${NC}"

    # ------------------------------------------------------------
    # 4. РАБОТА В RAM
    # ------------------------------------------------------------
    local TEMP_DIR="/dev/shm/ssh-$$"
    mkdir -p "$TEMP_DIR"
    echo -e "${YELLOW}[*] Работаем в RAM: $TEMP_DIR${NC}"

    # ------------------------------------------------------------
    # 5. СОЗДАЁМ SSH-КЛЮЧИ ДЛЯ ТУННЕЛЯ
    # ------------------------------------------------------------
    echo -e "${YELLOW}[*] Генерируем SSH-ключи...${NC}"
    ssh-keygen -t rsa -b 4096 -f "$TEMP_DIR/id_rsa" -N "" -C "tunnel@hack_kit" >/dev/null 2>&1
    
    if [ ! -f "$TEMP_DIR/id_rsa.pub" ]; then
        echo -e "${RED}[✗] Ошибка генерации ключей${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    echo -e "${GREEN}[✓] Ключи готовы${NC}"

    # ------------------------------------------------------------
    # 6. ЗАПУСК SSH-СЕРВЕРА В КОНТЕЙНЕРЕ
    # ------------------------------------------------------------
    local CONTAINER_NAME="ssh-server-$$"
    local IMAGE="docker.io/linuxserver/openssh-server:latest"
    
    echo -e "${YELLOW}[*] Запускаем SSH-сервер в контейнере...${NC}"
    
    # Создаём временный authorized_keys
    mkdir -p "$TEMP_DIR/ssh"
    cp "$TEMP_DIR/id_rsa.pub" "$TEMP_DIR/ssh/authorized_keys"
    
    # Запускаем контейнер
   podman run -d --name "$CONTAINER_NAME" \
    -p "$SSH_PORT:2222" \
    -e PUID=1000 \
    -e PGID=1000 \
    -e TZ=Europe/Moscow \
    -e PUBLIC_KEY="$(cat $TEMP_DIR/id_rsa.pub)" \
    -e USER_NAME=tunnel \
    -e SUDO_ACCESS=false \
    -e DOCKER_MODS=linuxserver/mods:openssh-server-ssh-tunnel \
    "$IMAGE" > /dev/null

    if [ $? -ne 0 ]; then
        echo -e "${RED}[✗] Ошибка запуска контейнера${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    sleep 3
    echo -e "${GREEN}[✓] Контейнер запущен${NC}"

    # ------------------------------------------------------------
    # 7. НАСТРОЙКА ПРАВ НА КЛЮЧ
    # ------------------------------------------------------------
    chmod 600 "$TEMP_DIR/id_rsa"

    # ------------------------------------------------------------
    # 8. ЗАПУСК SSH-ТУННЕЛЯ (SOCKS-ПРОКСИ)
    # ------------------------------------------------------------
    echo -e "${YELLOW}[*] Запускаем SSH-туннель (SOCKS5 на порту $SOCKS_PORT)...${NC}"
    
    # Запускаем SSH с динамическим прокси
    ssh -4 -f -N -D "$SOCKS_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i "$TEMP_DIR/id_rsa" \
        -p "$SSH_PORT" \
        tunnel@localhost >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}[✗] Ошибка запуска SSH-туннеля${NC}"
        podman stop "$CONTAINER_NAME" >/dev/null 2>&1
        podman rm "$CONTAINER_NAME" >/dev/null 2>&1
        rm -rf "$TEMP_DIR"
        return 1
    fi
    
    echo -e "${GREEN}[✓] SSH-туннель запущен${NC}"
    echo ""

    # ------------------------------------------------------------
    # 9. ПРОВЕРКА РАБОТОСПОСОБНОСТИ
    # ------------------------------------------------------------
    echo -e "${CYAN}🔍 ПРОВЕРКА СОЕДИНЕНИЯ:${NC}"
    
    # Проверяем через SOCKS-прокси
    if curl --socks5 localhost:$SOCKS_PORT --max-time 5 http://ifconfig.me -s > /dev/null; then
        echo -e "${GREEN}[✓] SOCKS-прокси работает! Трафик идёт через SSH-туннель${NC}"
        
        echo ""
        echo -e "${CYAN}📊 ТВОЙ ВНЕШНИЙ IP ЧЕРЕЗ ТУННЕЛЬ:${NC}"
        curl --socks5 localhost:$SOCKS_PORT --max-time 5 http://ifconfig.me -s
        echo ""
    else
        echo -e "${RED}[✗] SOCKS-прокси не отвечает${NC}"
    fi
    echo ""

    # ------------------------------------------------------------
    # 10. ИНФОРМАЦИЯ
    # ------------------------------------------------------------
    echo "══════════════════════════════════════════════════════"
    echo -e "${BLUE}🔌 SSH-ТУННЕЛЬ ЗАПУЩЕН${NC}"
    echo "══════════════════════════════════════════════════════"
    echo "  ▶ SSH-сервер в контейнере: порт $SSH_PORT"
    echo "  ▶ SOCKS-прокси на локальной машине: порт $SOCKS_PORT"
    echo "  ▶ Контейнер: $CONTAINER_NAME"
    echo "  ▶ RAM: $TEMP_DIR"
    echo ""
    echo "  ▶ Примеры использования:"
    echo "     curl --socks5 localhost:$SOCKS_PORT http://ifconfig.me"
    echo "     curl --socks5 localhost:$SOCKS_PORT https://check.torproject.org/api/ip"
    echo "     curl --socks5 localhost:$SOCKS_PORT -k https://localhost:443 (если HTTPS-сервер запущен)"
    echo ""
    echo "  ▶ SSH-команда для отладки:"
    echo "     ssh -i $TEMP_DIR/id_rsa -p $SSH_PORT tunnel@localhost"
    echo ""
    echo "  ▶ Для захвата трафика: запусти 01_sniffer на lo и делай запросы через прокси"
    echo "══════════════════════════════════════════════════════"
    echo ""

    # ------------------------------------------------------------
    # 11. ЛОГИРОВАНИЕ
    # ------------------------------------------------------------
    log_experiment "04_ssh_tunnel" "ssh-туннель" "Запуск SOCKS-прокси через SSH" \
                   "$CONTAINER_NAME" "$IMAGE" "успех" \
                   "SSH-порт $SSH_PORT, SOCKS-порт $SOCKS_PORT" "yes"

    # ------------------------------------------------------------
    # 12. ОЖИДАНИЕ ОСТАНОВКИ
    # ------------------------------------------------------------
    echo -e "${YELLOW}Нажми Enter, чтобы остановить туннель и удалить контейнер...${NC}"
    read

    echo -e "${YELLOW}[*] Останавливаем SSH-туннель и контейнер...${NC}"
    
    # Убиваем процесс SSH-туннеля
    pkill -f "ssh.*-D $SOCKS_PORT" 2>/dev/null
    
    # Останавливаем и удаляем контейнер
    podman stop "$CONTAINER_NAME" >/dev/null 2>&1
    podman rm "$CONTAINER_NAME" >/dev/null 2>&1
    
    # Чистим RAM
    rm -rf "$TEMP_DIR"
    
    echo -e "${GREEN}[✓] Готово${NC}"
}

# Защита от прямого запуска
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run "$@"
fi