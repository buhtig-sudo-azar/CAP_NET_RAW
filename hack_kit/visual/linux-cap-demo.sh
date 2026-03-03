#!/bin/bash


set -euo pipefail

# ===========================================
# ANSI ЦВЕТА
# ===========================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[✓] $1${NC}"; }
print_info() { echo -e "${BLUE}[i] $1${NC}"; }
print_warn() { echo -e "${YELLOW}[!] $1${NC}"; }
print_error() { echo -e "${RED}[✗] $1${NC}"; }

# ===========================================
# ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# ===========================================
PROJECT_DIR=""
VENV_ACTIVE=0

# ===========================================
# ОЧИСТКА
# ===========================================
cleanup() {
    if [[ $VENV_ACTIVE -eq 1 ]]; then
        deactivate 2>/dev/null || true
        VENV_ACTIVE=0
    fi
    if [[ -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
        cd /tmp && rm -rf "$PROJECT_DIR" 2>/dev/null || true
        PROJECT_DIR=""
    fi
}

# ===========================================
# СОЗДАНИЕ ПРОЕКТА
# ===========================================
create_project() {
    PROJECT_DIR=$(mktemp -d /tmp/linux-cap-demo.XXXXXX)
    print_status "Проект: $PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"/{app/templates,dist}
    cd "$PROJECT_DIR" || { print_error "Ошибка создания проекта"; return 1; }
}

# ===========================================
# PYTHON ENV
# ===========================================
setup_python_env() {
    local venv_path="$PROJECT_DIR/venv"
    
    if [[ ! -d "$venv_path" ]]; then
        print_warn "Создание venv..."
        python3 -m venv "$venv_path"
        source "$venv_path/bin/activate"
        pip install --quiet flask==2.3.3 pyinstaller==6.10.0
        print_status "venv готова"
    else
        source "$venv_path/bin/activate"
    fi
    VENV_ACTIVE=1
}

# ===========================================
# ГЕНЕРАЦИЯ ФАЙЛОВ (УМНАЯ КНОПКА)
# ===========================================
generate_app() {
    print_info "Генерация интерфейса с умной кнопкой..."
    
    cat > app/main.py << 'PYEOF'
#!/usr/bin/env python3
"""
🔍 CAP_NET_RAW Demo - ОБЪЯСНЕНИЕ:

1. Что такое capabilities?
   - Это дробные привилегии root в Linux
   - Вместо полного sudo даём только CAP_NET_RAW

2. Почему программа падает без прав?
   - socket(AF_PACKET, SOCK_RAW) требует CAP_NET_RAW
   - Ядро проверяет: if (!capable(CAP_NET_RAW)) return -EPERM

3. Что делает setcap?
   - setcap cap_net_raw+ep ./binary
   - Приклеивает capability к INODE файла
   - +e = effective (активна сразу)
   - +p = permitted (разрешена)

4. Почему теряется при пересборке?
   - Новый файл = новый INODE
   - Capability привязана к старому INODE
"""

from flask import Flask, render_template, jsonify
import os, sys, time, socket, subprocess
from pathlib import Path

app = Flask(__name__)
logs = []
PID = os.getpid()
EXE = Path(sys.executable if getattr(sys, 'frozen', False) else __file__).resolve()

def log(msg):
    global logs
    ts = time.strftime("%H:%M:%S")
    logs.append(f"[{ts}] {msg}")
    if len(logs) > 20:
        logs = logs[-15:]
    print(f"[{ts}] {msg}")

def test_cap():
    """Проверка CAP_NET_RAW через raw socket"""
    try:
        s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
        s.close()
        return True
    except PermissionError:
        return False
    except Exception as e:
        log(f"Ошибка: {e}")
        return False

def get_file_inode():
    try:
        stat = os.stat(EXE)
        return stat.st_ino
    except:
        return 0

@app.route('/')
def index():
    cap = test_cap()
    inode = get_file_inode()
    
    try:
        result = subprocess.run(['getcap', str(EXE)], capture_output=True, text=True, timeout=2)
        cap_info = result.stdout.strip()
    except:
        cap_info = "getcap не установлен (apt install libcap2-bin)"
    
    return render_template('index.html',
                         cap=cap,
                         pid=PID,
                         exe=str(EXE),
                         inode=inode,
                         cap_info=cap_info or "⚪ capability не установлена",
                         logs=logs[-10:])

@app.route('/test')
def api_test():
    result = test_cap()
    log(f"🧪 Тест: {'✅ РАБОТАЕТ' if result else '❌ НЕТ ДОСТУПА'}")
    return jsonify({'cap': result})

def main():
    log(f"🚀 Запуск PID: {PID}")
    log(f"📁 Файл: {EXE.name}")
    log(f"📌 INODE: {get_file_inode()}")
    log("🌐 http://localhost:5000")
    app.run(host='0.0.0.0', port=5000, debug=False, use_reloader=False)

if __name__ == '__main__':
    main()
PYEOF

    chmod +x app/main.py

    # ГЛАВНАЯ СТРАНИЦА 
    cat > app/templates/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>🔍 CAP_NET_RAW</title>
    <style>
        /* МАКСИМАЛЬНЫЙ КОНТРАСТ - БЕЛЫЙ НА ЧЕРНОМ */
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            background-color: #000000;
            color: #FFFFFF;
            font-family: 'Courier New', 'SF Mono', monospace;
            font-size: 18px;
            line-height: 1.6;
            min-height: 100vh;
            position: relative;
        }
        
        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 30px;
        }
        
        h1 {
            color: #FFFFFF;
            font-size: 48px;
            font-weight: bold;
            text-align: center;
            margin-bottom: 30px;
            border-bottom: 4px solid #FFFFFF;
            padding-bottom: 15px;
            text-transform: uppercase;
            letter-spacing: 2px;
        }
        
        h2 {
            color: #FFFFFF;
            font-size: 32px;
            font-weight: bold;
            margin: 40px 0 20px 0;
            border-left: 8px solid #FFFFFF;
            padding-left: 15px;
        }
        
        h3 {
            color: #FFFFFF;
            font-size: 24px;
            font-weight: bold;
            margin-bottom: 15px;
        }
        
        .status-box {
            background-color: #111111;
            border: 3px solid #FFFFFF;
            padding: 30px;
            margin-bottom: 30px;
        }
        
        .status-ok {
            color: #00FF00;
            font-size: 64px;
            font-weight: bold;
            text-align: center;
            margin: 20px 0;
            text-shadow: 0 0 10px #00FF00;
        }
        
        .status-no {
            color: #FF0000;
            font-size: 64px;
            font-weight: bold;
            text-align: center;
            margin: 20px 0;
            text-shadow: 0 0 10px #FF0000;
        }
        
        .info-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 30px;
            margin-bottom: 30px;
        }
        
        .info-card {
            background-color: #111111;
            border: 2px solid #FFFFFF;
            padding: 25px;
        }
        
        .info-label {
            color: #AAAAAA;
            font-size: 16px;
            text-transform: uppercase;
            letter-spacing: 1px;
            margin-bottom: 10px;
        }
        
        .info-value {
            color: #FFFFFF;
            font-size: 48px;
            font-weight: bold;
            font-family: 'Courier New', monospace;
            margin: 10px 0;
        }
        
        .info-desc {
            color: #CCCCCC;
            font-size: 16px;
            border-top: 1px solid #333333;
            padding-top: 10px;
        }
        
        .terminal-box {
            background-color: #000000;
            border: 3px solid #00FF00;
            padding: 20px;
            margin: 30px 0;
            font-family: 'Courier New', monospace;
            color: #00FF00;
            font-size: 16px;
        }
        
        .terminal-box pre {
            color: #00FF00;
            font-size: 16px;
            white-space: pre-wrap;
        }
        
        .button-grid {
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 20px;
            margin: 30px 0;
        }
        
        .action-button {
            background-color: #000000;
            color: #FFFFFF;
            border: 3px solid #FFFFFF;
            padding: 25px;
            font-size: 24px;
            font-weight: bold;
            cursor: pointer;
            transition: all 0.2s;
            text-align: center;
            font-family: 'Courier New', monospace;
        }
        
        .action-button:hover {
            background-color: #FFFFFF;
            color: #000000;
        }
        
        .warning-box {
            background-color: #330000;
            border: 3px solid #FF0000;
            padding: 25px;
            margin: 30px 0;
        }
        
        .warning-box p {
            color: #FF0000;
            font-size: 20px;
            font-weight: bold;
            margin: 10px 0;
        }
        
        .code-block {
            background-color: #222222;
            border-left: 5px solid #FFFFFF;
            padding: 15px;
            font-family: 'Courier New', monospace;
            color: #FFFFFF;
            font-size: 16px;
            margin: 15px 0;
        }
        
        .explanation-grid {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 20px;
            margin: 30px 0;
        }
        
        .explanation-card {
            background-color: #111111;
            border: 2px solid #FFFFFF;
            padding: 20px;
        }
        
        .explanation-card h4 {
            color: #FFFFFF;
            font-size: 22px;
            font-weight: bold;
            margin-bottom: 15px;
            border-bottom: 2px solid #FFFFFF;
            padding-bottom: 5px;
        }
        
        .explanation-card p {
            color: #CCCCCC;
            font-size: 16px;
            margin: 10px 0;
        }
        
        .explanation-card .command {
            color: #00FF00;
            font-size: 18px;
            font-weight: bold;
            background-color: #222222;
            padding: 10px;
            margin: 10px 0;
        }
        
        .log-box {
            background-color: #111111;
            border: 2px solid #FFFFFF;
            padding: 20px;
            height: 200px;
            overflow-y: auto;
            font-family: 'Courier New', monospace;
            color: #00FF00;
            font-size: 14px;
            margin: 30px 0;
        }
        
        a {
            color: #FFFFFF;
            text-decoration: underline;
            font-weight: bold;
        }
        
        a:hover {
            color: #00FF00;
        }
        
        .footer {
            margin-top: 50px;
            text-align: center;
            border-top: 2px solid #333333;
            padding-top: 20px;
            color: #AAAAAA;
        }
        
        /* Длинный контент для прокрутки */
        .scroll-content {
            margin: 50px 0;
        }
        
        /* =========================================== */
        /* УМНАЯ КНОПКА - ПОЯВЛЯЕТСЯ ПОСЛЕ ПРОКРУТКИ */
        /* =========================================== */
        .smart-button {
            position: fixed;
            bottom: 30px;
            right: 30px;
            width: 80px;
            height: 80px;
            border-radius: 50%;
            background: rgba(255, 255, 255, 0.03);
            border: 2px solid rgba(255, 255, 255, 0.2);
            box-shadow: 0 5px 20px rgba(0, 0, 0, 0.5);
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.3s ease;
            z-index: 1000;
            backdrop-filter: blur(8px);
            -webkit-backdrop-filter: blur(8px);
            opacity: 0;
            visibility: hidden;
            transform: scale(0.8);
        }
        
        .smart-button.visible {
            opacity: 1;
            visibility: visible;
            transform: scale(1);
        }
        
        .smart-button:hover {
            background: rgba(255, 255, 255, 0.1);
            border: 2px solid rgba(255, 255, 255, 0.5);
            box-shadow: 0 0 30px rgba(255, 255, 255, 0.2);
            transform: scale(1.1);
        }
        
        /* Паутинка */
        .web-design {
            width: 50px;
            height: 50px;
            position: relative;
        }
        
        /* Внешний круг паутины */
        .web-outer {
            position: absolute;
            top: 50%;
            left: 50%;
            width: 45px;
            height: 45px;
            border: 2px solid rgba(255, 255, 255, 0.5);
            border-radius: 50%;
            transform: translate(-50%, -50%);
            animation: pulse 2s infinite;
        }
        
        /* Средний круг */
        .web-middle {
            position: absolute;
            top: 50%;
            left: 50%;
            width: 30px;
            height: 30px;
            border: 2px solid rgba(255, 255, 255, 0.3);
            border-radius: 50%;
            transform: translate(-50%, -50%);
        }
        
        /* Внутренний круг */
        .web-inner {
            position: absolute;
            top: 50%;
            left: 50%;
            width: 15px;
            height: 15px;
            border: 2px solid rgba(255, 255, 255, 0.2);
            border-radius: 50%;
            transform: translate(-50%, -50%);
        }
        
        /* Линии паутины */
        .web-line {
            position: absolute;
            top: 50%;
            left: 50%;
            width: 2px;
            height: 50px;
            background: linear-gradient(to bottom, 
                rgba(255,255,255,0.6) 0%, 
                rgba(255,255,255,0.1) 80%,
                transparent 100%);
            transform-origin: 50% 0;
        }
        
        .line-0 { transform: translate(-50%, -50%) rotate(0deg); }
        .line-45 { transform: translate(-50%, -50%) rotate(45deg); }
        .line-90 { transform: translate(-50%, -50%) rotate(90deg); }
        .line-135 { transform: translate(-50%, -50%) rotate(135deg); }
        
        /* Паучок */
        .spider-icon {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: 20px;
            animation: crawl 3s infinite;
            filter: drop-shadow(0 0 5px rgba(255,255,255,0.5));
        }
        
        /* Стрелка (появляется при наведении) */
        .arrow-up {
            position: absolute;
            top: -30px;
            left: 50%;
            transform: translateX(-50%);
            font-size: 20px;
            color: rgba(255, 255, 255, 0.8);
            opacity: 0;
            transition: opacity 0.3s;
            white-space: nowrap;
        }
        
        .smart-button:hover .arrow-up {
            opacity: 1;
        }
        
        /* Тултип */
        .tooltip-text {
            position: absolute;
            bottom: -30px;
            left: 50%;
            transform: translateX(-50%);
            background: rgba(0, 0, 0, 0.8);
            color: #FFFFFF;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 12px;
            white-space: nowrap;
            border: 1px solid rgba(255, 255, 255, 0.2);
            backdrop-filter: blur(4px);
            opacity: 0;
            transition: opacity 0.3s;
            pointer-events: none;
        }
        
        .smart-button:hover .tooltip-text {
            opacity: 1;
        }
        
        /* Анимации */
        @keyframes pulse {
            0%, 100% { 
                border-color: rgba(255, 255, 255, 0.5);
                width: 45px;
                height: 45px;
            }
            50% { 
                border-color: rgba(255, 255, 255, 0.8);
                width: 50px;
                height: 50px;
            }
        }
        
        @keyframes crawl {
            0%, 100% { transform: translate(-50%, -50%) rotate(0deg); }
            25% { transform: translate(-50%, -50%) rotate(10deg); }
            75% { transform: translate(-50%, -50%) rotate(-10deg); }
        }
        
        /* Прогресс-бар прокрутки (опционально) */
        .scroll-progress {
            position: fixed;
            top: 0;
            left: 0;
            width: 0%;
            height: 3px;
            background: linear-gradient(90deg, #00FF00, #FFFFFF);
            z-index: 1001;
            transition: width 0.1s;
        }
    </style>
</head>
<body>
    <!-- Прогресс-бар прокрутки -->
    <div class="scroll-progress" id="scrollProgress"></div>
    
    <!-- УМНАЯ КНОПКА -->
    <div class="smart-button" id="smartButton" onclick="window.scrollTo({top: 0, behavior: 'smooth'});">
        <div class="web-design">
            <div class="web-outer"></div>
            <div class="web-middle"></div>
            <div class="web-inner"></div>
            <div class="web-line line-0"></div>
            <div class="web-line line-45"></div>
            <div class="web-line line-90"></div>
            <div class="web-line line-135"></div>
            <div class="spider-icon">🕷️</div>
        </div>
        <div class="arrow-up">↑</div>
        <div class="tooltip-text">Наверх</div>
    </div>

<div class="container">
    <h1>🔍 CAP_NET_RAW</h1>
    
    <!-- Блок статуса -->
    <div class="status-box">
        {% if cap %}
            <div class="status-ok">✅ CAP_NET_RAW АКТИВНА</div>
            <p style="text-align: center; font-size: 24px; color: #00FF00;">Raw socket создаётся успешно</p>
        {% else %}
            <div class="status-no">❌ CAP_NET_RAW ОТСУТСТВУЕТ</div>
            <p style="text-align: center; font-size: 24px; color: #FF0000;">Raw socket не работает (Permission denied)</p>
        {% endif %}
    </div>
    
    <!-- Информация о процессе и файле -->
    <div class="info-grid">
        <div class="info-card">
            <div class="info-label">PID процесса</div>
            <div class="info-value">{{ pid }}</div>
            <div class="info-desc">Уникальный идентификатор процесса в системе. Каждый запуск получает новый PID.</div>
        </div>
        <div class="info-card">
            <div class="info-label">INODE файла</div>
            <div class="info-value">{{ inode }}</div>
            <div class="info-desc">Указатель на файл в файловой системе. К этому INODE приклеивается capability.</div>
        </div>
    </div>
    
    <!-- Информация о файле -->
    <div class="info-card" style="margin-bottom: 30px;">
        <div class="info-label">ПУТЬ К ФАЙЛУ</div>
        <div class="code-block">{{ exe }}</div>
        <div class="info-desc">Исполняемый файл. Capability привязана к конкретному файлу (INODE).</div>
    </div>
    
    <!-- Статус capability -->
    <div class="terminal-box">
        <pre>$ getcap {{ exe.split('/')[-1] }}</pre>
        <pre>{{ cap_info }}</pre>
    </div>
    
    <!-- Кнопки управления -->
    <div class="button-grid">
        <button class="action-button" onclick="testCap()">
            🧪 ТЕСТ<br>
            <small style="font-size: 14px;">Проверить raw socket</small>
        </button>
        
        <button class="action-button" onclick="location.reload()">
            🔄 ОБНОВИТЬ<br>
            <small style="font-size: 14px;">Обновить статус</small>
        </button>
        
        <button class="action-button" onclick="window.open('https://man7.org/linux/man-pages/man7/capabilities.7.html', '_blank')">
            📚 ДОКИ<br>
            <small style="font-size: 14px;">man capabilities</small>
        </button>
    </div>
    
    {% if not cap %}
    <!-- Инструкция по установке -->
    <div class="warning-box">
        <p style="font-size: 28px; text-align: center;">⚠️ CAPABILITY НЕ УСТАНОВЛЕНА</p>
        <p style="font-size: 20px;">Выполните в терминале:</p>
        <div class="code-block" style="font-size: 20px; text-align: center; background: #000; color: #0F0;">
            sudo setcap cap_net_raw+ep {{ exe.split('/')[-1] }}
        </div>
        <p style="font-size: 18px; margin-top: 20px;">
            <strong>Что это даёт?</strong> Приклеивает capability к файлу.<br>
            <strong>Почему нужно sudo?</strong> Изменение capability требует прав root.<br>
            <strong>Что такое +ep?</strong> +e = active, +p = permitted.
        </p>
    </div>
    {% endif %}
    
    <!-- Длинный контент для прокрутки -->
    <div class="scroll-content">
        <!-- Подробное объяснение (4 блока) -->
        <h2>📖 ПОДРОБНОЕ ОБЪЯСНЕНИЕ</h2>
        
        <div class="explanation-grid">
            <div class="explanation-card">
                <h4>1️⃣ Что такое capabilities?</h4>
                <p>В Linux права root разделены на мелкие "способности". Вместо полного sudo даём только нужное.</p>
                <p><strong>CAP_NET_RAW</strong> - разрешение на raw socket'ы.</p>
                <div class="command"># Список всех capability<br>man capabilities</div>
            </div>
            
            <div class="explanation-card">
                <h4>2️⃣ Почему падает без прав?</h4>
                <p>Код в ядре Linux:</p>
                <div class="command">socket(AF_PACKET, SOCK_RAW, ...)<br>↓<br>if (!capable(CAP_NET_RAW))<br>    return -EPERM;</div>
                <p>Без capability → Permission denied</p>
            </div>
            
            <div class="explanation-card">
                <h4>3️⃣ Что делает setcap?</h4>
                <p>Приклеивает capability к INODE файла:</p>
                <div class="command">setcap cap_net_raw+ep ./binary</div>
                <p><strong>+e</strong> = effective (активна)<br><strong>+p</strong> = permitted (разрешена)</p>
            </div>
            
            <div class="explanation-card">
                <h4>4️⃣ Почему теряется?</h4>
                <p>При пересборке создаётся новый файл → новый INODE:</p>
                <div class="command"># Было<br>INODE: 123456 + cap<br><br># Пересобрали<br>INODE: 789012 - cap потеряна</div>
                <p>Нужно выполнить setcap заново.</p>
            </div>
        </div>
        
        <!-- Где применяется -->
        <h2 style="margin-top: 50px;">🔧 ГДЕ ПРИМЕНЯЕТСЯ В РЕАЛЬНОСТИ</h2>
        <div class="info-card">
            <ul style="font-size: 20px; margin-left: 30px;">
                <li><strong>tcpdump</strong> - сниффинг трафика (CAP_NET_RAW + CAP_NET_ADMIN)</li>
                <li><strong>ping</strong> - отправка ICMP пакетов через raw socket</li>
                <li><strong>Docker/контейнеры</strong> - для сетевых операций</li>
                <li><strong>Wireshark</strong> - захват пакетов</li>
                <li><strong>Системы IDS/IPS</strong> - анализ сетевого трафика</li>
            </ul>
        </div>
        
        <!-- Ссылки на документацию -->
        <h2 style="margin-top: 50px;">📚 ДОКУМЕНТАЦИЯ</h2>
        <div class="info-grid">
            <div class="info-card">
                <h3 style="margin-bottom: 15px;">man-страницы</h3>
                <ul style="font-size: 18px;">
                    <li><a href="https://man7.org/linux/man-pages/man7/capabilities.7.html" target="_blank">capabilities(7)</a> - полный список</li>
                    <li><a href="https://man7.org/linux/man-pages/man8/setcap.8.html" target="_blank">setcap(8)</a> - установка capability</li>
                    <li><a href="https://man7.org/linux/man-pages/man8/getcap.8.html" target="_blank">getcap(8)</a> - просмотр capability</li>
                </ul>
            </div>
            <div class="info-card">
                <h3 style="margin-bottom: 15px;">Документация ядра</h3>
                <ul style="font-size: 18px;">
                    <li><a href="https://www.kernel.org/doc/html/latest/security/credentials.html" target="_blank">Credentials in Linux</a></li>
                    <li><a href="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/capability.h" target="_blank">capability.h в ядре</a></li>
                </ul>
            </div>
        </div>
        
        <!-- Логи -->
        <h2 style="margin-top: 50px;">📋 ЖУРНАЛ СОБЫТИЙ</h2>
        <div class="log-box">
            {% for log in logs %}
                <div>{{ log }}</div>
            {% endfor %}
        </div>
    </div>
    
    <div class="footer">
        <p>Linux Capabilities Demo</p>
        
    </div>
</div>

<script>
// Функция тестирования capability
function testCap() {
    fetch('/test')
        .then(r => r.json())
        .then(d => {
            if (d.cap) {
                alert('✅ RAW SOCKET РАБОТАЕТ!\n\nCapability CAP_NET_RAW активна.');
            } else {
                alert('❌ RAW SOCKET НЕ РАБОТАЕТ!\n\nВыполните:\nsudo setcap cap_net_raw+ep ./linux-cap-demo');
            }
            location.reload();
        })
        .catch(e => alert('Ошибка: ' + e));
}

// УМНАЯ КНОПКА - появляется после прокрутки на 50%
const smartButton = document.getElementById('smartButton');
const scrollProgress = document.getElementById('scrollProgress');

function checkScroll() {
    // Высота окна
    const windowHeight = window.innerHeight;
    
    // Полная высота документа
    const documentHeight = document.documentElement.scrollHeight;
    
    // Текущая позиция прокрутки
    const scrollTop = window.scrollY || document.documentElement.scrollTop;
    
    // Максимальная прокрутка
    const maxScroll = documentHeight - windowHeight;
    
    // Процент прокрутки
    const scrollPercent = (scrollTop / maxScroll) * 100;
    
    // Обновляем прогресс-бар
    scrollProgress.style.width = scrollPercent + '%';
    
    // Показываем кнопку после 50% прокрутки
    if (scrollPercent >= 50) {
        smartButton.classList.add('visible');
    } else {
        smartButton.classList.remove('visible');
    }
}

// Слушаем событие прокрутки
window.addEventListener('scroll', checkScroll);
// Проверяем сразу при загрузке
window.addEventListener('load', checkScroll);

// Автообновление каждые 3 секунды
// setTimeout(() => location.reload(), 3000);
</script>
</body>
</html>
HTMLEOF

    print_status "Умная кнопка готова"
}

