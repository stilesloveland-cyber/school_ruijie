#!/bin/sh
#================================================================
# qhulogin - 锐捷ePortal自动认证工具
# Version: 2.9 (Lightweight & Stable Edition)
# 架构：极简 Curl 容器 / API级连通校验 / 10次轻量熔断 / 兼容 mihomo
# 平台：iStoreOS / OpenWrt / N1旁路由 / 复杂多线负载
#================================================================

set -u

#================================================================
# 全局变量与路径
#================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

readonly CONF_DIR="/etc/qhulogin"
readonly CONF_FILE="${CONF_DIR}/qhulogin.conf"
readonly LOG_FILE="/var/log/qhulogin.log"
readonly LOCK_FILE="/var/run/qhulogin.lock"
readonly INIT_SCRIPT="/etc/init.d/qhulogin"
readonly CACHE_FILE="${CONF_DIR}/.login_cache"
readonly FAIL_COUNT_FILE="/tmp/qhulogin_fail_count"
readonly PROBE_URLS="http://www.google.cn/generate_204 http://connect.rom.miui.com/generate_204 http://captive.apple.com/hotspot-detect.html"

export LOCK_TYPE=""

#================================================================
# 状态持久化：物理级熔断器
#================================================================
get_fail_count() { cat "$FAIL_COUNT_FILE" 2>/dev/null || echo "0"; }
inc_fail_count() { echo $(($(get_fail_count) + 1)) > "$FAIL_COUNT_FILE"; }
reset_fail_count() { rm -f "$FAIL_COUNT_FILE"; }

#================================================================
# 核心防御：单实例与 FD 安全释放
#================================================================
acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCK_FILE"
        if ! flock -n 9; then
            echo -e "${RED}[ERROR]${NC} 保活守护已在运行，拦截并发重入。"
            exit 1
        fi
        LOCK_TYPE="flock"
    else
        if ! mkdir "${LOCK_FILE}.d" 2>/dev/null; then
            # 检查锁是否为残留（原进程已死）
            local lock_pid=""
            lock_pid=$(cat "${LOCK_FILE}.d/pid" 2>/dev/null)
            if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
                echo -e "${RED}[ERROR]${NC} 保活守护已在运行 (PID: $lock_pid)。"
                exit 1
            fi
            # 残留锁，清理后重新获取
            rm -rf "${LOCK_FILE}.d"
            if ! mkdir "${LOCK_FILE}.d" 2>/dev/null; then
                echo -e "${RED}[ERROR]${NC} 无法获取锁。"
                exit 1
            fi
        fi
        echo $$ > "${LOCK_FILE}.d/pid"
        LOCK_TYPE="mkdir"
    fi
}

release_lock() {
    [ "$LOCK_TYPE" = "flock" ] && exec 9>&-
    [ "$LOCK_TYPE" = "mkdir" ] && rm -rf "${LOCK_FILE}.d"
}

