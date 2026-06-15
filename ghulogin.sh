#!/bin/sh
#================================================================
# qhulogin - 锐捷ePortal自动认证工具
# Version: 1.3.0
# 功能：校园网自动登录 + 保活重连 + 命令行管理
# 平台：iStoreOS/OpenWrt (斐讯N1)
# 用法：qhulogin [命令]
#================================================================

# 严格模式 (busybox ash 不支持 pipefail)
set -u

#================================================================
# 颜色定义
#================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

#================================================================
# 全局路径
#================================================================
readonly CONF_DIR="/etc/qhulogin"
readonly CONF_FILE="${CONF_DIR}/qhulogin.conf"
readonly LOG_FILE="/var/log/qhulogin.log"
readonly PID_FILE="/var/run/qhulogin.pid"
readonly INIT_SCRIPT="/etc/init.d/qhulogin"
readonly CACHE_FILE="${CONF_DIR}/.login_cache"

#================================================================
# 多网卡检测（只检测Client模式无线网卡）
#================================================================
detect_wlan_clients() {
    # 从路由表获取所有有默认路由的无线网卡
    # 不依赖 iwinfo，更可靠
    ip route show default 2>/dev/null | \
        awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | \
        sort -u
}

#================================================================
# 运营商映射
#================================================================
CAMPUS="%25E6%25A0%25A1%25E5%259B%25AD%25E7%25BD%2591"
UNICOM="%25E6%25A0%25A1%25E5%259B%25AD%25E8%2581%2594%25E9%2580%259A"
TELECOM="%25E6%25A0%25A1%25E5%259B%25AD%25E7%2594%25B5%25E4%25BF%25A1"
MOBILE="%25E6%25A0%25A1%25E5%259B%25AD%25E7%25A7%25BB%25E5%258A%25A8"

#================================================================
# 日志函数
#================================================================
log_msg() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null

    # 日志轮转：超过100KB截断保留最后200行
    local log_size
    log_size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$log_size" -gt 102400 ] 2>/dev/null; then
        local tmp_log="/tmp/qhulogin_log_tmp"
        tail -200 "$LOG_FILE" > "$tmp_log" 2>/dev/null
        mv "$tmp_log" "$LOG_FILE" 2>/dev/null
    fi
}

print_info()    { echo -e "${CYAN}[INFO]${NC} $*"; log_msg "INFO" "$*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; log_msg "SUCCESS" "$*"; }
print_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; log_msg "WARN" "$*"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*"; log_msg "ERROR" "$*"; }
print_debug()   { echo -e "${GRAY}[DEBUG]${NC} $*"; log_msg "DEBUG" "$*"; }

#================================================================
# 配置管理
#================================================================
load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        return 1
    fi
    . "$CONF_FILE"
    return 0
}

save_config() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_FILE" << EOF
# qhulogin 配置文件
# 修改后运行 qhulogin keepalive 重启保活
USERNAME="${USERNAME}"
PASSWORD="${PASSWORD}"
SERVICE="${SERVICE}"
PING_INTERVAL="${PING_INTERVAL:-30}"
EOF
    chmod 600 "$CONF_FILE"
    print_success "配置已保存到 $CONF_FILE"
}

get_service_string() {
    case "$1" in
        campus)  echo "$CAMPUS" ;;
        unicom)  echo "$UNICOM" ;;
        telecom) echo "$TELECOM" ;;
        mobile)  echo "$MOBILE" ;;
        *)       echo "$CAMPUS" ;;
    esac
}

get_service_name() {
    case "$1" in
        campus)  echo "校园网" ;;
        unicom)  echo "校园联通" ;;
        telecom) echo "校园电信" ;;
        mobile)  echo "校园移动" ;;
        *)       echo "校园网" ;;
    esac
}

