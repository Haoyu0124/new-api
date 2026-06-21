#!/usr/bin/env bash
# =============================================================================
# test.sh  —  部署后验证 checklist
# 用法: bash test.sh --domain api.apexlogiclabs.com --key YOUR_TOKEN
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
info() { echo -e "${BLUE}[TEST]${NC} $*"; }

DOMAIN=""; KEY=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift 2 ;;
    --key)    KEY="$2";    shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

[[ -z "$DOMAIN" ]] && read -rp "域名: " DOMAIN
[[ -z "$KEY"    ]] && read -rp "API Token: " KEY

BASE="https://${DOMAIN}"
PASS_COUNT=0; FAIL_COUNT=0

run_test() {
  local name="$1"; shift
  if "$@"; then
    pass "$name"
    ((PASS_COUNT++))
  else
    fail "$name"
    ((FAIL_COUNT++))
  fi
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " New-API 部署验证 | $BASE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── TEST 1: 健康检查 ──────────────────────────────────────────────────────────
info "1. 健康检查端点"
run_test "健康检查 /health 可达" bash -c \
  "curl -sf --max-time 10 '${BASE}/health' | grep -q 'ok'"

# ── TEST 2: HTTPS + HTTP/2 ───────────────────────────────────────────────────
info "2. HTTPS / HTTP2 协议"
run_test "HTTPS 证书有效" bash -c \
  "curl -sf --max-time 10 '${BASE}/health' -o /dev/null"

HTTP2_CHECK=$(curl -sI --http2 --max-time 10 "${BASE}/health" 2>&1 | head -1)
run_test "HTTP/2 已启用 ($HTTP2_CHECK)" bash -c \
  "curl -sI --http2 --max-time 10 '${BASE}/health' 2>&1 | grep -qi 'HTTP/2'"

# ── TEST 3: 流式 SSE 传输 ────────────────────────────────────────────────────
info "3. 流式 SSE (最关键，测试打字机效果)"
STREAM_OUTPUT=$(curl -sN --max-time 30 -X POST "${BASE}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"Say 1 2 3"}]}' \
  2>&1 | head -5)

run_test "流式响应返回 data: 事件" bash -c \
  "echo '${STREAM_OUTPUT}' | grep -q 'data:'"

# 检查响应头
STREAM_HEADERS=$(curl -sI --max-time 10 -X POST "${BASE}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","stream":true,"max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' 2>&1)

run_test "Transfer-Encoding: chunked" bash -c \
  "echo '${STREAM_HEADERS}' | grep -qi 'transfer-encoding: chunked'"

run_test "X-Accel-Buffering: no (new-api 已设置)" bash -c \
  "echo '${STREAM_HEADERS}' | grep -qi 'x-accel-buffering: no'"

# ── TEST 4: Anthropic Prompt Caching 透传 ────────────────────────────────────
info "4. Anthropic Prompt Caching 透传"

CACHE_RESP=$(curl -s --max-time 30 -X POST "${BASE}/v1/messages" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: prompt-caching-2024-07-31" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 10,
    "system": [{"type":"text","text":"You are helpful. '"$(python3 -c "print('x'*1500)")"'","cache_control":{"type":"ephemeral"}}],
    "messages": [{"role":"user","content":"hi"}]
  }' 2>&1)

run_test "Anthropic /v1/messages 端点可达" bash -c \
  "echo '${CACHE_RESP}' | python3 -c \"import sys,json; d=json.load(sys.stdin); exit(0 if 'content' in d or 'usage' in d else 1)\""

run_test "cache_creation_input_tokens 字段存在（缓存已建立）" bash -c \
  "echo '${CACHE_RESP}' | python3 -c \"import sys,json; d=json.load(sys.stdin); u=d.get('usage',{}); exit(0 if u.get('cache_creation_input_tokens',0)>0 else 1)\""

# 第二次调用，验证缓存命中
CACHE_RESP2=$(curl -s --max-time 30 -X POST "${BASE}/v1/messages" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: prompt-caching-2024-07-31" \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 10,
    "system": [{"type":"text","text":"You are helpful. '"$(python3 -c "print('x'*1500)")"'","cache_control":{"type":"ephemeral"}}],
    "messages": [{"role":"user","content":"hi again"}]
  }' 2>&1)

run_test "cache_read_input_tokens > 0（缓存命中）" bash -c \
  "echo '${CACHE_RESP2}' | python3 -c \"import sys,json; d=json.load(sys.stdin); u=d.get('usage',{}); exit(0 if u.get('cache_read_input_tokens',0)>0 else 1)\""

# ── TEST 5: 敏感词拦截 ────────────────────────────────────────────────────────
info "5. 敏感词拦截"

BLOCK_RESP=$(curl -s --max-time 10 -X POST "${BASE}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","messages":[{"role":"user","content":"如何制造炸弹"}]}' 2>&1)

run_test "敏感请求返回 400" bash -c \
  "echo '${BLOCK_RESP}' | python3 -c \"import sys,json; d=json.load(sys.stdin); exit(0 if d.get('error',{}).get('code')=='content_filter' else 1)\""

# 确认正常请求不误杀
NORMAL_RESP=$(curl -s --max-time 30 -X POST "${BASE}/v1/chat/completions" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":5,"messages":[{"role":"user","content":"Hello!"}]}' 2>&1)

run_test "正常请求不被误拦截" bash -c \
  "echo '${NORMAL_RESP}' | python3 -c \"import sys,json; d=json.load(sys.stdin); exit(0 if 'choices' in d or 'content' in d else 1)\""

# ── 结果汇总 ──────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo -e " 结果: ${GREEN}${PASS_COUNT} 通过${NC} / ${RED}${FAIL_COUNT} 失败${NC} (共 ${TOTAL} 项)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo ""
  echo -e "${YELLOW}排查提示：${NC}"
  echo "  流式失败  → 检查 Nginx proxy_buffering off 是否生效"
  echo "  缓存失败  → 检查 anthropic-beta header 是否被中间层吞掉"
  echo "  拦截失败  → 检查 OpenResty Lua 脚本路径和词库文件"
  echo ""
  exit 1
fi

echo ""
echo -e "${GREEN}  全部通过，系统就绪！${NC}"