is_daemon_running() {
    if command -v flock >/dev/null 2>&1; then
        ( exec 9>"$LOCK_FILE"; flock -n 9 ) && return 1 || return 0
    else
        if [ -d "${LOCK_FILE}.d" ]; then
            local lock_pid=""
            lock_pid=$(cat "${LOCK_FILE}.d/pid" 2>/dev/null)
            # 有PID且进程存活才算运行中，否则是残留锁
            [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null && return 0
            rm -rf "${LOCK_FILE}.d" 2>/dev/null
            return 1
        fi
        return 1
    fi
}

#================================================================
# 工具函数 & 安全日志轮转
#================================================================
shell_escape() {
    printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_size
    
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null

    log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$log_size" -gt 102400 ] 2>/dev/null; then
        mv "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
    fi
}

print_info()    { echo -e "${CYAN}[INFO]${NC} $*"; log_msg "INFO" "$*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; log_msg "SUCCESS" "$*"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log_msg "WARN" "$*"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*"; log_msg "ERROR" "$*"; }

#================================================================
# 配置与缓存管理 (纯文本解析引擎)
#================================================================
safe_get() {
    local key="$1"
    local file="$2"
    sed -n "s/^$key=//p" "$file" 2>/dev/null | head -1 | sed "s/^'//; s/'$//" | sed "s/'\\\\''/'/g"
}

load_config() {
    [ ! -f "$CONF_FILE" ] && return 1
    USERNAME=$(safe_get "USERNAME" "$CONF_FILE")
    PASSWORD=$(safe_get "PASSWORD" "$CONF_FILE")
    SERVICE=$(safe_get "SERVICE" "$CONF_FILE")
    PING_INTERVAL=$(safe_get "PING_INTERVAL" "$CONF_FILE")
    WAN_INTERFACES=$(safe_get "WAN_INTERFACES" "$CONF_FILE")
    FORCE_RELOGIN_AT=$(safe_get "FORCE_RELOGIN_AT" "$CONF_FILE")
    ENCODE_QUERY=$(safe_get "ENCODE_QUERY" "$CONF_FILE")
    
    [ -z "$PING_INTERVAL" ] && PING_INTERVAL="30"
    [ -z "$SERVICE" ] && SERVICE="campus"
    [ -z "$ENCODE_QUERY" ] && ENCODE_QUERY="0"
    return 0
}

save_config() {
    mkdir -p "$CONF_DIR" 2>/dev/null
    cat > "$CONF_FILE" << EOF
USERNAME=$(shell_escape "${USERNAME:-}")
PASSWORD=$(shell_escape "${PASSWORD:-}")
SERVICE=$(shell_escape "${SERVICE:-}")
PING_INTERVAL=$(shell_escape "${PING_INTERVAL:-30}")
WAN_INTERFACES=$(shell_escape "${WAN_INTERFACES:-}")
FORCE_RELOGIN_AT=$(shell_escape "${FORCE_RELOGIN_AT:-}")
ENCODE_QUERY=$(shell_escape "${ENCODE_QUERY:-0}")
EOF
    chmod 600 "$CONF_FILE"
}

load_cache() { 
    [ ! -f "$CACHE_FILE" ] && return
    CACHE_EPORTAL_HOST=$(safe_get "CACHE_EPORTAL_HOST" "$CACHE_FILE")
    CACHE_LOGIN_URL=$(safe_get "CACHE_LOGIN_URL" "$CACHE_FILE")
    CACHE_QUERY_STRING=$(safe_get "CACHE_QUERY_STRING" "$CACHE_FILE")
    CACHE_TIMESTAMP=$(safe_get "CACHE_TIMESTAMP" "$CACHE_FILE")
    # 缓存超过300秒强制过期
    local now_sec=$(date +%s)
    if [ -n "${CACHE_TIMESTAMP:-}" ] && [ $((now_sec - ${CACHE_TIMESTAMP:-0})) -gt 300 ]; then
        CACHE_EPORTAL_HOST=""
        CACHE_LOGIN_URL=""
        CACHE_QUERY_STRING=""
    fi
}

save_cache() {
    mkdir -p "$CONF_DIR" 2>/dev/null
    cat > "$CACHE_FILE" << EOF
CACHE_EPORTAL_HOST=$(shell_escape "${CACHE_EPORTAL_HOST:-}")
CACHE_LOGIN_URL=$(shell_escape "${CACHE_LOGIN_URL:-}")
CACHE_QUERY_STRING=$(shell_escape "${CACHE_QUERY_STRING:-}")
CACHE_TIMESTAMP=$(date +%s)
EOF
}

clear_session_cache() {
    unset CACHE_LOGIN_URL CACHE_QUERY_STRING 2>/dev/null || true
    save_cache
}

get_service_string() {
    case "$1" in
        unicom)  echo "%25E6%25A0%25A1%25E5%259B%25AD%25E8%2581%2594%25E9%2580%259A" ;;
        telecom) echo "%25E6%25A0%25A1%25E5%259B%25AD%25E7%2594%25B5%25E4%25BF%25A1" ;;
        mobile)  echo "%25E6%25A0%25A1%25E5%259B%25AD%25E7%25A7%25BB%25E5%258A%25A8" ;;
        *)       echo "%25E6%25A0%25A1%25E5%259B%25AD%25E7%25BD%2591" ;;
    esac
}

