#!/bin/bash
# ============================================================================
# МОДУЛЬ: 01_sniffer.sh (интерактивная версия с расширенным анализом)
# НАЗНАЧЕНИЕ: Запуск C-сниффера с выбором режима и интерфейса через меню.
#
# ФУНКЦИОНАЛ:
#   - Показывает список доступных сетевых интерфейсов.
#   - Предлагает выбрать режим: контейнер (Podman) или нативный запуск.
#   - В контейнерном режиме проверяет наличие Podman, собирает образ (если нужно).
#   - В нативном режиме компилирует и запускает сниффер прямо на хосте.
#   - Сохраняет дампы в ~/hack_kit/data/captures/ с расширенным анализом через Scapy.
#   - Поддерживает автоматический запуск с аргументами (для вызова из ядра без меню).
# ============================================================================

# ----------------------------------------------------------------------------
# Функция run() — обязательна для всех модулей. Вызывается ядром.
# Если переданы аргументы, используем их без меню (для автоматизации).
# Аргументы: $1 = интерфейс, $2 = режим (podman|native)
# ----------------------------------------------------------------------------
run() {
    local interface="$1"
    local mode="$2"

    # Если аргументы не заданы – запускаем интерактивное меню
    if [ -z "$interface" ] || [ -z "$mode" ]; then
        echo "=== Модуль 01: Сниффер трафика ==="
        choose_interface_and_mode
        return $?
    else
        # Автоматический режим (аргументы переданы)
        start_sniffer "$interface" "$mode"
        return $?
    fi
}