# ===========================================
# БИНАРНИК
# ===========================================
build_binary() {
    print_warn "Сборка бинарника..."
    cd app
    pyinstaller --onefile --name linux-cap-demo \
        --add-data "templates:templates" \
        --noconsole \
        --clean \
        main.py > /dev/null 2>&1
    
    if [[ -f "dist/linux-cap-demo" ]]; then
        mv dist/linux-cap-demo ../dist/
        chmod +x ../dist/linux-cap-demo
        print_status "Бинарник готов"
    else
        print_error "Ошибка сборки"
        cd ..
        return 1
    fi
    cd ..
}

# ===========================================
# ЗАПУСК
# ===========================================
run_demo() {
    if [[ ! -f "$PROJECT_DIR/dist/linux-cap-demo" ]]; then
        print_warn "Бинарник не найден. Собираем..."
        setup_python_env
        generate_app
        build_binary
    fi
    
    print_status "🌐 Сервер: http://localhost:5000"
    print_warn "Ctrl+C для остановки"
    echo
    
    cd "$PROJECT_DIR"
    ./dist/linux-cap-demo
}

# ===========================================
# МЕНЮ
# ===========================================
show_menu() {
    clear
    echo -e "${WHITE}"
    cat << 'EOF'
╔══════════════════════════════════════════════╗
║ 🔥 CAP_NET_RAW Demo v2.8 - SMART BUTTON     ║
╠══════════════════════════════════════════════╣
║  1) 🏠 Запустить демо (умная кнопка)         ║
║  2) 🔨 Только сборка бинарника               ║
║  3) 🧹 Очистка                               ║
║  0) 🚪 Выход                                 ║
╚══════════════════════════════════════════════╝
EOF
    echo -e "${NC}${YELLOW}> Выбор: ${NC}"
}

# ===========================================
# ОСНОВНОЙ ЦИКЛ
# ===========================================
trap cleanup EXIT INT TERM

while true; do
    show_menu
    read -r choice
    
    case "${choice:-x}" in
        1)
            [[ -z "$PROJECT_DIR" ]] && create_project
            [[ $VENV_ACTIVE -eq 0 ]] && setup_python_env
            [[ ! -f "$PROJECT_DIR/dist/linux-cap-demo" ]] && { generate_app; build_binary; }
            run_demo
            ;;
        2)
            [[ -z "$PROJECT_DIR" ]] && create_project
            [[ $VENV_ACTIVE -eq 0 ]] && setup_python_env
            generate_app
            build_binary
            echo -e "${YELLOW}[Enter] для продолжения...${NC}"
            read -r _
            ;;
        3)
            cleanup
            print_status "Очищено"
            sleep 1
            ;;
        0|q|Q)
            cleanup
            print_status "До свидания!"
            exit 0
            ;;
        *)
            print_error "0-3"
            sleep 1
            ;;
    esac
done