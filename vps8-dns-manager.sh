#!/usr/bin/env bash
set -uo pipefail

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly API_BASE="https://vps8.zz.cd"
readonly DNS_API="${API_BASE}/api/client/dnsopenapi"
readonly CERT_API="${API_BASE}/api/client/certcenter"
readonly DDNS_API="${API_BASE}/api/client/servicedns"
readonly STATUS_URL="https://status.i8.al/status/vps8"
readonly GITHUB_REPO="UIMAK/vps8_dns_manager"

# Config
CONFIG_DIR="${HOME}/.vps8-dns-manager"
CONFIG_FILE="${CONFIG_DIR}/config"
API_KEY=""
export API_KEY

# State
declare -a NAV_STACK=()

# Exit codes
readonly EXIT_OK=0
readonly EXIT_ERR=1
readonly EXIT_NOKEY=2

###############################################################################
# Terminal & Colors
###############################################################################
if [[ -t 1 ]]; then
    RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[0;33m'
    BLUE='\033[0;34m' MAGENTA='\033[0;35m' CYAN='\033[0;36m'
    BOLD='\033[1m'    DIM='\033[2m'       NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' NC=''
fi

# Terminal width (min 60, max 80)
_term_width() {
    local w
    w=$(tput cols 2>/dev/null || echo 80)
    (( w < 60 )) && w=60
    (( w > 120 )) && w=120
    echo "$w"
}

###############################################################################
# Signal Handling & Cleanup
###############################################################################
_cleanup() {
    local ec=$?
    [[ -f "${CONFIG_DIR}/.netrc.tmp" ]] && rm -f "${CONFIG_DIR}/.netrc.tmp"
    printf "\r\033[K" 2>/dev/null  # clear spinner line
    exit "$ec"
}
trap _cleanup EXIT INT TERM

###############################################################################
# Logging
###############################################################################
_log() {
    local level="$1"; shift
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $*" >> "${CONFIG_DIR}/app.log" 2>/dev/null
}

###############################################################################
# Output Helpers
###############################################################################
print_header() {
    local title="$1"
    local w=$(_term_width)
    echo ""
    printf "${BOLD}${CYAN}  ┌%s┐${NC}\n" "$(printf '─%.0s' $(seq 1 $((w-4))))"
    local pad_left=$(( (w - 4 - ${#title}) / 2 ))
    local pad_right=$(( w - 4 - ${#title} - pad_left ))
    printf "${BOLD}${CYAN}  │%*s%s%*s│${NC}\n" "$pad_left" "" "$title" "$pad_right" ""
    printf "${BOLD}${CYAN}  └%s┘${NC}\n" "$(printf '─%.0s' $(seq 1 $((w-4))))"
    echo ""
}

print_banner() {
    echo ""
    printf "${CYAN}${BOLD}"
    cat << 'ART'
   ██╗   ██╗██████╗ ███████╗ ██████╗
   ██║   ██║██╔══██╗██╔════╝██╔════╝
   ██║   ██║██████╔╝███████╗╚█████╗
   ╚██╗ ██╔╝██╔═══╝ ╚════██║ ╚═══██╗
    ╚████╔╝ ██║     ███████║██████╔╝
     ╚═══╝  ╚═╝     ╚══════╝╚═════╝
ART
    printf "${NC}"
    printf "  ${DIM}DNS · Certificate · DDNS Manager v${VERSION}${NC}\n"
    printf "  ${DIM}%s${NC}\n" "${API_BASE}"
}

sep() {
    local w=$(_term_width)
    printf "${DIM}  %s${NC}\n" "$(printf '─%.0s' $(seq 1 $((w-2))))"
}

ok()   { printf "  ${GREEN}✔${NC} %s\n" "$*"; }
info() { printf "  ${CYAN}ℹ${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; }
err()  { printf "  ${RED}✘${NC} %s\n" "$*" >&2; }

ask() {
    local prompt="$1" default="${2:-}" result
    if [[ -n "$default" ]]; then
        printf "  ${CYAN}?${NC} %s ${DIM}[%s]${NC}: " "$prompt" "$default"
    else
        printf "  ${CYAN}?${NC} %s: " "$prompt"
    fi
    read -r result
    echo "${result:-$default}"
}

ask_secure() {
    local prompt="$1" result
    printf "  ${CYAN}?${NC} %s: " "$prompt"
    read -rs result; echo ""
    echo "$result"
}

confirm() {
    local prompt="$1" default="${2:-n}"
    local yn="y/N"
    [[ "$default" == "y" ]] && yn="Y/n"
    printf "  ${CYAN}?${NC} %s ${DIM}(%s)${NC}: " "$prompt" "$yn"
    local ans; read -r ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[Yy] ]]
}

# Spinner
_spinner_pid=""
spinner_start() {
    local msg="${1:-处理中...}"
    (
        local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local i=0
        while true; do
            local c="${chars:i%${#chars}:1}"
            printf "\r  ${CYAN}%s${NC} %s" "$c" "$msg"
            sleep 0.1
            i=$(( (i + 1) % ${#chars} ))
        done
    ) &
    _spinner_pid=$!
    disown "$_spinner_pid" 2>/dev/null
}
spinner_stop() {
    [[ -n "$_spinner_pid" ]] && kill "$_spinner_pid" 2>/dev/null
    _spinner_pid=""
    printf "\r\033[K"
}

# Mask sensitive string: show first 3 and last 3 chars
mask_str() {
    local s="$1"
    local len=${#s}
    if (( len <= 8 )); then
        echo "${s:0:2}$(printf '*%.0s' $(seq 1 $((len-2))))"
    else
        echo "${s:0:3}$(printf '*%.0s' $(seq 1 $((len-6))))${s: -3}"
    fi
}

###############################################################################
# JSON Parsing (pure awk, no jq dependency)
###############################################################################

# Get value of a key from a flat JSON object
# Usage: json_get "$json" "key"
json_get() {
    local json="$1" key="$2"
    # Try string value first
    local val
    val=$(printf '%s' "$json" | awk -v k="\"$key\"" '{
        idx = index($0, k)
        if (idx > 0) {
            rest = substr($0, idx + length(k))
            sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
            if (substr(rest, 1, 1) == "\"") {
                sub(/^"/, "", rest)
                sub(/".*/, "", rest)
                print rest
                exit
            }
            # Non-string value (number, bool, null)
            sub(/[,}\n\r ].*/, "", rest)
            print rest
            exit
        }
    }')
    echo "$val"
}

# Extract the "data" field content from JSON response
# Returns the raw content between data: [ ... ] or data: { ... }
json_data_raw() {
    local json="$1"
    # Try array first
    local arr
    arr=$(printf '%s' "$json" | awk '{
        idx = index($0, "\"data\"")
        if (idx > 0) {
            rest = substr($0, idx + 6)
            sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
            if (substr(rest, 1, 1) == "[") {
                sub(/^\[/, "", rest)
                sub(/\][[:space:]]*[,}].*$/, "", rest)
                sub(/\][[:space:]]*$/, "", rest)
                print rest
                exit
            }
            # Object
            if (substr(rest, 1, 1) == "{") {
                sub(/^\{/, "", rest)
                sub(/\}[[:space:]]*[,}].*$/, "", rest)
                sub(/\}[[:space:]]*$/, "", rest)
                print rest
                exit
            }
        }
    }')
    echo "$arr"
}

# Count objects in a JSON array (by counting top-level { } pairs)
# Usage: json_data_count "$json"
json_data_count() {
    local json="$1"
    local raw
    raw=$(json_data_raw "$json")
    if [[ -z "$raw" ]]; then echo "0"; return; fi
    printf '%s' "$raw" | awk '{
        depth=0; count=0; instr=0
        for(i=1;i<=length($0);i++){
            c=substr($0,i,1)
            if(c=="\"" && (i==1 || substr($0,i-1,1)!="\\")){instr=!instr;continue}
            if(instr) continue
            if(c=="{"){depth++;if(depth==1)count++}
            else if(c=="}"){depth--}
        }
        print count
    }'
}

# Extract a field value from the Nth object (0-indexed) in the data array
# Handles nested objects correctly by tracking brace depth
# Usage: json_data_field "$json" 0 "domain"
json_data_field() {
    local json="$1" idx="$2" field="$3"
    local raw
    raw=$(json_data_raw "$json")
    if [[ -z "$raw" ]]; then echo ""; return; fi

    printf '%s' "$raw" | awk -v idx="$idx" -v field="$field" '
    BEGIN { n=0; inobj=0; depth=0; instr=0 }
    {
        for(i=1; i<=length($0); i++) {
            c = substr($0,i,1)
            if (c == "\"" && (i==1 || substr($0,i-1,1) != "\\")) { instr=!instr; continue }
            if (instr) continue
            if (c == "{") { depth++; if(depth==1) { n++; inobj=1; buf="" } }
            else if (c == "}") {
                depth--
                if (depth==0 && inobj && (n-1)==idx) {
                    # Extract field from buf (this is a flat object string)
                    pat = "\"" field "\""
                    pos = index(buf, pat)
                    if (pos > 0) {
                        rest = substr(buf, pos + length(pat))
                        sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
                        if (substr(rest,1,1) == "\"") {
                            sub(/^"/, "", rest)
                            sub(/".*/, "", rest)
                        } else {
                            sub(/[,}\r\n ].*/, "", rest)
                        }
                        print rest
                    }
                    exit
                }
                inobj=0
            }
            else if (inobj && depth >= 1) {
                # Only capture at depth 1 (top-level fields of the object)
                if (depth == 1) buf = buf c
            }
        }
    }'
}

# Check if data is an array or object
json_data_type() {
    local json="$1"
    printf '%s' "$json" | awk '{
        idx = index($0, "\"data\"")
        if (idx > 0) {
            rest = substr($0, idx + 6)
            sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
            if (substr(rest,1,1) == "[") print "array"
            else if (substr(rest,1,1) == "{") print "object"
            else print "other"
        }
    }'
}

# Get top-level status/message from response
json_status() { json_get "$1" "status"; }
json_message() {
    local msg
    msg=$(json_get "$1" "message")
    [[ -z "$msg" ]] && msg=$(json_get "$1" "msg")
    echo "$msg"
}

###############################################################################
# Configuration
###############################################################################
_ensure_config() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    chmod 700 "$CONFIG_DIR" 2>/dev/null
    touch "$CONFIG_FILE" 2>/dev/null
    chmod 600 "$CONFIG_FILE" 2>/dev/null
}

config_load() {
    _ensure_config
    if [[ -f "$CONFIG_FILE" ]]; then
        API_KEY=$(grep '^API_KEY=' "$CONFIG_FILE" | head -1 | cut -d= -f2-)
        export API_KEY
    fi
}

config_save_key() {
    _ensure_config
    local key="$1"
    if [[ -f "$CONFIG_FILE" ]] && grep -q '^API_KEY=' "$CONFIG_FILE"; then
        sed -i "s|^API_KEY=.*|API_KEY=${key}|" "$CONFIG_FILE"
    else
        echo "API_KEY=${key}" >> "$CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE"
    API_KEY="$key"
    export API_KEY
}

###############################################################################
# API Layer
###############################################################################

# Generic POST with Basic Auth
# api_post <url> <body> [content_type]
api_post() {
    local url="$1" body="${2:-{}}" ctype="${3:-application/json}"
    local netrc="${CONFIG_DIR}/.netrc.tmp"
    printf "machine %s login client password %s\n" \
        "$(echo "$url" | sed 's|https\?://||;s|/.*||')" "$API_KEY" > "$netrc"
    chmod 600 "$netrc"

    local resp http_code
    resp=$(curl -sS -w '\n__HTTP_%{http_code}__' \
        --netrc-file "$netrc" \
        -H "Content-Type: $ctype" \
        -X POST "$url" -d "$body" 2>&1)
    local rc=$?
    rm -f "$netrc"

    if (( rc != 0 )); then
        _log ERROR "curl failed ($rc): $resp"
        echo "{\"status\":\"error\",\"message\":\"网络请求失败: $resp\"}"
        return 1
    fi

    http_code=$(echo "$resp" | grep -o '__HTTP_[0-9]*__' | grep -o '[0-9]*')
    resp=$(echo "$resp" | sed '/__HTTP_[0-9]*__/d')

    case "${http_code:-0}" in
        429) echo "{\"status\":\"error\",\"message\":\"请求过于频繁 (HTTP 429)，请稍后再试\"}" ;;
        401|403) echo "{\"status\":\"error\",\"message\":\"认证失败: API Key 无效或已过期 (HTTP ${http_code})\"}" ;;
        0) echo "{\"status\":\"error\",\"message\":\"无法连接服务器，请检查网络\"}" ;;
        *) echo "$resp" ;;
    esac
}

# POST with retry (for important operations)
api_post_retry() {
    local url="$1" body="${2:-{}}" ctype="${3:-application/json}"
    local max_retries=3 resp
    for ((i=1; i<=max_retries; i++)); do
        resp=$(api_post "$url" "$body" "$ctype")
        local st
        st=$(json_status "$resp")
        if [[ "$st" == "success" ]]; then
            echo "$resp"; return 0
        fi
        if (( i < max_retries )); then
            local wait=$(( i * 2 ))
            _log WARN "Attempt $i failed, retrying in ${wait}s..."
            sleep "$wait"
        else
            echo "$resp"; return 1
        fi
    done
}

###############################################################################
# Validation Helpers
###############################################################################
is_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}
is_record_type() {
    local t; t=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    [[ "$t" =~ ^(A|AAAA|MX|CNAME|TXT|NS)$ ]]
}
is_ipv4() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
is_ipv6() {
    [[ "$1" =~ : ]] && [[ "$1" =~ ^[0-9a-fA-F:]+$ ]]
}
is_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

# Colorize record type
_type_color() {
    local t="$1"
    case "$t" in
        A)     echo "${GREEN}${t}${NC}" ;;
        AAAA)  echo "${BLUE}${t}${NC}" ;;
        CNAME) echo "${YELLOW}${t}${NC}" ;;
        MX)    echo "${MAGENTA}${t}${NC}" ;;
        TXT)   echo "${CYAN}${t}${NC}" ;;
        NS)    echo "${RED}${t}${NC}" ;;
        *)     echo "$t" ;;
    esac
}

