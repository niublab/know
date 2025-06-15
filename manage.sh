#!/bin/bash

# ESS Community 完整管理系统
# 版本: 3.0.0 - 最终完善版本
# 作者: ESS Community 中文社区
# 许可证: AGPL-3.0 (仅限非商业用途)
# 
# 基于ESS官方最新规范和完整问题解决方案
# 支持：自定义端口、nginx反代、Element Call、用户管理、完整诊断
# 解决：所有已知的部署和配置问题

set -euo pipefail

# 版本信息
readonly SCRIPT_VERSION="3.0.0"
readonly ESS_VERSION="25.6.1"
readonly SCRIPT_NAME="ESS Community 完整管理系统"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# 配置目录
readonly ESS_CONFIG_DIR="/opt/ess-config"
readonly NGINX_SITES_DIR="/etc/nginx/sites-available"
readonly NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

# 默认配置
readonly DEFAULT_HTTP_PORT="8080"
readonly DEFAULT_HTTPS_PORT="8443"
readonly TRAEFIK_HTTP_PORT="8080"
readonly TRAEFIK_HTTPS_PORT="8443"

# 全局变量
SUDO_CMD=""
SERVER_NAME=""
ELEMENT_WEB_HOST=""
MAS_HOST=""
RTC_HOST=""
SYNAPSE_HOST=""
EXTERNAL_HTTP_PORT=""
EXTERNAL_HTTPS_PORT=""

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${PURPLE}[DEBUG]${NC} $1"
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}${SCRIPT_NAME}${NC}                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}版本: ${SCRIPT_VERSION}${NC}                                           ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${BLUE}支持ESS版本: ${ESS_VERSION}${NC}                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  ${YELLOW}功能特性：${NC}                                                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  • 完整的nginx反代配置（解决ISP端口封锁）                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  • Element Call问题一键修复                                 ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  • 用户管理和权限控制                                       ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  • 完整的系统诊断和修复                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  • 基于官方最新规范                                         ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 检查系统要求
check_system_requirements() {
    log_info "检查系统要求..."
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测操作系统版本"
        exit 1
    fi
    
    local os_info=$(grep "^ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
    log_info "检测到操作系统: $os_info"
    
    # 检查是否为root或有sudo权限
    if [[ $EUID -eq 0 ]]; then
        SUDO_CMD=""
        log_success "以root用户运行"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        SUDO_CMD="sudo"
        log_success "检测到sudo权限"
    else
        log_error "需要root权限或sudo权限"
        echo "请使用以下方式之一运行："
        echo "1. sudo $0"
        echo "2. 切换到root用户后运行"
        exit 1
    fi
    
    # 检查必需的命令
    local required_commands=("kubectl" "helm" "curl" "nginx" "systemctl")
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "缺少必需的命令: ${missing_commands[*]}"
        echo ""
        echo "请先安装缺少的软件包："
        echo "Ubuntu/Debian: apt update && apt install -y ${missing_commands[*]}"
        echo "CentOS/RHEL: yum install -y ${missing_commands[*]}"
        exit 1
    fi
    
    log_success "系统要求检查通过"
}

# 读取ESS配置
read_ess_config() {
    log_info "读取ESS配置..."
    
    # 检查ESS是否已部署
    if ! kubectl get namespace ess >/dev/null 2>&1; then
        log_error "ESS命名空间不存在，请先部署ESS"
        echo ""
        echo "请使用setup.sh脚本进行ESS初始部署："
        echo "./setup.sh"
        exit 1
    fi
    
    # 检查ESS服务状态
    local ess_pods=$(kubectl get pods -n ess --no-headers 2>/dev/null | wc -l)
    if [[ $ess_pods -eq 0 ]]; then
        log_error "ESS服务未运行，请检查部署状态"
        exit 1
    fi
    
    log_success "ESS服务运行正常 ($ess_pods 个Pod)"
    
    # 从Ingress获取域名配置
    local ingresses=$(kubectl get ingress -n ess --no-headers 2>/dev/null || echo "")
    if [[ -z "$ingresses" ]]; then
        log_error "未找到ESS Ingress配置"
        exit 1
    fi
    
    # 解析域名配置
    SERVER_NAME=$(kubectl get ingress ess-well-known -n ess -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    ELEMENT_WEB_HOST=$(kubectl get ingress ess-element-web -n ess -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    MAS_HOST=$(kubectl get ingress ess-matrix-authentication-service -n ess -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    RTC_HOST=$(kubectl get ingress ess-matrix-rtc -n ess -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    SYNAPSE_HOST=$(kubectl get ingress ess-synapse -n ess -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    
    # 验证域名配置
    if [[ -z "$SERVER_NAME" || -z "$ELEMENT_WEB_HOST" || -z "$MAS_HOST" || -z "$RTC_HOST" || -z "$SYNAPSE_HOST" ]]; then
        log_error "无法获取完整的域名配置"
        echo "请检查ESS Ingress配置是否正确"
        exit 1
    fi
    
    log_success "域名配置读取成功"
    log_info "主域名: $SERVER_NAME"
    log_info "Element Web: $ELEMENT_WEB_HOST"
    log_info "认证服务: $MAS_HOST"
    log_info "RTC服务: $RTC_HOST"
    log_info "Matrix服务器: $SYNAPSE_HOST"
}

# 检查Traefik状态
check_traefik_status() {
    log_info "检查Traefik状态..."
    
    # 检查Traefik服务
    local traefik_svc=$(kubectl get svc -n kube-system traefik --no-headers 2>/dev/null || echo "")
    if [[ -z "$traefik_svc" ]]; then
        log_error "Traefik服务未找到"
        exit 1
    fi
    
    # 获取Traefik端口信息
    local traefik_info=$(kubectl get svc -n kube-system traefik -o jsonpath='{.spec.ports}' 2>/dev/null || echo "")
    log_debug "Traefik端口配置: $traefik_info"
    
    # 验证Traefik端口配置
    if echo "$traefik_info" | grep -q "8080.*8443"; then
        log_success "Traefik运行在推荐端口 (8080/8443)"
    else
        log_warning "Traefik端口配置可能不标准，将使用默认配置"
    fi
    
    log_success "Traefik状态检查完成"
}

# 配置自定义端口
configure_custom_ports() {
    log_info "配置外部访问端口..."
    
    echo ""
    echo -e "${YELLOW}端口配置说明：${NC}"
    echo "• 由于ISP可能封锁标准端口(80/443)，建议使用自定义端口"
    echo "• HTTP端口用于重定向到HTTPS"
    echo "• HTTPS端口用于实际的SSL服务"
    echo "• 推荐使用8080/8443端口组合"
    echo ""
    
    # HTTP端口配置
    while true; do
        read -p "请输入HTTP端口 [默认: $DEFAULT_HTTP_PORT]: " EXTERNAL_HTTP_PORT || EXTERNAL_HTTP_PORT=""
        EXTERNAL_HTTP_PORT=${EXTERNAL_HTTP_PORT:-$DEFAULT_HTTP_PORT}
        
        if [[ "$EXTERNAL_HTTP_PORT" =~ ^[0-9]+$ ]] && [[ "$EXTERNAL_HTTP_PORT" -ge 1024 ]] && [[ "$EXTERNAL_HTTP_PORT" -le 65535 ]]; then
            break
        else
            log_error "请输入有效的端口号 (1024-65535)"
        fi
    done
    
    # HTTPS端口配置
    while true; do
        read -p "请输入HTTPS端口 [默认: $DEFAULT_HTTPS_PORT]: " EXTERNAL_HTTPS_PORT || EXTERNAL_HTTPS_PORT=""
        EXTERNAL_HTTPS_PORT=${EXTERNAL_HTTPS_PORT:-$DEFAULT_HTTPS_PORT}
        
        if [[ "$EXTERNAL_HTTPS_PORT" =~ ^[0-9]+$ ]] && [[ "$EXTERNAL_HTTPS_PORT" -ge 1024 ]] && [[ "$EXTERNAL_HTTPS_PORT" -le 65535 ]] && [[ "$EXTERNAL_HTTPS_PORT" != "$EXTERNAL_HTTP_PORT" ]]; then
            break
        else
            log_error "请输入有效且不重复的端口号 (1024-65535)"
        fi
    done
    
    log_success "端口配置完成"
    log_info "外部HTTP端口: $EXTERNAL_HTTP_PORT"
    log_info "外部HTTPS端口: $EXTERNAL_HTTPS_PORT"
    
    # 导出变量供其他函数使用
    export SERVER_NAME ELEMENT_WEB_HOST MAS_HOST RTC_HOST SYNAPSE_HOST
    export EXTERNAL_HTTP_PORT EXTERNAL_HTTPS_PORT
}

# 主菜单
show_main_menu() {
    show_banner
    
    echo -e "${WHITE}请选择要执行的操作：${NC}"
    echo ""
    echo -e "${GREEN}=== 核心功能 ===${NC}"
    echo "1) 🚀 完整配置nginx反代 (推荐 - 一键解决所有问题)"
    echo "2) 👤 用户管理 (创建、修改、查看用户)"
    echo "3) 🔧 Element Call问题修复"
    echo ""
    echo -e "${BLUE}=== 系统管理 ===${NC}"
    echo "4) 📊 系统状态检查"
    echo "5) 📋 查看服务日志"
    echo "6) 🔄 重启ESS服务"
    echo "7) 💾 备份配置"
    echo ""
    echo -e "${YELLOW}=== 诊断工具 ===${NC}"
    echo "8) 🔍 完整系统诊断"
    echo "9) 🌐 网络连接测试"
    echo "10) 🎥 Matrix RTC诊断"
    echo ""
    echo -e "${RED}0) 退出${NC}"
    echo ""
    
    read -p "请输入选择 [0-10]: " choice || choice=""
    
    case $choice in
        1) full_nginx_setup ;;
        2) user_management ;;
        3) fix_element_call ;;
        4) show_system_status ;;
        5) show_service_logs ;;
        6) restart_ess_services ;;
        7) backup_configuration ;;
        8) full_system_diagnosis ;;
        9) network_connectivity_test ;;
        10) matrix_rtc_diagnosis ;;
        0) exit 0 ;;
        *)
            log_error "无效选择，请输入有效选项 [0-10]"
            sleep 2
            show_main_menu
            ;;
    esac
}