# ----------------------------------------------------------------------------
# Функция выбора интерфейса и режима через меню
# ----------------------------------------------------------------------------
choose_interface_and_mode() {
    # Получаем список активных сетевых интерфейсов (без loopback)
    local interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -v lo))
    
    if [ ${#interfaces[@]} -eq 0 ]; then
        echo "[!] Нет доступных сетевых интерфейсов (кроме loopback)."
        return 1
    fi

    # Меню выбора интерфейса
    echo ""
    echo "Доступные интерфейсы:"
    for i in "${!interfaces[@]}"; do
        echo "  $((i+1))) ${interfaces[$i]}"
    done
    echo ""
    read -p "Выбери номер интерфейса (по умолчанию 1): " iface_choice
    iface_choice=${iface_choice:-1}
    
    # Проверка корректности ввода
    if ! [[ "$iface_choice" =~ ^[0-9]+$ ]] || [ "$iface_choice" -lt 1 ] || [ "$iface_choice" -gt "${#interfaces[@]}" ]; then
        echo "[!] Неверный выбор. Использую первый интерфейс: ${interfaces[0]}"
        iface_choice=1
    fi
    local selected_iface="${interfaces[$((iface_choice-1))]}"
    echo "Выбран интерфейс: $selected_iface"
    echo ""

    # Меню выбора режима
    echo "Выбери режим запуска:"
    echo "  1) В контейнере (Podman/Docker) – изоляция, воспроизводимость"
    echo "  2) Нативный (прямо на хосте) – быстрее, требует root"
    echo "  3) Выход"
    echo ""
    read -p "Твой выбор (по умолчанию 1): " mode_choice
    mode_choice=${mode_choice:-1}

    case "$mode_choice" in
        1)
            echo "Выбран режим: контейнер"
            start_sniffer "$selected_iface" "podman"
            ;;
        2)
            echo "Выбран режим: нативный"
            start_sniffer "$selected_iface" "native"
            ;;
        3)
            echo "Выход из модуля."
            return 0
            ;;
        *)
            echo "[!] Неверный выбор. Использую контейнерный режим."
            start_sniffer "$selected_iface" "podman"
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Функция, которая запускает сниффер в указанном режиме
# Параметры: $1 — интерфейс, $2 — режим (podman или native)
# ----------------------------------------------------------------------------
start_sniffer() {
    local interface="$1"
    local mode="$2"

    # ----------------------------------------------------------
    # 1. Базовые пути
    # ----------------------------------------------------------
    local base_dir="${HACK_KIT_ROOT:-$(pwd)}"
    local dockerfile_dir="$base_dir/dockerfiles/01_sniffer"
    local c_source="$dockerfile_dir/sniffer.c"

    # Проверка наличия исходника C
    if [ ! -f "$c_source" ]; then
        echo "[01_sniffer][ОШИБКА] Не найден исходник C: $c_source" >&2
        return 1
    fi

    # ----------------------------------------------------------
    # 2. RAM-диск (временная папка в памяти)
    # ----------------------------------------------------------
    local ram_dir="/dev/shm/sniffer_$$"
    mkdir -p "$ram_dir"
    echo "[01_sniffer] Временные файлы: $ram_dir"

    # ----------------------------------------------------------
    # 3. Запуск в зависимости от режима
    # ----------------------------------------------------------
    local exit_code=0
    if [ "$mode" = "podman" ]; then
        # --- Режим контейнера ---
        if ! command -v podman &> /dev/null; then
            echo "[01_sniffer][ОШИБКА] Podman не найден. Установи podman или выбери нативный режим." >&2
            rm -rf "$ram_dir"
            return 1
        fi

        local dockerfile="$dockerfile_dir/Dockerfile"
        if [ ! -f "$dockerfile" ]; then
            echo "[01_sniffer][ОШИБКА] Не найден Dockerfile: $dockerfile" >&2
            rm -rf "$ram_dir"
            return 1
        fi

        local image_name="localhost/hack_kit_01_sniffer:latest"
        
        # Сборка образа (если ещё не собран)
        if ! podman image exists "$image_name" 2>/dev/null; then
            echo "[01_sniffer] Сборка образа $image_name..."
            podman build -t "$image_name" -f "$dockerfile" "$dockerfile_dir"
            if [ $? -ne 0 ]; then
                echo "[01_sniffer][ОШИБКА] Сборка провалилась" >&2
                rm -rf "$ram_dir"
                return 2
            fi
        fi

        echo "[01_sniffer] Запуск контейнера на интерфейсе: $interface"
        podman run --rm \
            --privileged \
            --network=host \
            -v "$ram_dir:/data:Z" \
            "$image_name" \
            "/data/dump.pcap" "$interface"
        exit_code=$?

    elif [ "$mode" = "native" ]; then
        # --- Нативный режим ---
        echo "[01_sniffer] Компиляция C-кода..."
        gcc "$c_source" -o "$ram_dir/sniffer"
        if [ $? -ne 0 ]; then
            echo "[01_sniffer][ОШИБКА] Компиляция провалилась" >&2
            rm -rf "$ram_dir"
            return 3
        fi

        echo "[01_sniffer] Запуск нативного сниффера на интерфейсе: $interface"
        echo "[01_sniffer] (требуется root, запросим sudo)"
        sudo "$ram_dir/sniffer" "$ram_dir/dump.pcap" "$interface"
        exit_code=$?
    else
        echo "[01_sniffer][ОШИБКА] Неизвестный режим: $mode" >&2
        rm -rf "$ram_dir"
        return 4
    fi

    # ----------------------------------------------------------
    # 4. Обработка результата (общая для обоих режимов)
    # ----------------------------------------------------------
    if [ -f "$ram_dir/dump.pcap" ]; then
        local size=$(stat -c%s "$ram_dir/dump.pcap" 2>/dev/null || stat -f%z "$ram_dir/dump.pcap" 2>/dev/null)
        echo "[01_sniffer] Поймано $(($size / 1024)) KB данных"

        if [ $size -gt 0 ]; then
            local save_dir="$base_dir/data/captures"
            mkdir -p "$save_dir"
            local save_file="$save_dir/sniffer_$(date +%Y%m%d_%H%M%S).pcap"
            cp "$ram_dir/dump.pcap" "$save_file"

            # Корректируем владельца, если запускалось через sudo
            if [ -n "$SUDO_USER" ]; then
                chown "$SUDO_USER:$SUDO_USER" "$save_file"
            fi

            echo "[01_sniffer] ✅ Дамп сохранён: $save_file"
            analyze "$save_file"
        else
            echo "[01_sniffer] ⚠️  Дамп пустой (нет трафика)"
        fi
    else
        echo "[01_sniffer][ОШИБКА] Файл дампа не создан" >&2
    fi

    # ----------------------------------------------------------
    # 5. Очистка RAM-диска
    # ----------------------------------------------------------
    rm -rf "$ram_dir"
    echo "[01_sniffer] Временные файлы очищены"

    return $exit_code
}