get_service_name() {
    case "$1" in
        unicom)  echo "校园联通" ;; telecom) echo "校园电信" ;;
        mobile)  echo "校园移动" ;; *) echo "校园网" ;;
    esac
}

#================================================================
# 极简 Curl 容器 (直接利用 noproxy 与原生 Root 网卡绑定)
#================================================================
# 检测 curl 是否支持 --noproxy（首次调用时检测并缓存结果）
_CURL_NOPROXY_OK=""
run_curl() {
    if [ -z "$_CURL_NOPROXY_OK" ]; then
        if curl --noproxy '*' -s -m 1 -o /dev/null http://127.0.0.1 2>/dev/null; then
            _CURL_NOPROXY_OK="1"
        else
            _CURL_NOPROXY_OK="0"
        fi
    fi

    local noproxy_arg=""
    [ "$_CURL_NOPROXY_OK" = "1" ] && noproxy_arg="--noproxy '*'"

    if [ -n "${LOGIN_INTERFACE:-}" ]; then
        curl $noproxy_arg --interface "$LOGIN_INTERFACE" "$@" 2>/dev/null
    else
        curl $noproxy_arg "$@" 2>/dev/null
    fi
}

#================================================================
# 内核级 ubus 接口嗅探 (添加 mihomo/Meta 黑名单)
#================================================================
detect_wlan_clients() {
    local devs=""
    local iface=""

    if [ -n "${WAN_INTERFACES:-}" ]; then
        for iface in $WAN_INTERFACES; do
            ip -4 addr show dev "$iface" 2>/dev/null | grep -q 'inet ' && echo "$iface"
        done | tr ' ' '\n' | grep -v '^$' | sort -u
        return
    fi
    
    if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
        devs=$(ubus call network.interface dump 2>/dev/null | jsonfilter -e '@.interface[@.up=true].l3_device' 2>/dev/null)
    fi
    
    if [ -z "$devs" ]; then
        # fallback: 取有IPv4的接口，但排除内网AP段 (192.168.x.x / 10.x.x.x / 172.16-31.x.x)
        devs=$(ip -4 addr show 2>/dev/null | awk '/inet / {
            ip=$2; iface=$NF;
            split(ip, a, "/"); addr=a[1];
            if (addr !~ /^192\.168\./ && addr !~ /^10\./ && addr !~ /^172\.(1[6-9]|2[0-9]|3[01])\./) print iface
        }')
    fi

    # 纯黑名单过滤：拦截内网桥接及各种代理内核隧道
    echo "$devs" | grep -vE '^(lo|br-|docker|veth|ifb|tun|tap|clash|mihomo|Meta|wg|wireguard)' | sort -u
}

#================================================================
# API置顶 与 三体探针探测
#================================================================
discover_eportal_host() {
    local location=""
    local url=""
    local host=""
    local gw_resp=""

    load_cache
    [ -n "${CACHE_EPORTAL_HOST:-}" ] && { echo "$CACHE_EPORTAL_HOST"; return; }

    for url in $PROBE_URLS; do
        location=$(run_curl -s -I -m 3 -L -o /dev/null -w '%{redirect_url}' "$url" 2>/dev/null)
        
        if [ -z "$location" ]; then
            gw_resp=$(run_curl -s -m 3 "$url")
            location=$(echo "$gw_resp" | grep -oE "href='[^']+'" | head -1 | sed "s/href='//;s/'//")
            [ -z "$location" ] && location=$(echo "$gw_resp" | grep -oE 'href="[^"]+"' | head -1 | sed 's/href="//;s/"//')
            [ -z "$location" ] && location=$(echo "$gw_resp" | grep -oE "location\.href='[^']+'" | head -1 | sed "s/location\.href='//;s/'//")
            [ -z "$location" ] && location=$(echo "$gw_resp" | grep -oE 'window\.location="[^"]+"' | head -1 | sed 's/window\.location="//;s/"//')
            [ -z "$location" ] && location=$(echo "$gw_resp" | grep -oiE 'url=[^"]+' | head -1 | sed 's/[Uu][Rr][Ll]=//')
        fi
        
        [ -n "$location" ] && break
    done

    if [ -n "$location" ]; then
        host=$(echo "$location" | sed -n 's|.*://\([^/]*\).*|\1|p' | head -1)
        if [ -n "$host" ]; then
            CACHE_EPORTAL_HOST="$host"
            save_cache
            echo "$host"
        fi
    fi
}

