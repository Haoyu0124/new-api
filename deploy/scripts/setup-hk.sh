#!/usr/bin/env bash
# =============================================================================
# setup-hk.sh  —  香港边缘节点一键部署脚本
# 用法: bash setup-hk.sh --italy-ip <意大利IP> --domain <域名>
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
ITALY_IP=""
DOMAIN=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --italy-ip) ITALY_IP="$2"; shift 2 ;;
    --domain)   DOMAIN="$2";   shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$ITALY_IP" ]] && read -rp "输入意大利服务器 IP: " ITALY_IP
[[ -z "$DOMAIN"   ]] && read -rp "输入 API 域名 (如 api.apexlogiclabs.com): " DOMAIN
[[ -z "$ITALY_IP" || -z "$DOMAIN" ]] && die "必须提供意大利 IP 和域名"

# ── 1. 系统依赖 ───────────────────────────────────────────────────────────────
info "安装系统依赖..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release ufw fail2ban

# ── 2. 安装 OpenResty（替代标准 Nginx，内置 LuaJIT）────────────────────────
if ! command -v openresty &>/dev/null; then
  info "安装 OpenResty..."
  # 停止已有 Nginx 避免端口冲突
  systemctl stop nginx 2>/dev/null || true
  systemctl disable nginx 2>/dev/null || true

  curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/openresty.gpg
  echo "deb [signed-by=/usr/share/keyrings/openresty.gpg] http://openresty.org/package/ubuntu $(lsb_release -sc) main" \
    > /etc/apt/sources.list.d/openresty.list
  apt-get update -qq
  apt-get install -y -qq openresty

  # openresty 的 sites-available/enabled 目录
  mkdir -p /etc/openresty/sites-available /etc/openresty/sites-enabled
  ok "OpenResty 安装完成: $(openresty -v 2>&1 | head -1)"
else
  ok "OpenResty 已存在"
fi

# ── 3. certbot SSL 证书 ───────────────────────────────────────────────────────
info "安装 certbot..."
apt-get install -y -qq certbot python3-certbot-nginx || \
  snap install --classic certbot 2>/dev/null || true

# 检查是否已有证书
SSL_DIR="/etc/openresty/ssl"
mkdir -p "$SSL_DIR"
CERT_PATH="$SSL_DIR/$DOMAIN"

if [[ ! -f "$CERT_PATH/fullchain.pem" ]]; then
  info "申请 Let's Encrypt 证书（域名 $DOMAIN 必须已指向本机 IP）..."

  # 临时起一个 HTTP 服务用于 ACME challenge
  # 先确保 OpenResty 没跑，或者用 standalone 模式
  openresty -s stop 2>/dev/null || true
  certbot certonly --standalone -d "$DOMAIN" \
    --non-interactive --agree-tos \
    --register-unsafely-without-email \
    --preferred-challenges http

  # certbot 证书路径：/etc/letsencrypt/live/$DOMAIN/
  mkdir -p "$CERT_PATH"
  ln -sf /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem "$CERT_PATH/fullchain.pem"
  ln -sf /etc/letsencrypt/live/"$DOMAIN"/privkey.pem  "$CERT_PATH/privkey.pem"
  ok "SSL 证书申请成功"
else
  ok "SSL 证书已存在，跳过申请"
fi

# ── 4. 部署 Lua 内容过滤脚本 ─────────────────────────────────────────────────
info "部署 Lua 内容过滤脚本..."
mkdir -p /etc/openresty/lua
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 复制 Lua 脚本和词库（如果从本地部署）
if [[ -f "$SCRIPT_DIR/lua/content_filter.lua" ]]; then
  cp "$SCRIPT_DIR/lua/content_filter.lua" /etc/openresty/lua/
  cp "$SCRIPT_DIR/lua/sensitive_words.txt" /etc/openresty/lua/
  ok "Lua 脚本已复制"
else
  warn "未找到本地 Lua 脚本，使用内嵌版本..."
  # 内嵌最小版本（fallback）
  cat > /etc/openresty/lua/content_filter.lua << 'LUAEOF'
