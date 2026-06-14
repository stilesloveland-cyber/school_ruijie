#!/bin/sh
#================================================================
# qhulogin - 锐捷ePortal自动认证工具
# Version: 1.0.0
# 功能：校园网自动登录 + 保活重连 + 命令行管理
# 平台：iStoreOS/OpenWrt (斐讯N1)
# 用法：qhulogin [命令]
#================================================================

# 严格模式
set -uo pipefail

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
PING_HOST="${PING_HOST:-180.101.50.188}"
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
# 网络检测
#================================================================
check_online() {
    local code
    code=$(curl -s -I -m 10 -o /dev/null -w '%{http_code}' http://www.google.cn/generate_204 2>/dev/null)
    if [ "$code" = "204" ]; then
        return 0
    else
        return 1
    fi
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
# 认证核心
#================================================================
do_login() {
    # 检查配置
    if [ -z "${USERNAME:-}" ] || [ -z "${PASSWORD:-}" ]; then
        print_error "未配置用户名或密码，请先运行 qhulogin config"
        return 1
    fi

    # 检测网络
    if check_online; then
        print_success "已在线，无需认证"
        return 0
    fi

    print_info "检测到需要认证，开始登录..."

    # 获取302重定向URL (ePortal返回HTML包含JS跳转或meta刷新)
    local response
    response=$(curl -s -L -m 10 "http://www.google.cn/generate_204" 2>/dev/null)
    if [ -z "$response" ]; then
        # 如果完全无响应，可能是物理网络不通
        print_error "网络不通，无法访问认证服务器"
        log_msg "LOGIN" "网络不通，curl无响应"
        return 1
    fi

    # 提取登录页URL (多种格式: JS跳转/location.href/meta refresh/直接URL)
    local login_page_url
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
    if [ -z "$login_page_url" ]; then
        print_error "无法从响应中提取登录页URL"
        log_msg "LOGIN" "响应内容: $(echo "$response" | head -c 500)"
        return 1
    fi

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
    login_html=$(curl -s -m 10 "$login_page_url" 2>/dev/null)
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
            print_success "RSA加密成功"
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
    result=$(curl -s -m 15 \
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
    if echo "$result" | grep -q '"success"' 2>/dev/null; then
        print_success "认证成功!"
        log_msg "LOGIN" "用户 ${USERNAME} 认证成功"
        return 0
    elif echo "$result" | grep -q 'success' 2>/dev/null; then
        print_success "认证成功!"
        log_msg "LOGIN" "用户 ${USERNAME} 认证成功"
        return 0
    else
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
    print_info "Ping目标: ${PING_HOST:-180.101.50.188}  间隔: ${PING_INTERVAL:-30}s"

    # 写入PID
    echo $$ > "$PID_FILE"

    # 初始认证（带重试）
    local retry=0
    while [ $retry -lt 30 ]; do
        if do_login; then
            break
        fi
        retry=$((retry + 1))
        print_warn "初始认证未成功，5秒后重试 ($retry/30)"
        sleep 5
    done

    # 保活循环
    local interval="${PING_INTERVAL:-30}"
    while true; do
        sleep "$interval"

        # 用HTTP检测认证状态（Ping不经过ePortal，无法检测认证掉线）
        if check_online; then
            continue
        fi

        print_warn "认证掉线或网络断开，尝试重新认证..."
        log_msg "KEEPALIVE" "检测到掉线，重新认证"

        # 重新认证，无限重试
        local reconnect=0
        while true; do
            if do_login; then
                break
            fi
            reconnect=$((reconnect + 1))
            print_warn "重连失败，10秒后重试 (第${reconnect}次)"
            sleep 10
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
    if check_online; then
        echo -e "  网络状态: ${GREEN}● 在线${NC}"
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

    # Ping目标
    printf "  Ping目标 [${PING_HOST:-180.101.50.188}]: "
    read -r input
    PING_HOST="${input:-${PING_HOST:-180.101.50.188}}"

    # Ping间隔
    printf "  Ping间隔(秒) [${PING_INTERVAL:-30}]: "
    read -r input
    PING_INTERVAL="${input:-${PING_INTERVAL:-30}}"

    echo ""
    save_config

    echo -e ""
    print_info "配置摘要:"
    echo -e "  用户名: ${USERNAME}"
    echo -e "  密码:   ${PASSWORD}"
    echo -e "  运营商: $(get_service_name "$SERVICE")"
    echo -e "  Ping:   ${PING_HOST} / ${PING_INTERVAL}s"
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
    killall qhulogin 2>/dev/null
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
    local repo="https://raw.githubusercontent.com/stilesloveland-cyber/school_ruijie/main/qhulogin.sh"
    local tmp_file="/tmp/qhulogin_update.sh"

    print_info "正在检查更新..."

    # 下载最新版本
    if ! curl -sS -L -o "$tmp_file" "$repo" 2>/dev/null; then
        print_error "下载失败，请检查网络连接"
        return 1
    fi

    # 检查下载是否有效
    if [ ! -s "$tmp_file" ]; then
        print_error "下载文件为空"
        rm -f "$tmp_file"
        return 1
    fi

    # 检查是否为有效脚本
    if ! head -1 "$tmp_file" | grep -q "^#!/bin/sh"; then
        print_error "下载文件无效"
        rm -f "$tmp_file"
        return 1
    fi

    # 对比版本
    local current_ver
    current_ver=$(grep '^# Version:' "$0" 2>/dev/null | head -1 | awk '{print $3}')
    local new_ver
    new_ver=$(grep '^# Version:' "$tmp_file" 2>/dev/null | head -1 | awk '{print $3}')

    if [ -n "$current_ver" ] && [ -n "$new_ver" ] && [ "$current_ver" = "$new_ver" ]; then
        print_info "当前已是最新版本 ($current_ver)"
        rm -f "$tmp_file"
        return 0
    fi

    # 停止服务
    if [ -x "$INIT_SCRIPT" ]; then
        print_info "停止服务..."
        "$INIT_SCRIPT" stop 2>/dev/null
    fi

    # 替换脚本
    local target
    if [ -x /usr/bin/qhulogin ]; then
        target="/usr/bin/qhulogin"
    else
        target=$(readlink -f "$0" 2>/dev/null || echo "$0")
    fi

    cp "$tmp_file" "$target"
    chmod +x "$target"
    rm -f "$tmp_file"

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

        # 显示简要状态
        if check_online 2>/dev/null; then
            echo -e "  状态: ${GREEN}● 在线${NC}"
        else
            echo -e "  状态: ${RED}● 离线${NC}"
        fi

        echo ""
        echo -e "  ${CYAN}1${NC}) 立即登录"
        echo -e "  ${CYAN}2${NC}) 查看状态"
        echo -e "  ${CYAN}3${NC}) 查看日志"
        echo -e "  ${CYAN}4${NC}) 配置账号"
        echo -e "  ${CYAN}5${NC}) 启动保活"
        echo -e "  ${CYAN}6${NC}) 停止保活"
        echo -e "  ${CYAN}7${NC}) 安装到系统"
        echo -e "  ${CYAN}8${NC}) 卸载"
        echo -e "  ${CYAN}9${NC}) 检查更新"
        echo -e "  ${CYAN}0${NC}) 退出"
        echo ""
        printf "  请选择 [0-9]: "
        read -r choice

        case "$choice" in
            1) do_login ;;
            2) do_status ;;
            3) do_logs ;;
            4) do_config ;;
            5) do_service_ctrl start ;;
            6) do_service_ctrl stop ;;
            7) do_install ;;
            8) do_uninstall ;;
            9) do_update ;;
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