###############################################################################
# DNS Operations
###############################################################################
dns_list_domains() {
    print_header "DNS 域名列表"

    local resp
    resp=$(api_post "${DNS_API}/domain_list" '{}')
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" != "success" ]]; then
        msg=$(json_message "$resp")
        err "${msg:-获取域名列表失败}"
        return 1
    fi

    local count
    count=$(json_data_count "$resp")
    if (( count == 0 )); then
        info "暂无 DNS 域名"
        return 0
    fi

    # Build data arrays
    local -a domains=()
    for ((i=0; i<count; i++)); do
        local d
        d=$(json_data_field "$resp" "$i" "domain")
        [[ -z "$d" ]] && d=$(json_data_field "$resp" "$i" "name")
        [[ -z "$d" ]] && d=$(json_data_field "$resp" "$i" "zone")
        domains+=("${d:-N/A}")
    done

    # Print table
    sep
    printf "  ${BOLD}%-5s  %-40s${NC}\n" "#" "域名"
    sep
    for ((i=0; i<${#domains[@]}; i++)); do
        printf "  ${CYAN}%-5s${NC}  %-40s\n" "$((i+1))" "${domains[$i]}"
    done
    sep
    info "共 ${#domains[@]} 个域名"
}

dns_list_records() {
    print_header "DNS 记录查询"

    local domain
    domain=$(ask "请输入域名")
    if [[ -z "$domain" ]]; then warn "未输入域名"; return 1; fi
    if ! is_domain "$domain"; then err "无效域名: $domain"; return 1; fi

    local resp
    resp=$(api_post "${DNS_API}/record_list" "{\"domain\":\"${domain}\"}")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" != "success" ]]; then
        msg=$(json_message "$resp")
        err "${msg:-获取记录失败}"
        return 1
    fi

    local count
    count=$(json_data_count "$resp")
    if (( count == 0 )); then
        info "域名 ${domain} 暂无记录"
        return 0
    fi

    # Parse records
    local -a ids=() hosts=() types=() vals=() ttls=()
    for ((i=0; i<count; i++)); do
        ids+=("$(json_data_field "$resp" "$i" "id")")
        local h
        h=$(json_data_field "$resp" "$i" "host")
        [[ -z "$h" ]] && h=$(json_data_field "$resp" "$i" "name")
        hosts+=("${h:-@}")
        types+=("$(json_data_field "$resp" "$i" "type")")
        vals+=("$(json_data_field "$resp" "$i" "value")")
        ttls+=("$(json_data_field "$resp" "$i" "ttl")")
    done

    # Print table
    sep
    printf "  ${BOLD}%-8s %-16s %-8s %-30s %-6s${NC}\n" "ID" "主机" "类型" "值" "TTL"
    sep
    for ((i=0; i<${#ids[@]}; i++)); do
        local type_c
        type_c=$(_type_color "${types[$i]}")
        printf "  %-8s %-16s %b %-30s %-6s\n" \
            "${ids[$i]}" "${hosts[$i]}" "$type_c" "${vals[$i]}" "${ttls[$i]:-300}"
    done
    sep
    info "共 ${#ids[@]} 条记录"
}

dns_create_record() {
    print_header "创建 DNS 记录"

    local domain host rtype value ttl
    domain=$(ask "域名 (如 example.com)")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名: $domain"; return 1; }

    host=$(ask "主机记录 (如 www, @, mail)" "@")
    rtype=$(ask "记录类型 (A/AAAA/MX/CNAME/TXT/NS)" "A")
    rtype=$(echo "$rtype" | tr '[:lower:]' '[:upper:]')
    is_record_type "$rtype" || { err "不支持的记录类型: $rtype"; return 1; }

    value=$(ask "记录值")
    [[ -z "$value" ]] && { warn "未输入记录值"; return 1; }

    # Validate value by type
    case "$rtype" in
        A)    is_ipv4 "$value" || { err "无效 IPv4 地址: $value"; return 1; } ;;
        AAAA) is_ipv6 "$value" || { err "无效 IPv6 地址: $value"; return 1; } ;;
    esac

    ttl=$(ask "TTL (秒)" "600")
    is_number "$ttl" || ttl=600

    # Confirm
    echo ""
    info "即将创建记录:"
    printf "    域名:   %s\n" "$domain"
    printf "    主机:   %s\n" "$host"
    printf "    类型:   %s\n" "$rtype"
    printf "    值:     %s\n" "$value"
    printf "    TTL:    %s\n" "$ttl"
    echo ""
    confirm "确认创建?" "y" || { info "已取消"; return 0; }

    local body
    body=$(printf '{"domain":"%s","host":"%s","type":"%s","value":"%s","ttl":%s}' \
        "$domain" "$host" "$rtype" "$value" "$ttl")

    local resp
    resp=$(api_post "${DNS_API}/record_create" "$body")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" == "success" ]]; then
        ok "记录创建成功: ${host}.${domain} → ${value} (${rtype})"
    else
        msg=$(json_message "$resp")
        err "${msg:-创建记录失败}"
    fi
}

dns_update_record() {
    print_header "更新 DNS 记录"

    local domain record_id value ttl
    domain=$(ask "域名")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名"; return 1; }

    info "提示: 请先使用「查询记录」获取记录 ID"
    record_id=$(ask "记录 ID")
    is_number "$record_id" || { err "无效 ID: $record_id"; return 1; }

    value=$(ask "新的记录值")
    [[ -z "$value" ]] && { warn "未输入新值"; return 1; }
    ttl=$(ask "TTL (秒)" "600")
    is_number "$ttl" || ttl=600

    local body
    body=$(printf '{"domain":"%s","id":%s,"value":"%s","ttl":%s}' \
        "$domain" "$record_id" "$value" "$ttl")

    local resp
    resp=$(api_post "${DNS_API}/record_update" "$body")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" == "success" ]]; then
        ok "记录更新成功: ID ${record_id} → ${value}"
    else
        msg=$(json_message "$resp")
        err "${msg:-更新记录失败}"
    fi
}

dns_delete_record() {
    print_header "删除 DNS 记录"

    local domain record_id
    domain=$(ask "域名")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名"; return 1; }

    info "提示: 请先使用「查询记录」获取记录 ID"
    record_id=$(ask "记录 ID")
    is_number "$record_id" || { err "无效 ID: $record_id"; return 1; }

    echo ""
    warn "即将删除记录: 域名=${domain}, ID=${record_id}"
    confirm "确认删除? 此操作不可恢复" "n" || { info "已取消"; return 0; }

    local body
    body=$(printf '{"domain":"%s","id":%s}' "$domain" "$record_id")

    local resp
    resp=$(api_post "${DNS_API}/record_delete" "$body")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" == "success" ]]; then
        ok "记录已删除: ID ${record_id}"
    else
        msg=$(json_message "$resp")
        err "${msg:-删除记录失败}"
    fi
}

###############################################################################
# DDNS Operations
###############################################################################
ddns_update() {
    print_header "DDNS 动态 IP 更新"

    local domain record_name record_type record_value ttl

    domain=$(ask "域名 (如 example.com 或 sub.example.com)")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名"; return 1; }

    record_name=$(ask "记录名" "@")
    record_type=$(ask "记录类型 (A/AAAA)" "A")
    record_type=$(echo "$record_type" | tr '[:lower:]' '[:upper:]')

    if [[ "$record_type" != "A" && "$record_type" != "AAAA" ]]; then
        err "DDNS 仅支持 A 或 AAAA 记录类型"
        return 1
    fi

    record_value=$(ask "IP 地址 (留空则自动获取当前公网 IP)")

    # Auto-detect public IP
    if [[ -z "$record_value" ]]; then
        info "正在检测公网 IP..."
        if [[ "$record_type" == "A" ]]; then
            record_value=$(curl -sS --max-time 5 https://api.ipify.org 2>/dev/null \
                || curl -sS --max-time 5 https://ifconfig.me 2>/dev/null \
                || curl -sS --max-time 5 https://ip.sb 2>/dev/null)
        else
            record_value=$(curl -sS --max-time 5 https://api6.ipify.org 2>/dev/null \
                || curl -sS --max-time 5 https://ifconfig.me 2>/dev/null)
        fi
        if [[ -z "$record_value" ]]; then
            err "无法获取公网 IP，请手动输入"
            return 1
        fi
        ok "检测到公网 IP: ${record_value}"
    fi

    # Validate IP
    if [[ "$record_type" == "A" ]]; then
        is_ipv4 "$record_value" || { err "无效 IPv4: $record_value"; return 1; }
    else
        is_ipv6 "$record_value" || { err "无效 IPv6: $record_value"; return 1; }
    fi

    ttl=$(ask "TTL (秒)" "300")
    is_number "$ttl" || ttl=300

    # Confirm
    echo ""
    info "DDNS 更新详情:"
    printf "    域名:     %s\n" "$domain"
    printf "    记录名:   %s\n" "$record_name"
    printf "    类型:     %s\n" "$record_type"
    printf "    IP:       %s\n" "$record_value"
    printf "    TTL:      %s\n" "$ttl"
    echo ""
    confirm "确认更新?" "y" || { info "已取消"; return 0; }

    local body
    body=$(printf '{"domain":"%s","record_name":"%s","record_type":"%s","record_value":"%s","ttl":%s}' \
        "$domain" "$record_name" "$record_type" "$record_value" "$ttl")

    local resp
    resp=$(api_post "${DDNS_API}/ddns_update" "$body")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" == "success" ]]; then
        ok "DDNS 更新成功: ${record_name}.${domain} → ${record_value}"
    else
        msg=$(json_message "$resp")
        err "${msg:-DDNS 更新失败}"
    fi
}

###############################################################################
# Certificate Operations
###############################################################################
cert_list() {
    print_header "证书列表"

    local domain
    domain=$(ask "请输入域名")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名"; return 1; }

    local resp
    resp=$(api_post "${CERT_API}/list" "domain=${domain}" "application/x-www-form-urlencoded")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" != "success" ]]; then
        msg=$(json_message "$resp")
        err "${msg:-获取证书列表失败}"
        return 1
    fi

    local dtype count
    dtype=$(json_data_type "$resp")
    count=$(json_data_count "$resp")

    # Handle single object response
    if [[ "$dtype" == "object" ]]; then
        local id issuer expiry cert_status
        id=$(json_get "$resp" "id")
        issuer=$(json_get "$resp" "issuer")
        [[ -z "$issuer" ]] && issuer=$(json_get "$resp" "ca")
        expiry=$(json_get "$resp" "expiry")
        [[ -z "$expiry" ]] && expiry=$(json_get "$resp" "expire")
        [[ -z "$expiry" ]] && expiry=$(json_get "$resp" "not_after")
        cert_status=$(json_get "$resp" "status")

        sep
        printf "  ${BOLD}%-12s %-20s %-22s %-10s${NC}\n" "ID" "签发者" "到期时间" "状态"
        sep
        local sc="${GREEN}"
        [[ "$cert_status" == "expired" ]] && sc="${RED}"
        [[ "$cert_status" == "pending" ]] && sc="${YELLOW}"
        printf "  %-12s %-20s %-22s ${sc}%-10s${NC}\n" \
            "${id:-N/A}" "${issuer:-N/A}" "${expiry:-N/A}" "${cert_status:-N/A}"
        sep
        return 0
    fi

    if (( count == 0 )); then
        info "域名 ${domain} 暂无证书"
        return 0
    fi

    # Parse array
    local -a c_ids=() c_issuers=() c_expiries=() c_statuses=()
    for ((i=0; i<count; i++)); do
        local id issuer expiry cs
        id=$(json_data_field "$resp" "$i" "id")
        issuer=$(json_data_field "$resp" "$i" "issuer")
        [[ -z "$issuer" ]] && issuer=$(json_data_field "$resp" "$i" "ca")
        expiry=$(json_data_field "$resp" "$i" "expiry")
        [[ -z "$expiry" ]] && expiry=$(json_data_field "$resp" "$i" "expire")
        [[ -z "$expiry" ]] && expiry=$(json_data_field "$resp" "$i" "not_after")
        cs=$(json_data_field "$resp" "$i" "status")
        c_ids+=("${id:-N/A}")
        c_issuers+=("${issuer:-N/A}")
        c_expiries+=("${expiry:-N/A}")
        c_statuses+=("${cs:-N/A}")
    done

    sep
    printf "  ${BOLD}%-12s %-20s %-22s %-10s${NC}\n" "ID" "签发者" "到期时间" "状态"
    sep
    for ((i=0; i<${#c_ids[@]}; i++)); do
        local sc="${GREEN}"
        [[ "${c_statuses[$i]}" == "expired" ]] && sc="${RED}"
        [[ "${c_statuses[$i]}" == "pending" ]] && sc="${YELLOW}"
        printf "  %-12s %-20s %-22s ${sc}%-10s${NC}\n" \
            "${c_ids[$i]}" "${c_issuers[$i]}" "${c_expiries[$i]}" "${c_statuses[$i]}"
    done
    sep
    info "共 ${#c_ids[@]} 个证书"
}

cert_download() {
    print_header "下载证书"

    local domain dl_type
    domain=$(ask "域名")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名"; return 1; }

    echo ""
    info "下载类型:"
    printf "    ${CYAN}1${NC}) fullchain  — 完整证书链\n"
    printf "    ${CYAN}2${NC}) cert       — 仅证书\n"
    printf "    ${CYAN}3${NC}) privkey    — 私钥\n"
    printf "    ${CYAN}4${NC}) bundle     — 打包下载\n"
    echo ""
    local choice
    choice=$(ask "选择下载类型 (1-4)" "1")
    case "$choice" in
        1|fullchain) dl_type="fullchain" ;;
        2|cert)      dl_type="cert" ;;
        3|privkey)   dl_type="privkey" ;;
        4|bundle)    dl_type="bundle" ;;
        *)           dl_type="fullchain" ;;
    esac

    local save_dir="${SCRIPT_DIR}/certs/${domain}"
    mkdir -p "$save_dir" 2>/dev/null

    info "正在下载 ${dl_type}..."
    local resp
    resp=$(api_post_retry "${CERT_API}/download" "domain=${domain}&type=${dl_type}" \
        "application/x-www-form-urlencoded")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" != "success" ]]; then
        msg=$(json_message "$resp")
        err "${msg:-下载失败}"
        return 1
    fi

    # Extract PEM content
    local content
    content=$(json_get "$resp" "content")
    [[ -z "$content" ]] && content=$(json_get "$resp" "certificate")
    [[ -z "$content" ]] && content=$(json_get "$resp" "pem")
    [[ -z "$content" ]] && content=$(json_get "$resp" "data")

    if [[ -z "$content" ]]; then
        # Maybe raw PEM in response
        if echo "$resp" | grep -q "BEGIN"; then
            content="$resp"
        fi
    fi

    if [[ -n "$content" ]]; then
        # Unescape \n
        content=$(printf '%b' "$content")
        local fname
        case "$dl_type" in
            fullchain) fname="fullchain.pem" ;;
            cert)      fname="cert.pem" ;;
            privkey)   fname="privkey.pem" ;;
            bundle)    fname="bundle.tar.gz" ;;
            *)         fname="cert.pem" ;;
        esac
        printf '%s' "$content" > "${save_dir}/${fname}"
        # Set permissions
        if [[ "$dl_type" == "privkey" ]]; then
            chmod 600 "${save_dir}/${fname}"
        else
            chmod 644 "${save_dir}/${fname}"
        fi
        ok "已保存: ${save_dir}/${fname}"
    else
        err "未获取到证书内容"
    fi
}

