#!/bin/bash
# modules/03_https_server.sh — HTTPS сервер с самоподписанным сертификатом (РАБОЧАЯ ВЕРСИЯ)

run() {
    # ------------------------------------------------------------
    # 1. ИНИЦИАЛИЗАЦИЯ
    # ------------------------------------------------------------
    if [ -z "$HACK_KIT_ROOT" ]; then
        export HACK_KIT_ROOT="$HOME/TOR/hack_kit"
    fi

    # Цвета (если не загружены из ядра)
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    echo -e "${YELLOW}[*] Запуск модуля HTTPS сервера${NC}"
    echo ""

    # Проверка Podman
    if ! command -v podman &> /dev/null; then
        echo -e "${RED}[✗] Podman не установлен!${NC}"
        return 1
    fi

    # ------------------------------------------------------------
    # 2. ПОРТ
    # ------------------------------------------------------------
    local HTTPS_PORT="443"
    read -p "Порт для HTTPS [${HTTPS_PORT}]: " input_port
    HTTPS_PORT=${input_port:-$HTTPS_PORT}

    # Проверка свободного порта
    if ss -tln | grep -q ":$HTTPS_PORT "; then
        echo -e "${YELLOW}[!] Порт $HTTPS_PORT занят. Ищу свободный...${NC}"
        local found=0
        for port in {4443..4450}; do
            if ! ss -tln | grep -q ":$port "; then
                HTTPS_PORT=$port
                found=1
                echo -e "${GREEN}[✓] Найден свободный порт: $HTTPS_PORT${NC}"
                break
            fi
        done
        if [ $found -eq 0 ]; then
            echo -e "${RED}[✗] Нет свободных портов${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}[✓] Порт $HTTPS_PORT свободен${NC}"
    fi

    # ------------------------------------------------------------
    # 3. РАБОТА В RAM
    # ------------------------------------------------------------
    local TEMP_DIR="/dev/shm/nginx-$$"
    mkdir -p "$TEMP_DIR"
    echo -e "${YELLOW}[*] Работаем в RAM: $TEMP_DIR${NC}"

    # ------------------------------------------------------------
    # 4. ГЕНЕРАЦИЯ СЕРТИФИКАТА (БЕЗ ЗАПРОСОВ)
    # ------------------------------------------------------------
    echo -e "${YELLOW}[*] Генерируем сертификат...${NC}"
    openssl req -x509 -newkey rsa:4096 \
        -keyout "$TEMP_DIR/key.pem" \
        -out "$TEMP_DIR/cert.pem" \
        -days 365 -nodes \
        -subj "/C=RU/ST=Local/L=Local/O=HackKit/CN=localhost" 2>/dev/null

    if [ ! -f "$TEMP_DIR/cert.pem" ]; then
        echo -e "${RED}[✗] Ошибка генерации сертификата${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi
    echo -e "${GREEN}[✓] Сертификат готов${NC}"

    # ------------------------------------------------------------
    # 5. КОНФИГ NGINX
    # ------------------------------------------------------------
    cat > "$TEMP_DIR/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    server {
        listen 443 ssl;
        server_name localhost;

        ssl_certificate /etc/nginx/ssl/cert.pem;
        ssl_certificate_key /etc/nginx/ssl/key.pem;

        root /usr/share/nginx/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
}
EOF

    # ------------------------------------------------------------
    # 6. HTML С КОРРЕКТНОЙ КОДИРОВКОЙ
    # ------------------------------------------------------------
    cat > "$TEMP_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>HTTPS тест</title>
</head>
<body>
    <h1>Привет от HTTPS сервера в контейнере!</h1>
    <p>Сертификат самоподписанный, но шифрование работает.</p>
    <p>Твой HTTPS сервер на порту 443 (или другом) работает правильно.</p>
</body>
</html>
EOF

    # ------------------------------------------------------------
    # 7. ЗАПУСК КОНТЕЙНЕРА
    # ------------------------------------------------------------
    local CONTAINER_NAME="nginx-https-$$"
    local IMAGE="docker.io/nginx:alpine"

    # Удаляем старый контейнер
    podman rm -f "$CONTAINER_NAME" 2>/dev/null

    echo -e "${YELLOW}[*] Запускаем контейнер...${NC}"
    podman run -d --name "$CONTAINER_NAME" \
        -p "$HTTPS_PORT:443" \
        -v "$TEMP_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$TEMP_DIR:/etc/nginx/ssl:ro" \
        -v "$TEMP_DIR/index.html:/usr/share/nginx/html/index.html:ro" \
        "$IMAGE" > /dev/null

    if [ $? -ne 0 ]; then
        echo -e "${RED}[✗] Ошибка запуска контейнера${NC}"
        rm -rf "$TEMP_DIR"
        return 1
    fi

    sleep 2
    echo -e "${GREEN}[✓] Контейнер запущен${NC}"

    # ------------------------------------------------------------
    # 8. ПРОВЕРКА
    # ------------------------------------------------------------
    echo -e "\n${CYAN}🔍 ПРОВЕРКА:${NC}"
    if curl -k "https://localhost:$HTTPS_PORT" -s > /dev/null; then
        echo -e "${GREEN}[✓] HTTPS сервер отвечает!${NC}"
        echo -e "\n${CYAN}📄 ЗАГОЛОВОК СТРАНИЦЫ:${NC}"
        curl -k "https://localhost:$HTTPS_PORT" -s | head -5
    else
        echo -e "${RED}[✗] HTTPS сервер не отвечает${NC}"
        echo "    Логи: podman logs $CONTAINER_NAME"
    fi

    # ------------------------------------------------------------
    # 9. ИНФОРМАЦИЯ
    # ------------------------------------------------------------
    echo -e "\n${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}🔒 HTTPS СЕРВЕР ЗАПУЩЕН${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo "  ▶ Адрес: https://localhost:$HTTPS_PORT"
    echo "  ▶ Контейнер: $CONTAINER_NAME"
    echo "  ▶ RAM: $TEMP_DIR"
    echo ""
    echo "  ▶ curl -k https://localhost:$HTTPS_PORT"
    echo "  ▶ curl -k https://localhost:$HTTPS_PORT -v"
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}\n"

    # ------------------------------------------------------------
    # 10. ЛОГИРОВАНИЕ
    # ------------------------------------------------------------
    log_experiment "03_https_server" "шифрование" "Запуск HTTPS" \
                   "$CONTAINER_NAME" "$IMAGE" "успех" \
                   "Порт $HTTPS_PORT, RAM" "yes"

    # ------------------------------------------------------------
    # 11. ОЖИДАНИЕ
    # ------------------------------------------------------------
    echo -e "${YELLOW}Нажми Enter, чтобы остановить сервер...${NC}"
    read

    echo -e "${YELLOW}[*] Останавливаем и чистим...${NC}"
    podman stop "$CONTAINER_NAME" >/dev/null 2>&1
    podman rm "$CONTAINER_NAME" >/dev/null 2>&1
    rm -rf "$TEMP_DIR"
    echo -e "${GREEN}[✓] Готово${NC}"
}

# Защита от прямого запуска
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run "$@"
fi