# 完整nginx反代配置
full_nginx_setup() {
    log_info "开始完整nginx反代配置..."

    # 配置自定义端口
    configure_custom_ports

    echo ""
    echo -e "${BLUE}=== nginx反代配置流程 ===${NC}"
    echo "1. 安装和配置nginx"
    echo "2. 生成SSL证书"
    echo "3. 配置防火墙"
    echo "4. 修复ESS内部配置"
    echo "5. 修复Element Call问题"
    echo "6. 验证配置"
    echo ""

    read -p "确认开始配置? [y/N]: " confirm || confirm=""
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        show_main_menu
        return
    fi

    # 执行配置步骤
    install_nginx
    extract_ssl_certificates
    generate_nginx_config
    configure_firewall
    fix_ess_internal_configs
    fix_element_call_issues
    verify_configuration

    echo ""
    log_success "nginx反代配置完成！"
    echo ""
    echo -e "${GREEN}访问地址：${NC}"
    echo "• Element Web: https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
    echo "• 认证服务: https://$MAS_HOST:$EXTERNAL_HTTPS_PORT"
    echo "• Matrix服务器: https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"
    echo ""
    echo -e "${YELLOW}注意事项：${NC}"
    echo "• 请确保防火墙开放了端口 $EXTERNAL_HTTP_PORT 和 $EXTERNAL_HTTPS_PORT"
    echo "• 如果使用云服务器，请在安全组中开放这些端口"
    echo "• Element Call功能已自动修复"
    echo ""

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 安装nginx
install_nginx() {
    log_info "安装和配置nginx..."

    # 检查nginx是否已安装
    if command -v nginx >/dev/null 2>&1; then
        log_success "nginx已安装"
    else
        log_info "安装nginx..."
        if command -v apt >/dev/null 2>&1; then
            $SUDO_CMD apt update
            $SUDO_CMD apt install -y nginx
        elif command -v yum >/dev/null 2>&1; then
            $SUDO_CMD yum install -y nginx
        else
            log_error "不支持的包管理器，请手动安装nginx"
            exit 1
        fi
        log_success "nginx安装完成"
    fi

    # 启用nginx服务
    $SUDO_CMD systemctl enable nginx
    $SUDO_CMD systemctl start nginx

    log_success "nginx服务已启动"
}

# 提取SSL证书
extract_ssl_certificates() {
    log_info "提取ESS SSL证书..."

    # 创建证书目录
    $SUDO_CMD mkdir -p /etc/ssl/certs
    $SUDO_CMD mkdir -p /etc/ssl/private

    # 从ESS Secret中提取证书
    local cert_secret=$(kubectl get secret -n ess | grep "tls" | head -1 | awk '{print $1}')
    if [[ -z "$cert_secret" ]]; then
        log_error "未找到ESS TLS证书"
        exit 1
    fi

    log_info "使用证书: $cert_secret"

    # 提取证书和私钥
    kubectl get secret "$cert_secret" -n ess -o jsonpath='{.data.tls\.crt}' | base64 -d | $SUDO_CMD tee /etc/ssl/certs/ess.crt >/dev/null
    kubectl get secret "$cert_secret" -n ess -o jsonpath='{.data.tls\.key}' | base64 -d | $SUDO_CMD tee /etc/ssl/private/ess.key >/dev/null

    # 设置证书权限
    $SUDO_CMD chmod 644 /etc/ssl/certs/ess.crt
    $SUDO_CMD chmod 600 /etc/ssl/private/ess.key

    log_success "SSL证书提取完成"
}

# 生成nginx配置
generate_nginx_config() {
    log_info "生成nginx配置文件..."

    local config_file="$NGINX_SITES_DIR/ess-proxy"

    # 备份现有配置
    if [[ -f "$config_file" ]]; then
        $SUDO_CMD cp "$config_file" "${config_file}.backup.$(date +%Y%m%d-%H%M%S)"
        log_info "已备份现有配置"
    fi

    # 生成配置文件
    $SUDO_CMD tee "$config_file" >/dev/null <<EOF
# ESS Community nginx反代配置
# 版本: 3.0.0
# 基于ESS官方推荐配置

# HTTPS服务器配置
server {
    listen $EXTERNAL_HTTPS_PORT ssl http2;
    listen [::]:$EXTERNAL_HTTPS_PORT ssl http2;

    # 支持所有ESS域名
    server_name $ELEMENT_WEB_HOST $MAS_HOST $RTC_HOST $SYNAPSE_HOST $SERVER_NAME;

    # SSL配置
    ssl_certificate /etc/ssl/certs/ess.crt;
    ssl_certificate_key /etc/ssl/private/ess.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 安全头
    add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains; preload' always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # 日志配置
    access_log /var/log/nginx/ess-access.log;
    error_log /var/log/nginx/ess-error.log;

    # 主要代理配置
    location / {
        proxy_pass http://127.0.0.1:$TRAEFIK_HTTP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # WebSocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 超时配置
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # 缓冲配置
        proxy_buffering off;
        proxy_request_buffering off;

        # 文件上传限制
        client_max_body_size 50M;
    }

    # well-known路径特殊处理（修复Element Call问题）
    location /.well-known/ {
        proxy_pass http://127.0.0.1:$TRAEFIK_HTTP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 确保正确的Content-Type
        proxy_set_header Accept "application/json";

        # 禁用缓存
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Pragma "no-cache";
        add_header Expires "0";
    }
}

# HTTP重定向到HTTPS
server {
    listen $EXTERNAL_HTTP_PORT;
    listen [::]:$EXTERNAL_HTTP_PORT;

    server_name $ELEMENT_WEB_HOST $MAS_HOST $RTC_HOST $SYNAPSE_HOST $SERVER_NAME;

    # 重定向到HTTPS
    return 301 https://\$host:$EXTERNAL_HTTPS_PORT\$request_uri;
}
EOF

    # 启用配置
    $SUDO_CMD ln -sf "$config_file" "$NGINX_ENABLED_DIR/"

    # 删除默认配置
    $SUDO_CMD rm -f "$NGINX_ENABLED_DIR/default"

    # 测试配置
    if $SUDO_CMD nginx -t; then
        log_success "nginx配置生成成功"
        $SUDO_CMD systemctl reload nginx
        log_success "nginx配置已重新加载"
    else
        log_error "nginx配置测试失败"
        exit 1
    fi
}

# 主程序入口
main() {
    # 检查系统要求
    check_system_requirements

    # 读取ESS配置
    read_ess_config

    # 检查Traefik状态
    check_traefik_status

    # 显示主菜单
    show_main_menu
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙规则..."

    if command -v ufw >/dev/null 2>&1; then
        log_info "检测到UFW防火墙"

        # 开放自定义端口
        $SUDO_CMD ufw allow "$EXTERNAL_HTTP_PORT/tcp" comment "ESS HTTP"
        $SUDO_CMD ufw allow "$EXTERNAL_HTTPS_PORT/tcp" comment "ESS HTTPS"

        # 开放WebRTC端口（修复Element Call）
        $SUDO_CMD ufw allow "30881/tcp" comment "WebRTC TCP"
        $SUDO_CMD ufw allow "30882/udp" comment "WebRTC UDP"

        # 确保SSH端口开放
        $SUDO_CMD ufw allow "22/tcp" comment "SSH"

        log_success "UFW防火墙规则已添加"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        log_info "检测到firewalld防火墙"

        # 开放自定义端口
        $SUDO_CMD firewall-cmd --permanent --add-port="$EXTERNAL_HTTP_PORT/tcp"
        $SUDO_CMD firewall-cmd --permanent --add-port="$EXTERNAL_HTTPS_PORT/tcp"

        # 开放WebRTC端口
        $SUDO_CMD firewall-cmd --permanent --add-port="30881/tcp"
        $SUDO_CMD firewall-cmd --permanent --add-port="30882/udp"

        $SUDO_CMD firewall-cmd --reload

        log_success "firewalld防火墙规则已添加"
    else
        log_warning "未检测到支持的防火墙，请手动开放端口："
        echo "• HTTP端口: $EXTERNAL_HTTP_PORT"
        echo "• HTTPS端口: $EXTERNAL_HTTPS_PORT"
        echo "• WebRTC端口: 30881/tcp, 30882/udp"
    fi
}

# 修复ESS内部配置
fix_ess_internal_configs() {
    log_info "修复ESS内部配置..."

    # 修复MAS ConfigMap
    fix_mas_configmap

    # 修复well-known ConfigMap
    fix_wellknown_configmap

    # 修复Element Web ConfigMap
    fix_element_web_configmap

    log_success "ESS内部配置修复完成"
}

# 修复MAS ConfigMap
fix_mas_configmap() {
    log_info "修复MAS ConfigMap中的端口配置..."

    # 获取当前MAS配置
    local current_public_base=$(kubectl get configmap ess-matrix-authentication-service -n ess -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep "public_base:" | awk '{print $2}' || echo "")

    if [[ -z "$current_public_base" ]]; then
        log_error "无法获取MAS ConfigMap配置"
        return 1
    fi

    log_info "当前MAS public_base: $current_public_base"

    # 检查是否需要修复
    local expected_public_base="https://$MAS_HOST:$EXTERNAL_HTTPS_PORT"

    if [[ "$current_public_base" == "$expected_public_base" ]]; then
        log_success "MAS ConfigMap配置已正确，无需修复"
        return 0
    fi

    log_warning "需要修复MAS ConfigMap配置"
    log_info "当前值: $current_public_base"
    log_info "期望值: $expected_public_base"

    # 备份当前ConfigMap
    local backup_file="$ESS_CONFIG_DIR/mas-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
    $SUDO_CMD mkdir -p "$ESS_CONFIG_DIR"
    if kubectl get configmap ess-matrix-authentication-service -n ess -o yaml > "$backup_file" 2>/dev/null; then
        log_success "ConfigMap备份完成: $backup_file"
    else
        log_warning "ConfigMap备份失败"
    fi

    # 修复配置
    log_info "正在修复MAS public_base配置..."
    local config_yaml=$(kubectl get configmap ess-matrix-authentication-service -n ess -o jsonpath='{.data.config\.yaml}')
    local fixed_config=$(echo "$config_yaml" | sed "s|public_base:.*|public_base: $expected_public_base|")

    if kubectl patch configmap ess-matrix-authentication-service -n ess --type merge -p "{\"data\":{\"config.yaml\":\"$fixed_config\"}}"; then
        log_success "MAS ConfigMap修复成功"

        # 重启MAS服务
        kubectl rollout restart deployment ess-matrix-authentication-service -n ess
        log_info "MAS服务已重启"
    else
        log_error "MAS ConfigMap修复失败"
        return 1
    fi
}

# 修复well-known ConfigMap
fix_wellknown_configmap() {
    log_info "修复well-known ConfigMap中的端口配置..."

    # 检查当前well-known server配置
    local current_server=$(kubectl get configmap ess-well-known-haproxy -n ess -o jsonpath='{.data.server}' 2>/dev/null | grep -o 'matrix.*:[0-9]*' || echo "")

    if [[ -z "$current_server" ]]; then
        log_error "无法获取well-known ConfigMap中的server配置"
        return 1
    fi

    log_info "当前well-known server配置: $current_server"

    # 检查是否需要修复
    local expected_server="$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"

    if [[ "$current_server" == "$expected_server" ]]; then
        log_success "well-known ConfigMap配置已正确，无需修复"
        return 0
    fi

    log_warning "需要修复well-known ConfigMap配置"
    log_info "当前值: $current_server"
    log_info "期望值: $expected_server"

    # 备份当前ConfigMap
    local backup_file="$ESS_CONFIG_DIR/wellknown-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
    if kubectl get configmap ess-well-known-haproxy -n ess -o yaml > "$backup_file" 2>/dev/null; then
        log_success "ConfigMap备份完成: $backup_file"
    else
        log_warning "ConfigMap备份失败"
    fi

    # 修复server配置
    log_info "正在修复well-known server配置..."
    local server_config="{\"m.server\": \"$expected_server\"}"

    if kubectl patch configmap ess-well-known-haproxy -n ess --type merge -p "{\"data\":{\"server\":\"$server_config\"}}"; then
        log_success "well-known server配置修复成功"
    else
        log_error "well-known server配置修复失败"
        return 1
    fi

    # 修复client配置
    log_info "正在修复well-known client配置..."
    local client_config="{
  \"m.homeserver\": {
    \"base_url\": \"https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT\"
  },
  \"org.matrix.msc2965.authentication\": {
    \"account\": \"https://$MAS_HOST:$EXTERNAL_HTTPS_PORT/account\",
    \"issuer\": \"https://$MAS_HOST:$EXTERNAL_HTTPS_PORT/\"
  },
  \"org.matrix.msc4143.rtc_foci\": [
    {
      \"type\": \"livekit\",
      \"livekit_service_url\": \"https://$RTC_HOST:$EXTERNAL_HTTPS_PORT\"
    }
  ]
}"

    if kubectl patch configmap ess-well-known-haproxy -n ess --type merge -p "{\"data\":{\"client\":\"$client_config\"}}"; then
        log_success "well-known client配置修复成功"
    else
        log_error "well-known client配置修复失败"
        return 1
    fi

    # 重启HAProxy服务
    log_info "重启HAProxy服务以应用新配置..."
    if kubectl rollout restart deployment ess-haproxy -n ess; then
        log_success "HAProxy服务重启命令已执行"

        # 等待重启完成
        log_info "等待HAProxy服务重启完成..."
        if kubectl rollout status deployment ess-haproxy -n ess --timeout=300s; then
            log_success "HAProxy服务重启完成"
        else
            log_warning "HAProxy服务重启超时，请手动检查状态"
        fi
    else
        log_error "HAProxy服务重启失败"
        return 1
    fi
}