check_iface_online() {
    local iface="$1"
    local url=""
    local code=""
    local iface_ip=""
    local saved_login_iface="${LOGIN_INTERFACE:-}"

    # 无IP不测
    iface_ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    [ -z "$iface_ip" ] && return 1

    # 1. 优先调用 Portal API
    load_cache
    load_config 2>/dev/null
    if [ -n "${USERNAME:-}" ] && [ -n "${CACHE_EPORTAL_HOST:-}" ]; then
        local info_resp
        LOGIN_INTERFACE="$iface"
        info_resp=$(run_curl -s -m 3 -d "userId=${USERNAME}" "http://${CACHE_EPORTAL_HOST}/eportal/InterFace.do?method=getOnlineUserInfo")
        LOGIN_INTERFACE="$saved_login_iface"
        # 兼容整型与字符串 userIndex（排除 null 和空值）
        if echo "$info_resp" | grep -qE '"userIndex"[[:space:]]*:[[:space:]]*"[^",}]+'; then
            return 0
        fi
        if echo "$info_resp" | grep -qE '"userIndex"[[:space:]]*:[[:space:]]*[1-9][0-9]*'; then
            return 0
        fi
    fi

    # 2. 探针 fallback
    for url in $PROBE_URLS; do
        LOGIN_INTERFACE="$iface"
        code=$(run_curl -s -I -m 3 -o /dev/null -w '%{http_code}' "$url")
        LOGIN_INTERFACE="$saved_login_iface"
        [ "$code" = "204" ] && return 0
        [ "$code" = "200" ] && echo "$url" | grep -q "apple" && return 0
    done

    return 1
}

# 全局连通性仅检测主路由，防链路风暴
check_global_online() {
    local eportal_host=""
    local info_resp=""
    local default_iface=""

    load_config 2>/dev/null
    
    # 必须通过默认接口检测，避免旁路由场景下全局探针误判
    default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
    if [ -n "$default_iface" ]; then
        check_iface_online "$default_iface" && return 0 || return 1
    fi
    
    return 1
}

bind_iface_and_login() {
    export LOGIN_INTERFACE="$1"
    do_login force
    unset LOGIN_INTERFACE
}

#================================================================
# 安全加密 (Mktemp 隔离)
#================================================================
rsa_encrypt_password() {
    local pubkey="$1"
    local password="$2"
    local pubkey_file=""
    local encrypted=""

    pubkey_file=$(mktemp /tmp/qhulogin_pubkey.XXXXXX 2>/dev/null || echo "/tmp/qhulogin_pubkey_$$.pem")
    
    echo "-----BEGIN PUBLIC KEY-----" > "$pubkey_file"
    echo "$pubkey" | fold -w 64 >> "$pubkey_file"
    echo "-----END PUBLIC KEY-----" >> "$pubkey_file"

    if command -v openssl >/dev/null 2>&1; then
        encrypted=$(echo -n "$password" | openssl pkeyutl -encrypt -pubin -inkey "$pubkey_file" -pkeyopt rsa_padding_mode:pkcs1 2>/dev/null | xxd -p -c 256 | tr 'a-f' 'A-F')
        [ -z "$encrypted" ] && encrypted=$(echo -n "$password" | openssl rsautl -encrypt -pubin -inkey "$pubkey_file" -pkcs 2>/dev/null | xxd -p -c 256 | tr 'a-f' 'A-F')
    fi
    rm -f "$pubkey_file"

    [ -n "$encrypted" ] && { echo "$encrypted"; return 0; } || return 1
}

