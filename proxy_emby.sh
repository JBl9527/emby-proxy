#!/bin/bash

echo "================================================="
echo "       Emby 反向代理 Nginx 配置生成脚本      "
echo "================================================="

# 1. 收集本地服务器信息
echo -n "👉 请输入你这台 VPS 的 IP 或域名 (例如: 1.2.3.4): "
read VPS_HOST
echo -n "👉 请输入你想使用的本地访问端口 (例如: 8096): "
read VPS_PORT

echo ""
echo "================================================="
# 2. 收集目标 Emby 服信息
echo -n "👉 请输入目标 Emby 服的域名 (例如: emby.example.com): "
read TARGET_DOMAIN
echo -n "👉 请输入目标 Emby 服的端口 (公共服若是HTTPS通常是 443): "
read TARGET_PORT

# 简单的容错处理
if [ -z "$VPS_HOST" ] || [ -z "$VPS_PORT" ] || [ -z "$TARGET_DOMAIN" ] || [ -z "$TARGET_PORT" ]; then
    echo "❌ 错误: 所有参数都必须填写！脚本已退出。"
    exit 1
fi

# 检查 Nginx 配置目录是否存在
CONFIG_DIR="/etc/nginx/conf.d"
if [ ! -d "$CONFIG_DIR" ]; then
    echo "🔧 目录 $CONFIG_DIR 不存在，正在创建..."
    mkdir -p "$CONFIG_DIR"
fi

CONFIG_FILE="$CONFIG_DIR/emby_proxy_${VPS_PORT}.conf"

# 3. 生成并写入 Nginx 配置
# 注意：此处的 EOF 不加引号，允许变量解析，但 Nginx 原生变量需要加 \ 转义
cat > "$CONFIG_FILE" <<EOF
server {
    listen $VPS_PORT;
    server_name $VPS_HOST;

    client_max_body_size 5000M;
    proxy_cache off;
    proxy_redirect off;
    proxy_buffering off;

    location / {
        # 强制使用 https 转发目标域名
        proxy_pass https://$TARGET_DOMAIN:$TARGET_PORT;
        
        # 伪装 Host 为目标域名
        proxy_set_header Host $TARGET_DOMAIN;
        
        # 开启 SNI (核心破防配置，解决 502 错误)
        proxy_ssl_server_name on;
        proxy_ssl_verify off;

        # Emby 流媒体与 WebSocket 必备配置
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 传递真实 IP
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 86400;
    }
}
EOF

echo ""
echo "================================================="
echo "✅ 恭喜！反代配置已成功生成！"
echo "📄 文件已保存至: $CONFIG_FILE"
echo ""
echo "请执行以下命令检查并重启 Nginx 使配置生效:"
echo "  nginx -t && systemctl reload nginx"
echo "================================================="
echo "🎉 生效后，你可以通过以下地址访问:"
echo "  http://$VPS_HOST:$VPS_PORT"
echo "================================================="