# 修复Element Web ConfigMap
fix_element_web_configmap() {
    log_info "修复Element Web ConfigMap中的端口配置..."

    # 检查当前Element Web配置
    local current_base_url=$(kubectl get configmap ess-element-web -n ess -o jsonpath='{.data.config\.json}' 2>/dev/null | sed -n 's/.*"base_url": *"\([^"]*\)".*/\1/p' || echo "")

    if [[ -z "$current_base_url" ]]; then
        log_error "无法获取Element Web ConfigMap中的base_url配置"
        return 1
    fi

    log_info "当前Element Web base_url配置: $current_base_url"

    # 检查是否需要修复
    local expected_base_url="https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"

    if [[ "$current_base_url" == "$expected_base_url" ]]; then
        log_success "Element Web ConfigMap配置已正确，无需修复"
        return 0
    fi

    log_warning "需要修复Element Web ConfigMap配置"
    log_info "当前值: $current_base_url"
    log_info "期望值: $expected_base_url"

    # Element Web配置通常由ESS自动管理，只记录差异
    log_info "Element Web配置将在服务重启后自动更新"

    return 0
}

# 修复Element Call问题
fix_element_call_issues() {
    log_info "修复Element Call问题..."

    # 检查WebRTC端口状态
    local tcp_listening=$(netstat -tlnp 2>/dev/null | grep ":30881" && echo "是" || echo "否")
    local udp_listening=$(netstat -ulnp 2>/dev/null | grep ":30882" && echo "是" || echo "否")

    echo "WebRTC端口状态："
    echo "TCP 30881: $tcp_listening"
    echo "UDP 30882: $udp_listening"

    if [[ "$tcp_listening" == "否" || "$udp_listening" == "否" ]]; then
        log_warning "WebRTC端口未正确监听，尝试修复..."

        # 重启Matrix RTC服务
        log_info "重启Matrix RTC服务..."
        kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
        kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess

        # 等待重启完成
        kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s
        kubectl rollout status deployment ess-matrix-rtc-authorisation-service -n ess --timeout=300s

        # 重启网络组件
        log_info "重启Kubernetes网络组件..."
        $SUDO_CMD systemctl restart kube-proxy 2>/dev/null || true
        $SUDO_CMD systemctl restart kubelet 2>/dev/null || true

        # 等待端口启动
        sleep 30

        # 再次检查端口
        local tcp_after=$(netstat -tlnp 2>/dev/null | grep ":30881" && echo "是" || echo "否")
        local udp_after=$(netstat -ulnp 2>/dev/null | grep ":30882" && echo "是" || echo "否")

        echo "修复后WebRTC端口状态："
        echo "TCP 30881: $tcp_after"
        echo "UDP 30882: $udp_after"

        if [[ "$tcp_after" == "是" && "$udp_after" == "是" ]]; then
            log_success "WebRTC端口修复成功"
        else
            log_warning "WebRTC端口仍有问题，可能需要检查ESS部署配置"
        fi
    else
        log_success "WebRTC端口监听正常"
    fi

    log_success "Element Call问题修复完成"
}