#================================================================
# 核心认证引擎
#================================================================
do_login() {
    local force="${1:-}"
    local my_iface=""
    local my_ip=""
    local ip_tag=""
    local login_page_url=""
    local eportal_host=""
    local gw_resp=""
    local login_url=""
    local query_string=""
    local login_html=""
    local rsa_key=""
    local encrypted_password=""
    local password_encrypt="false"
    local enc=""
    local service_string=""
    local result=""
    local current_fails=""
    local default_iface=""
    local other=""

    if ! load_config || [ -z "${USERNAME:-}" ]; then
        print_error "无可用配置，请先运行 config"
        return 1
    fi

    # 10次轻量熔断防爆 (带超时自恢复)
    current_fails=$(get_fail_count)
    if [ "$current_fails" -ge 10 ]; then
        local fuse_time_file="/tmp/qhulogin_fuse_time"
        local now_sec=$(date +%s)
        local fuse_sec=$(cat "$fuse_time_file" 2>/dev/null || echo "0")
        # 首次熔断记录时间
        [ "$fuse_sec" = "0" ] && { echo "$now_sec" > "$fuse_time_file"; fuse_sec="$now_sec"; }
        # 超过300秒自动解除断路器
        if [ $((now_sec - fuse_sec)) -ge 300 ]; then
            print_warn "熔断超时 300 秒，自动重置"
            reset_fail_count
            rm -f "$fuse_time_file"
        else
            print_error "【熔断警戒】连续失败已达 ${current_fails} 次，休眠中..."
            return 1
        fi
    else
        rm -f "/tmp/qhulogin_fuse_time" 2>/dev/null
    fi

    my_iface="${LOGIN_INTERFACE:-$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)}"
    my_ip=$(ip -4 addr show dev "$my_iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    ip_tag=" [${my_iface:-未知}:${my_ip:-无IP}]"

    if [ "$force" != "force" ] && check_global_online; then
        print_success "全局主接口已在线"
        reset_fail_count
        return 0
    fi

    load_cache
    login_page_url="${CACHE_LOGIN_URL:-}"
    
    if [ -z "$login_page_url" ]; then
        eportal_host=$(discover_eportal_host)
        if [ -n "$eportal_host" ]; then
            gw_resp=$(run_curl -s -L -m 3 "http://${eportal_host}/eportal/index.jsp")
            login_page_url=$(echo "$gw_resp" | grep -oE "href='[^']+'" | head -1 | sed "s/href='//;s/'//")
            [ -z "$login_page_url" ] && login_page_url=$(echo "$gw_resp" | grep -oE 'href="[^"]+"' | head -1 | sed 's/href="//;s/"//')
            [ -z "$login_page_url" ] && login_page_url=$(echo "$gw_resp" | grep -oE "location\.href='[^']+'" | head -1 | sed "s/location\.href='//;s/'//")
            [ -z "$login_page_url" ] && login_page_url=$(echo "$gw_resp" | grep -oE 'window\.location="[^"]+"' | head -1 | sed 's/window\.location="//;s/"//')
            [ -z "$login_page_url" ] && login_page_url=$(echo "$gw_resp" | grep -oiE 'url=[^"]+' | head -1 | sed 's/[Uu][Rr][Ll]=//')
        fi
    fi

    if [ -z "$login_page_url" ]; then
        print_error "网关失联，无法获取认证页面"
        inc_fail_count
        return 1
    fi

    CACHE_LOGIN_URL="$login_page_url"
    login_url=$(echo "$login_page_url" | awk -F '?' '{print $1}')
    login_url="${login_url/index.jsp/InterFace.do?method=login}"

    query_string="${CACHE_QUERY_STRING:-}"
    if [ -z "$query_string" ]; then
        query_string=$(echo "$login_page_url" | awk -F '?' '{print $2}')
        # 兼容开关：部分老式锐捷需要深度 Encode
        if [ "${ENCODE_QUERY:-0}" = "1" ]; then
            query_string="${query_string//&/%2526}"
            query_string="${query_string//=/%253D}"
        fi
        CACHE_QUERY_STRING="$query_string"
    fi
    save_cache

    login_html=$(run_curl -s -m 5 "$login_page_url")
    rsa_key=$(echo "$login_html" | grep -oiE 'publickey[^a-zA-Z0-9]+[a-zA-Z0-9+/=]{60,}' | grep -oE '[a-zA-Z0-9+/=]{60,}' | head -1)

    encrypted_password="$PASSWORD"
    if [ -n "$rsa_key" ]; then
        enc=$(rsa_encrypt_password "$rsa_key" "$PASSWORD")
        if [ -n "$enc" ]; then
            encrypted_password="$enc"
            password_encrypt="true"
        fi
    fi

    service_string=$(get_service_string "${SERVICE:-campus}")
    result=$(run_curl -s -m 15 \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/149.0.0.0 Safari/537.36" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "userId=${USERNAME}&password=${encrypted_password}&service=${service_string}&queryString=${query_string}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=${password_encrypt}" \
        "$login_url")

    # 严密判定，屏蔽 {"success":false} 误伤
    if echo "$result" | grep -qE '"success"[[:space:]]*:[[:space:]]*true|"result"[[:space:]]*:[[:space:]]*"(1|success)"'; then
        print_success "认证成功!${ip_tag}"
        reset_fail_count
        
        if [ -z "${AUTH_DONE:-}" ]; then
            export AUTH_DONE="1"
            default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
            for other in $(detect_wlan_clients); do
                [ "$other" != "$default_iface" ] && bind_iface_and_login "$other"
            done
            unset AUTH_DONE
        fi
        return 0
    else
        if echo "$result" | grep -q '数量上限' 2>/dev/null; then
            print_error "设备触达上限"
            return 2
        fi
        
        inc_fail_count
        clear_session_cache 
        print_error "认证驳回: $(echo "$result" | head -c 80)"
        return 1
    fi
}

do_logout() {
    local login_page_url=""
    local eportal_host=""
    local logout_url=""
    local info=""
    local user_index=""
    local req_data=""

    load_config 2>/dev/null
    load_cache
    
    login_page_url="${CACHE_LOGIN_URL:-}"
    if [ -z "$login_page_url" ]; then
        eportal_host=$(discover_eportal_host)
        [ -n "$eportal_host" ] && login_page_url="http://${eportal_host}/eportal/index.jsp"
    fi
    [ -z "$login_page_url" ] && return 1

    logout_url=$(echo "$login_page_url" | awk -F '?' '{print $1}')
    logout_url="${logout_url/index.jsp/InterFace.do?method=logout}"

    info=$(run_curl -s -m 5 -d "userId=${USERNAME}" "${logout_url/method=logout/method=getOnlineUserInfo}")
    user_index=$(echo "$info" | grep -oE '"userIndex"[[:space:]]*:[[:space:]]*"?[^,}]+' | awk -F':' '{print $2}' | tr -d ' "')

    req_data="userId=${USERNAME}"
    [ -n "$user_index" ] && req_data="userIndex=${user_index}"

    if run_curl -s -m 5 -d "$req_data" "$logout_url" | grep -qE '"success"[[:space:]]*:[[:space:]]*true'; then
        print_success "下线指令已确认"
        clear_session_cache
        return 0
    fi
    print_warn "下发完成 (网关无返回)"
}

#================================================================
# 智能防爆保活引擎
#================================================================
do_keepalive() {
    local interval=""
    local relogin_date_file="/tmp/qhulogin_relogin_date"
    local now_date=""
    local now_time=""
    local last_date=""
    local ret=0
    local iface=""
    local current_fails=""
    local default_iface=""

    load_config || exit 1
    
    print_info "==================================="
    print_info " 引擎启航 [Node:${SERVICE}] "
    print_info "==================================="

    trap '{ release_lock; exit 0; }' INT TERM

    interval="${PING_INTERVAL:-30}"
    # 校验 PING_INTERVAL 必须为正整数，防止 sleep 报错导致 CPU 拉满
    case "$interval" in ''|*[!0-9]*) interval=30 ;; esac
    [ "$interval" -lt 5 ] && interval=5
    reset_fail_count
    
    while true; do
        current_fails=$(get_fail_count)
        if [ "$current_fails" -ge 10 ]; then
            print_error "【全网熔断】超时/报错达 10 次，休眠 300 秒防风控..."
            sleep 300
            reset_fail_count 
            clear_session_cache
            continue
        fi

        if [ -n "${FORCE_RELOGIN_AT:-}" ]; then
            now_date=$(date '+%Y-%m-%d')
            now_time=$(date '+%H:%M')
            last_date=$(cat "$relogin_date_file" 2>/dev/null)
            if [ "$now_time" = "$FORCE_RELOGIN_AT" ] && [ "$now_date" != "$last_date" ]; then
                do_login force
                echo "$now_date" > "$relogin_date_file"
            fi
        fi

        if ! check_global_online; then
            do_login
            ret=$?
            [ $ret -eq 2 ] && sleep 120 # 上限冲突避让
        fi

        default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)
        for iface in $(detect_wlan_clients); do
            [ "$iface" = "$default_iface" ] && continue
            ! check_iface_online "$iface" && bind_iface_and_login "$iface"
        done
        
        sleep "$interval"
    done
}

