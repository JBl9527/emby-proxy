#!/bin/bash
# ==========================================
# Emby 多端口中转发车面板 (Pro进阶版) - 一键部署脚本
# 适用环境: Ubuntu / Debian
# ==========================================

# 1. 确保以 Root 运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户运行此脚本"
  exit 1
fi

echo ">>> 开始部署 Emby 多端口中转面板..."

# 清理可能冲突的老程序 (比如之前的 Realm)
systemctl stop realm 2>/dev/null
systemctl disable realm 2>/dev/null

# 2. 交互式获取用户域名
read -p "请输入你已解析到本 VPS 的管理面板域名 (例如: panel.yourdomain.com): " USER_DOMAIN

# 3. 安装必要的系统依赖环境
echo ">>> 正在更新系统并安装依赖 (Python, Caddy)..."
apt update -y
apt install -y python3 python3-pip python3-flask curl
pip3 install Flask --break-system-packages 2>/dev/null

# 4. 安装 Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update -y
apt install -y caddy

# 5. 创建工作目录并初始化配置文件
mkdir -p /opt/emby-proxy
echo "$USER_DOMAIN" > /opt/emby-proxy/domain.txt
echo "[]" > /opt/emby-proxy/config.json # 初始化空的规则列表

# 6. 生成 Python 后端与前端 UI 完整代码
cat << 'EOF' > /opt/emby-proxy/app.py
from flask import Flask, request, jsonify
import subprocess
import json
import os

app = Flask(__name__)

CONFIG_FILE = '/opt/emby-proxy/config.json'
DOMAIN_FILE = '/opt/emby-proxy/domain.txt'

def get_domain():
    with open(DOMAIN_FILE, 'r') as f:
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
    
    # 基础面板配置
    caddyfile_content = f"{domain} {{\n    reverse_proxy 127.0.0.1:5000\n}}\n\n"
    
    # 动态生成每个转发规则的块
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
    # 写入并重载
    with open('/etc/caddy/Caddyfile', 'w') as f:
        f.write(caddyfile_content)
    
    subprocess.run(['systemctl', 'reload', 'caddy'], check=True)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Emby 中转管理核心</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background-color: #f4f7f6; margin: 0; padding: 40px 20px; }
        .container { max-width: 800px; margin: 0 auto; background: #fff; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        h2 { color: #333; margin-top: 0; border-bottom: 2px solid #eee; padding-bottom: 15px; }
        .add-form { display: flex; gap: 10px; margin-bottom: 30px; flex-wrap: wrap; }
        input { flex: 1; min-width: 150px; padding: 10px; border: 1px solid #ddd; border-radius: 6px; }
        button { padding: 10px 20px; background: #00b09b; color: white; border: none; border-radius: 6px; cursor: pointer; font-weight: bold; }
        button:hover { background: #009684; }
        button.delete-btn { background: #ff4757; padding: 6px 12px; }
        button.delete-btn:hover { background: #ff2f42; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { text-align: left; padding: 12px; border-bottom: 1px solid #eee; }
        th { background-color: #f8f9fa; color: #555; }
        #status { margin-top: 15px; font-size: 14px; color: #666; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <h2>🚀 添加新的 Emby 转发节点</h2>
        <div class="add-form">
            <input type="text" id="embyHost" placeholder="目标 Emby 域名 (如: hxd.as174.de)" />
            <input type="number" id="embyPort" placeholder="目标端口 (如: 443)" />
            <input type="number" id="vpsPort" placeholder="分配的 VPS 端口 (如: 1443)" />
            <button onclick="addRule()">保存并应用</button>
        </div>
        <div id="status"></div>

        <h2 style="margin-top: 40px;">📋 当前运行中的转发服务</h2>
        <table>
            <thead>
                <tr>
                    <th>VPS 端口</th>
                    <th>目标地址</th>
                    <th>目标端口</th>
                    <th>操作</th>
                </tr>
            </thead>
            <tbody id="ruleList">
                <!-- 列表由 JS 动态渲染 -->
            </tbody>
        </table>
    </div>

    <script>
        // 页面加载时拉取现有规则
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
                    </tr>
                `;
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
                status.style.color = 'red';
                status.innerText = "请填写完整所有参数！";
                return;
            }

            status.style.color = '#333';
            status.innerText = "⚙️ 正在写入配置并重载 Caddy...";

            try {
                const res = await fetch('/api/add', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(data)
                });
                const result = await res.json();
                
                if (result.success) {
                    status.style.color = 'green';
                    status.innerText = "✅ 节点添加成功！";
                    document.getElementById('embyHost').value = '';
                    document.getElementById('embyPort').value = '';
                    document.getElementById('vpsPort').value = '';
                    loadRules();
                } else {
                    status.style.color = 'red';
                    status.innerText = "❌ 添加失败: " + result.message;
                }
            } catch (err) {
                status.style.color = 'red';
                status.innerText = "❌ 网络错误";
            }
        }

        async function deleteRule(vpsPort) {
            if(!confirm("确定要删除端口 " + vpsPort + " 的转发服务吗？Caddy 将自动释放该端口。")) return;
            
            try {
                const res = await fetch('/api/delete', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ vps_port: vpsPort })
                });
                const result = await res.json();
                
                if (result.success) {
                    loadRules();
                } else {
                    alert("删除失败: " + result.message);
                }
            } catch (err) {
                alert("网络错误");
            }
        }
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    return HTML_TEMPLATE

@app.route('/api/list', methods=['GET'])
def list_rules():
    return jsonify(load_rules())

@app.route('/api/add', methods=['POST'])
def add_rule():
    data = request.json
    rules = load_rules()
    
    # 检查端口是否已存在，防止重复添加
    for rule in rules:
        if rule['vps_port'] == data['vps_port']:
            return jsonify({"success": False, "message": "该 VPS 端口已在使用了，请换一个！"})
            
    rules.append({
        "emby_host": data['emby_host'],
        "emby_port": data['emby_port'],
        "vps_port": data['vps_port']
    })
    
    save_rules(rules)
    try:
        generate_and_reload_caddy()
        return jsonify({"success": True})
    except Exception as e:
        # 如果重载失败（例如新加的端口被系统其他程序占用了），回滚配置
        rules.pop()
        save_rules(rules)
        generate_and_reload_caddy()
        return jsonify({"success": False, "message": "Caddy 重载失败，可能是该端口已被其他程序占用。"})

@app.route('/api/delete', methods=['POST'])
def delete_rule():
    vps_port = request.json.get('vps_port')
    rules = load_rules()
    
    # 过滤掉要删除的端口
    new_rules = [r for r in rules if r['vps_port'] != vps_port]
    
    save_rules(new_rules)
    try:
        generate_and_reload_caddy()
        return jsonify({"success": True})
    except Exception as e:
        return jsonify({"success": False, "message": str(e)})

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF

# 7. 配置 Systemd 守护进程
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

# 8. 初始化默认 Caddyfile (只有面板，没有转发规则)
cat << EOF > /etc/caddy/Caddyfile
$USER_DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

systemctl restart caddy

echo "=========================================="
echo "🎉 进阶版多端口 Emby 中转面板 部署完成！"
echo "👉 请访问: https://$USER_DOMAIN"
echo "=========================================="
