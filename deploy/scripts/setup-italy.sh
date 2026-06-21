#!/usr/bin/env bash
# =============================================================================
# setup-italy.sh  —  意大利源站一键部署脚本
# 用法: bash setup-italy.sh [--hk-ip <香港服务器IP>]
# =============================================================================
set -euo pipefail

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

# ── 参数解析 ──────────────────────────────────────────────────────────────────
HK_IP=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --hk-ip) HK_IP="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -z "$HK_IP" ]] && read -rp "输入香港服务器 IP: " HK_IP
[[ -z "$HK_IP" ]] && die "必须提供香港服务器 IP"

# ── 目录 ──────────────────────────────────────────────────────────────────────
DEPLOY_DIR="/opt/new-api"
mkdir -p "$DEPLOY_DIR"/{data,logs,backups}

# ── 1. 系统依赖 ───────────────────────────────────────────────────────────────
info "安装系统依赖..."
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban htop unzip git

# ── 2. 安装 Docker ────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  info "安装 Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  ok "Docker 安装完成"
else
  ok "Docker 已存在: $(docker --version)"
fi

if ! command -v docker compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
  info "安装 Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin
fi

# ── 3. 内核 TCP 调优 ──────────────────────────────────────────────────────────
info "内核 TCP 调优..."
cat > /etc/sysctl.d/99-newapi.conf << 'EOF'
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
sysctl -p /etc/sysctl.d/99-newapi.conf >/dev/null

# 文件描述符
if ! grep -q "nofile 1000000" /etc/security/limits.conf; then
  echo "* soft nofile 1000000" >> /etc/security/limits.conf
  echo "* hard nofile 1000000" >> /etc/security/limits.conf
fi

# ── 4. 生成密钥 ───────────────────────────────────────────────────────────────
ENV_FILE="$DEPLOY_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  warn ".env 已存在，跳过密钥生成（保留现有密钥）"
else
  info "生成随机密钥..."
  DB_PASS=$(openssl rand -hex 24)
  REDIS_PASS=$(openssl rand -hex 24)
  SESSION_SECRET=$(openssl rand -hex 32)
  CRYPTO_SECRET=$(openssl rand -hex 32)

  cat > "$ENV_FILE" << EOF
# 意大利源站环境变量 — 生成于 $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# ⚠️  CRYPTO_SECRET 丢失 = 所有上游 API Key 无法解密，务必备份此文件！
DB_PASSWORD=${DB_PASS}
REDIS_PASSWORD=${REDIS_PASS}
SESSION_SECRET=${SESSION_SECRET}
CRYPTO_SECRET=${CRYPTO_SECRET}
HK_IP=${HK_IP}
EOF
  chmod 600 "$ENV_FILE"
  ok "密钥已写入 $ENV_FILE"
  echo -e "${RED}★ 请立即备份 $ENV_FILE ★${NC}"
fi

# 加载环境变量
set -a; source "$ENV_FILE"; set +a

# ── 5. 写 docker-compose.yml ──────────────────────────────────────────────────
info "写入 docker-compose.yml..."
cat > "$DEPLOY_DIR/docker-compose.yml" << 'COMPOSE'
version: '3.4'

services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://newapi:${DB_PASSWORD}@postgres:5432/newapi
      - REDIS_CONN_STRING=redis://:${REDIS_PASSWORD}@redis:6379
      - SESSION_SECRET=${SESSION_SECRET}
      - CRYPTO_SECRET=${CRYPTO_SECRET}
      - TZ=Europe/Rome
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - BATCH_UPDATE_INTERVAL=5
      - NODE_NAME=italy-origin
      - STREAMING_TIMEOUT=300
      - RELAY_IDLE_CONN_TIMEOUT=90
      - RELAY_MAX_IDLE_CONNS=1000
      - RELAY_MAX_IDLE_CONNS_PER_HOST=200
      - SYNC_FREQUENCY=60
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_started
    networks:
      - new-api-network
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\":true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  redis:
    image: redis:7-alpine
    container_name: redis
    restart: always
    command: >
      redis-server
      --requirepass ${REDIS_PASSWORD}
      --maxmemory 512mb
      --maxmemory-policy allkeys-lru
      --tcp-keepalive 60
      --timeout 0
    volumes:
      - redis_data:/data
    networks:
      - new-api-network

  postgres:
    image: postgres:16-alpine
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: newapi
      POSTGRES_INITDB_ARGS: "--encoding=UTF8 --locale=C"
    volumes:
      - pg_data:/var/lib/postgresql/data
    networks:
      - new-api-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi -d newapi"]
      interval: 10s
      timeout: 5s
      retries: 5
    command: >
      postgres
      -c max_connections=200
      -c shared_buffers=256MB
      -c effective_cache_size=1GB
      -c work_mem=4MB
      -c checkpoint_completion_target=0.9
      -c wal_buffers=16MB

  pg-backup:
    image: postgres:16-alpine
    container_name: pg-backup
    restart: always
    environment:
      PGPASSWORD: ${DB_PASSWORD}
    volumes:
      - ./backups:/backups
    entrypoint: >
      sh -c "while true; do
        sleep 86400;
        FNAME=/backups/newapi_$$(date +%Y%m%d_%H%M%S).sql.gz;
        pg_dump -h postgres -U newapi newapi | gzip > $$FNAME;
        echo \"Backup done: $$FNAME\";
        find /backups -name '*.sql.gz' -mtime +7 -delete;
      done"
    depends_on:
      - postgres
    networks:
      - new-api-network