#================================================================
# 安全更新机制 (SHA256 密码学防伪)
#================================================================
do_update() {
    local repo="https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/qhulogin.sh"
    local mirror="https://ghfast.top/https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/qhulogin.sh"
    local tmp_file="/tmp/qhulogin_update.sh"
    local target="/usr/bin/qhulogin"
    local http_code=""

    [ ! -x "$target" ] && target=$(readlink -f "$0" 2>/dev/null || echo "$0")

    print_info "拉取远程版本..."

    http_code=$(curl -L -s --connect-timeout 10 -o "$tmp_file" -w '%{http_code}' "$repo" 2>/dev/null)
    if [ "$http_code" != "200" ]; then
        print_warn "直连失败，切换镜像源..."
        http_code=$(curl -L -s --connect-timeout 10 -o "$tmp_file" -w '%{http_code}' "$mirror" 2>/dev/null)
    fi

    if [ "$http_code" != "200" ] || [ ! -s "$tmp_file" ]; then
        print_error "下载失败或文件为空"
        rm -f "$tmp_file"
        return 1
    fi

    if ! head -n 1 "$tmp_file" | grep -q "^#!/bin/sh"; then
        print_error "文件头异常，疑似被劫持！"
        rm -f "$tmp_file"
        return 1
    fi

    # 语法校验
    if ! sh -n "$tmp_file" 2>/dev/null; then
        print_error "语法校验失败 (下载中断或被污染)，更新中止！"
        rm -f "$tmp_file"
        return 1
    fi

    # 先停止保活守护进程，避免替换文件时运行中脚本出错
    if is_daemon_running; then
        if [ -x "$INIT_SCRIPT" ]; then
            "$INIT_SCRIPT" stop 2>/dev/null
        else
            for _pid in $(pidof qhulogin 2>/dev/null); do
                tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q 'keepalive' && kill "$_pid" 2>/dev/null
            done
            release_lock 2>/dev/null
        fi
        sleep 1
    fi

    cp "$tmp_file" "$target"
    chmod +x "$target"
    rm -f "$tmp_file"
    print_success "核心态替换与完整性校验通过！"
    
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" restart 2>/dev/null
        print_info "守护服务已平滑重启"
    fi
}

