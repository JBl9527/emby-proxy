#!/bin/bash
# ==========================================
# Emby 多端口中转发车面板 (防死锁增强版)
# ==========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本${RESET}"
  exit 1
fi

install_or_update() {
    echo -e "${GREEN}>>> 正在初始化 Emby 中转面板环境...${RESET}"
    mkdir -p /opt/emby-proxy

    if [ -f "/opt/emby-proxy/domain.txt" ]; then
        USER_DOMAIN=$(cat /opt/emby-proxy/domain.txt)
        echo -e "${YELLOW}>>> 检测到已配置域名: $USER_DOMAIN，保留原配置${RESET}"
    else
        read -p "请输入你已解析到本 VPS 的管理面板域名 (如: panel.yourdomain.com): " USER_DOMAIN
        echo "$USER_DOMAIN" > /opt/emby-proxy/domain.txt
    fi

    if [ -f "/opt/emby-proxy/password.txt" ]; then
        echo -e "${YELLOW}>>> 检测到已配置密码，保留原配置${RESET}"
    else
        read -p "请设置 Web 面板的登录密码 (必填，用于安全防护): " WEB_PASSWORD
        echo "$WEB_PASSWORD" > /opt/emby-proxy/password.txt
    fi

    if [ ! -f "/opt/emby-proxy/config.json" ]; then
        echo "[]" > /opt/emby-proxy/config.json
    fi

    echo -e "${GREEN}>>> 正在检查并安装依赖环境 (Python, Caddy)...${RESET}"
    apt update -y > /dev/null 2>&1
    apt install -y python3 python3-pip python3-flask curl > /dev/null 2>&1
    pip3 install Flask --break-system-packages > /dev/null 2>&1

    if ! command -v caddy &> /dev/null; then
        apt install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
        apt update -y > /dev/null 2>&1
        apt install -y caddy > /dev/null 2>&1
    fi

    cat << 'EOF' > /opt/emby-proxy/app.py
from flask import Flask, request, jsonify, session, redirect, url_for
import subprocess
import json
import os

app = Flask(__name__)
app.secret_key = "emby_proxy_super_secret_key"

CONFIG_FILE = '/opt/emby-proxy/config.json'
DOMAIN_FILE = '/opt/emby-proxy/domain.txt'
PASS_FILE = '/opt/emby-proxy/password.txt'

def get_domain():
    with open(DOMAIN_FILE, 'r') as f:
        return f.read().strip()

def get_password():
    with open(PASS_FILE, 'r') as f:
        return f.read().strip()

def load_rules():
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            return json.load(f)
    return []

def save_rules(rules):
    with open(CONFIG_FILE, 'w') as f:
        json.dump(rules, f, indent=4)

def generate_and_reload_caddy():
    domain = get_domain()
    rules = load_rules()
    caddyfile_content = f"{domain} {{\n    reverse_proxy 127.0.0.1:5000\n}}\n\n"
    
    for rule in rules:
        emby_host = rule['emby_host']
        emby_port = rule['emby_port']
        vps_port = rule['vps_port']
        scheme = "https" if str(emby_port) in ["443", "8920"] else "http"
        transport_block = """
        transport http {
            tls_insecure_skip_verify
        }""" if scheme == "https" else ""
        
        caddyfile_content += f"""{domain}:{vps_port} {{
    reverse_proxy {scheme}://{emby_host}:{emby_port} {{
        header_up Host "{emby_host}"{transport_block}
    }}
}}
"""
    with open('/etc/caddy/Caddyfile', 'w') as f:
        f.write(caddyfile_content)
    
    # 修复死锁：绕过 systemctl，直接调用 Caddy 原生命令重载，并设置 10 秒超时
    subprocess.run(['caddy', 'reload', '--config', '/etc/caddy/Caddyfile'], check=True, timeout=10)

LOGIN_HTML = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>登录 - Emby 中转核心</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background-color: #f4f7f6; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
        .login-box { background: #fff; padding: 40px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.1); text-align: center; width: 100%; max-width: 320px; }
        input { width: 100%; padding: 12px; margin: 15px 0; border: 1px solid #ddd; border-radius: 6px; box-sizing: border-box; font-size: 14px; }
        button { width: 100%; padding: 12px; background: #00b09b; color: white; border: none; border-radius: 6px; font-weight: bold; cursor: pointer; font-size: 16px; }
        button:hover { background: #009684; }
    </style>
</head>
<body>
    <div class="login-box">
        <h2>🔒 面板安全验证</h2>
        <form method="POST">
            <input type="password" name="password" placeholder="请输入管理员密码" required />
            <button type="submit">进入面板</button>
        </form>
    </div>
</body>
</html>
"""

PANEL_HTML = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Emby 中转管理核心</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background-color: #f4f7f6; margin: 0; padding: 40px 20px; }
        .container { max-width: 800px; margin: 0 auto; background: #fff; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #eee; padding-bottom: 15px; margin-bottom: 30px; }
        h2 { color: #333; margin: 0; }
        .btn-update { background: #f39c12; color: white; padding: 8px 15px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; margin-right: 10px; }
        .btn-logout { background: #95a5a6; color: white; padding: 8px 15px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; text-decoration: none; }
        .add-form { display: flex; gap: 10px; margin-bottom: 30px; flex-wrap: wrap; }
        input { flex: 1; min-width: 150px; padding: 10px; border: 1px solid #ddd; border-radius: 6px; }
        button.add-btn { padding: 10px 20px; background: #00b09b; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; }
        button.delete-btn { background: #ff4757; color: white; padding: 6px 12px; border: none; border-radius: 6px; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #eee; }
        th { background-color: #f8f9fa; color: #555; }
        #status { margin-top: 15px; font-size: 14px; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🚀 Emby 中转控制台</h2>
            <div>
                <button class="btn-update" onclick="updateScript()">🔄 从 GitHub 拉取更新</button>
                <a class="btn-logout" href="/logout">🚪 退出登录</a>
            </div>
        </div>
        
        <h3>➕ 添加转发规则</h3>
        <div class="add-form">
            <input type="text" id="embyHost" placeholder="目标 (如: paolu.emby.media)" />
            <input type="number" id="embyPort" placeholder="目标端口 (如: 443)" />
            <input type="number" id="vpsPort" placeholder="VPS 开放端口 (如: 8888)" />
            <button class="add-btn" onclick="addRule()">保存并应用</button>
        </div>
        <div id="status"></div>

        <h3 style="margin-top: 40px;">📋 运行中的转发服务</h3>
        <table>
            <thead>
                <tr>
                    <th>VPS 端口</th>
                    <th>目标地址</th>
                    <th>目标端口</th>
                    <th>操作</th>
                </tr>
            </thead>
            <tbody id="ruleList"></tbody>
        </table>
    </div>

    <script>
        window.onload = loadRules;

        async function loadRules() {
            const res = await fetch('/api/list');
            const rules = await res.json();
            const tbody = document.getElementById('ruleList');
            tbody.innerHTML = '';
            rules.forEach(rule => {
                tbody.innerHTML += `
                    <tr>
                        <td><strong>${rule.vps_port}</strong></td>
                        <td>${rule.emby_host}</td>
                        <td>${rule.emby_port}</td>
                        <td><button class="delete-btn" onclick="deleteRule(${rule.vps_port})">删除并释放</button></td>
                    </tr>`;
            });
        }

        async function addRule() {
            const status = document.getElementById('status');
            const data = {
                emby_host: document.getElementById('embyHost').value.trim(),
                emby_port: parseInt(document.getElementById('embyPort').value),
                vps_port: parseInt(document.getElementById('vpsPort').value)
            };
            if (!data.emby_host || !data.emby_port || !data.vps_port) {
                status.style.color = 'red'; status.innerText = "请填写完整！"; return;
            }
            status.style.color = '#333'; status.innerText = "⚙️ 正在写入配置...";
            try {
                const res = await fetch('/api/add', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
                const result = await res.json();
                if (result.success) {
                    status.style.color = 'green'; status.innerText = "✅ 添加成功！";
                    document.getElementById('embyHost').value = '';
                    document.getElementById('embyPort').value = '';
                    document.getElementById('vpsPort').value = '';
                    loadRules();
                } else {
                    status.style.color = 'red'; status.innerText = "❌ " + result.message;
                }
            } catch (err) { status.innerText = "网络错误"; }
        }

        async function deleteRule(vpsPort) {
            if(!confirm(`确定要删除端口 ${vpsPort} 吗？系统将自动解除占用。`)) return;
            const res = await fetch('/api/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ vps_port: vpsPort }) });
            if ((await res.json()).success) loadRules();
        }

        async function updateScript() {
            if(!confirm("确定要拉取 GitHub 最新代码并更新面板吗？\n\n期间面板会重启，大约需要等待 5-10 秒。")) return;
            try {
                await fetch('/api/update', { method: 'POST' });
                alert("指令已下发！系统将在后台静默更新，请在 10 秒后手动刷新页面。");
            } catch (err) {}
        }
    </script>
</body>
</html>
"""

@app.before_request
def require_login():
    if request.endpoint not in ['login', 'static'] and not session.get('logged_in'):
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form.get('password') == get_password():
            session['logged_in'] = True
            return redirect(url_for('index'))
        else:
            return "<script>alert('密码错误！');window.location.href='/login';</script>"
    return LOGIN_HTML

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def index():
    return PANEL_HTML

@app.route('/api/list', methods=['GET'])
def list_rules():
    return jsonify(load_rules())

@app.route('/api/add', methods=['POST'])
def add_rule():
    data = request.json
    rules = load_rules()
    for rule in rules:
        if rule['vps_port'] == data['vps_port']:
            return jsonify({"success": False, "message": "端口已存在！"})
    rules.append(data)
    save_rules(rules)
    try:
        generate_and_reload_caddy()
        return jsonify({"success": True})
    except Exception as e:
        rules.pop()
        save_rules(rules)
        generate_and_reload_caddy()
        return jsonify({"success": False, "message": "配置错误或重载超时"})

@app.route('/api/delete', methods=['POST'])
def delete_rule():
    vps_port = request.json.get('vps_port')
    rules = load_rules()
    save_rules([r for r in rules if r['vps_port'] != vps_port])
    generate_and_reload_caddy()
    return jsonify({"success": True})

@app.route('/api/update', methods=['POST'])
def update_script():
    # 修复死锁：使用 Popen 完全脱离当前进程挂起执行，保证 API 瞬间返回
    subprocess.Popen("sleep 2 && /usr/local/bin/emby-proxy 2", shell=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify({"success": True})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF

    cat << EOF > /etc/systemd/system/emby-proxy-web.service
[Unit]
Description=Emby Proxy Web UI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/emby-proxy
ExecStart=/usr/bin/python3 app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable emby-proxy-web > /dev/null 2>&1
    systemctl restart emby-proxy-web

    cat << EOF > /etc/caddy/Caddyfile
$USER_DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

    if [ -s /opt/emby-proxy/config.json ] && [ "$(cat /opt/emby-proxy/config.json)" != "[]" ]; then
        python3 -c "from app import generate_and_reload_caddy; generate_and_reload_caddy()" 2>/dev/null
    else
        systemctl restart caddy
    fi

    if [ ! -f "/usr/local/bin/emby-proxy" ]; then
        echo 'bash <(curl -sL https://raw.githubusercontent.com/JBl9527/emby-proxy/main/proxy_emby.sh) $1' > /usr/local/bin/emby-proxy
        chmod +x /usr/local/bin/emby-proxy
        echo -e "${GREEN}>>> 快捷指令 emby-proxy 已创建生效！${RESET}"
    fi

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "🎉 面板安装/更新完成！"
    echo -e "👉 请访问: https://$USER_DOMAIN"
    echo -e "💡 日常维护只需在终端输入: ${YELLOW}emby-proxy${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

uninstall_panel() {
    echo -e "${RED}>>> 警告：你正在执行彻底卸载操作！${RESET}"
    read -p "将删除所有配置、释放所有端口。确认卸载吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}>>> 已取消卸载操作。${RESET}"
        exit 0
    fi

    echo -e "正在停止服务并删除相关文件..."
    systemctl stop emby-proxy-web caddy 2>/dev/null
    systemctl disable emby-proxy-web caddy 2>/dev/null
    rm -f /etc/systemd/system/emby-proxy-web.service
    systemctl daemon-reload
    rm -rf /opt/emby-proxy
    rm -f /etc/caddy/Caddyfile
    rm -f /usr/local/bin/emby-proxy
    
    echo -e "${GREEN}✅ 卸载完成！所有相关文件和服务已彻底清理干净。${RESET}"
}

show_menu() {
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "   🚀 Emby 中转发车面板 - 一键管理脚本"
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "  ${YELLOW}1.${RESET} 🛠️  安装 / 覆盖更新 面板"
    echo -e "  ${YELLOW}2.${RESET} 🗑️  彻底卸载 面板"
    echo -e "  ${YELLOW}0.${RESET} ❌  退出脚本"
    echo -e "${GREEN}==========================================${RESET}"
    read -p "请输入数字选择操作: " choice

    case $choice in
        1) install_or_update ;;
        2) uninstall_panel ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效，请重新运行脚本。${RESET}" ;;
    esac
}

if [ "$1" == "2" ]; then
    install_or_update
else
    show_menu
fi