#================================================================
# 网络检测（快速版：先试一个URL，1s超时）
#================================================================
check_online() {
    local iface="${1:-}"
    local curl_cmd="curl"
    if [ -n "$iface" ]; then
        curl_cmd="curl --interface $iface"
    fi

    # 快速检测：单个URL，2s超时
    local code
    code=$($curl_cmd -s -I -m 2 -o /dev/null -w '%{http_code}' http://www.google.cn/generate_204 2>/dev/null)
    [ "$code" = "204" ] && return 0

    # 备选检测（罕见失败时再试）
    code=$($curl_cmd -s -I -m 2 -o /dev/null -w '%{http_code}' http://connect.rom.miui.com/generate_204 2>/dev/null)
    [ "$code" = "204" ] && return 0

    return 1
}

# 检测所有WLAN客户端（串行，但每个只等2s）
check_all_online() {
    # 默认路由最可能在线，优先
    check_online && return 0

    # 逐个检查其他WLAN客户端（最多等 2s × N）
    local found=1
    for iface in $(detect_wlan_clients); do
        if check_online "$iface"; then
            found=0
            break
        fi
    done
    return $found
}

#================================================================
# RSA加密
#================================================================
rsa_encrypt_password() {
    local pubkey="$1"
    local password="$2"

    # 将Base64公钥写入临时文件
    local pubkey_file="/tmp/qhulogin_pubkey.pem"
    echo "-----BEGIN PUBLIC KEY-----" > "$pubkey_file"
    echo "$pubkey" | fold -w 64 >> "$pubkey_file"
    echo "-----END PUBLIC KEY-----" >> "$pubkey_file"

    # 使用openssl加密
    local encrypted
    encrypted=$(echo -n "$password" | openssl rsautl -encrypt -pubin -inkey "$pubkey_file" -pkcs 2>/dev/null | xxd -p -c 256 | tr 'a-f' 'A-F')
    rm -f "$pubkey_file"

    if [ -n "$encrypted" ]; then
        echo "$encrypted"
        return 0
    else
        return 1
    fi
}

#================================================================
# 登出（踢出旧会话）
#================================================================
do_logout() {
    load_config 2>/dev/null

    # 从缓存获取认证服务器地址
    local login_page_url=""
    if [ -f "$CACHE_FILE" ]; then
        login_page_url=$(cat "$CACHE_FILE" 2>/dev/null)
    fi

    # 尝试通过网关获取
    if [ -z "$login_page_url" ]; then
        local gateway=""
        gateway=$(route -n 2>/dev/null | grep '^0.0.0.0' | awk '{print $2}' | head -1)
        if [ -n "$gateway" ]; then
            login_page_url="http://${gateway}/eportal/index.jsp"
        fi
    fi

    if [ -z "$login_page_url" ]; then
        return 1
    fi

    # 构造登出URL
    local logout_url
    logout_url=$(echo "$login_page_url" | awk -F '?' '{print $1}')
    logout_url="${logout_url/index.jsp/InterFace.do?method=logout}"

    # 获取userIndex（需要先查询在线用户信息）
    local user_index=""
    local query_url
    query_url="${logout_url/method=logout/method=getOnlineUserInfo}"

    local info
    info=$(curl -s -m 10 -d "userId=${USERNAME}" "$query_url" 2>/dev/null)
    if [ -n "$info" ]; then
        user_index=$(echo "$info" | grep -oE '"userIndex"\s*:\s*"[^"]*"' | sed 's/.*: *"//;s/"//')
    fi

    # 发送登出请求
    local logout_result
    if [ -n "$user_index" ]; then
        logout_result=$(curl -s -m 10 -d "userIndex=${user_index}" "$logout_url" 2>/dev/null)
    else
        # 没有userIndex，尝试用userId登出
        logout_result=$(curl -s -m 10 -d "userId=${USERNAME}" "$logout_url" 2>/dev/null)
    fi

    if echo "$logout_result" | grep -q 'success' 2>/dev/null; then
        print_success "已成功登出"
        log_msg "LOGOUT" "用户 ${USERNAME} 登出成功"
        return 0
    else
        print_warn "已发送登出请求（结果未知）"
        log_msg "LOGOUT" "登出请求已发送: ${logout_result:-无响应}"
        return 0
    fi
}

#================================================================
# 认证核心
#================================================================
do_login() {
    local force="${1:-}"
    local bind_iface="${2:-}"

    # 加载配置
    load_config 2>/dev/null

    # 检查配置
    if [ -z "${USERNAME:-}" ] || [ -z "${PASSWORD:-}" ]; then
        print_error "未配置用户名或密码，请先运行 qhulogin config"
        return 1
    fi

    # 构造curl命令（可选绑定来源接口，用于多网卡分别认证）
    local curl_cmd="curl"
    local ip_tag=""
    if [ -n "$bind_iface" ]; then
        curl_cmd="curl --interface $bind_iface"
    fi

    # 获取本机IP用于日志显示（从默认路由或指定接口）
    local my_ip=""
    local my_iface="$bind_iface"
    if [ -z "$my_iface" ]; then
        my_iface=$(ip route show default 2>/dev/null | grep '^default' | awk '{print $5}' | head -1)
    fi
    if [ -n "$my_iface" ]; then
        my_ip=$(ip addr show dev "$my_iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
    fi
    if [ -n "$my_iface" ] && [ -n "$my_ip" ]; then
        ip_tag=" [$my_iface:$my_ip]"
    fi

    # 非强制模式：已在线则跳过
    if [ "$force" != "force" ]; then
        if check_all_online; then
            print_success "已在线，无需认证"
            return 0
        fi
    fi

    print_info "开始登录${ip_tag}..."

    # 获取认证页面（3s超时，离线时快速返回）
    local response
    response=$($curl_cmd -s -L -m 3 "http://www.google.cn/generate_204" 2>/dev/null)

    # 提取登录页URL
    local login_page_url=""
    if [ -n "$response" ]; then
        # 尝试从href='xxx'提取
        login_page_url=$(echo "$response" | grep -oE "href='[^']+'" | head -1 | sed "s/href='//;s/'//")
        # 尝试从href="xxx"提取
        if [ -z "$login_page_url" ]; then
            login_page_url=$(echo "$response" | grep -oE 'href="[^"]+"' | head -1 | sed 's/href="//;s/"//')
        fi
        # 尝试从location.href='xxx'提取
        if [ -z "$login_page_url" ]; then
            login_page_url=$(echo "$response" | grep -oE "location\.href='[^']+'" | head -1 | sed "s/location\.href='//;s/'//")
        fi
        # 尝试从window.location="xxx"提取
        if [ -z "$login_page_url" ]; then
            login_page_url=$(echo "$response" | grep -oE 'window\.location="[^"]+"' | head -1 | sed 's/window\.location="//;s/"//')
        fi
        # 尝试从meta refresh提取
        if [ -z "$login_page_url" ]; then
            login_page_url=$(echo "$response" | grep -oiE 'url=[^"]+' | head -1 | sed 's/[Uu][Rr][Ll]=//')
        fi
    fi

    # 在线但拿不到URL时，尝试其他方式获取
    if [ -z "$login_page_url" ]; then
        # 1. 使用缓存的URL
        if [ -f "$CACHE_FILE" ]; then
            login_page_url=$(cat "$CACHE_FILE" 2>/dev/null)
            print_info "使用缓存的认证URL"
        else
            # 2. 通过网关IP直接访问ePortal
            local gateway=""
            gateway=$(route -n 2>/dev/null | grep '^0.0.0.0' | awk '{print $2}' | head -1)
            if [ -n "$gateway" ]; then
                print_info "尝试通过网关 $gateway 获取认证页..."
                local gw_response=""
                gw_response=$($curl_cmd -s -L -m 3 "http://${gateway}/eportal/index.jsp" 2>/dev/null)
                if [ -z "$gw_response" ]; then
                    gw_response=$($curl_cmd -s -L -m 3 "http://${gateway}" 2>/dev/null)
                fi
                if [ -n "$gw_response" ]; then
                    login_page_url=$(echo "$gw_response" | grep -oE "href='[^']+" | head -1 | sed "s/href='//")
                    if [ -z "$login_page_url" ]; then
                        login_page_url=$(echo "$gw_response" | grep -oE 'href="[^"]+' | head -1 | sed 's/href="//')
                    fi
                fi
            fi

            # 3. 仍然拿不到，在线则跳过
            if [ -z "$login_page_url" ]; then
                if check_online; then
                    print_success "已在线，无法获取认证页URL（下次登录成功后会缓存）"
                    return 0
                fi
                print_error "网络不通，无法访问认证服务器"
                log_msg "LOGIN" "网络不通，curl无响应"
                return 1
            fi
        fi
    fi

    # 缓存认证页URL
    echo "$login_page_url" > "$CACHE_FILE"

    # 构造登录URL
    local login_url
    login_url=$(echo "$login_page_url" | awk -F '?' '{print $1}')
    login_url="${login_url/index.jsp/InterFace.do?method=login}"

    # 构造queryString (二次URL编码)
    local query_string
    query_string=$(echo "$login_page_url" | awk -F '?' '{print $2}')
    query_string="${query_string//&/%2526}"
    query_string="${query_string//=/%253D}"

    # 获取登录页HTML，提取RSA公钥
    local login_html rsa_key encrypted_password password_encrypt
    login_html=$($curl_cmd -s -m 5 "$login_page_url" 2>/dev/null)
    rsa_key=$(echo "$login_html" | grep -oE 'publicKey\s*=\s*["\x27][A-Za-z0-9+/=]{100,}["\x27]' | sed "s/.*=['\"]//;s/['\"]$//")

    # 加密密码
    encrypted_password="$PASSWORD"
    password_encrypt="false"
    if [ -n "$rsa_key" ]; then
        print_info "使用RSA加密密码..."
        local enc
        enc=$(rsa_encrypt_password "$rsa_key" "$PASSWORD")
        if [ -n "$enc" ]; then
            encrypted_password="$enc"
            password_encrypt="true"
        else
            print_warn "RSA加密失败，回退到明文模式"
        fi
    else
        print_warn "未获取到RSA公钥，使用明文模式"
    fi

    # 获取运营商编码
    local service_string
    service_string=$(get_service_string "${SERVICE:-campus}")

    # 发送认证请求
    print_info "发送认证请求..."
    local result
    result=$($curl_cmd -s -m 15 \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36" \
        -e "$login_page_url" \
        -H "Accept: */*" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -d "userId=${USERNAME}&password=${encrypted_password}&service=${service_string}&queryString=${query_string}&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=${password_encrypt}" \
        "$login_url" 2>/dev/null)

    if [ -z "$result" ]; then
        print_error "认证请求无响应"
        return 1
    fi

    # 判断结果
    local login_ok=false
    if echo "$result" | grep -q '"success"' 2>/dev/null || echo "$result" | grep -q 'success' 2>/dev/null; then
        login_ok=true
    fi

    if $login_ok; then
        print_success "认证成功!${ip_tag}"
        log_msg "LOGIN" "用户 ${USERNAME}${ip_tag} 认证成功"

        # 默认路由认证成功后，用 --interface 认证其他WLAN客户端
        if [ -z "$bind_iface" ]; then
            local default_iface
            default_iface=$(ip route show default 2>/dev/null | grep '^default' | awk '{print $5}' | head -1)
            for other in $(detect_wlan_clients); do
                if [ "$other" != "$default_iface" ]; then
                    print_info "从 $other 发起认证..."
                    do_login "" "$other"
                fi
            done
        fi
        return 0
    else
        # 检查是否"同时在线用户数量上限"
        if echo "$result" | grep -q '同时在线用户数量上限' 2>/dev/null; then
            print_error "认证失败: 账号在其他设备在线"
            log_msg "LOGIN" "认证失败: 多设备在线上限${ip_tag}"
            return 2
        fi
        print_error "认证失败: $(echo "$result" | head -c 200)"
        log_msg "LOGIN" "认证失败: $result"
        return 1
    fi
}

#================================================================
# 保活模式
#================================================================
do_keepalive() {
    if ! load_config; then
        print_error "未找到配置文件 $CONF_FILE，请先运行 qhulogin config"
        return 1
    fi

    print_info "qhulogin 保活模式启动"
    print_info "用户: ${USERNAME}  运营商: $(get_service_name "${SERVICE:-campus}")"
    print_info "检测间隔: ${PING_INTERVAL:-30}s"

    # 写入PID
    echo $$ > "$PID_FILE"

    # 初始认证（带重试+退避）
    local retry=0
    local backoff=5
    while [ $retry -lt 30 ]; do
        do_login
        local ret=$?
        if [ $ret -eq 0 ]; then
            break
        fi
        retry=$((retry + 1))
        if [ $ret -eq 2 ]; then
            backoff=120
            print_warn "多设备在线冲突，${backoff}秒后重试 ($retry/30)"
        else
            backoff=5
            print_warn "初始认证未成功，${backoff}秒后重试 ($retry/30)"
        fi
        sleep "$backoff"
    done

    # 保活循环
    local interval="${PING_INTERVAL:-30}"
    while true; do
        sleep "$interval"

        # 用HTTP检测认证状态（检查所有WLAN客户端）
        if check_all_online; then
            continue
        fi

        print_warn "认证掉线或网络断开，尝试重新认证..."
        log_msg "KEEPALIVE" "检测到掉线，重新认证"

        # 重新认证，带退避重试
        local reconnect=0
        local backoff=10
        while true; do
            do_login
            local ret=$?
            if [ $ret -eq 0 ]; then
                break
            fi
            reconnect=$((reconnect + 1))
            # "在线上限"错误(ret=2)增加退避，避免疯狂重试
            if [ $ret -eq 2 ]; then
                backoff=120
                print_warn "多设备在线冲突，${backoff}秒后重试 (第${reconnect}次)"
            else
                backoff=10
                print_warn "重连失败，${backoff}秒后重试 (第${reconnect}次)"
            fi
            sleep "$backoff"
        done
    done
}

#================================================================
# 查看状态
#================================================================
do_status() {
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}   GHU 校园网登录 - 状态${NC}"
    echo -e "${BOLD}========================================${NC}"

    # 在线状态
    if check_all_online; then
        echo -e "  网络状态: ${GREEN}● 在线${NC}"
        # 显示各WLAN客户端（通过路由表判断）
        for iface in $(detect_wlan_clients); do
            # 检查该接口是否有默认路由
            local has_route
            has_route=$(ip route show default 2>/dev/null | grep -c "dev $iface")
            if [ "$has_route" -gt 0 ]; then
                echo -e "    ${iface}: ${GREEN}● 已接入${NC}"
            else
                echo -e "    ${iface}: ${GRAY}○ 备用${NC}"
            fi
        done
    else
        echo -e "  网络状态: ${RED}● 离线${NC}"
    fi

    # 配置信息
    if load_config; then
        echo -e "  用户名:   ${USERNAME:-未配置}"
        echo -e "  运营商:   $(get_service_name "${SERVICE:-campus}")"
    else
        echo -e "  配置:     ${RED}未配置${NC}"
    fi

    # 服务状态
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
        echo -e "  保活进程: ${GREEN}运行中${NC} (PID: $(cat "$PID_FILE"))"
    else
        echo -e "  保活进程: ${GRAY}未运行${NC}"
    fi

    # init.d状态
    if [ -x "$INIT_SCRIPT" ]; then
        if "$INIT_SCRIPT" enabled 2>/dev/null; then
            echo -e "  开机自启: ${GREEN}已启用${NC}"
        else
            echo -e "  开机自启: ${GRAY}未启用${NC}"
        fi
    else
        echo -e "  开机自启: ${GRAY}未安装${NC}"
    fi

    # 最近日志
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo -e "${BOLD}  最近日志:${NC}"
        tail -5 "$LOG_FILE" 2>/dev/null | while read -r line; do
            echo -e "  ${GRAY}$line${NC}"
        done
    fi

    echo -e "${BOLD}========================================${NC}"
}

#================================================================
# 查看日志
#================================================================
do_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        print_warn "日志文件不存在"
        return
    fi
    echo -e "${BOLD}=== qhulogin 日志 (最近50条) ===${NC}"
    tail -50 "$LOG_FILE" | while read -r line; do
        case "$line" in
            *SUCCESS*) echo -e "${GREEN}$line${NC}" ;;
            *ERROR*)   echo -e "${RED}$line${NC}" ;;
            *WARN*)    echo -e "${YELLOW}$line${NC}" ;;
            *)         echo -e "${GRAY}$line${NC}" ;;
        esac
    done
}

#================================================================
# 交互式配置
#================================================================
do_config() {
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}   GHU 校园网登录 - 配置${NC}"
    echo -e "${BOLD}========================================${NC}"

    # 加载当前配置
    load_config 2>/dev/null

    # 用户名
    printf "  用户名(学号) [${USERNAME:-}]: "
    read -r input
    USERNAME="${input:-${USERNAME:-}}"

    # 密码
    printf "  密码 [${PASSWORD:-}]: "
    read -r input
    PASSWORD="${input:-${PASSWORD:-}}"

    # 运营商
    echo ""
    echo -e "  ${CYAN}1${NC}) 校园网 (campus)"
    echo -e "  ${CYAN}2${NC}) 校园联通 (unicom)"
    echo -e "  ${CYAN}3${NC}) 校园电信 (telecom)"
    echo -e "  ${CYAN}4${NC}) 校园移动 (mobile)"
    printf "  选择运营商 [1-4, 当前: ${SERVICE:-campus}]: "
    read -r input
    case "$input" in
        1) SERVICE="campus" ;;
        2) SERVICE="unicom" ;;
        3) SERVICE="telecom" ;;
        4) SERVICE="mobile" ;;
        *) SERVICE="${SERVICE:-campus}" ;;
    esac

    echo ""
    save_config

    echo -e ""
    print_info "配置摘要:"
    echo -e "  用户名: ${USERNAME}"
    echo -e "  密码:   ****"
    echo -e "  运营商: $(get_service_name "$SERVICE")"
}

#================================================================
# 安装/卸载
#================================================================
do_install() {
    print_info "安装 qhulogin 到系统..."

    # 复制脚本到 /usr/bin
    local script_path
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    cp "$script_path" /usr/bin/qhulogin
    chmod +x /usr/bin/qhulogin
    print_success "已安装到 /usr/bin/qhulogin"

    # 安装init.d服务
    mkdir -p /etc/init.d
    cat > "$INIT_SCRIPT" << 'INITEOF'
#!/bin/sh /etc/rc.common
# qhulogin procd服务
START=99
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/qhulogin keepalive
    procd_set_param respawn 3600 5 5
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param pidfile /var/run/qhulogin.pid
    procd_close_instance
}

stop_service() {
    local pid
    pid=$(cat /var/run/qhulogin.pid 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    killall qhulogin 2>/dev/null; true
}
INITEOF
    chmod +x "$INIT_SCRIPT"
    print_success "已安装服务脚本到 $INIT_SCRIPT"

    # 创建配置目录
    mkdir -p "$CONF_DIR"

    # 启用开机自启
    "$INIT_SCRIPT" enable 2>/dev/null
    print_success "已启用开机自启"

    echo ""
    print_info "安装完成! 接下来:"
    echo -e "  ${CYAN}1.${NC} 运行 ${BOLD}qhulogin config${NC} 配置账号"
    echo -e "  ${CYAN}2.${NC} 运行 ${BOLD}qhulogin keepalive${NC} 或 ${BOLD}/etc/init.d/qhulogin start${NC} 启动"
}

do_uninstall() {
    print_warn "卸载 qhulogin..."

    # 停止服务
    if [ -x "$INIT_SCRIPT" ]; then
        "$INIT_SCRIPT" stop 2>/dev/null
        "$INIT_SCRIPT" disable 2>/dev/null
        rm -f "$INIT_SCRIPT"
    fi

    # 停止进程
    killall qhulogin 2>/dev/null

    # 删除文件
    rm -f /usr/bin/qhulogin
    rm -f "$PID_FILE"

    print_success "已卸载 (配置文件 $CONF_DIR 保留)"
}

#================================================================
# 更新
#================================================================
do_update() {
    local repo="https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/ghulogin.sh"
    local mirror="https://ghfast.top/https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/master/ghulogin.sh"
    local tmp_file="/tmp/qhulogin_update.sh"

    print_info "正在检查更新..."

    # 下载最新版本（先尝试直连，失败后用镜像）
    local http_code
    http_code=$(curl -L -s --connect-timeout 10 -o "$tmp_file" -w '%{http_code}' "$repo" 2>/dev/null)
    if [ "$http_code" != "200" ]; then
        print_warn "直连 GitHub 失败 (HTTP ${http_code:-无响应})，尝试镜像源..."
        http_code=$(curl -L -s --connect-timeout 10 -o "$tmp_file" -w '%{http_code}' "$mirror" 2>/dev/null)
    fi

    if [ "$http_code" != "200" ]; then
        print_error "下载失败 (HTTP ${http_code:-无响应})，请检查网络"
        rm -f "$tmp_file"
        return 1
    fi

    # 检查下载是否有效
    if [ ! -s "$tmp_file" ]; then
        print_error "下载文件为空，可能网络不通或仓库地址有误"
        rm -f "$tmp_file"
        return 1
    fi

    # 检查是否为有效脚本 (兼容不同换行符)
    if ! head -1 "$tmp_file" | grep -q '#!/bin/sh'; then
        print_error "下载内容非有效脚本（可能返回了错误页面）"
        log_msg "UPDATE" "文件开头: $(head -1 "$tmp_file" | head -c 100)"
        rm -f "$tmp_file"
        return 1
    fi

    # 对比文件内容（版本号+文件哈希双重检测）
    local current_ver new_ver
    current_ver=$(grep '^# Version:' "$0" 2>/dev/null | head -1 | awk '{print $3}')
    new_ver=$(grep '^# Version:' "$tmp_file" 2>/dev/null | head -1 | awk '{print $3}')

    # 计算文件MD5
    local current_md5 new_md5
    current_md5=$(md5sum "$0" 2>/dev/null | awk '{print $1}')
    new_md5=$(md5sum "$tmp_file" 2>/dev/null | awk '{print $1}')

    if [ "$current_md5" = "$new_md5" ]; then
        print_info "当前已是最新版本 ($current_ver)"
        rm -f "$tmp_file"
        return 0
    fi

    if [ -n "$new_ver" ] && [ "$current_ver" != "$new_ver" ]; then
        print_info "发现新版本: ${current_ver:-未知} → $new_ver"
    elif [ -n "$new_ver" ] && [ "$current_ver" = "$new_ver" ]; then
        print_info "检测到文件变更 (${current_ver})，准备更新"
    else
        print_info "发现文件变更，准备更新"
    fi

    # 停止保活进程（只杀PID文件中的，不杀自己）
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ]; then
            kill "$old_pid" 2>/dev/null
            sleep 1
        fi
    fi

    # 替换脚本（先备份，验证后删除备份）
    local target
    if [ -x /usr/bin/qhulogin ]; then
        target="/usr/bin/qhulogin"
    else
        target=$(readlink -f "$0" 2>/dev/null || echo "$0")
    fi

    # 备份当前版本
    cp "$target" "${target}.bak" 2>/dev/null

    cp "$tmp_file" "$target"
    chmod +x "$target"
    rm -f "$tmp_file"

    # 验证新脚本可执行
    if ! sh -n "$target" 2>/dev/null; then
        print_error "新脚本语法错误，回滚到旧版本"
        cp "${target}.bak" "$target" 2>/dev/null
        chmod +x "$target"
        rm -f "${target}.bak"
        return 1
    fi
    rm -f "${target}.bak"

    if [ -n "$new_ver" ]; then
        print_success "已更新到版本 $new_ver"
    else
        print_success "更新完成"
    fi

    # 重启服务
    if [ -x "$INIT_SCRIPT" ]; then
        print_info "重启服务..."
        "$INIT_SCRIPT" start 2>/dev/null
    fi
}

#================================================================
# 保活服务管理
#================================================================
do_service_ctrl() {
    local action="$1"
    if [ ! -x "$INIT_SCRIPT" ]; then
        print_error "服务未安装，请先运行 qhulogin install"
        return 1
    fi
    case "$action" in
        start)   "$INIT_SCRIPT" start ;;
        stop)    "$INIT_SCRIPT" stop ;;
        restart) "$INIT_SCRIPT" restart ;;
        enable)  "$INIT_SCRIPT" enable ;;
        disable) "$INIT_SCRIPT" disable ;;
    esac
}

#================================================================
# 交互式菜单
#================================================================
show_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}========================================${NC}"
        echo -e "${BOLD}     GHU 校园网登录管理${NC}"
        echo -e "${BOLD}========================================${NC}"

        # 显示状态（读取缓存，不阻塞菜单。缓存过期时后台刷新但不显示"检测中"）
        local status_file="/tmp/qhulogin_status"
        local status="${GRAY}● 检测中...${NC}"

        # 读取已有缓存
        local cached_status=""
        if [ -f "$status_file" ]; then
            cached_status=$(cat "$status_file" 2>/dev/null)
        fi

        # 无缓存或过期时后台刷新
        if [ -z "$cached_status" ] || [ "$(($(date +%s) - $(stat -c %Y "$status_file" 2>/dev/null || echo 0)))" -gt 10 ]; then
            (check_all_online 2>/dev/null && echo "ONLINE" || echo "OFFLINE") > "$status_file" &
        fi

        # 显示缓存值（不显示"检测中"）
        case "$cached_status" in
            ONLINE)  status="${GREEN}● 在线${NC}" ;;
            OFFLINE) status="${RED}● 离线${NC}" ;;
            *)       status="${GRAY}● 检测中...${NC}" ;;
        esac
        echo -e "  状态: $status"

        echo ""
        echo -e "  ${CYAN}1${NC}) 立即登录"
        echo -e "  ${CYAN}2${NC}) 强制重新登录"
        echo -e "  ${CYAN}3${NC}) 登出"
        echo -e "  ${CYAN}4${NC}) 查看状态"
        echo -e "  ${CYAN}5${NC}) 查看日志"
        echo -e "  ${CYAN}6${NC}) 配置账号"
        echo -e "  ${CYAN}7${NC}) 启动保活"
        echo -e "  ${CYAN}8${NC}) 停止保活"
        echo -e "  ${CYAN}9${NC}) 安装到系统"
        echo -e "  ${CYAN}d${NC}) 卸载"
        echo -e "  ${CYAN}u${NC}) 检查更新"
        echo -e "  ${CYAN}0${NC}) 退出"
        echo ""
        printf "  请选择: "
        read -r choice

        case "$choice" in
            1) do_login ;;
            2) do_login force ;;
            3) do_logout ;;
            4) do_status ;;
            5) do_logs ;;
            6) do_config ;;
            7) do_service_ctrl start ;;
            8) do_service_ctrl stop ;;
            9) do_install ;;
            d) do_uninstall ;;
            u) do_update ;;
            0) echo -e "${GRAY}再见!${NC}"; exit 0 ;;
            *) print_error "无效选择" ;;
        esac
    done
}

#================================================================
# 帮助信息
#================================================================
show_help() {
    echo -e "${BOLD}qhulogin${NC} - 锐捷ePortal自动认证工具"
    echo ""
    echo -e "${BOLD}用法:${NC}"
    echo "  qhulogin              交互式菜单"
    echo "  qhulogin <命令>       执行指定命令"
    echo ""
    echo -e "${BOLD}命令:${NC}"
    echo -e "  ${CYAN}login${NC}       立即认证"
    echo -e "  ${CYAN}relogin${NC}     强制重新认证(即使已在线)"
    echo -e "  ${CYAN}logout${NC}      登出当前账号"
    echo -e "  ${CYAN}status${NC}      查看状态"
    echo -e "  ${CYAN}logs${NC}        查看日志"
    echo -e "  ${CYAN}config${NC}      交互式配置"
    echo -e "  ${CYAN}keepalive${NC}   启动保活模式(前台)"
    echo -e "  ${CYAN}install${NC}     安装到系统"
    echo -e "  ${CYAN}uninstall${NC}   卸载"
    echo -e "  ${CYAN}update${NC}      检查并安装更新"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  qhulogin              # 打开菜单"
    echo "  qhulogin login        # 立即登录"
    echo "  qhulogin status       # 查看状态"
}

#================================================================
# 主入口
#================================================================
main() {
    local cmd="${1:-}"

    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

    case "$cmd" in
        login)      do_login ;;
        relogin)    do_login force ;;
        logout)     do_logout ;;
        status)     do_status ;;
        logs)       do_logs ;;
        config)     do_config ;;
        keepalive)  do_keepalive ;;
        install)    do_install ;;
        uninstall)  do_uninstall ;;
        update)     do_update ;;
        start)      do_service_ctrl start ;;
        stop)       do_service_ctrl stop ;;
        restart)    do_service_ctrl restart ;;
        -h|--help)  show_help ;;
        "")         show_menu ;;
        *)
            print_error "未知命令: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
