#!/bin/bash
# ============================================================
# vps8 CertCenter 证书管理脚本
# https://vps8.zz.cd/certcenter
# ============================================================

set -euo pipefail

# ---- 路径常量 ----
BASE_DIR="${HOME}/vps8_cert_manager"
CONFIG_FILE="${BASE_DIR}/config.conf"
LOG_FILE="${BASE_DIR}/logs/cert_manager.log"
CERT_BASE_DIR="/cert"
API_BASE="https://vps8.zz.cd/api/client/certcenter"

RENEW_DAYS_BEFORE=15
RENEW_WAIT_SECONDS=30
DOWNLOAD_TYPES=("fullchain" "cert" "privkey")

# ---- 颜色 ----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- 依赖检查与自动安装 ----
detect_pkg_manager() {
  command -v apt-get >/dev/null 2>&1 && echo "apt" && return
  command -v apk     >/dev/null 2>&1 && echo "apk" && return
  command -v yum     >/dev/null 2>&1 && echo "yum" && return
  command -v dnf     >/dev/null 2>&1 && echo "dnf" && return
  command -v pacman  >/dev/null 2>&1 && echo "pacman" && return
  command -v zypper  >/dev/null 2>&1 && echo "zypper" && return
  echo ""
}

ensure_tool() {
  local binary="$1" pkg="$2"
  command -v "$binary" >/dev/null 2>&1 && return 0

  echo -e "  ${YELLOW}缺少依赖：${binary}，正在自动安装...${NC}"
  local pm
  pm=$(detect_pkg_manager)
  case "$pm" in
    apt) apt-get update -qq && apt-get install -y -qq "$pkg" ;;
    apk) apk add --no-cache "$pkg" ;;
    yum) yum install -y -q "$pkg" ;;
    dnf) dnf install -y -q "$pkg" ;;
    pacman) pacman -S --noconfirm "$pkg" ;;
    zypper) zypper install -y "$pkg" ;;
    "") echo -e "  ${RED}未检测到包管理器，请手动安装 ${binary} 后重试${NC}"; return 1 ;;
  esac
  if ! command -v "$binary" >/dev/null 2>&1; then
    echo -e "  ${RED}自动安装 ${binary} 失败，请手动安装后重试${NC}"
    return 1
  fi
  echo -e "  ${GREEN}✓ ${binary} 已安装${NC}"
}

check_deps() {
  local ok=0
  ensure_tool "bash" "bash" || ok=1
  ensure_tool "curl" "curl" || ok=1
  # crontab 的包名因发行版而异：Debian/Ubuntu → cron, Alpine → dcron, CentOS → cronie
  ensure_tool "crontab" "cron" 2>/dev/null || \
    ensure_tool "crontab" "cronie" 2>/dev/null || \
    ensure_tool "crontab" "dcron" || ok=1
  return "$ok"
}

# ---- 初始化目录 ----
init_dirs() {
  mkdir -p "${BASE_DIR}/logs"
  touch "$LOG_FILE"
  if [ ! -f "$CONFIG_FILE" ]; then
    printf "API_KEY=\nDOMAINS=\n" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
  fi
  # cert_cron.sh 已废弃，定时任务通过 cert_manager.sh auto-renew 执行
  local cron_script="${BASE_DIR}/cert_cron.sh"
  if [ -f "$cron_script" ]; then
    rm -f "$cron_script"
  fi
}

# ---- 管道执行 / 自安装 ----
bootstrap_pipe_exec() {
  local script_url="https://raw.githubusercontent.com/YOUIMARK/vps8_cert_manager/main/cert_manager.sh"
  local target="${BASE_DIR}/cert_manager.sh"
  echo "检测到管道执行，正在从 GitHub 下载脚本..."
  mkdir -p "$BASE_DIR"
  curl -sS --fail -o "$target" "$script_url" || { echo "下载失败，请手动克隆：git clone https://github.com/YOUIMARK/vps8_cert_manager.git"; exit 1; }
  chmod +x "$target"
  echo "已安装到 ${target}，正在启动..."
  export PIPE_EXEC_DONE=1
  exec bash "$target"
}