#================================================================
# 面板与路由
#================================================================
do_status() {
    echo -e "${BOLD}=== V2.9 Stable Topology ===${NC}"
    local o_cnt=0 
    local t_cnt=0
    local iface=""
    local ip=""
    local current_fails=""
    
    for iface in $(detect_wlan_clients); do
        t_cnt=$((t_cnt + 1))
        ip=$(ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        if check_iface_online "$iface"; then
            o_cnt=$((o_cnt + 1)); echo -e "  [${GREEN}UP${NC}] $iface (${ip:-No IP})"
        else
            echo -e "  [${RED}DW${NC}] $iface (${ip:-No IP})"
        fi
    done
    
    [ "$t_cnt" -eq 0 ] && echo -e "  ${GRAY}No Route to WAN${NC}"
    echo -e "\n  System: $([ "$o_cnt" -eq "$t_cnt" ] && [ "$t_cnt" -gt 0 ] && echo "${GREEN}Healthy${NC}" || echo "${YELLOW}Degraded${NC}")"
    
    if is_daemon_running; then
        echo -e "  Engine: ${GREEN}Running${NC} (Daemonize)"
    else
        echo -e "  Engine: ${GRAY}Stopped${NC}"
    fi
    
    current_fails=$(get_fail_count)
    echo -e "  Fuses:  ${current_fails}/10 $([ "$current_fails" -ge 10 ] && echo "${RED}(LOCKED)${NC}")"
    echo -e "${BOLD}============================${NC}"
}

do_logs() {
    local line=""
    [ ! -f "$LOG_FILE" ] && return
    tail -30 "$LOG_FILE" | while read -r line; do
        case "$line" in
            *SUCCESS*) echo -e "${GREEN}$line${NC}" ;; *ERROR*) echo -e "${RED}$line${NC}" ;;
            *WARN*) echo -e "${YELLOW}$line${NC}" ;; *) echo -e "${GRAY}$line${NC}" ;;
        esac
    done
}