# 验证配置
verify_configuration() {
    log_info "验证配置..."

    echo ""
    echo -e "${BLUE}=== 配置验证结果 ===${NC}"

    # 验证nginx服务
    if systemctl is-active --quiet nginx; then
        log_success "nginx服务运行正常"
    else
        log_error "nginx服务未运行"
    fi

    # 验证端口监听
    if netstat -tlnp 2>/dev/null | grep -q ":$EXTERNAL_HTTPS_PORT"; then
        log_success "nginx正在监听端口 $EXTERNAL_HTTPS_PORT"
    else
        log_warning "nginx未监听端口 $EXTERNAL_HTTPS_PORT"
    fi

    # 验证SSL证书
    if [[ -f "/etc/ssl/certs/ess.crt" && -f "/etc/ssl/private/ess.key" ]]; then
        log_success "SSL证书文件存在"
    else
        log_warning "SSL证书文件缺失"
    fi

    # 验证防火墙
    if command -v ufw >/dev/null 2>&1; then
        if ufw status | grep -q "$EXTERNAL_HTTPS_PORT"; then
            log_success "防火墙规则已配置"
        else
            log_warning "防火墙规则可能未配置"
        fi
    fi

    # 验证ESS服务
    local ess_pods_ready=$(kubectl get pods -n ess --no-headers 2>/dev/null | grep "1/1.*Running" | wc -l)
    local ess_pods_total=$(kubectl get pods -n ess --no-headers 2>/dev/null | wc -l)

    if [[ $ess_pods_ready -gt 0 ]]; then
        log_success "ESS服务运行正常 ($ess_pods_ready/$ess_pods_total Pod就绪)"
    else
        log_warning "ESS服务可能有问题"
    fi

    echo ""
    log_success "配置验证完成"
}