cert_renew() {
    print_header "续签证书"

    local domain
    domain=$(ask "域名")
    [[ -z "$domain" ]] && { warn "未输入域名"; return 1; }
    is_domain "$domain" || { err "无效域名"; return 1; }

    confirm "确认续签 ${domain} 的证书?" "y" || { info "已取消"; return 0; }

    info "正在发起续签请求..."
    local resp
    resp=$(api_post_retry "${CERT_API}/renew" "domain=${domain}" \
        "application/x-www-form-urlencoded")
    local st msg
    st=$(json_status "$resp")

    if [[ "$st" == "success" ]]; then
        ok "证书续签请求已提交: ${domain}"
        info "证书签发可能需要几分钟，请稍后查看证书列表确认状态"
    else
        msg=$(json_message "$resp")
        err "${msg:-续签失败}"
    fi
}

###############################################################################
# Settings
###############################################################################
settings_api_key() {
    print_header "API Key 设置"

    if [[ -n "$API_KEY" ]]; then
        info "当前 API Key: $(mask_str "$API_KEY")"
    else
        warn "尚未配置 API Key"
    fi

    echo ""
    info "获取方式:"
    printf "    1. 登录 ${CYAN}%s${NC}\n" "$API_BASE"
    printf "    2. 打开 ${BOLD}Account / Profile${NC} 设置\n"
    printf "    3. 找到 ${BOLD}API Key${NC} 区域，生成或复制 Key\n"
    echo ""

    local new_key
    new_key=$(ask_secure "请输入 API Key")
    if [[ -n "$new_key" ]]; then
        config_save_key "$new_key"
        ok "API Key 已保存至 ${CONFIG_FILE}"
    else
        info "未输入，保持原设置"
    fi
}

