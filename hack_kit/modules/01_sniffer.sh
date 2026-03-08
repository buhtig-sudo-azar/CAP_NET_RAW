#!/bin/bash
# modules/01_sniffer.sh — ПРОФЕССИОНАЛЬНЫЙ СНИФФЕР (С ЖИВЫМ ВЫВОДОМ)

run() {
    # ------------------------------------------------------------
    # 1. АВТОМАТИЧЕСКАЯ ИНИЦИАЛИЗАЦИЯ
    # ------------------------------------------------------------
    
    # Автоматически определяем корень проекта
    if [ -z "$HACK_KIT_ROOT" ]; then
        local current_dir="$PWD"
        while [ "$current_dir" != "/" ]; do
            if [ -d "$current_dir/dockerfiles" ] && [ -d "$current_dir/modules" ]; then
                export HACK_KIT_ROOT="$current_dir"
                break
            fi
            current_dir="$(dirname "$current_dir")"
        done
        
        if [ -z "$HACK_KIT_ROOT" ]; then
            export HACK_KIT_ROOT="$HOME/TOR/hack_kit"
        fi
    fi
    
    echo -e "${BLUE}📁 Корень проекта: $HACK_KIT_ROOT${NC}"
    
    # ------------------------------------------------------------
    # 2. АВТОМАТИЧЕСКОЕ СОЗДАНИЕ СТРУКТУРЫ
    # ------------------------------------------------------------
    
    local BIN_DIR="$HACK_KIT_ROOT/bin"
    local DUMPS_DIR="$HACK_KIT_ROOT/dumps"
    local DATA_DIR="$HACK_KIT_ROOT/bin/data/captures"
    local SNIFFER_SRC="$HACK_KIT_ROOT/dockerfiles/01_sniffer/sniffer.c"
    local SNIFFER_BIN="$BIN_DIR/sniffer"
    
    mkdir -p "$BIN_DIR" "$DUMPS_DIR" "$DATA_DIR" 2>/dev/null
    
    # ------------------------------------------------------------
    # 3. ЦВЕТА ДЛЯ ВЫВОДА
    # ------------------------------------------------------------
    
    local RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' 
    local BLUE='\033[0;34m' CYAN='\033[0;36m' PURPLE='\033[0;35m' NC='\033[0m'

    # ------------------------------------------------------------
    # 4. ПРОВЕРКА И КОМПИЛЯЦИЯ
    # ------------------------------------------------------------
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo -e "${BLUE}🔧 ПРОВЕРКА КОМПОНЕНТОВ${NC}"
    echo "═══════════════════════════════════════════════════════"
    
    if [ -f "$SNIFFER_SRC" ]; then
        echo -e "${YELLOW}🔨 Компилирую сниффер...${NC}"
        
        if ! command -v gcc >/dev/null 2>&1; then
            echo -e "${RED}❌ gcc не установлен!${NC}"
        else
            gcc -o "$SNIFFER_BIN" "$SNIFFER_SRC" -Wall 2>/tmp/compile_errors.log
            
            if [ $? -eq 0 ] && [ -f "$SNIFFER_BIN" ]; then
                chmod +x "$SNIFFER_BIN"
                echo -e "${GREEN}✅ Компиляция успешна!${NC}"
            else
                echo -e "${RED}❌ Ошибка компиляции!${NC}"
                rm -f "$SNIFFER_BIN"
            fi
        fi
    fi
    
    # ------------------------------------------------------------
    # 5. ПРОВЕРКА ИНТЕРФЕЙСА
    # ------------------------------------------------------------
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo -e "${BLUE}🔌 ПРОВЕРКА ИНТЕРФЕЙСА${NC}"
    echo "═══════════════════════════════════════════════════════"
    
    local INTERFACE=""
    
    # Сначала пробуем выбранный в ядре
    if [ -n "$SELECTED_INTERFACE" ]; then
        if ip link show "$SELECTED_INTERFACE" >/dev/null 2>&1; then
            INTERFACE="$SELECTED_INTERFACE"
            echo -e "${GREEN}✅ Использую интерфейс из ядра: $INTERFACE${NC}"
        fi
    fi
    
    # Если не работает - предлагаем выбрать
    if [ -z "$INTERFACE" ]; then
        echo -e "${YELLOW}📡 Доступные интерфейсы:${NC}"
        echo ""
        
        local interfaces=()
        local i=1
        
        while read -r line; do
            if [[ "$line" =~ ^[0-9]+:\ (eth[0-9]+|wlan[0-9]+|enp[0-9]s[0-9]+):.*state\ UP ]]; then
                iface="${BASH_REMATCH[1]}"
                interfaces[$i]="$iface"
                local ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
                echo -e "  ${YELLOW}$i)${NC} ${GREEN}$iface${NC} ${ip:+🌐 $ip}"
                ((i++))
            fi
        done < <(ip link show)
        
        # Добавляем lo
        interfaces[$i]="lo"
        echo -e "  ${YELLOW}$i)${NC} ${GREEN}lo${NC} 🌐 127.0.0.1"
        
        echo ""
        read -p "Выбери номер интерфейса: " choice
        
        if [ -n "${interfaces[$choice]}" ]; then
            INTERFACE="${interfaces[$choice]}"
            echo -e "${GREEN}✅ Выбран интерфейс: $INTERFACE${NC}"
        else
            INTERFACE="eth0"
            echo -e "${YELLOW}⚠️  Использую eth0${NC}"
        fi
    fi
    
    # Показываем IP
    local ipv4=$(ip -4 addr show dev "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
    [ -n "$ipv4" ] && echo -e "   └─ IPv4: $ipv4"

    # ------------------------------------------------------------
    # 6. ОСНОВНЫЕ ФУНКЦИИ
    # ------------------------------------------------------------
    
    clean_domain() {
        echo "$1" | sed -E 's|^[a-zA-Z]+://||' | cut -d/ -f1 | cut -d: -f1 | xargs
    }

    get_ip() {
        local domain="$1"
        local ip
        
        ip=$(nslookup "$domain" 2>/dev/null | grep -A 1 "Name:" | grep "Address:" | head -1 | awk '{print $2}')
        [ -z "$ip" ] && ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
        [ -z "$ip" ] && ip=$(ping -c1 "$domain" 2>/dev/null | head -1 | grep -oP '\(\K[^)]+')
        
        echo "$ip"
    }

    check_ip() {
        timeout 2 bash -c "echo >/dev/tcp/$1/${2:-80}" 2>/dev/null
        return $?
    }

    # 🔥 ФУНКЦИЯ ЗАПУСКА С ЖИВЫМ ВЫВОДОМ
    run_sniffer_live() {
        local filter="$1"
        local target="$2"
        local dump_file="$DUMPS_DIR/dump_$(date +%Y%m%d_%H%M%S).pcap"
        
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo -e "${GREEN}🚀 ЗАПУСК СНИФФЕРА С ЖИВЫМ ВЫВОДОМ${NC}"
        echo "═══════════════════════════════════════════════════════"
        echo "  🌐 Интерфейс: $INTERFACE"
        echo "  💾 Дамп:      $(basename "$dump_file")"
        echo "  🎯 Цель:      $target"
        echo "  🔍 Фильтр:    $filter"
        echo ""
        echo -e "${YELLOW}⚠️  Ctrl+C для остановки и анализа${NC}"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        
        read -p "Запустить? (y/N): " confirm
        [[ "${confirm,,}" != "y" ]] && return 1
        
        # Очищаем экран перед началом
        clear
        
        # Запускаем сниффер в фоне
        if [ -x "$SNIFFER_BIN" ]; then
            # Своя программа
            sudo "$SNIFFER_BIN" "$dump_file" "$INTERFACE" "$filter" &
            SNIFFER_PID=$!
            
            echo -e "${GREEN}🔍 СНИФФЕР ЗАПУЩЕН (PID: $SNIFFER_PID)${NC}"
            echo -e "${YELLOW}📡 ЛОВЛЮ ПАКЕТЫ...${NC}"
            echo ""
            
            # Показываем живые пакеты
            local last_size=0
            local count=0
            
            while kill -0 $SNIFFER_PID 2>/dev/null; do
                if [ -f "$dump_file" ]; then
                    local current_size=$(stat -c%s "$dump_file" 2>/dev/null || echo 0)
                    
                    if [ "$current_size" -gt "$last_size" ]; then
                        # Появились новые данные
                        echo -e "${CYAN}📦 Новые пакеты (${current_size} байт):${NC}"
                        
                        # Показываем последние 3 пакета из дампа
                        sudo tcpdump -r "$dump_file" -c 3 -n 2>/dev/null | tail -3
                        echo ""
                        
                        last_size=$current_size
                        ((count++))
                        
                        if [ $count -ge 10 ]; then
                            echo -e "${YELLOW}📊 Показано 10 пакетов. Дамп продолжается...${NC}"
                            echo -e "${YELLOW}   Нажми Ctrl+C для остановки${NC}"
                            count=0
                        fi
                    fi
                fi
                sleep 0.5
            done
            
        else
            # tcpdump с живым выводом
            echo -e "${YELLOW}🔍 Использую tcpdump (живой вывод)${NC}"
            echo ""
            
            sudo tcpdump -i "$INTERFACE" -w "$dump_file" "$filter" -v 2>&1 | while read line; do
                echo -e "${CYAN}📦${NC} $line"
            done &
            TCPDUMP_PID=$!
            
            wait $TCPDUMP_PID
        fi
        
        # Анализируем результат
        if [ -f "$dump_file" ]; then
            local size=$(du -h "$dump_file" | cut -f1)
            local packets=$(tcpdump -r "$dump_file" 2>/dev/null | wc -l)
            
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo -e "${GREEN}✅ ЗАХВАТ ЗАВЕРШЕН${NC}"
            echo "═══════════════════════════════════════════════════════"
            echo "  📁 Дамп: $(basename "$dump_file")"
            echo "  📊 Пакетов: $packets"
            echo "  💾 Размер: $size"
            echo ""
            
            # Спрашиваем про анализ
            read -p "Анализировать дамп? (y/N): " anal
            if [[ "${anal,,}" == "y" ]]; then
                analyze_dump "$dump_file" "$filter" "$target"
            fi
        else
            echo -e "${RED}❌ Дамп не создан!${NC}"
        fi
    }

    # 🔥 ФУНКЦИЯ БЫСТРОГО ЗАХВАТА
    run_sniffer_quick() {
        local filter="$1"
        local target="$2"
        local dump_file="$DUMPS_DIR/quick_$(date +%Y%m%d_%H%M%S).pcap"
        
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo -e "${GREEN}🚀 БЫСТРЫЙ ЗАХВАТ (10 секунд)${NC}"
        echo "═══════════════════════════════════════════════════════"
        echo "  🌐 Интерфейс: $INTERFACE"
        echo "  🎯 Цель:      $target"
        echo "  ⏱️  Время:    10 секунд"
        echo ""
        
        # Запускаем сниффер на 10 секунд
        if [ -x "$SNIFFER_BIN" ]; then
            sudo "$SNIFFER_BIN" "$dump_file" "$INTERFACE" "$filter" &
            SNIFFER_PID=$!
        else
            sudo tcpdump -i "$INTERFACE" -w "$dump_file" "$filter" &
            SNIFFER_PID=$!
        fi
        
        # Обратный отсчет
            for i in {10..1}; do
            echo -ne "${YELLOW}⏳ Осталось: $i сек${NC}\r"
            sleep 1
        done
        echo -e "${GREEN}✅ Время вышло!${NC}"
        
        # Убиваем процесс
        sudo kill $SNIFFER_PID 2>/dev/null
        sleep 1
        
        # Проверяем результат
        if [ -f "$dump_file" ]; then
            local size=$(du -h "$dump_file" | cut -f1)
            local packets=$(tcpdump -r "$dump_file" 2>/dev/null | wc -l)
            
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo -e "${GREEN}✅ ЗАХВАТ ЗАВЕРШЕН${NC}"
            echo "═══════════════════════════════════════════════════════"
            echo "  📁 Дамп: $(basename "$dump_file")"
            echo "  📊 Пакетов: $packets"
            echo "  💾 Размер: $size"
            echo ""
            
            # Показываем первые 10 пакетов
            echo -e "${CYAN}📋 Первые 10 пакетов:${NC}"
            tcpdump -r "$dump_file" -c 10 -n 2>/dev/null
            echo ""
            
            read -p "Анализировать подробно? (y/N): " anal
            if [[ "${anal,,}" == "y" ]]; then
                analyze_dump "$dump_file" "$filter" "$target"
            fi
        else
            echo -e "${RED}❌ Дамп не создан!${NC}"
        fi
    }

    analyze_dump() {
        local dump_file="$1"
        local filter="$2"
        local target="$3"
        
        [ ! -f "$dump_file" ] && { 
            echo -e "${RED}❌ Файл дампа не найден${NC}"
            return 1 
        }
        
        clear
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo -e "${CYAN}🔍 АНАЛИЗ ПЕРЕХВАЧЕННОГО ТРАФИКА${NC}"
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo ""
        echo "📁 Файл:  $(basename "$dump_file")"
        echo "📏 Размер: $(du -h "$dump_file" | cut -f1)"
        echo "🎯 Цель:  $target (фильтр: $filter)"
        echo ""
        
        # Общая статистика
        local total=$(tcpdump -r "$dump_file" -n 2>/dev/null | wc -l)
        local ip_count=$(tcpdump -r "$dump_file" -n 2>/dev/null | grep -c "IP" || echo 0)
        local arp_count=$(tcpdump -r "$dump_file" -n 2>/dev/null | grep -c "ARP" || echo 0)
        
        echo "📊 Статистика:"
        echo "   Всего пакетов: $total"
        echo "   IP пакетов:    $ip_count"
        echo "   ARP пакетов:   $arp_count"
        echo ""
        
        # Топ источников
        echo -e "${PURPLE}📊 Топ источников:${NC}"
        tcpdump -r "$dump_file" -n 2>/dev/null | awk '{print $3}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head -10
        echo ""
        
        # Топ назначений
        echo -e "${PURPLE}📊 Топ назначений:${NC}"
        tcpdump -r "$dump_file" -n 2>/dev/null | awk '{print $5}' | cut -d. -f1-4 | sort | uniq -c | sort -rn | head -10
        echo ""
        
        # Протоколы
        echo -e "${PURPLE}📊 Протоколы:${NC}"
        tcpdump -r "$dump_file" -v 2>/dev/null | grep -oP '(?<=, )\w+(?=,)' | sort | uniq -c | sort -rn | head -10
        echo ""
        
        # Показываем пакеты с целью
        if [ -n "$filter" ] && [ "$filter" != "any" ]; then
            echo -e "${PURPLE}🎯 Пакеты с целью $filter:${NC}"
            tcpdump -r "$dump_file" -n -c 20 2>/dev/null | grep "$filter" | head -10
            echo ""
        fi
        
        echo "═══════════════════════════════════════════════════════════════════════════════"
        echo -e "${YELLOW}💡 Команды для глубокого анализа:${NC}"
        echo "   wireshark \"$dump_file\""
        echo "   tshark -r \"$dump_file\" -Y \"ip.addr == $filter\""
        echo "   tcpdump -r \"$dump_file\" -nnvv -A"
    }

    # ------------------------------------------------------------
    # 7. ГЛАВНЫЙ ЦИКЛ
    # ------------------------------------------------------------
    
    while true; do
        clear
        echo "═══════════════════════════════════════════════════════"
        echo -e "${BLUE}🔍 ПРОФЕССИОНАЛЬНЫЙ СНИФФЕР v6.0 (ЖИВОЙ ВЫВОД)${NC}"
        echo "═══════════════════════════════════════════════════════"
        echo -e "🌐 Интерфейс: ${GREEN}$INTERFACE${NC}"
        
        if [ -x "$SNIFFER_BIN" ]; then
            echo -e "   └─ ${GREEN}✓ своя программа${NC}"
        else
            echo -e "   └─ ${YELLOW}⚠️  tcpdump${NC}"
        fi
        
        local ipv4=$(ip -4 addr show dev "$INTERFACE" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
        [ -n "$ipv4" ] && echo -e "   └─ IPv4: ${CYAN}$ipv4${NC}"
        
        echo "───────────────────────────────────────────────────────"
        echo "   1) 🎯 ЗАХВАТИТЬ (с живым выводом)"
        echo "   2) 📊 Анализ дампа"
        echo "   3) ⚡ БЫСТРЫЙ ЗАХВАТ (10 сек)"
        echo "   4) 🧪 ТЕСТОВЫЙ (ping + захват)"
        echo "   5) ❌ Выход"
        echo ""
        read -p "Выбери режим [1]: " mode
        mode=${mode:-1}
        
        case $mode in
            1|3|4)
                echo ""
                read -p "🎯 Цель (домен/IP): " target
                target=$(clean_domain "$target")
                
                # Получаем IP
                if [[ $target =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ $target =~ ^[0-9a-fA-F:]+$ ]]; then
                    target_ip="$target"
                else
                    target_ip=$(get_ip "$target")
                fi
                
                if [ -z "$target_ip" ]; then
                    echo -e "${RED}❌ Не удалось разрешить домен${NC}"
                    read -p $'\nНажми Enter...'
                    continue
                fi
                
                echo -e "${GREEN}✅ IP: $target_ip${NC}"
                
                # Проверка доступности для тестового режима
                if [ "$mode" = "4" ]; then
                    echo -n "🔍 Проверка доступности... "
                    if check_ip "$target_ip"; then
                        echo -e "${GREEN}ОТВЕЧАЕТ${NC}"
                        echo -e "${YELLOW}📡 Запускаю ping...${NC}"
                        ping -c 5 "$target_ip" >/dev/null 2>&1 &
                    else
                        echo -e "${YELLOW}⚠️  НЕ ОТВЕЧАЕТ${NC}"
                    fi
                fi
                
                # Фильтр
                local filter="$target_ip"
                
                # Выбор режима
                case $mode in
                    1) run_sniffer_live "$filter" "$target" ;;
                    3) run_sniffer_quick "$filter" "$target" ;;
                    4) run_sniffer_live "$filter" "$target" ;;
                esac
                ;;
                
            2)
                echo ""
                echo "📁 Доступные дампы:"
                local dumps=("$DUMPS_DIR"/*.pcap)
                
                if [ ${#dumps[@]} -eq 0 ] || [ ! -f "${dumps[0]}" ]; then
                    echo -e "${YELLOW}📭 Нет дампов${NC}"
                else
                    local i=1
                    for dump in "${dumps[@]}"; do
                        if [ -f "$dump" ]; then
                            local size=$(du -h "$dump" 2>/dev/null | cut -f1)
                            echo "  $i) $(basename "$dump") ($size)"
                            ((i++))
                        fi
                    done
                    echo ""
                    read -p "Выбери номер дампа: " num
                    
                    local selected_dump=""
                    i=1
                    for dump in "${dumps[@]}"; do
                        if [ -f "$dump" ]; then
                            if [ "$i" -eq "$num" ]; then
                                selected_dump="$dump"
                                break
                            fi
                            ((i++))
                        fi
                    done
                    
                    if [ -n "$selected_dump" ]; then
                        read -p "Цель для анализа (IP): " target_ip
                        analyze_dump "$selected_dump" "$target_ip" "$target_ip"
                    fi
                fi
                ;;
                
            5|q|Q)
                echo -e "${GREEN}👋 Пока!${NC}"
                return 0
                ;;
        esac
        
        echo ""
        read -p "🔄 Нажми Enter для продолжения..."
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run
fi