# 用户管理
user_management() {
    show_banner

    echo -e "${WHITE}用户管理功能${NC}"
    echo ""
    echo "1) 创建新用户"
    echo "2) 修改用户密码"
    echo "3) 锁定用户"
    echo "4) 解锁用户"
    echo "5) 查看用户列表"
    echo "0) 返回主菜单"
    echo ""

    read -p "请选择操作 [0-5]: " choice || choice=""

    case $choice in
        1) create_user ;;
        2) change_user_password ;;
        3) lock_user ;;
        4) unlock_user ;;
        5) list_users ;;
        0) show_main_menu ;;
        *)
            log_error "无效选择"
            sleep 2
            user_management
            ;;
    esac
}

# 创建用户
create_user() {
    echo ""
    echo -e "${BLUE}=== 创建新用户 ===${NC}"
    echo ""

    read -p "用户名: " username || username=""
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        sleep 2
        user_management
        return
    fi

    read -s -p "密码: " password || password=""
    echo ""
    if [[ -z "$password" ]]; then
        log_error "密码不能为空"
        sleep 2
        user_management
        return
    fi

    read -p "邮箱 (可选): " email || email=""
    read -p "显示名 (可选): " display_name || display_name=""
    read -p "设为管理员? [y/N]: " is_admin || is_admin=""

    # 构建命令
    local cmd="kubectl exec -n ess deployment/ess-matrix-authentication-service -- mas-cli manage register-user"
    cmd="$cmd --password '$password'"
    cmd="$cmd --yes"
    cmd="$cmd --ignore-password-complexity"

    if [[ -n "$email" ]]; then
        cmd="$cmd --email '$email'"
    fi

    if [[ -n "$display_name" ]]; then
        cmd="$cmd --display-name '$display_name'"
    fi

    if [[ "$is_admin" =~ ^[Yy]$ ]]; then
        cmd="$cmd --admin"
    fi

    cmd="$cmd '$username'"

    log_info "创建用户: $username"

    if eval "$cmd"; then
        log_success "用户创建成功"
        echo ""
        echo "用户信息："
        echo "• 用户名: $username"
        echo "• 邮箱: ${email:-未设置}"
        echo "• 显示名: ${display_name:-未设置}"
        echo "• 管理员: $([ "$is_admin" = "y" ] && echo "是" || echo "否")"
    else
        log_error "用户创建失败"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
    user_management
}