settings_view() {
    print_header "设置信息"

    info "配置文件: ${CONFIG_FILE}"
    info "日志文件: ${CONFIG_DIR}/app.log"
    if [[ -n "$API_KEY" ]]; then
        info "API Key:  $(mask_str "$API_KEY")"
    else
        warn "API Key:  未配置"
    fi
    info "API 地址: ${API_BASE}"
    info "状态页面: ${STATUS_URL}"
    info "版本:     v${VERSION}"
}

###############################################################################
# Submenus
###############################################################################
menu_dns() {
    while true; do
        print_header "DNS 记录管理"
        printf "    ${CYAN}1${NC}) 列出所有域名\n"
        printf "    ${CYAN}2${NC}) 查询域名记录\n"
        printf "    ${CYAN}3${NC}) 创建记录\n"
        printf "    ${CYAN}4${NC}) 更新记录\n"
        printf "    ${CYAN}5${NC}) 删除记录\n"
        echo ""
        printf "    ${CYAN}0${NC}) 返回主菜单\n"
        echo ""
        local choice
        choice=$(ask "请选择" "0")
        case "$choice" in
            1) dns_list_domains; read -rp "  按 Enter 继续..." _ ;;
            2) dns_list_records; read -rp "  按 Enter 继续..." _ ;;
            3) dns_create_record; read -rp "  按 Enter 继续..." _ ;;
            4) dns_update_record; read -rp "  按 Enter 继续..." _ ;;
            5) dns_delete_record; read -rp "  按 Enter 继续..." _ ;;
            0|*) return ;;
        esac
    done
}