self_install() {
  local self="$1" target="$2"
  cp "$self" "$target"
  chmod +x "$target"
  echo -e "${GREEN}✓ 脚本已安装到 ${target}${NC}"
  echo -e "${YELLOW}  原文件将被删除，以后请运行：bash ${target}${NC}"
  echo ""
  if [ -f "$self" ] && [ "$self" != "$target" ]; then
    rm -f "$self"
  fi
}

# ---- 日志 ----
log() {
  local level="$1"; shift
  local ts
  ts=$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M:%S')
  echo "${ts} [${level}] $*" >> "$LOG_FILE"
}

# ---- 配置读写 ----
# 白名单解析：只提取 API_KEY 和 DOMAINS，不执行任何 shell 代码
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  API_KEY=$(grep '^API_KEY=' "$CONFIG_FILE" | head -1 | cut -d= -f2-)
}

save_api_key() {
  local escaped
  escaped="${1//\\/\\\\}"; escaped="${escaped//&/\\&}"; escaped="${escaped//|/\\|}"
  sed -i "s|^API_KEY=.*|API_KEY=${escaped}|" "$CONFIG_FILE"
}

load_domains() {
  DOMAIN_LIST=()
  local raw
  raw=$(grep '^DOMAINS=' "$CONFIG_FILE" | cut -d= -f2-)
  IFS=',' read -ra DOMAIN_LIST <<< "$raw"
  local cleaned=()
  for d in "${DOMAIN_LIST[@]}"; do
    [ -n "$d" ] && cleaned+=("$d")
  done
  DOMAIN_LIST=("${cleaned[@]}")
}

save_domains() {
  local joined
  joined=$(IFS=','; echo "${DOMAIN_LIST[*]}")
  sed -i "s|^DOMAINS=.*|DOMAINS=${joined}|" "$CONFIG_FILE"
}

domain_exists() {
  local target="$1"
  for d in "${DOMAIN_LIST[@]}"; do
    [ "$d" = "$target" ] && return 0
  done
  return 1
}