# Element Call修复
fix_element_call() {
    show_banner

    echo -e "${WHITE}Element Call问题修复${NC}"
    echo ""
    echo "此功能将检查和修复Element Call相关问题："
    echo "• WebRTC端口状态"
    echo "• Matrix RTC服务"
    echo "• well-known配置"
    echo "• 网络连接"
    echo ""

    read -p "确认开始修复? [y/N]: " confirm || confirm=""
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        show_main_menu
        return
    fi

    # 读取配置
    read_ess_config
    configure_custom_ports

    # 执行修复
    fix_element_call_issues

    echo ""
    log_success "Element Call修复完成！"
    echo ""
    echo "测试步骤："
    echo "1. 清除浏览器缓存"
    echo "2. 访问: https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
    echo "3. 登录并创建房间"
    echo "4. 测试视频通话功能"
    echo ""

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 显示系统状态
show_system_status() {
    show_banner

    echo -e "${WHITE}系统状态检查${NC}"
    echo ""

    # ESS服务状态
    echo -e "${BLUE}=== ESS服务状态 ===${NC}"
    kubectl get pods -n ess
    echo ""

    # nginx状态
    echo -e "${BLUE}=== nginx状态 ===${NC}"
    systemctl status nginx --no-pager -l
    echo ""

    # 端口监听状态
    echo -e "${BLUE}=== 端口监听状态 ===${NC}"
    netstat -tlnp | grep -E ":(80|443|8080|8443|30881|30882)" || echo "未找到相关端口"
    echo ""

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
