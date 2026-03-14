#!/bin/bash

# Модуль 05: WireGuard Local Sandbox - С МОСТОМ
MODULE_NAME="05_wireguard_local"
MODULE_DESC="WireGuard: изолированный namespace на хосте + мост"

HACK_KIT_ROOT="/home/azar/TOR/hack_kit"
KEYS_DIR="$HACK_KIT_ROOT/data/wireguard/keys"
SERVER_IP="10.66.66.1"
CLIENT_IP="10.66.66.2"
SERVER_PORT="51280"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_deps() {
    if ! command -v wg-quick &> /dev/null; then
        echo -e "${RED}❌ wireguard-tools не найден${NC}"
        sudo apt update && sudo apt install -y wireguard-tools
    fi
    
    if ! lsmod | grep -q wireguard; then
        sudo modprobe wireguard
    fi
    
    return 0
}

generate_keys() {
    echo -e "${GREEN}[*] Генерация ключей...${NC}"
    mkdir -p "$KEYS_DIR"
    
    wg genkey | tee "$KEYS_DIR/server_private" | wg pubkey > "$KEYS_DIR/server_public"
    wg genkey | tee "$KEYS_DIR/client_private" | wg pubkey > "$KEYS_DIR/client_public"
    chmod 600 "$KEYS_DIR"/*
    
    echo -e "${GREEN}✅ Ключи сгенерированы${NC}"
}

create_server_config() {
    echo -e "${GREEN}[*] Создание конфига сервера...${NC}"
    
    local SERVER_PRIV=$(cat "$KEYS_DIR/server_private")
    local CLIENT_PUB=$(cat "$KEYS_DIR/client_public")
    
    sudo tee /etc/wireguard/wg0.conf > /dev/null << EOF
[Interface]
Address = $SERVER_IP/24
PrivateKey = $SERVER_PRIV
ListenPort = $SERVER_PORT
PostUp = iptables -t nat -A POSTROUTING -o eth2 -j MASQUERADE; iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o eth2 -j MASQUERADE; iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = $CLIENT_IP/32
EOF
    
    sudo chmod 600 /etc/wireguard/wg0.conf
    echo -e "${GREEN}✅ Конфиг сервера создан${NC}"
}

create_client_config() {
    echo -e "${GREEN}[*] Создание конфига клиента...${NC}"
    
    local CLIENT_PRIV=$(cat "$KEYS_DIR/client_private")
    local SERVER_PUB=$(cat "$KEYS_DIR/server_public")
    
    # IP хоста для эндпоинта
    local HOST_IP="10.0.4.15"
    
    sudo tee /etc/wireguard/client.conf > /dev/null << EOF
[Interface]
Address = $CLIENT_IP/24
PrivateKey = $CLIENT_PRIV

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $HOST_IP:$SERVER_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    sudo chmod 600 /etc/wireguard/client.conf
    echo -e "${GREEN}✅ Конфиг клиента создан${NC}"
}

setup_veth_bridge() {
    echo -e "${GREEN}[*] Создание виртуального моста для namespace...${NC}"
    
    # Удаляем старые интерфейсы если есть
    sudo ip link delete veth0 2>/dev/null
    
    # Создаем veth-пару
    sudo ip link add veth0 type veth peer name veth1
    
    # Один конец в хосте
    sudo ip addr add 10.66.67.1/24 dev veth0
    sudo ip link set veth0 up
    
    # Другой конец в namespace
    sudo ip link set veth1 netns client-ns
    sudo ip netns exec client-ns ip addr add 10.66.67.2/24 dev veth1
    sudo ip netns exec client-ns ip link set veth1 up
    sudo ip netns exec client-ns ip link set lo up
    
    # Добавляем маршрут по умолчанию в namespace через хост
    sudo ip netns exec client-ns ip route add default via 10.66.67.1 dev veth1
    
    # Включаем NAT для трафика из namespace
    sudo iptables -t nat -A POSTROUTING -s 10.66.67.0/24 -o eth2 -j MASQUERADE
    sudo iptables -A FORWARD -i veth0 -o eth2 -j ACCEPT
    sudo iptables -A FORWARD -i eth2 -o veth0 -j ACCEPT
    
    echo -e "${GREEN}✅ Мост создан${NC}"
    
    # Тест соединения
    echo -e "${YELLOW}Тест связи с хостом из namespace:${NC}"
    sudo ip netns exec client-ns ping -c 2 10.66.67.1
}

run() {
    echo -e "${GREEN}=== Модуль 05: WireGuard Local Sandbox ===${NC}"
    echo ""
    
    # Чистим предыдущие запуски
    sudo wg-quick down wg0 2>/dev/null
    sudo ip netns delete client-ns 2>/dev/null
    sudo ip link delete veth0 2>/dev/null
    sudo iptables -F FORWARD 2>/dev/null
    sudo iptables -t nat -F POSTROUTING 2>/dev/null
    
    check_deps
    generate_keys
    create_server_config
    create_client_config
    
    # Запускаем сервер
    echo -e "${GREEN}[*] Запуск WireGuard сервера...${NC}"
    sudo wg-quick up wg0
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
    
    echo -e "\n${GREEN}=== СЕРВЕР ===${NC}"
    sudo wg show
    
    # Создаем namespace
    echo -e "\n${GREEN}[*] Создание namespace...${NC}"
    sudo ip netns add client-ns
    
    # Настраиваем мост
    setup_veth_bridge
    
    # Запускаем клиент в namespace
    echo -e "\n${GREEN}[*] Запуск WireGuard клиента в namespace...${NC}"
    sudo ip netns exec client-ns wg-quick up /etc/wireguard/client.conf
    
    echo -e "\n${GREEN}=== КЛИЕНТ ===${NC}"
    sudo ip netns exec client-ns wg show
    
    # Тесты
    echo -e "\n${YELLOW}=== ТЕСТ PING ДО СЕРВЕРА ===${NC}"
    sudo ip netns exec client-ns ping -c 4 10.66.66.1
    
    echo -e "\n${YELLOW}=== ТЕСТ ИНТЕРНЕТА ЧЕРЕЗ VPN ===${NC}"
    sudo ip netns exec client-ns curl -s ifconfig.me
    echo ""
    
    echo -e "\n${GREEN}=== ФИНАЛЬНЫЙ СТАТУС ===${NC}"
    echo -e "\n${BLUE}Сервер:${NC}"
    sudo wg show
    echo -e "\n${BLUE}Клиент:${NC}"
    sudo ip netns exec client-ns wg show
}

# Для прямого запуска
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run
fi