# ----------------------------------------------------------
# ФУНКЦИЯ АНАЛИЗА (расширенная версия)
# ----------------------------------------------------------
analyze() {
    local pcap_file="$1"
    
    if [ ! -f "$pcap_file" ]; then
        echo "Ошибка: файл $pcap_file не найден" >&2
        return 1
    fi
    
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "📊 АНАЛИЗ ЗАХВАЧЕННОГО ТРАФИКА"
    echo "══════════════════════════════════════════════════════"
    
    # Запускаем Python-скрипт с Scapy
    python3 -c "
import sys
from collections import Counter
try:
    from scapy.all import rdpcap, IP, TCP, UDP, ICMP, ARP
except ImportError:
    print('[!] Scapy не установлен. Установи: sudo apt install python3-scapy')
    sys.exit(1)

try:
    packets = rdpcap(sys.argv[1])
except Exception as e:
    print(f'[!] Ошибка чтения pcap: {e}')
    sys.exit(1)

total = len(packets)
if total == 0:
    print('[!] Файл пуст')
    sys.exit(0)

print(f'📦 Всего пакетов: {total}')

# Подсчёт пакетов по протоколам
proto_count = Counter()
ip_src = Counter()
ip_dst = Counter()
http_requests = []

for pkt in packets:
    if ARP in pkt:
        proto_count['ARP'] += 1
    elif IP in pkt:
        ip = pkt[IP]
        ip_src[ip.src] += 1
        ip_dst[ip.dst] += 1
        
        if TCP in pkt:
            tcp = pkt[TCP]
            proto_count['TCP'] += 1
            # Проверяем, похоже ли на HTTP-запрос (на 80 порту или с данными)
            if (tcp.dport == 80 or tcp.sport == 80) and tcp.payload:
                payload = bytes(tcp.payload).decode('utf-8', errors='ignore')
                if payload.startswith(('GET', 'POST', 'HEAD', 'PUT')):
                    http_requests.append({
                        'src': ip.src,
                        'dst': ip.dst,
                        'method': payload.split(' ')[0],
                        'uri': payload.split(' ')[1] if len(payload.split(' ')) > 1 else ''
                    })
        elif UDP in pkt:
            proto_count['UDP'] += 1
        elif ICMP in pkt:
            proto_count['ICMP'] += 1
        else:
            proto_count['IP-other'] += 1
    else:
        proto_count['Other'] += 1

# Вывод статистики по протоколам
print('\n📈 Протоколы:')
for proto, cnt in proto_count.most_common():
    print(f'  {proto:8} : {cnt:5} пакетов ({cnt/total*100:5.1f}%)')

# Топ-5 отправителей
print('\n⬆️  Топ-5 отправителей (IP):')
for ip, cnt in ip_src.most_common(5):
    print(f'  {ip:15} : {cnt:5} пакетов')

# Топ-5 получателей
print('\n⬇️  Топ-5 получателей (IP):')
for ip, cnt in ip_dst.most_common(5):
    print(f'  {ip:15} : {cnt:5} пакетов')

# HTTP-запросы
if http_requests:
    print('\n🌐 HTTP-запросы (GET/POST):')
    for req in http_requests[:5]:  # покажем только первые 5
        print(f'  {req["src"]} -> {req["dst"]} : {req["method"]} {req["uri"]}')
    if len(http_requests) > 5:
        print(f'  ... и ещё {len(http_requests)-5} запросов')
else:
    print('\n🌐 HTTP-запросов не найдено (возможно, весь трафик HTTPS)')

print('\n══════════════════════════════════════════════════════\n')
" "$pcap_file"
}

# ----------------------------------------------------------------------------
# Если скрипт запущен напрямую (не через ядро) — позволяем передать аргументы
# или запустить меню.
# ----------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Скрипт запущен как самостоятельный, а не через source
    if [ "$#" -ge 2 ]; then
        # Аргументы: интерфейс и режим
        run "$1" "$2"
    else
        # Без аргументов — запускаем меню
        run
    fi
fi