do_config() {
    local i=""
    load_config 2>/dev/null
    printf "学号 [${USERNAME:-}]: "; read -r i; USERNAME="${i:-${USERNAME:-}}"
    printf "密码 [****]: "; read -r i; [ -n "$i" ] && PASSWORD="$i"
    printf "运营商 (1:校 2:联 3:电 4:移) [${SERVICE:-campus}]: "; read -r i
    case "$i" in 1) SERVICE="campus";; 2) SERVICE="unicom";; 3) SERVICE="telecom";; 4) SERVICE="mobile";; esac
    printf "QueryString强转义 (部分老系统填1) [${ENCODE_QUERY:-0}]: "; read -r i
    ENCODE_QUERY="${i:-${ENCODE_QUERY:-0}}"
    save_config
}

main() {
    local cmd="${1:-}"
    local c=""
    
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    
    [ "$cmd" = "keepalive" ] && acquire_lock

    case "$cmd" in
        login) do_login ;; relogin) do_login force ;; logout) do_logout ;;
        status) do_status ;; logs) do_logs ;; config) do_config ;;
        keepalive) do_keepalive ;; update) do_update ;;
        *) 
            while true; do
                do_status
                echo -e "  ${CYAN}1${NC} 登入  ${CYAN}2${NC} 登出  ${CYAN}3${NC} 日志  ${CYAN}4${NC} 配置  ${CYAN}5${NC} 启停保活  ${CYAN}u${NC} 更新  ${CYAN}0${NC} 退出"
                printf "选择: "; read -r c
                case "$c" in
                    1) do_login ;; 2) do_logout ;; 3) do_logs ;; 4) do_config ;;
                    5) 
                        if is_daemon_running; then
                            [ -x "$INIT_SCRIPT" ] && "$INIT_SCRIPT" stop 2>/dev/null || {
                                # 精准终止 keepalive 守护进程，避免误杀当前交互进程
                                for _pid in $(pidof qhulogin 2>/dev/null); do
                                    [ "$_pid" = "$$" ] && continue
                                    tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q 'keepalive' && kill "$_pid" 2>/dev/null
                                done
                                release_lock
                            }
                            print_info "后台保活已停止"
                        else
                            [ -x "$INIT_SCRIPT" ] && "$INIT_SCRIPT" start 2>/dev/null || "$0" keepalive >/dev/null 2>&1 &
                            print_info "后台保活已启动"
                        fi
                        sleep 1
                        ;;
                    u) do_update ;; 0) exit 0 ;;
                esac
            done
            ;;
    esac
}

main "$@"