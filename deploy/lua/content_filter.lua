-- content_filter.lua — OpenResty 请求拦截，香港节点前置内容审计
-- 加载路径：/etc/openresty/lua/content_filter.lua

local cjson = require "cjson.safe"

-- ── AI 推理端点匹配（管理面板等放行）────────────────────────────────────────
local uri = ngx.var.uri
if not (uri:match("^/v1/") or uri:match("^/api/v1/") or uri:match("^/v1$")) then
  return
end

if ngx.req.get_method() ~= "POST" then
  return
end

-- ── 读取 body ────────────────────────────────────────────────────────────────
ngx.req.read_body()
local body_data = ngx.req.get_body_data()
if not body_data then
  return
end

-- ── 解析 JSON ────────────────────────────────────────────────────────────────
local body = cjson.decode(body_data)
if not body or type(body) ~= "table" then
  return
end

-- ── 提取文本内容 ─────────────────────────────────────────────────────────────
local text_parts = {}

-- messages 数组（OpenAI / Anthropic 兼容格式）
if body.messages and type(body.messages) == "table" then
  for _, msg in ipairs(body.messages) do
    if msg.role == "user" or msg.role == "system" then
      if type(msg.content) == "string" then
        text_parts[#text_parts + 1] = msg.content
      elseif type(msg.content) == "table" then
        for _, block in ipairs(msg.content) do
          if type(block) == "table" and block.type == "text" and block.text then
            text_parts[#text_parts + 1] = block.text
          end
        end
      end
    end
  end
end

-- Anthropic 原生格式 system 字段
if body.system then
  if type(body.system) == "string" then
    text_parts[#text_parts + 1] = body.system
  elseif type(body.system) == "table" then
    for _, block in ipairs(body.system) do
      if block.type == "text" and block.text then
        text_parts[#text_parts + 1] = block.text
      end
    end
  end
end

if #text_parts == 0 then
  return
end

local full_text = table.concat(text_parts, " "):lower()

-- ── 加载敏感词库 ─────────────────────────────────────────────────────────────
-- 从文件读取，每行一个词，# 开头为注释
local function load_patterns(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local list = {}
  for line in f:lines() do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      list[#list + 1] = line:lower()
    end
  end
  f:close()
  return list
end

local WORDS_FILE = "/etc/openresty/lua/sensitive_words.txt"
local patterns = load_patterns(WORDS_FILE)

-- ── 检测 ─────────────────────────────────────────────────────────────────────
for _, word in ipairs(patterns) do
  if full_text:find(word, 1, true) then
    ngx.log(ngx.WARN,
      "content_filter blocked | ip=", ngx.var.remote_addr,
      " | word=", word,
      " | uri=", uri)

    ngx.status = 400
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.print(cjson.encode({
      error = {
        message = "Request blocked by content policy.",
        type    = "content_policy_violation",
        code    = "content_filter",
        param   = nil,
      }
    }))
    return ngx.exit(400)
  end
end
