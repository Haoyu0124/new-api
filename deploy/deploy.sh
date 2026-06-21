#!/usr/bin/env bash
# =============================================================================
# deploy.sh  —  本地一键部署入口
# 从你的 Mac 上运行：bash deploy/deploy.sh
# 需要：SSH 能免密登录两台服务器（或脚本会提示输入密码）
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${BLUE}"
cat << 'BANNER'
  ███╗   ██╗███████╗██╗    ██╗       █████╗ ██████╗ ██╗
  ████╗  ██║██╔════╝██║    ██║      ██╔══██╗██╔══██╗██║
  ██╔██╗ ██║█████╗  ██║ █╗ ██║█████╗███████║██████╔╝██║
  ██║╚██╗██║██╔══╝  ██║███╗██║╚════╝██╔══██║██╔═══╝ ██║
  ██║ ╚████║███████╗╚███╔███╔╝      ██║  ██║██║     ██║
  ╚═╝  ╚═══╝╚══════╝ ╚══╝╚══╝       ╚═╝  ╚═╝╚═╝     ╚═╝
BANNER
echo -e "${NC}"
echo "  New-API 双节点一键部署工具"
echo ""

# ── 收集参数 ──────────────────────────────────────────────────────────────────
read -rp "意大利服务器 SSH (如 root@203.0.113.10): " ITALY_SSH
read -rp "香港服务器 SSH   (如 root@1.2.3.4): "      HK_SSH
read -rp "API 域名          (如 api.apexlogiclabs.com): " DOMAIN
read -rp "SSH 端口 [默认 22]: " SSH_PORT
SSH_PORT="${SSH_PORT:-22}"

# 从 SSH 字符串提取 IP
ITALY_IP=$(echo "$ITALY_SSH" | sed 's/.*@//')
HK_IP=$(echo "$HK_SSH" | sed 's/.*@//')

echo ""
info "配置摘要："
echo "  意大利: $ITALY_SSH"
echo "  香港:   $HK_SSH"
echo "  域名:   $DOMAIN"
echo "  SSH端口: $SSH_PORT"
echo ""
read -rp "确认以上信息正确？[y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "已取消"

# ── SSH 公共参数 ──────────────────────────────────────────────────────────────
SSH_OPTS="-p $SSH_PORT -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"

ssh_exec() {
  local target="$1"; shift
  ssh $SSH_OPTS "$target" "$@"
}

scp_upload() {
  local src="$1"
  local target="$2"
  local dest="$3"
  scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new -r "$src" "${target}:${dest}"
}

# ── 检查 SSH 连通性 ───────────────────────────────────────────────────────────
info "测试 SSH 连通性..."
ssh_exec "$ITALY_SSH" "echo 'Italy OK'" || die "无法连接意大利服务器"
ssh_exec "$HK_SSH"    "echo 'HK OK'"    || die "无法连接香港服务器"
ok "两台服务器均可达"

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 1：部署意大利源站
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}══ 阶段 1/2：部署意大利源站 ══${NC}"

info "上传部署脚本到意大利服务器..."
ssh_exec "$ITALY_SSH" "mkdir -p /tmp/new-api-deploy/scripts"
scp_upload "$DEPLOY_DIR/scripts/setup-italy.sh" "$ITALY_SSH" "/tmp/new-api-deploy/scripts/"

info "在意大利服务器执行部署脚本..."
ssh_exec "$ITALY_SSH" "bash /tmp/new-api-deploy/scripts/setup-italy.sh --hk-ip ${HK_IP}"
ok "意大利源站部署完成"

# ── 获取意大利服务器的实际出口 IP（用于香港防火墙白名单验证）────────────────
ITALY_ACTUAL_IP=$(ssh_exec "$ITALY_SSH" "curl -s ifconfig.me")
info "意大利服务器出口 IP: $ITALY_ACTUAL_IP"

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 2：部署香港边缘节点
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}══ 阶段 2/2：部署香港边缘节点 ══${NC}"

info "上传部署脚本和 Lua 文件到香港服务器..."
ssh_exec "$HK_SSH" "mkdir -p /tmp/new-api-deploy/scripts /tmp/new-api-deploy/lua"
scp_upload "$DEPLOY_DIR/scripts/setup-hk.sh"         "$HK_SSH" "/tmp/new-api-deploy/scripts/"
scp_upload "$DEPLOY_DIR/lua/content_filter.lua"       "$HK_SSH" "/tmp/new-api-deploy/lua/"
scp_upload "$DEPLOY_DIR/lua/sensitive_words.txt"      "$HK_SSH" "/tmp/new-api-deploy/lua/"

info "在香港服务器执行部署脚本..."
ssh_exec "$HK_SSH" "bash /tmp/new-api-deploy/scripts/setup-hk.sh --italy-ip ${ITALY_IP} --domain ${DOMAIN}"
ok "香港边缘节点部署完成"

# ══════════════════════════════════════════════════════════════════════════════
# 阶段 3：自动化验证
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLUE}══ 阶段 3/3：连通性验证 ══${NC}"

info "验证香港 → 意大利链路..."
HK_TO_ITALY=$(ssh_exec "$HK_SSH" "curl -sk --max-time 10 https://${ITALY_IP}/health && echo PASS || echo FAIL")
if [[ "$HK_TO_ITALY" == *"PASS"* ]]; then
  ok "香港 → 意大利：PASS"
else
  warn "香港 → 意大利：FAIL（可能意大利防火墙还未更新 HK IP）"
  echo "  手动在意大利服务器运行：ufw allow from ${HK_IP} to any port 443"
fi

info "验证域名 HTTPS 可达..."
DOMAIN_CHECK=$(curl -sk --max-time 15 "https://${DOMAIN}/health" && echo PASS || echo FAIL)
if [[ "$DOMAIN_CHECK" == *"PASS"* ]]; then
  ok "https://${DOMAIN}/health：PASS"
else
  warn "域名暂不可达，请确认 DNS 已指向香港服务器 ${HK_IP}"
fi

# ── 输出 .env 备份提醒 ───────────────────────────────────────────────────────
echo ""
info "获取意大利服务器密钥（请妥善保存）..."
echo ""
echo -e "${RED}★━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━★${NC}"
echo -e "${RED}  以下密钥务必备份！CRYPTO_SECRET 丢失无法恢复！${NC}"
echo -e "${RED}★━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━★${NC}"
ssh_exec "$ITALY_SSH" "cat /opt/new-api/.env"
echo ""

echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  全部部署完成！${NC}"
echo -e "${GREEN}════════════════════════════════════════════════${NC}"
echo ""
echo "  API 端点:     https://${DOMAIN}"
echo "  管理面板:     http://${ITALY_IP}:3000  (仅意大利本地)"
echo ""
echo -e "${YELLOW}  首次登录 new-api 管理面板必做：${NC}"
echo "  1. 默认账号 root / 123456 → 立即改密"
echo "  2. 添加 Anthropic / OpenAI 上游渠道"
echo "  3. 创建用户 Token，设置额度"
echo "  4. 检查 Prompt Caching 倍率配置（防穿仓）"
echo ""
echo -e "${YELLOW}  运行验证测试：${NC}"
echo "  bash $DEPLOY_DIR/scripts/test.sh --domain ${DOMAIN} --key YOUR_TOKEN"