# 域名格式校验：防路径遍历和注入
validate_domain() {
  local domain="$1"
  [ -z "$domain" ] && return 1
  [ ${#domain} -gt 253 ] && return 1
  # 禁止路径分隔符和危险字符
  [[ "$domain" =~ [/\"\'\\\`\$\;] ]] && return 1
  # 标准 FQDN 格式：字母数字开头，允许连字符和点号
  [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
  # 禁止连续点号（空标签）
  [[ "$domain" =~ \.\. ]] && return 1
  return 0
}

# ---- 清理函数 ----
cleanup() {
  local exit_code=$?
  rm -f "${NETRC_FILE:-}"
  if [ "$exit_code" -ne 0 ] && [ -n "${1:-}" ]; then
    echo -e "${RED}脚本异常退出（退出码：${exit_code}），查看日志：${LOG_FILE}${NC}" >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ---- netrc 临时凭证 ----
setup_netrc() {
  umask 077
  NETRC_FILE=$(mktemp) || { echo -e "${RED}无法创建临时文件${NC}"; exit 1; }
  chmod 600 "$NETRC_FILE" || { echo -e "${RED}无法设置 netrc 文件权限${NC}"; exit 1; }
  printf '%s' "machine vps8.zz.cd login client password ${API_KEY}" > "$NETRC_FILE"
}

# ---- API 调用 ----
api_post() {
  curl -sS --connect-timeout 10 --max-time 30 \
    --netrc-file "$NETRC_FILE" \
    -X POST "${API_BASE}/$1" \
    -d "$2"
}

# 关键操作重试封装（续签、下载），最多 3 次，间隔 2s/4s
api_post_retry() {
  local endpoint="$1" data="$2" max_retries="${3:-3}"
  local attempt=0 delay response http_code
  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$((attempt + 1))
    response=$(curl -sS --connect-timeout 10 --max-time 120 \
      -w "\n__HTTP_CODE__%{http_code}" \
      --netrc-file "$NETRC_FILE" \
      -X POST "${API_BASE}/${endpoint}" \
      -d "$data" 2>/dev/null) || true
    http_code=$(echo "$response" | grep '__HTTP_CODE__' | tail -1 | sed 's/.*__HTTP_CODE__//')
    response=$(echo "$response" | sed '/__HTTP_CODE__/d')
    if [ "$http_code" -eq 200 ] && [ -n "$response" ]; then
      echo "$response"
      return 0
    fi
    if [ "$attempt" -lt "$max_retries" ]; then
      delay=$((2 * attempt))
      sleep "$delay"
    fi
  done
  echo "$response"
  return 1
}

# ---- 纯 awk JSON 字段提取（无 python3/jq 依赖） ----
# 从扁平 JSON 中提取顶层字段值，支持字符串（解码 \n \\ \" \/）和数字
json_get() {
  echo "$1" | awk -v key="$2" '
  { json = json $0 }
  END {
    re = "\042" key "\042[[:space:]]*:[[:space:]]*"
    if (!match(json, re)) exit 1
    rest = substr(json, RSTART + RLENGTH)
    if (substr(rest, 1, 1) == "\042") {
      rest = substr(rest, 2)
      res = ""; esc = 0
      while (length(rest) > 0) {
        ch = substr(rest, 1, 1); rest = substr(rest, 2)
        if (esc) {
          if      (ch == "n")  res = res "\n"
          else if (ch == "\\") res = res "\\"
          else if (ch == "/")  res = res "/"
          else if (ch == "\042") res = res "\042"
          else                 res = res ch
          esc = 0
        } else if (ch == "\\") { esc = 1 }
        else if (ch == "\042") { printf "%s", res; exit 0 }
        else                   { res = res ch }
      }
      printf "%s", res
    } else {
      res = ""
      while (length(rest) > 0) {
        ch = substr(rest, 1, 1)
        if (ch == "," || ch == "}" || ch == " " || ch == "\t") break
        res = res ch
        rest = substr(rest, 2)
      }
      printf "%s", res
    }
  }
  '
}

# ---- 验证 API Key ----
verify_api_key() {
  local http_code
  http_code=$(curl -sS -o /dev/null -w "%{http_code}" \
    --connect-timeout 10 --max-time 30 \
    --netrc-file "$NETRC_FILE" \
    -X POST "${API_BASE}/list" \
    -d "domain=verify.test" 2>/dev/null)
  [ "$http_code" -eq 200 ] && return 0 || return 1
}

# ---- 解析到期时间戳 ----
get_expiry_timestamp() {
  local response expire_str
  response=$(api_post "list" "domain=$1" 2>>"$LOG_FILE")

  expire_str=$(json_get "$response" "expire" 2>/dev/null)
  [ -z "$expire_str" ] && expire_str=$(json_get "$response" "expiry" 2>/dev/null)
  [ -z "$expire_str" ] && expire_str=$(json_get "$response" "not_after" 2>/dev/null)
  [ -z "$expire_str" ] && expire_str=$(json_get "$response" "valid_to" 2>/dev/null)

  if [ -z "$expire_str" ]; then
    echo "__RAW__${response}"; return 1
  fi

  if [[ "$expire_str" =~ ^[0-9]+$ ]]; then
    echo "$expire_str"; return 0
  fi

  local ts
  ts=$(TZ='Asia/Shanghai' date -d "$expire_str" +%s 2>/dev/null || \
       TZ='Asia/Shanghai' date -j -f "%Y-%m-%dT%H:%M:%S" "$expire_str" +%s 2>/dev/null)
  [ -z "$ts" ] && return 1
  echo "$ts"
}

# 将 Unix 时间戳格式化为 YYYY-MM-DD（Asia/Shanghai 时区）
format_expiry_date() {
  local ts="$1"
  TZ='Asia/Shanghai' date -d "@${ts}" '+%Y-%m-%d' 2>/dev/null || date -r "$ts" '+%Y-%m-%d' 2>/dev/null
}

# ---- 从 JSON 响应中提取 content 字段 ----
json_extract_content() {
  local raw="$1" out="$2"
  json_get "$raw" "content" > "$out" 2>/dev/null
  [ -s "$out" ] && return 0 || return 1
}

# ---- 下载证书 ----
do_download() {
  local domain="$1"
  local fail=0
  for type in "${DOWNLOAD_TYPES[@]}"; do
    local dest_dir="${CERT_BASE_DIR}/${domain}"
    mkdir -p "$dest_dir"
    local dest_file="${dest_dir}/${type}.pem"
    local tmp_file
    tmp_file=$(mktemp "${dest_dir}/cert-XXXXXXXX") || { log ERROR "[${domain}] 无法创建临时文件"; fail=$((fail + 1)); continue; }

    local http_code attempt=0 max_retries=3
    while true; do
      attempt=$((attempt + 1))
      http_code=$(curl -sS -w "%{http_code}" -o "$tmp_file" \
        --connect-timeout 10 --max-time 120 \
        --netrc-file "$NETRC_FILE" \
        -X POST "${API_BASE}/download" \
        -d "domain=${domain}&type=${type}" 2>>"$LOG_FILE")
      if [ "$http_code" -eq 200 ] && [ -s "$tmp_file" ]; then
        break
      fi
      if [ "$attempt" -ge "$max_retries" ]; then
        break
      fi
      log WARN "[${domain}] 下载 ${type} 第 ${attempt} 次失败，$((2 * attempt))s 后重试"
      sleep $((2 * attempt))
    done

    if [ "$http_code" -eq 200 ] && [ -s "$tmp_file" ]; then
      # API 返回 JSON，证书内容在 content 字段中
      local raw
      raw=$(cat "$tmp_file")
      if echo "$raw" | grep -q '"content"'; then
        json_extract_content "$raw" "${tmp_file}.pem"
        [ -s "${tmp_file}.pem" ] && mv "${tmp_file}.pem" "$tmp_file"
      fi
      [ "$type" = "privkey" ] && chmod 600 "$tmp_file" || chmod 644 "$tmp_file"
      mv "$tmp_file" "$dest_file"
      echo -e "  ${GREEN}✓${NC} ${type} -> ${dest_file}"
      log OK "[${domain}] 下载 ${type} 成功"
    else
      rm -f "$tmp_file"
      echo -e "  ${RED}✗${NC} ${type} 下载失败（HTTP ${http_code}）"
      log ERROR "[${domain}] 下载 ${type} 失败（HTTP ${http_code}）"
      fail=$(( fail + 1 ))
    fi
  done
  return "$fail"
}

# ---- 续签 ----
do_renew() {
  local domain="$1"
  local response
  response=$(api_post_retry "renew" "domain=${domain}" 2>>"$LOG_FILE")

  if echo "$response" | grep -qi '"status"[[:space:]]*:[[:space:]]*"already_issued"'; then
    local msg
    msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    echo -e "  ${YELLOW}${msg:-证书未到期，暂不需要续签}${NC}"
    log OK "[${domain}] 续签跳过（证书未到期）"
    return 2
  fi
  if echo "$response" | grep -qiE '"error"[[:space:]]*:[[:space:]]*null'; then
    log OK "[${domain}] 续签请求成功"
    return 0
  fi
  log ERROR "[${domain}] 续签失败：${response}"
  return 1
}

# ---- 续签并下载（共享编排，供交互/CLI/cron 三个入口调用） ----
renew_and_download() {
  local domain="$1"
  local renew_rc=0
  do_renew "$domain" || renew_rc=$?
  if [ "$renew_rc" -ne 0 ]; then
    return "$renew_rc"
  fi

  log INFO "[${domain}] 续签请求成功，等待证书签发..."
  local poll_seconds=0 max_poll=60 poll_interval=5 check_expiry
  while [ "$poll_seconds" -lt "$max_poll" ]; do
    sleep "$poll_interval"
    poll_seconds=$((poll_seconds + poll_interval))
    printf '\r  等待中... %ds / %ds' "$poll_seconds" "$max_poll"
    check_expiry=$(get_expiry_timestamp "$domain" 2>/dev/null) || true
    if [ -n "$check_expiry" ] && [[ "$check_expiry" =~ ^[0-9]+$ ]]; then
      if [ "$check_expiry" -gt "$(date +%s)" ]; then
        echo ""
        log OK "[${domain}] 证书已签发"
        break
      fi
    fi
  done
  if [ "$poll_seconds" -ge "$max_poll" ]; then
    echo ""
    log WARN "[${domain}] 等待超时（${max_poll}s），仍尝试下载"
  fi
  do_download "$domain" || true
  return 0
}

# ---- crontab 管理 ----
add_cron() {
  local domain="$1"
  local script_path="${BASE_DIR}/cert_manager.sh"

  if cron_exists "$domain"; then
    echo -e "${YELLOW}该域名的定时任务已存在，跳过${NC}"
    return
  fi

  local tmp_cron lock_fd lock_file
  lock_file="${BASE_DIR}/.cron.lock"
  mkdir -p "$BASE_DIR"
  exec {lock_fd}>"$lock_file" 2>/dev/null || true
  if [ -n "${lock_fd:-}" ]; then
    flock -w 10 /dev/fd/$lock_fd 2>/dev/null || true
  fi
  tmp_cron=$(mktemp)
  crontab -l 2>/dev/null > "$tmp_cron" || true
  build_cron_line "$script_path" "$domain" "$LOG_FILE" >> "$tmp_cron"
  echo "" >> "$tmp_cron"
  crontab "$tmp_cron" || true
  rm -f "$tmp_cron"
  if [ -n "${lock_fd:-}" ]; then
    flock -u /dev/fd/$lock_fd 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
  fi
  echo -e "${GREEN}✓ 已添加定时任务（每天北京时间凌晨自动续签）${NC}"
  log INFO "[${domain}] 添加 crontab 自动续签"
}

remove_cron() {
  local domain="$1"
  local tmp lock_fd lock_file
  lock_file="${BASE_DIR}/.cron.lock"
  exec {lock_fd}>"$lock_file" 2>/dev/null || true
  if [ -n "${lock_fd:-}" ]; then
    flock -w 10 /dev/fd/$lock_fd 2>/dev/null || true
  fi
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "cert_manager.sh auto-renew" | grep -vF "${domain}" > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
  if [ -n "${lock_fd:-}" ]; then
    flock -u /dev/fd/$lock_fd 2>/dev/null || true
    eval "exec ${lock_fd}>&-" 2>/dev/null || true
  fi
  log INFO "[${domain}] 移除 crontab 自动续签"
}

# 检查域名是否已有 crontab 定时任务
cron_exists() {
  local domain="$1"
  crontab -l 2>/dev/null | grep -qF "cert_manager.sh auto-renew" | grep -qF "${domain}" 2>/dev/null
}

# 构造 crontab 条目（不含换行符）
build_cron_line() {
  local script_path="$1" domain="$2" log_file="$3"
  local minute=$(( RANDOM % 60 ))
  printf "%-5d %-5d %-5s %-5s %-5s %s" "$minute" 1 '*' '*' '*' "TZ=Asia/Shanghai \"${script_path}\" auto-renew \"${domain}\" >> \"${log_file}\" 2>&1"
}

# ---- 分隔线 ----
hr() { echo -e "${CYAN}──────────────────────────────────────${NC}"; }

# ---- 交互式域名选择（公共函数，避免菜单函数中重复） ----
select_domain() {
  load_domains
  local domain="" choice
  if [ "${#DOMAIN_LIST[@]}" -gt 0 ]; then
    echo "已保存的域名：" >&2
    for i in "${!DOMAIN_LIST[@]}"; do
      echo "  $((i+1)). ${DOMAIN_LIST[$i]}" >&2
    done
    echo "  n. 输入其他域名" >&2
    echo "" >&2
    read -rp "请选择: " choice
    if [ "$choice" = "n" ] || [ -z "$choice" ]; then
      read -rp "请输入域名: " domain
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DOMAIN_LIST[@]}" ]; then
      domain="${DOMAIN_LIST[$((choice-1))]}"
    else
      echo "无效选择" >&2
      return 1
    fi
  else
    read -rp "请输入域名: " domain
  fi
  [ -z "$domain" ] && echo "域名不能为空" >&2 && return 1
  validate_domain "$domain" || { echo -e "${RED}域名格式无效：${domain}${NC}" >&2; return 1; }
  printf '%s' "$domain"
  return 0
}

# ============================================================
# 菜单功能
# ============================================================

menu_query() {
  hr
  echo -e "${BOLD}查询证书${NC}"
  hr
  local domain
  domain=$(select_domain) || return

  echo -e "\n正在查询 ${CYAN}${domain}${NC} ..."
  local result
  result=$(get_expiry_timestamp "$domain")

  if [[ "$result" == __RAW__* ]]; then
    echo -e "${RED}查询失败，原始响应：${NC}"
    echo "${result#__RAW__}"
    return
  fi

  if [ -z "$result" ]; then
    echo -e "${RED}查询失败，无法解析到期时间${NC}"
    return
  fi

  local now days_left expire_date
  now=$(date +%s)
  days_left=$(( (result - now) / 86400 ))
  expire_date=$(format_expiry_date "$result")

  echo -e "\n  域名：${CYAN}${domain}${NC}"
  echo -e "  到期：${expire_date}"
  if [ "$days_left" -le "$RENEW_DAYS_BEFORE" ]; then
    echo -e "  剩余：${RED}${days_left} 天${NC}（建议续签）"
  else
    echo -e "  剩余：${GREEN}${days_left} 天${NC}"
  fi
  echo ""

  load_domains
  if ! domain_exists "$domain"; then
    read -rp "是否保存该域名？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      DOMAIN_LIST+=("$domain")
      save_domains
      echo -e "${GREEN}✓ 已保存${NC}"
    fi
  fi
}

menu_download() {
  hr
  echo -e "${BOLD}下载证书${NC}"
  hr
  local domain
  domain=$(select_domain) || return

  echo -e "\n正在下载 ${CYAN}${domain}${NC} 的证书..."
  if do_download "$domain"; then
    echo -e "\n${GREEN}下载完成${NC}"
    log INFO "[${domain}] 下载完成"
    echo ""
    read -rp "是否设置每天自动续签？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      add_cron "$domain"
      load_domains
      if ! domain_exists "$domain"; then
        DOMAIN_LIST+=("$domain")
        save_domains
      fi
    fi
  else
    echo -e "\n${RED}部分文件下载失败，请查看日志：${LOG_FILE}${NC}"
  fi
}

menu_renew() {
  hr
  echo -e "${BOLD}手动续签${NC}"
  hr
  local domain
  domain=$(select_domain) || return

  echo -e "\n正在对 ${CYAN}${domain}${NC} 发起续签..."
  local renew_rc=0
  renew_and_download "$domain" || renew_rc=$?
  if [ "$renew_rc" -eq 0 ]; then
    echo -e "\n${GREEN}完成${NC}"
  elif [ "$renew_rc" -eq 2 ]; then
    : # already_issued，已在 do_renew 中打印提示
  else
    echo -e "${RED}续签失败，请查看日志：${LOG_FILE}${NC}"
  fi
}

menu_manage() {
  hr
  echo -e "${BOLD}管理已保存域名${NC}"
  hr
  load_domains

  if [ "${#DOMAIN_LIST[@]}" -eq 0 ]; then
    echo "暂无已保存的域名"
    echo -e "${YELLOW}提示：在「查询证书」或「下载证书」时选择保存，域名会自动添加${NC}"
    return
  fi

  echo "已保存的域名（均已设置自动续签）："
  echo ""
  for i in "${!DOMAIN_LIST[@]}"; do
    local cron_status=""
    cron_exists "${DOMAIN_LIST[$i]}" \
      && cron_status=" ${GREEN}[定时任务已启用]${NC}"
    echo -e "  $((i+1)). ${DOMAIN_LIST[$i]}${cron_status}"
  done
  echo ""
  read -rp "输入序号删除（直接回车返回）: " choice
  [ -z "$choice" ] && return

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DOMAIN_LIST[@]}" ]; then
    local target="${DOMAIN_LIST[$((choice-1))]}"
    read -rp "确认删除 ${target} 的自动续签？(y/N): " yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
      remove_cron "$target"
      DOMAIN_LIST=("${DOMAIN_LIST[@]:0:$((choice-1))}" "${DOMAIN_LIST[@]:$choice}")
      save_domains
      echo -e "${GREEN}已删除 ${target} 的自动续签${NC}"
    fi
  else
    echo "无效序号"
  fi
}

menu_uninstall() {
  hr
  echo -e "${BOLD}${RED}卸载脚本${NC}"
  hr
  echo "将要执行以下操作："
  echo -e "  ${RED}✗${NC} 删除目录：${BASE_DIR}"
  echo -e "  ${RED}✗${NC} 移除所有相关 crontab 条目"
  echo ""
  echo -e "  ${YELLOW}！保留${NC}：/cert 目录及其中的证书文件"
  echo -e "  如需删除证书，请卸载完成后手动执行："
  echo -e "  ${BOLD}rm -rf /cert${NC}"
  echo ""
  read -rp "确认卸载？输入 yes 继续: " confirm
  [ "$confirm" != "yes" ] && echo "已取消" && return

  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "cert_cron.sh" | grep -vF "cert_manager.sh" > "$tmp" || true
  crontab "$tmp"
  rm -f "$tmp"
  echo -e "${GREEN}✓ 已清除 crontab${NC}"

  rm -rf "$BASE_DIR"
  echo -e "${GREEN}✓ 已删除 ${BASE_DIR}${NC}"
  echo ""
  echo "卸载完成。"
  exit 0
}

# ============================================================
# 首次运行 / API Key 检查
# ============================================================
first_run_or_check_key() {
  load_config

  if [ -z "$API_KEY" ]; then
    echo ""
    echo -e "${BOLD}欢迎使用 vps8 CertCenter 证书管理脚本${NC}"
    hr
    echo -e "首次使用，请输入您的 API Key。"
    echo -e "API Key 可在 ${CYAN}https://vps8.zz.cd/client/profile${NC} 获取。"
    echo ""
    while true; do
      read -rsp "API Key: " input_key
      echo ""
      [ -z "$input_key" ] && echo "API Key 不能为空" && continue

      API_KEY="$input_key"
      setup_netrc

      echo -n "正在验证..."
      if verify_api_key; then
        save_api_key "$API_KEY"
        echo -e " ${GREEN}验证成功${NC}"
        break
      else
        echo -e " ${RED}验证失败，请检查 API Key${NC}"
        local verify_resp
        verify_resp=$(curl -sS --connect-timeout 10 --max-time 30 \
          --netrc-file "$NETRC_FILE" \
          -X POST "${API_BASE}/list" \
          -d "domain=verify.test" 2>/dev/null) || true
        [ -n "$verify_resp" ] && echo -e "  服务器返回：${verify_resp}"
        rm -f "$NETRC_FILE"
        API_KEY=""
      fi
    done
  else
    setup_netrc
  fi
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
  while true; do
    echo ""
    hr
    echo -e "  ${BOLD}vps8 CertCenter 证书管理${NC}"
    hr
    echo "  1. 查询证书"
    echo "  2. 下载证书"
    echo "  3. 手动续签"
    echo "  4. 管理已保存域名"
    echo "  5. 卸载脚本"
    echo "  0. 退出"
    hr
    read -rp "请选择: " opt
    case "$opt" in
      1) menu_query ;;
      2) menu_download ;;
      3) menu_renew ;;
      4) menu_manage ;;
      5) menu_uninstall ;;
      0) echo "再见"; exit 0 ;;
      *) echo -e "${YELLOW}无效选项${NC}" ;;
    esac
  done
}

