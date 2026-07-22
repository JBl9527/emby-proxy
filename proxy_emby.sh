#!/bin/bash
# ==========================================
# Emby 多端口中转发车面板 (完整版)
# 功能: 多规则中转 / 密码修改 / 域名更换 / BBR 加速
# ==========================================

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
RESET="\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}请使用 root 用户运行此脚本${RESET}"
  exit 1
fi

# ================= BBR 加速 =================

bbr_status() {
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo -e "${GREEN}已开启${RESET}"
    else
        echo -e "${YELLOW}未开启${RESET}"
    fi
}

enable_bbr() {
    local kver kmaj kmin
    kver=$(uname -r)
    kmaj=${kver%%.*}
    kmin=$(echo "$kver" | cut -d. -f2)

    if [ "$kmaj" -lt 4 ] || { [ "$kmaj" -eq 4 ] && [ "$kmin" -lt 9 ]; }; then
        echo -e "${RED}当前内核 $kver 低于 4.9，不支持 BBR，请先升级内核${RESET}"
        return
    fi

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo -e "${GREEN}BBR 已经是开启状态，无需重复操作${RESET}"
        return
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1

    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        echo -e "${GREEN}✅ BBR 加速开启成功！${RESET}"
    else
        echo -e "${RED}开启失败，请尝试执行 modprobe tcp_bbr 后重试${RESET}"
    fi
}

# ================= 密码修改 =================