menu_cert() {
    while true; do
        print_header "证书管理"
        printf "    ${CYAN}1${NC}) 查询证书\n"
        printf "    ${CYAN}2${NC}) 下载证书\n"
        printf "    ${CYAN}3${NC}) 续签证书\n"
        echo ""
        printf "    ${CYAN}0${NC}) 返回主菜单\n"
        echo ""
        local choice
        choice=$(ask "请选择" "0")
        case "$choice" in
            1) cert_list; read -rp "  按 Enter 继续..." _ ;;
            2) cert_download; read -rp "  按 Enter 继续..." _ ;;
            3) cert_renew; read -rp "  按 Enter 继续..." _ ;;
            0|*) return ;;
        esac
    done
}

menu_settings() {
    while true; do
        print_header "设置"
        printf "    ${CYAN}1${NC}) 配置 API Key\n"
        printf "    ${CYAN}2${NC}) 查看设置信息\n"
        printf "    ${CYAN}3${NC}) 查看服务状态\n"
        echo ""
        printf "    ${CYAN}0${NC}) 返回主菜单\n"
        echo ""
        local choice
        choice=$(ask "请选择" "0")
        case "$choice" in
            1) settings_api_key; read -rp "  按 Enter 继续..." _ ;;
            2) settings_view; read -rp "  按 Enter 继续..." _ ;;
            3) info "正在打开状态页面..."; echo "  ${CYAN}${STATUS_URL}${NC}" ;;
            0|*) return ;;
        esac
    done
}