# ============================================================
# CLI 子命令实现
# ============================================================
cli_query() {
  local domain="$1"
  validate_domain "$domain" || { echo -e "${RED}域名格式无效：${domain}${NC}"; exit 1; }
  local result
  result=$(get_expiry_timestamp "$domain") || true
  if [[ "$result" == __RAW__* ]]; then
    echo -e "${RED}查询失败${NC}"
    echo "${result#__RAW__}"
    exit 1
  fi
  if [ -z "$result" ]; then
    echo -e "${RED}查询失败，无法解析到期时间${NC}"
    exit 1
  fi
  local now days_left expire_date
  now=$(date +%s)
  days_left=$(( (result - now) / 86400 ))
  expire_date=$(format_expiry_date "$result")
  echo "域名：${domain}"
  echo "到期：${expire_date}"
  echo "剩余：${days_left} 天"
}

cli_download() {
  local domain="$1"
  validate_domain "$domain" || { echo -e "${RED}域名格式无效：${domain}${NC}"; exit 1; }
  do_download "$domain" || { echo -e "${RED}下载失败${NC}"; exit 1; }
}

cli_renew() {
  local domain="$1"
  validate_domain "$domain" || { echo -e "${RED}域名格式无效：${domain}${NC}"; exit 1; }
  local renew_rc=0
  renew_and_download "$domain" || renew_rc=$?
  if [ "$renew_rc" -eq 0 ]; then
    echo -e "${GREEN}完成${NC}"
  elif [ "$renew_rc" -eq 2 ]; then
    echo "证书未到期，暂不需要续签"
  else
    echo -e "${RED}续签失败${NC}"
    exit 1
  fi
}