change_password() {
    if [ ! -f /opt/emby-proxy/password.txt ]; then
        echo -e "${RED}未检测到安装，请先安装面板${RESET}"
        return
    fi
    local p1 p2
    read -r -s -p "请输入新密码 (至少 6 位，输入不显示): " p1
    echo ""
    read -r -s -p "请再次输入新密码: " p2
    echo ""
    if [ -z "$p1" ] || [ "$p1" != "$p2" ]; then
        echo -e "${RED}两次输入不一致或密码为空${RESET}"
        return
    fi
    if [ ${#p1} -lt 6 ]; then
        echo -e "${RED}密码长度至少 6 位${RESET}"
        return
    fi
    echo "$p1" > /opt/emby-proxy/password.txt
    chmod 600 /opt/emby-proxy/password.txt
    # 删除 session 密钥并重启面板，强制所有已登录会话下线
    rm -f /opt/emby-proxy/secret.key
    systemctl restart emby-proxy-web
    echo -e "${GREEN}✅ 密码已修改，所有会话已注销，请用新密码重新登录${RESET}"
}

# ================= 域名更换 =================

change_domain() {
    if [ ! -f /opt/emby-proxy/domain.txt ]; then
        echo -e "${RED}未检测到安装，请先安装面板${RESET}"
        return
    fi
    local OLD_DOMAIN NEW_DOMAIN PUBLIC_IP RESOLVED c
    OLD_DOMAIN=$(cat /opt/emby-proxy/domain.txt)
    echo -e "当前域名: ${YELLOW}${OLD_DOMAIN}${RESET}"
    read -r -p "请输入新域名 (必须已解析到本 VPS): " NEW_DOMAIN
    NEW_DOMAIN=$(echo "$NEW_DOMAIN" | tr -d '[:space:]')

    if ! [[ "$NEW_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
        echo -e "${RED}域名格式不正确${RESET}"
        return
    fi
    if [ "$NEW_DOMAIN" == "$OLD_DOMAIN" ]; then
        echo -e "${YELLOW}与原域名相同，未做修改${RESET}"
        return
    fi

    # DNS 预检：新域名没解析到本机就换，等于把自己锁在面板外
    PUBLIC_IP=$(curl -s4 --max-time 8 ifconfig.me 2>/dev/null || true)
    RESOLVED=$(getent ahostsv4 "$NEW_DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')
    if [ -n "$PUBLIC_IP" ] && [ "$RESOLVED" != "$PUBLIC_IP" ]; then
        echo -e "${RED}警告: $NEW_DOMAIN 解析到 [$RESOLVED]，本机 IP 是 [$PUBLIC_IP]${RESET}"
        echo -e "${RED}更换后新域名证书无法签发，面板和全部中转都会不可用！${RESET}"
        read -r -p "确认仍要更换吗？[y/N]: " c
        [[ "$c" =~ ^[Yy]$ ]] || return
    fi

    echo "$NEW_DOMAIN" > /opt/emby-proxy/domain.txt
    chmod 600 /opt/emby-proxy/domain.txt

    if (cd /opt/emby-proxy && python3 -c "from app import generate_and_reload_caddy; generate_and_reload_caddy()"); then
        echo -e "${GREEN}✅ 域名更换成功！${RESET}"
        echo -e "👉 新面板地址: ${YELLOW}https://$NEW_DOMAIN${RESET}"
        echo -e "👉 所有中转地址同步变为: ${YELLOW}https://$NEW_DOMAIN:端口${RESET}"
        echo -e "💡 新证书将在首次访问时自动签发（约几秒），80/443 需保持可达"
    else
        echo -e "${RED}配置应用失败，已回滚为原域名${RESET}"
        echo "$OLD_DOMAIN" > /opt/emby-proxy/domain.txt
        (cd /opt/emby-proxy && python3 -c "from app import generate_and_reload_caddy; generate_and_reload_caddy()") || true
    fi
}

# ================= 安装 / 更新 =================

install_or_update() {
    echo -e "${GREEN}>>> 正在初始化 Emby 中转面板环境...${RESET}"
    mkdir -p /opt/emby-proxy

    if [ -f "/opt/emby-proxy/domain.txt" ]; then
        USER_DOMAIN=$(cat /opt/emby-proxy/domain.txt)
        echo -e "${YELLOW}>>> 检测到已配置域名: $USER_DOMAIN，保留原配置${RESET}"
    else
        read -r -p "请输入你已解析到本 VPS 的管理面板域名 (如: panel.yourdomain.com): " USER_DOMAIN
        USER_DOMAIN=$(echo "$USER_DOMAIN" | tr -d '[:space:]')
        if ! [[ "$USER_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
            echo -e "${RED}域名格式不正确，安装中止${RESET}"
            exit 1
        fi
        echo "$USER_DOMAIN" > /opt/emby-proxy/domain.txt
    fi
    chmod 600 /opt/emby-proxy/domain.txt

    if [ -f "/opt/emby-proxy/password.txt" ]; then
        echo -e "${YELLOW}>>> 检测到已配置密码，保留原配置${RESET}"
    else
        read -r -s -p "请设置 Web 面板的登录密码 (输入不显示): " WEB_PASSWORD
        echo ""
        if [ -z "$WEB_PASSWORD" ]; then
            echo -e "${RED}密码不能为空${RESET}"
            exit 1
        fi
        echo "$WEB_PASSWORD" > /opt/emby-proxy/password.txt
    fi
    chmod 600 /opt/emby-proxy/password.txt

    if [ ! -f "/opt/emby-proxy/config.json" ]; then
        echo "[]" > /opt/emby-proxy/config.json
    fi
    chmod 600 /opt/emby-proxy/config.json

    echo -e "${GREEN}>>> 正在检查并安装依赖环境 (Python, Caddy)...${RESET}"
    apt update -y > /dev/null 2>&1
    apt install -y python3 python3-pip python3-flask curl > /dev/null 2>&1
    pip3 install Flask --break-system-packages > /dev/null 2>&1 || pip3 install Flask > /dev/null 2>&1 || true

    if ! command -v caddy &> /dev/null; then
        apt install -y debian-keyring debian-archive-keyring apt-transport-https
        curl -1sLf --max-time 30 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
        curl -1sLf --max-time 30 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
        apt update -y > /dev/null 2>&1
        apt install -y caddy > /dev/null 2>&1
    fi
    command -v caddy >/dev/null 2>&1 || { echo -e "${RED}Caddy 安装失败，中止${RESET}"; exit 1; }

    # ---------- 后端 + 前端 ----------
    cat << 'EOF' > /opt/emby-proxy/app.py
from flask import Flask, request, jsonify, session, redirect, url_for
import subprocess
import json
import os
import re
import secrets

app = Flask(__name__)

CONFIG_FILE = '/opt/emby-proxy/config.json'
DOMAIN_FILE = '/opt/emby-proxy/domain.txt'
PASS_FILE = '/opt/emby-proxy/password.txt'
SECRET_FILE = '/opt/emby-proxy/secret.key'
CADDYFILE = '/etc/caddy/Caddyfile'

RESERVED_PORTS = {80, 443, 5000}
HOST_RE = re.compile(r'^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$')

# session 密钥: 每机随机生成, 硬编码=任何人可伪造登录
def get_secret():
    if not os.path.exists(SECRET_FILE):
        with open(SECRET_FILE, 'w') as f:
            f.write(secrets.token_hex(32))
        os.chmod(SECRET_FILE, 0o600)
    with open(SECRET_FILE, 'r') as f:
        return f.read().strip()

app.secret_key = get_secret()

def get_domain():
    with open(DOMAIN_FILE, 'r') as f:
        return f.read().strip()

def get_password():
    with open(PASS_FILE, 'r') as f:
        return f.read().strip()

def load_rules():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, 'r') as f:
                return json.load(f)
        except Exception:
            return []
    return []

def save_rules(rules):
    tmp = CONFIG_FILE + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(rules, f, indent=4)
    os.replace(tmp, CONFIG_FILE)
    os.chmod(CONFIG_FILE, 0o600)

def norm_rule(data):
    host = str(data.get('emby_host', '')).strip()
    try:
        eport = int(data.get('emby_port'))
        vport = int(data.get('vps_port'))
    except (TypeError, ValueError):
        return None, '端口必须是数字'
    if not HOST_RE.match(host) or '..' in host:
        return None, '目标地址格式不正确（只允许域名或 IPv4）'
    if not (1 <= eport <= 65535) or not (1 <= vport <= 65535):
        return None, '端口必须在 1-65535 之间'
    if vport in RESERVED_PORTS:
        return None, 'VPS 端口 %s 与面板/Caddy 保留端口冲突' % vport
    return {'emby_host': host, 'emby_port': eport, 'vps_port': vport}, None

def generate_and_reload_caddy():
    """生成完整 Caddyfile -> 校验通过才落地 -> 同步 reload 并检查结果。
    磁盘上永远保留最后一份有效配置，这是重启后能正常启动的关键。"""
    domain = get_domain()
    rules = load_rules()
    content = "%s {\n    reverse_proxy 127.0.0.1:5000\n}\n\n" % domain

    for rule in rules:
        host = rule['emby_host']
        eport = int(rule['emby_port'])
        vport = int(rule['vps_port'])
        scheme = "https" if eport in (443, 8920) else "http"
        if scheme == "https":
            proxy = ("reverse_proxy {\n"
                     "        to https://%s:%s\n"
                     "        header_up Host %s\n"
                     "        transport http {\n"
                     "            tls_insecure_skip_verify\n"
                     "        }\n"
                     "    }" % (host, eport, host))
        else:
            proxy = "reverse_proxy http://%s:%s" % (host, eport)
        content += "%s:%s {\n    %s\n}\n\n" % (domain, vport, proxy)

    tmp = CADDYFILE + '.tmp'
    with open(tmp, 'w') as f:
        f.write(content)

    r = subprocess.run(['caddy', 'validate', '--config', tmp, '--adapter', 'caddyfile'],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        os.remove(tmp)
        raise RuntimeError('Caddy 配置校验失败: ' + (r.stderr or r.stdout)[-200:])

    os.replace(tmp, CADDYFILE)

    r = subprocess.run(['systemctl', 'reload', 'caddy'],
                       capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError('caddy reload 失败: ' + (r.stderr or '')[-200:])

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
        .container { max-width: 860px; margin: 0 auto; background: #fff; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #eee; padding-bottom: 15px; margin-bottom: 30px; flex-wrap: wrap; gap: 10px; }
        h2 { color: #333; margin: 0; }
        .btn-update { background: #f39c12; color: white; padding: 8px 15px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; }
        .btn-pass { background: #3498db; color: white; padding: 8px 15px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; }
        .btn-logout { background: #95a5a6; color: white; padding: 8px 15px; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; text-decoration: none; }
        .add-form { display: flex; gap: 10px; margin-bottom: 30px; flex-wrap: wrap; }
        input { flex: 1; min-width: 150px; padding: 10px; border: 1px solid #ddd; border-radius: 6px; }
        button.add-btn { padding: 10px 20px; background: #00b09b; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; }
        button.delete-btn { background: #ff4757; color: white; padding: 6px 12px; border: none; border-radius: 6px; cursor: pointer; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #eee; }
        th { background-color: #f8f9fa; color: #555; }
        a.link { color: #00b09b; text-decoration: none; }
        #status { margin-top: 15px; font-size: 14px; font-weight: bold; word-break: break-all; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h2>🚀 Emby 中转控制台</h2>
            <div>
                <button class="btn-pass" onclick="changePass()">🔑 修改密码</button>
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
                    <th>访问地址 (客户端填这个)</th>
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
            const data = await res.json();
            const tbody = document.getElementById('ruleList');
            tbody.innerHTML = '';
            data.rules.forEach(rule => {
                const url = 'https://' + data.domain + ':' + rule.vps_port;
                tbody.innerHTML += '<tr>' +
                    '<td><a class="link" href="' + url + '" target="_blank"><strong>' + url + '</strong></a></td>' +
                    '<td>' + rule.emby_host + '</td>' +
                    '<td>' + rule.emby_port + '</td>' +
                    '<td><button class="delete-btn" onclick="deleteRule(' + rule.vps_port + ')">删除并释放</button></td>' +
                    '</tr>';
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
                status.style.color = 'red'; status.innerText = '请填写完整！'; return;
            }
            status.style.color = '#333'; status.innerText = '⚙️ 正在校验并写入配置...';
            try {
                const res = await fetch('/api/add', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
                const result = await res.json();
                if (result.success) {
                    status.style.color = 'green';
                    status.innerText = '✅ 添加成功！访问地址: ' + result.url;
                    document.getElementById('embyHost').value = '';
                    document.getElementById('embyPort').value = '';
                    document.getElementById('vpsPort').value = '';
                    loadRules();
                } else {
                    status.style.color = 'red'; status.innerText = '❌ ' + result.message;
                }
            } catch (err) { status.style.color = 'red'; status.innerText = '网络错误'; }
        }

        async function deleteRule(vpsPort) {
            if (!confirm('确定要删除端口 ' + vpsPort + ' 吗？系统将自动解除占用。')) return;
            const res = await fetch('/api/delete', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ vps_port: vpsPort }) });
            if ((await res.json()).success) loadRules();
        }

        async function changePass() {
            const oldP = prompt('请输入当前密码:');
            if (oldP === null) return;
            const newP = prompt('请输入新密码 (至少 6 位):');
            if (newP === null) return;
            const newP2 = prompt('请再次输入新密码:');
            if (newP !== newP2) { alert('两次输入不一致'); return; }
            const res = await fetch('/api/password', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ old_password: oldP, new_password: newP }) });
            const result = await res.json();
            if (result.success) {
                alert('密码已修改，请使用新密码重新登录');
                window.location.href = '/login';
            } else {
                alert('修改失败: ' + result.message);
            }
        }

        async function updateScript() {
            if (!confirm('确定要拉取 GitHub 最新代码并更新面板吗？期间面板会重启，约 5-10 秒。')) return;
            try {
                await fetch('/api/update', { method: 'POST' });
                alert('指令已下发！系统将在后台静默更新，请在 10 秒后手动刷新页面。');
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
    return jsonify({"domain": get_domain(), "rules": load_rules()})

@app.route('/api/add', methods=['POST'])
def add_rule():
    rule, err = norm_rule(request.get_json(silent=True) or {})
    if err:
        return jsonify({"success": False, "message": err})

    rules = load_rules()
    if any(int(r['vps_port']) == rule['vps_port'] for r in rules):
        return jsonify({"success": False, "message": "该 VPS 端口已被其他规则占用！"})

    r = subprocess.run(['ss', '-lntHp', 'sport = :%s' % rule['vps_port']],
                       capture_output=True, text=True)
    if r.stdout.strip() and 'caddy' not in r.stdout:
        return jsonify({"success": False, "message": "端口 %s 已被其他程序占用" % rule['vps_port']})

    rules.append(rule)
    save_rules(rules)
    try:
        generate_and_reload_caddy()
    except Exception as e:
        rules.pop()
        save_rules(rules)
        try:
            generate_and_reload_caddy()
        except Exception:
            pass
        return jsonify({"success": False, "message": str(e)})

    return jsonify({"success": True, "url": "https://%s:%s" % (get_domain(), rule['vps_port'])})

@app.route('/api/delete', methods=['POST'])
def delete_rule():
    try:
        vps_port = int(request.json.get('vps_port'))
    except (TypeError, ValueError):
        return jsonify({"success": False, "message": "端口参数错误"})
    rules = load_rules()
    save_rules([r for r in rules if int(r['vps_port']) != vps_port])
    try:
        generate_and_reload_caddy()
    except Exception:
        pass
    return jsonify({"success": True})

@app.route('/api/password', methods=['POST'])
def change_password_api():
    data = request.get_json(silent=True) or {}
    old = str(data.get('old_password', ''))
    new = str(data.get('new_password', ''))
    if old != get_password():
        return jsonify({"success": False, "message": "原密码错误"})
    if len(new) < 6:
        return jsonify({"success": False, "message": "新密码至少 6 位"})
    with open(PASS_FILE, 'w') as f:
        f.write(new)
    os.chmod(PASS_FILE, 0o600)
    # 轮换 session 密钥，使所有旧登录态立即失效
    with open(SECRET_FILE, 'w') as f:
        f.write(secrets.token_hex(32))
    os.chmod(SECRET_FILE, 0o600)
    app.secret_key = get_secret()
    session.clear()
    return jsonify({"success": True})

@app.route('/api/update', methods=['POST'])
def update_script():
    subprocess.Popen("sleep 2 && /usr/local/bin/emby-proxy 2", shell=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jsonify({"success": True})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF

    # ---------- Systemd ----------
    cat << EOF > /etc/systemd/system/emby-proxy-web.service
[Unit]
Description=Emby Proxy Web UI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/emby-proxy
ExecStart=/usr/bin/python3 app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable emby-proxy-web > /dev/null 2>&1
    systemctl enable caddy > /dev/null 2>&1
    systemctl restart emby-proxy-web

    # ---------- 生成 Caddyfile ----------
    cat << EOF > /etc/caddy/Caddyfile
$USER_DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

    # 已有规则时回写完整配置
    if [ -s /opt/emby-proxy/config.json ] && [ "$(cat /opt/emby-proxy/config.json)" != "[]" ]; then
        (cd /opt/emby-proxy && python3 -c "from app import generate_and_reload_caddy; generate_and_reload_caddy()") \
            || systemctl reload-or-restart caddy
    else
        systemctl reload-or-restart caddy
    fi

    sleep 1
    systemctl is-active --quiet caddy || echo -e "${RED}⚠️ caddy 未在运行，请 journalctl -u caddy -n 50 排查${RESET}"
    systemctl is-active --quiet emby-proxy-web || echo -e "${RED}⚠️ 面板服务未在运行，请 journalctl -u emby-proxy-web -n 50 排查${RESET}"

    # ========== 本次唯一修改点：快捷指令改为"下载到文件再执行"+破缓存参数 ==========
    if [ ! -f "/usr/local/bin/emby-proxy" ]; then
        cat > /usr/local/bin/emby-proxy <<'EOF_SC'
#!/bin/bash
curl -fsSL --max-time 30 "https://raw.githubusercontent.com/JBl9527/emby-proxy/main/proxy_emby.sh?t=$(date +%s)" -o /tmp/proxy_emby.sh || { echo "下载失败"; exit 1; }
sed -i 's/\r$//' /tmp/proxy_emby.sh
bash /tmp/proxy_emby.sh "$@"
EOF_SC
        chmod +x /usr/local/bin/emby-proxy
        echo -e "${GREEN}>>> 快捷指令 emby-proxy 已创建生效！${RESET}"
    fi

    echo -e "${GREEN}==========================================${RESET}"
    echo -e "🎉 面板安装/更新完成！"
    echo -e "👉 请访问: https://$USER_DOMAIN"
    echo -e "💡 日常维护只需在终端输入: ${YELLOW}emby-proxy${RESET}"
    echo -e "${GREEN}==========================================${RESET}"
}

# ================= 卸载 =================

uninstall_panel() {
    echo -e "${RED}>>> 警告：你正在执行彻底卸载操作！${RESET}"
    read -r -p "将删除所有配置、释放所有端口。确认卸载吗？(y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${YELLOW}>>> 已取消卸载操作。${RESET}"
        return
    fi

    echo -e "正在停止服务并删除相关文件..."
    systemctl stop emby-proxy-web caddy 2>/dev/null
    systemctl disable emby-proxy-web caddy 2>/dev/null
    rm -f /etc/systemd/system/emby-proxy-web.service
    systemctl daemon-reload
    rm -rf /opt/emby-proxy
    rm -f /etc/caddy/Caddyfile /etc/caddy/Caddyfile.tmp
    rm -f /usr/local/bin/emby-proxy

    echo -e "${GREEN}✅ 卸载完成！（Caddy 软件包保留，如需删除: apt remove caddy）${RESET}"
    exit 0
}

# ================= 主菜单 =================

show_menu() {
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "   🚀 Emby 中转发车面板 - 一键管理脚本"
    echo -e "${GREEN}==========================================${RESET}"
    echo -e "  BBR 加速状态: $(bbr_status)"
    echo -e "------------------------------------------"
    echo -e "  ${YELLOW}1.${RESET} 🛠️  安装 / 覆盖更新 面板"
    echo -e "  ${YELLOW}2.${RESET} 🔑  修改面板登录密码"
    echo -e "  ${YELLOW}3.${RESET} 🌐  更换面板域名"
    echo -e "  ${YELLOW}4.${RESET} ⚡  开启 BBR 网络加速"
    echo -e "  ${YELLOW}5.${RESET} 🗑️  彻底卸载 面板"
    echo -e "  ${YELLOW}0.${RESET} ❌  退出脚本"
    echo -e "${GREEN}==========================================${RESET}"
    read -r -p "请输入数字选择操作: " choice

    case $choice in
        1) install_or_update ;;
        2) change_password ;;
        3) change_domain ;;
        4) enable_bbr ;;
        5) uninstall_panel ;;
        0) exit 0 ;;
        *) echo -e "${RED}输入无效，请重新选择。${RESET}" ;;
    esac
}

if [ "${1:-}" == "2" ]; then
    install_or_update
else
    while true; do
        show_menu
    done
fi
