#!/bin/bash
# ==========================================
# Emby 多端口中转发车面板 (安全加强 & 热更新版)
# ==========================================

if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本"
  exit 1
fi

echo ">>> 正在初始化 Emby 中转面板环境..."

# 创建工作目录
mkdir -p /opt/emby-proxy

# 1. 智能交互配置 (支持热更新时静默跳过)
if [ -f "/opt/emby-proxy/domain.txt" ]; then
    USER_DOMAIN=$(cat /opt/emby-proxy/domain.txt)
    echo ">>> 检测到已配置域名: $USER_DOMAIN，跳过输入"
else
    read -p "请输入你已解析到本 VPS 的管理面板域名 (如: panel.yourdomain.com): " USER_DOMAIN
    echo "$USER_DOMAIN" > /opt/emby-proxy/domain.txt
fi

if [ -f "/opt/emby-proxy/password.txt" ]; then
    WEB_PASSWORD=$(cat /opt/emby-proxy/password.txt)
    echo ">>> 检测到已配置密码，跳过输入"
else
    read -p "请设置 Web 面板的登录密码 (必填，用于安全防护): " WEB_PASSWORD
    echo "$WEB_PASSWORD" > /opt/emby-proxy/password.txt
fi

if [ ! -f "/opt/emby-proxy/config.json" ]; then
    echo "[]" > /opt/emby-proxy/config.json
fi

# 2. 清理可能冲突的老程序
systemctl stop realm 2>/dev/null
systemctl disable realm 2>/dev/null

# 3. 安装依赖 (如果已安装会自动跳过)
echo ">>> 正在检查并安装依赖环境..."
apt update -y
apt install -y python3 python3-pip python3-flask curl
pip3 install Flask --break-system-packages 2>/dev/null

# 4. 安装 Caddy
if ! command -v caddy &> /dev/null; then
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt update -y
    apt install -y caddy
fi

# 5. 生成 Python 后端与带密码验证的 UI 完整代码
cat << 'EOF' > /opt/emby-proxy/app.py
from flask import Flask, request, jsonify, session, redirect, url_for
import subprocess
import json
import os

app = Flask(__name__)
app.secret_key = "emby_proxy_super_secret_key" # 用于 Session 加密

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
    subprocess.run(['systemctl', 'reload', 'caddy'], check=True)

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
                alert("指令已下发！系统正在后台静默更新，请在 10 秒后手动刷新本页面。");
            } catch (err) {}
        }
    </script>
</body>
</html>
"""

# --- 路由拦截器：强制登录验证 ---
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
            return "<script>alert('密码错误！你是不是想跑路？');window.location.href='/login';</script>"
    return LOGIN_HTML

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/')
def index():
    return PANEL_HTML

# --- API 核心逻辑 ---
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
        return jsonify({"success": False, "message": "配置错误或端口被占用"})

@app.route('/api/delete', methods=['POST'])
def delete_rule():
    vps_port = request.json.get('vps_port')
    rules = load_rules()
    save_rules([r for r in rules if r['vps_port'] != vps_port])
    generate_and_reload_caddy()
    return jsonify({"success": True})

@app.route('/api/update', methods=['POST'])
def update_script():
    # 核心热更新逻辑：在后台静默执行 GitHub 最新的 shell 脚本
    os.system("bash -c 'sleep 1; curl -sL https://raw.githubusercontent.com/JBl9527/emby-proxy/main/proxy_emby.sh | bash' &")
    return jsonify({"success": True})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF

# 6. 配置系统服务
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
systemctl enable emby-proxy-web
systemctl restart emby-proxy-web

# 7. 重构并重启 Caddy (如果在更新，它会自动读取 config.json 并保持现有转发)
cat << EOF > /etc/caddy/Caddyfile
$USER_DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

# 如果有历史转发规则，触发一次自动重载融合
if [ -s /opt/emby-proxy/config.json ] && [ "$(cat /opt/emby-proxy/config.json)" != "[]" ]; then
    python3 -c "from app import generate_and_reload_caddy; generate_and_reload_caddy()" 2>/dev/null
else
    systemctl restart caddy
fi

echo "=========================================="
echo "🎉 安全加强版 Emby 中转面板 部署/更新完成！"
echo "👉 请访问: https://$USER_DOMAIN"
echo "=========================================="