cli_auto_renew() {
  local domain="$1"
  validate_domain "$domain" || { log ERROR "[${domain}] 域名格式无效"; exit 1; }
  log INFO "[${domain}] 定时任务开始"

  # 使用共享的到期时间查询（不再重复实现字段回退链和日期解析）
  local result
  result=$(get_expiry_timestamp "$domain" 2>/dev/null) || true
  if [[ "$result" == __RAW__* ]]; then
    log ERROR "[${domain}] 无法获取到期时间，原始响应：${result#__RAW__}"
    exit 1
  fi
  [ -z "$result" ] && { log ERROR "[${domain}] 无法获取到期时间"; exit 1; }

  local now days_left
  now=$(date +%s)
  days_left=$(( (result - now) / 86400 ))
  log INFO "[${domain}] 剩余 ${days_left} 天"

  if [ "$days_left" -gt "$RENEW_DAYS_BEFORE" ]; then
    if [ -f "${CERT_BASE_DIR}/${domain}/${DOWNLOAD_TYPES[0]}.pem" ]; then
      log INFO "[${domain}] 证书有效，无需操作"
      exit 0
    fi
    log INFO "[${domain}] 本地证书不存在，补充下载"
  else
    log INFO "[${domain}] 触发续签（剩余 ${days_left} 天 ≤ ${RENEW_DAYS_BEFORE} 天）"
    local rn_rc=0
    renew_and_download "$domain" || rn_rc=$?
    if [ "$rn_rc" -eq 2 ]; then
      log OK "[${domain}] 证书未到期，跳过续签"
      exit 0
    elif [ "$rn_rc" -eq 0 ]; then
      log OK "[${domain}] 定时任务完成"
      exit 0
    else
      log ERROR "[${domain}] 续签失败"
      exit 1
    fi
    return
  fi

  do_download "$domain"
  local dl_rc=$?
  [ "$dl_rc" -eq 0 ] && log OK "[${domain}] 定时任务完成" || log ERROR "[${domain}] ${dl_rc} 个文件下载失败"
  exit "$dl_rc"
}