###############################################################################
# CLI Mode (non-interactive, for scripting/cron)
###############################################################################
cli_usage() {
    cat << 'EOF'

  vps8 DNS Manager — CLI 用法

  DNS 记录管理:
    domains                     列出所有 DNS 域名
    records <domain>            列出指定域名的 DNS 记录
    create <domain> <host> <type> <value> [ttl]
                                创建 DNS 记录
    update <domain> <id> <value> [ttl]
                                更新 DNS 记录
    delete <domain> <id>        删除 DNS 记录

  DDNS:
    ddns <domain> [type] [value] [name] [ttl]
                                DDNS 动态更新 (默认 A 记录)

  证书管理:
    cert-list <domain>          查询证书
    cert-download <domain> [type]
                                下载证书 (fullchain/cert/privkey/bundle)
    cert-renew <domain>         续签证书

  设置:
    set-key <api_key>           配置 API Key
    status                      查看状态信息
    version                     显示版本
    help                        显示此帮助

  示例:
    ./vps8-dns-manager.sh domains
    ./vps8-dns-manager.sh records example.com
    ./vps8-dns-manager.sh create example.com www A 1.2.3.4 600
    ./vps8-dns-manager.sh ddns example.com A
    ./vps8-dns-manager.sh cert-list example.com
    ./vps8-dns-manager.sh cert-download example.com fullchain

EOF
}