volumes:
  pg_data:
  redis_data:

networks:
  new-api-network:
    driver: bridge
COMPOSE

# ── 6. 本地 Nginx（意大利端，只允许香港 IP）──────────────────────────────────
info "安装 Nginx（意大利端，源站保护）..."
apt-get install -y -qq nginx

cat > /etc/nginx/sites-available/new-api-origin.conf << EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;

    # 占位证书（意大利端可用自签证书，因为只有香港节点访问）
    ssl_certificate     /etc/nginx/ssl/origin/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/origin/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    # 只允许香港节点 IP
    allow ${HK_IP};
    deny all;

    proxy_buffering             off;
    proxy_cache                 off;
    proxy_request_buffering     off;
    proxy_http_version          1.1;
    proxy_set_header Connection "";
    proxy_set_header X-Real-IP          \$remote_addr;
    proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
    proxy_set_header Host               \$host;
    proxy_read_timeout  300s;
    proxy_send_timeout  300s;
    proxy_connect_timeout 10s;

    location / {
        proxy_pass http://127.0.0.1:3000;
    }

    location = /health {
        access_log off;
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }
}
EOF

# 生成自签证书（仅用于意大利→香港内网通信）
mkdir -p /etc/nginx/ssl/origin
if [[ ! -f /etc/nginx/ssl/origin/fullchain.pem ]]; then
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/origin/privkey.pem \
    -out /etc/nginx/ssl/origin/fullchain.pem \
    -subj "/CN=origin-internal" 2>/dev/null
  ok "自签证书生成完毕"
fi

ln -sf /etc/nginx/sites-available/new-api-origin.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# ── 7. 防火墙 UFW ─────────────────────────────────────────────────────────────
info "配置 UFW 防火墙..."
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
ufw allow from "$HK_IP" to any port 443 comment "HK edge node"
ufw --force enable
ok "UFW 配置完成，仅允许 $HK_IP 访问 443"

# ── 8. fail2ban ───────────────────────────────────────────────────────────────
systemctl enable fail2ban
systemctl start fail2ban

# ── 9. 启动 Docker 服务 ───────────────────────────────────────────────────────
info "拉取镜像并启动服务..."
cd "$DEPLOY_DIR"
docker compose pull
docker compose up -d

# ── 10. 等待健康检查 ──────────────────────────────────────────────────────────
info "等待 new-api 就绪（最多 120s）..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:3000/api/status | grep -q '"success":true'; then
    ok "new-api 健康检查通过！"
    break
  fi
  [[ $i -eq 24 ]] && die "new-api 启动超时，查看日志: docker compose -f $DEPLOY_DIR/docker-compose.yml logs"
  echo -n "."; sleep 5
done

echo ""
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  意大利源站部署完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  new-api 管理面板: http://$(curl -s ifconfig.me):3000"
echo "  (仅本机可访问，通过香港中转后可用)"
echo ""
echo -e "${YELLOW}  下一步：${NC}"
echo "  1. 登录 http://localhost:3000 完成初始设置（默认 root/123456，立即改密）"
echo "  2. 在 new-api 后台添加上游 Anthropic/OpenAI 渠道"
echo "  3. 在香港服务器运行 setup-hk.sh"
echo ""
echo -e "${RED}  ★ 务必备份: $ENV_FILE ★${NC}"