cli_list() {
  load_domains
  if [ "${#DOMAIN_LIST[@]}" -eq 0 ]; then
    echo "暂无已保存的域名"
    return
  fi
  echo "已保存的域名："
  for d in "${DOMAIN_LIST[@]}"; do
    local cron_info=""
    cron_exists "$d" && cron_info=" [定时任务已启用]"
    echo "  ${d}${cron_info}"
  done
}

cli_uninstall() {
  echo "确认卸载？输入 yes 继续: "
  read -r confirm
  [ "$confirm" != "yes" ] && echo "已取消" && exit 0

  local tmp
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -vF "cert_cron.sh" | grep -vF "cert_manager.sh" > "$tmp" || true
  crontab "$tmp" || true
  rm -f "$tmp"
  echo "已清除 crontab"

  rm -rf "$BASE_DIR"
  echo "已删除 ${BASE_DIR}"
  echo "卸载完成。证书目录 ${CERT_BASE_DIR} 未删除，如需清理请手动执行：rm -rf ${CERT_BASE_DIR}"
  exit 0
}

# ============================================================
# 入口
# ============================================================

# 脚本自身路径（提前计算，管道检测和自安装都需要）
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TARGET="${BASE_DIR}/cert_manager.sh"

# 管道执行检测：stdin 非终端 且 $SELF 不是真实文件（curl | bash 时 $0 为 "bash"）
if [ ! -t 0 ] && [ ! -f "$SELF" ] && [ "${PIPE_EXEC_DONE:-}" != "1" ]; then
  bootstrap_pipe_exec
fi

echo -e "${BOLD}vps8 CertCenter 证书管理脚本${NC}"
check_deps || exit 1
init_dirs

# 脚本自身不在 BASE_DIR 时，复制过去并提示用户
if [ "$SELF" != "$TARGET" ]; then
  self_install "$SELF" "$TARGET"
fi

first_run_or_check_key

# CLI 模式：检测子命令
if [ $# -gt 0 ]; then
  case "$1" in
    query|download|renew|auto-renew)
      [ $# -lt 2 ] && { echo "用法：$0 $1 <域名>"; exit 1; }
      "cli_${1//-/_}" "$2"
      ;;
    list) cli_list ;;
    uninstall) cli_uninstall ;;
    *)
      echo "未知命令：$1"
      echo "支持：query download renew auto-renew list uninstall"
      echo "无参数运行进入交互菜单"
      exit 1
      ;;
  esac
  exit 0
fi

main_menu