cli_dispatch() {
    local cmd="$1"; shift

    case "$cmd" in
        # DNS
        domains)
            dns_list_domains ;;
        records)
            [[ $# -lt 1 ]] && { err "用法: records <domain>"; return 1; }
            # Override ask to return args
            local domain="$1"
            if ! is_domain "$domain"; then err "无效域名: $domain"; return 1; fi
            local resp
            resp=$(api_post "${DNS_API}/record_list" "{\"domain\":\"${domain}\"}")
            local st
            st=$(json_status "$resp")
            if [[ "$st" != "success" ]]; then
                err "$(json_message "$resp")"
                return 1
            fi
            local count
            count=$(json_data_count "$resp")
            if (( count == 0 )); then
                echo "No records found for ${domain}"
                return 0
            fi
            printf "%-8s %-20s %-8s %-30s %-6s\n" "ID" "HOST" "TYPE" "VALUE" "TTL"
            for ((i=0; i<count; i++)); do
                local id host rtype val ttl
                id=$(json_data_field "$resp" "$i" "id")
                host=$(json_data_field "$resp" "$i" "host")
                [[ -z "$host" ]] && host=$(json_data_field "$resp" "$i" "name")
                rtype=$(json_data_field "$resp" "$i" "type")
                val=$(json_data_field "$resp" "$i" "value")
                ttl=$(json_data_field "$resp" "$i" "ttl")
                printf "%-8s %-20s %-8s %-30s %-6s\n" "$id" "${host:-@}" "$rtype" "$val" "${ttl:-300}"
            done
            ;;
        create)
            [[ $# -lt 4 ]] && { err "用法: create <domain> <host> <type> <value> [ttl]"; return 1; }
            local domain="$1" host="$2" rtype="$3" value="$4" ttl="${5:-600}"
            rtype=$(echo "$rtype" | tr '[:lower:]' '[:upper:]')
            is_domain "$domain" || { err "无效域名"; return 1; }
            is_record_type "$rtype" || { err "不支持的类型: $rtype"; return 1; }
            local body
            body=$(printf '{"domain":"%s","host":"%s","type":"%s","value":"%s","ttl":%s}' \
                "$domain" "$host" "$rtype" "$value" "$ttl")
            local resp
            resp=$(api_post "${DNS_API}/record_create" "$body")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                ok "Created: ${host}.${domain} ${rtype} ${value}"
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;
        update)
            [[ $# -lt 3 ]] && { err "用法: update <domain> <id> <value> [ttl]"; return 1; }
            local domain="$1" rid="$2" value="$3" ttl="${4:-600}"
            is_domain "$domain" || { err "无效域名"; return 1; }
            is_number "$rid" || { err "无效 ID"; return 1; }
            local body
            body=$(printf '{"domain":"%s","id":%s,"value":"%s","ttl":%s}' \
                "$domain" "$rid" "$value" "$ttl")
            local resp
            resp=$(api_post "${DNS_API}/record_update" "$body")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                ok "Updated: ID ${rid} → ${value}"
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;
        delete)
            [[ $# -lt 2 ]] && { err "用法: delete <domain> <id>"; return 1; }
            local domain="$1" rid="$2"
            is_domain "$domain" || { err "无效域名"; return 1; }
            is_number "$rid" || { err "无效 ID"; return 1; }
            local body
            body=$(printf '{"domain":"%s","id":%s}' "$domain" "$rid")
            local resp
            resp=$(api_post "${DNS_API}/record_delete" "$body")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                ok "Deleted: ID ${rid}"
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;

        # DDNS
        ddns)
            [[ $# -lt 1 ]] && { err "用法: ddns <domain> [type] [value] [name] [ttl]"; return 1; }
            local domain="$1" rtype="${2:-A}" value="${3:-}" rname="${4:-@}" ttl="${5:-300}"
            rtype=$(echo "$rtype" | tr '[:lower:]' '[:upper:]')
            is_domain "$domain" || { err "无效域名"; return 1; }
            [[ "$rtype" != "A" && "$rtype" != "AAAA" ]] && { err "DDNS 仅支持 A/AAAA"; return 1; }
            # Auto-detect IP if not provided
            if [[ -z "$value" ]]; then
                if [[ "$rtype" == "A" ]]; then
                    value=$(curl -sS --max-time 5 https://api.ipify.org 2>/dev/null \
                        || curl -sS --max-time 5 https://ifconfig.me 2>/dev/null)
                else
                    value=$(curl -sS --max-time 5 https://api6.ipify.org 2>/dev/null)
                fi
                [[ -z "$value" ]] && { err "无法获取公网 IP"; return 1; }
            fi
            local body
            body=$(printf '{"domain":"%s","record_name":"%s","record_type":"%s","record_value":"%s","ttl":%s}' \
                "$domain" "$rname" "$rtype" "$value" "$ttl")
            local resp
            resp=$(api_post "${DDNS_API}/ddns_update" "$body")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                ok "DDNS: ${rname}.${domain} → ${value} (${rtype})"
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;

        # Certs
        cert-list)
            [[ $# -lt 1 ]] && { err "用法: cert-list <domain>"; return 1; }
            local domain="$1"
            is_domain "$domain" || { err "无效域名"; return 1; }
            local resp
            resp=$(api_post "${CERT_API}/list" "domain=${domain}" "application/x-www-form-urlencoded")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                printf "%s\n" "$resp"
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;
        cert-download)
            [[ $# -lt 1 ]] && { err "用法: cert-download <domain> [type]"; return 1; }
            local domain="$1" dl_type="${2:-fullchain}"
            is_domain "$domain" || { err "无效域名"; return 1; }
            local save_dir="${SCRIPT_DIR}/certs/${domain}"
            mkdir -p "$save_dir" 2>/dev/null
            local resp
            resp=$(api_post_retry "${CERT_API}/download" "domain=${domain}&type=${dl_type}" \
                "application/x-www-form-urlencoded")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                local content
                content=$(json_get "$resp" "content")
                [[ -z "$content" ]] && content=$(json_get "$resp" "certificate")
                if [[ -n "$content" ]]; then
                    local fname="${dl_type}.pem"
                    [[ "$dl_type" == "bundle" ]] && fname="bundle.tar.gz"
                    printf '%b' "$content" > "${save_dir}/${fname}"
                    ok "Saved: ${save_dir}/${fname}"
                else
                    err "未获取到证书内容"
                    return 1
                fi
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;
        cert-renew)
            [[ $# -lt 1 ]] && { err "用法: cert-renew <domain>"; return 1; }
            local domain="$1"
            is_domain "$domain" || { err "无效域名"; return 1; }
            local resp
            resp=$(api_post_retry "${CERT_API}/renew" "domain=${domain}" \
                "application/x-www-form-urlencoded")
            if [[ "$(json_status "$resp")" == "success" ]]; then
                ok "Renewal submitted: ${domain}"
            else
                err "$(json_message "$resp")"
                return 1
            fi
            ;;

        # Settings
        set-key)
            [[ $# -lt 1 ]] && { err "用法: set-key <api_key>"; return 1; }
            config_save_key "$1"
            ok "API Key 已保存"
            ;;
        status)
            settings_view ;;
        version|-v|--version)
            echo "vps8-dns-manager v${VERSION}" ;;
        help|-h|--help)
            cli_usage ;;
        *)
            err "未知命令: $cmd"
            cli_usage
            return 1
            ;;
    esac
}

###############################################################################
# Interactive Main Menu
###############################################################################
menu_main() {
    NAV_STACK=("main")

    while true; do
        print_banner
        echo ""
        printf "  ${BOLD}━━━ DNS 管理 ━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        printf "    ${CYAN}1${NC}) 列出所有域名\n"
        printf "    ${CYAN}2${NC}) 查询 DNS 记录\n"
        printf "    ${CYAN}3${NC}) 创建 DNS 记录\n"
        printf "    ${CYAN}4${NC}) 更新 DNS 记录\n"
        printf "    ${CYAN}5${NC}) 删除 DNS 记录\n"
        echo ""
        printf "  ${BOLD}━━━ DDNS ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        printf "    ${CYAN}6${NC}) DDNS 动态 IP 更新\n"
        echo ""
        printf "  ${BOLD}━━━ 证书管理 ━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        printf "    ${CYAN}7${NC}) 查询证书\n"
        printf "    ${CYAN}8${NC}) 下载证书\n"
        printf "    ${CYAN}9${NC}) 续签证书\n"
        echo ""
        printf "  ${BOLD}━━━ 系统 ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        printf "    ${YELLOW}s${NC}) API Key 设置"
        if [[ -n "$API_KEY" ]]; then
            printf "  ${DIM}[$(mask_str "$API_KEY")]${NC}"
        else
            printf "  ${RED}[未配置]${NC}"
        fi
        echo ""
        printf "    ${YELLOW}i${NC}) 查看信息\n"
        printf "    ${YELLOW}q${NC}) 退出\n"
        echo ""
        sep

        local choice
        choice=$(ask "请选择操作" "")
        echo ""

        case "$choice" in
            1) dns_list_domains; read -rp "  按 Enter 继续..." _ ;;
            2) dns_list_records; read -rp "  按 Enter 继续..." _ ;;
            3) dns_create_record; read -rp "  按 Enter 继续..." _ ;;
            4) dns_update_record; read -rp "  按 Enter 继续..." _ ;;
            5) dns_delete_record; read -rp "  按 Enter 继续..." _ ;;
            6) ddns_update; read -rp "  按 Enter 继续..." _ ;;
            7) cert_list; read -rp "  按 Enter 继续..." _ ;;
            8) cert_download; read -rp "  按 Enter 继续..." _ ;;
            9) cert_renew; read -rp "  按 Enter 继续..." _ ;;
            s|S) settings_api_key; read -rp "  按 Enter 继续..." _ ;;
            i|I) settings_view; read -rp "  按 Enter 继续..." _ ;;
            q|Q|0) echo -e "  ${GREEN}再见!${NC}\n"; exit 0 ;;
            *) warn "无效选项: $choice"; sleep 1 ;;
        esac
    done
}

###############################################################################
# Entry Point
###############################################################################
main() {
    # Load config
    config_load

    # Check API key for non-settings commands
    if [[ -z "$API_KEY" ]]; then
        # Allow help/version/set-key without API key
        if [[ $# -gt 0 ]]; then
            case "$1" in
                help|-h|--help|version|-v|--version|set-key) ;;
                *)
                    print_banner
                    echo ""
                    warn "尚未配置 API Key"
                    info "请先运行以下命令配置:"
                    printf "    ${CYAN}./%s set-key YOUR_API_KEY${NC}\n" "$SCRIPT_NAME"
                    info "或在交互模式中选择 's' 进行配置"
                    echo ""
                    ;;
            esac
        fi
    fi

    # CLI mode or interactive mode
    if [[ $# -gt 0 ]]; then
        cli_dispatch "$@"
    else
        menu_main
    fi
}

main "$@"