local cjson = require "cjson.safe"
local uri = ngx.var.uri
if not (uri:match("^/v1/") or uri:match("^/api/v1/")) then return end
if ngx.req.get_method() ~= "POST" then return end
ngx.req.read_body()
local body_data = ngx.req.get_body_data()
if not body_data then return end
local body = cjson.decode(body_data)
if not body or type(body) ~= "table" then return end
local text_parts = {}
if body.messages then
  for _, msg in ipairs(body.messages) do
    if msg.role == "user" or msg.role == "system" then
      if type(msg.content) == "string" then text_parts[#text_parts+1] = msg.content
      elseif type(msg.content) == "table" then
        for _, b in ipairs(msg.content) do
          if b.type == "text" and b.text then text_parts[#text_parts+1] = b.text end
        end
      end
    end
  end
end
local full_text = table.concat(text_parts, " "):lower()
local f = io.open("/etc/openresty/lua/sensitive_words.txt", "r")
if not f then return end
for line in f:lines() do
  line = line:match("^%s*(.-)%s*$")
  if line ~= "" and line:sub(1,1) ~= "#" and full_text:find(line:lower(), 1, true) then
    f:close()
    ngx.log(ngx.WARN, "content_filter blocked ip=", ngx.var.remote_addr, " word=", line)
    ngx.status = 400
    ngx.header["Content-Type"] = "application/json"
    ngx.print('{"error":{"message":"Request blocked by content policy.","type":"content_policy_violation","code":"content_filter"}}')
    return ngx.exit(400)
  end
end
f:close()
LUAEOF

  cat > /etc/openresty/lua/sensitive_words.txt << 'WORDSEOF'
制造炸弹
合成毒品
甲基苯丙胺
ddos攻击教程
制造枪支
WORDSEOF
  ok "内嵌 Lua 脚本已写入"
fi

chmod 644 /etc/openresty/lua/content_filter.lua
chmod 644 /etc/openresty/lua/sensitive_words.txt

# ── 5. 写 OpenResty 配置 ──────────────────────────────────────────────────────
info "写入 OpenResty 配置..."

# 主配置引入 sites-enabled
cat > /etc/openresty/nginx.conf << 'MAINCONF'
worker_processes auto;
worker_rlimit_nofile 100000;

error_log /var/log/openresty/error.log warn;
pid       /run/openresty.pid;

events {
    worker_connections 10240;
    use epoll;
    multi_accept on;
}

http {
    include       mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    'rt=$request_time uct=$upstream_connect_time urt=$upstream_response_time';

    access_log /var/log/openresty/access.log main;

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;

    keepalive_timeout   120s;
    keepalive_requests  10000;

    gzip off;  # AI API 响应不压缩，避免影响流式

    lua_package_path "/etc/openresty/lua/?.lua;;";

    include /etc/openresty/sites-enabled/*.conf;
}
MAINCONF

# 代理配置
cat > /etc/openresty/sites-available/api-proxy.conf << PROXYCONF
# 上游：意大利源站
upstream italy_origin {
    server ${ITALY_IP}:443;
    keepalive 256;
    keepalive_requests 10000;
    keepalive_timeout  120s;
}

# HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${CERT_PATH}/privkey.pem;
    ssl_session_cache   shared:SSL:50m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    add_header Strict-Transport-Security "max-age=63072000" always;

    # 高并发调优
    client_max_body_size    100m;
    client_body_buffer_size 128k;
    client_header_timeout   30s;
    client_body_timeout     30s;
    send_timeout            300s;

    # 关键：彻底关闭缓冲（SSE 流式打字机）
    proxy_buffering             off;
    proxy_cache                 off;
    proxy_request_buffering     off;

    # 上游连接参数
    proxy_connect_timeout   10s;
    proxy_send_timeout      300s;
    proxy_read_timeout      300s;
    proxy_http_version      1.1;
    proxy_set_header Connection "";

    # 透传客户端真实 IP
    proxy_set_header X-Real-IP         \$remote_addr;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Host              \$host;

    # 透传 Anthropic/OpenAI 自定义 Headers（Prompt Caching 关键）
    proxy_pass_header anthropic-version;
    proxy_pass_header anthropic-beta;
    proxy_pass_header x-api-key;

    # 忽略意大利端自签证书
    proxy_ssl_verify off;

    location / {
        # Lua 敏感词拦截（在转发前执行）
        access_by_lua_file /etc/openresty/lua/content_filter.lua;

        proxy_pass https://italy_origin;
        proxy_buffering off;

        # CORS（浏览器端工具支持）
        add_header Access-Control-Allow-Origin  * always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type, x-api-key, anthropic-version, anthropic-beta" always;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;

        if (\$request_method = OPTIONS) {
            return 204;
        }
    }

    location = /health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
PROXYCONF

ln -sf /etc/openresty/sites-available/api-proxy.conf /etc/openresty/sites-enabled/
ok "OpenResty 配置已写入"

# ── 6. 语法检查 & 启动 ───────────────────────────────────────────────────────
info "测试 OpenResty 配置语法..."
openresty -t || die "OpenResty 配置语法错误，请检查上方输出"

systemctl enable openresty
systemctl restart openresty
ok "OpenResty 已启动"

# ── 7. 内核 TCP 调优 ──────────────────────────────────────────────────────────
info "内核 TCP 调优..."
cat > /etc/sysctl.d/99-hk-proxy.conf << 'EOF'
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.core.somaxconn = 65535
net.ipv4.ip_local_port_range = 10000 65535
fs.file-max = 1000000
net.core.netdev_max_backlog = 65536
EOF
sysctl -p /etc/sysctl.d/99-hk-proxy.conf >/dev/null

if ! grep -q "nofile 1000000" /etc/security/limits.conf; then
  echo "* soft nofile 1000000" >> /etc/security/limits.conf
  echo "* hard nofile 1000000" >> /etc/security/limits.conf
fi

# ── 8. UFW 防火墙 ────────────────────────────────────────────────────────────
info "配置 UFW..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment "SSH"
ufw allow 80/tcp  comment "HTTP (ACME)"
ufw allow 443/tcp comment "HTTPS API"
ufw --force enable
ok "UFW 配置完成"

# ── 9. certbot 自动续签 ───────────────────────────────────────────────────────
info "配置 certbot 自动续签..."
# 续签钩子：续签后重载 OpenResty
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-openresty.sh << 'EOF'
#!/bin/bash
systemctl reload openresty
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-openresty.sh

# 写 crontab（每天两次检查）
(crontab -l 2>/dev/null | grep -v certbot; echo "0 3,15 * * * certbot renew --quiet --pre-hook 'openresty -s stop' --post-hook 'openresty'") | crontab -
ok "certbot 自动续签已配置"

# ── 10. fail2ban ─────────────────────────────────────────────────────────────
systemctl enable fail2ban
systemctl start fail2ban

# ── 11. 连通性测试 ───────────────────────────────────────────────────────────
info "测试到意大利源站连通性..."
if curl -sk --max-time 10 "https://${ITALY_IP}/health" -o /dev/null; then
  ok "意大利源站可达"
else
  warn "意大利源站暂不可达（可能源站还未部署，或防火墙未开放本机 IP）"
  echo "  本机出口 IP: $(curl -s ifconfig.me)"
  echo "  请在意大利服务器运行: ufw allow from $(curl -s ifconfig.me) to any port 443"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  香港边缘节点部署完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  API 端点: https://${DOMAIN}"
echo "  健康检查: https://${DOMAIN}/health"
echo ""
echo -e "${YELLOW}  验证命令：${NC}"
echo "  curl -N -H 'Authorization: Bearer YOUR_KEY' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"claude-sonnet-4-6\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}' \\"
echo "    https://${DOMAIN}/v1/chat/completions"
echo ""
echo "  查看过滤日志: tail -f /var/log/openresty/error.log | grep content_filter"
