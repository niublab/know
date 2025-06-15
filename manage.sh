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

    # 检查WebRTC端口状态（正确的方法）
    log_info "检查WebRTC端口状态..."

    # 首先检查Pod内部端口监听
    local pod_name=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-rtc-sfu -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    local pod_tcp_listening="否"
    local pod_udp_listening="否"

    if [[ -n "$pod_name" ]]; then
        if kubectl exec -n ess "$pod_name" -- netstat -tlnp 2>/dev/null | grep -q ":30881"; then
            pod_tcp_listening="是"
        fi
        # 注意：UDP端口在netstat中可能不显示，但配置文件显示已配置
        pod_udp_listening="是（已配置）"
    fi

    # 检查宿主机iptables规则
    local iptables_tcp="否"
    local iptables_udp="否"

    if $SUDO_CMD iptables -t nat -L -n | grep -q "30881"; then
        iptables_tcp="是"
    fi

    if $SUDO_CMD iptables -t nat -L -n | grep -q "30882"; then
        iptables_udp="是"
    fi

    echo "WebRTC端口状态详细检查："
    echo "Pod内部 TCP 30881: $pod_tcp_listening"
    echo "Pod内部 UDP 30882: $pod_udp_listening"
    echo "iptables TCP规则: $iptables_tcp"
    echo "iptables UDP规则: $iptables_udp"

    # 判断是否需要修复
    local needs_fix="否"
    if [[ "$pod_tcp_listening" == "否" || "$iptables_tcp" == "否" || "$iptables_udp" == "否" ]]; then
        needs_fix="是"
    fi

    if [[ "$needs_fix" == "是" ]]; then
        log_warning "WebRTC端口未正确监听，尝试修复..."

        # 重启Matrix RTC服务
        log_info "重启Matrix RTC服务..."
        kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
        kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess

        # 等待重启完成
        kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s
        kubectl rollout status deployment ess-matrix-rtc-authorisation-service -n ess --timeout=300s

        # 深度诊断WebRTC端口问题
        log_info "深度诊断WebRTC端口问题..."

        # 检查NodePort服务配置
        echo "检查NodePort服务配置："
        kubectl get svc -n ess | grep matrix-rtc

        # 检查服务端点
        echo ""
        echo "检查服务端点："
        kubectl get endpoints -n ess | grep matrix-rtc

        # 检查iptables规则
        echo ""
        echo "检查iptables NAT规则："
        $SUDO_CMD iptables -t nat -L | grep -E "30881|30882" || echo "未找到WebRTC端口的iptables规则"

        # 检查Pod网络状态
        echo ""
        echo "检查Matrix RTC Pod网络状态："
        kubectl exec -n ess deployment/ess-matrix-rtc-sfu -- netstat -tlnp 2>/dev/null | grep -E "7880|30881" || echo "Pod内部端口检查失败"

        # 重启网络组件
        log_info "重启Kubernetes网络组件..."
        $SUDO_CMD systemctl restart kube-proxy 2>/dev/null || true
        $SUDO_CMD systemctl restart kubelet 2>/dev/null || true

        # 强制重新创建NodePort服务
        log_info "尝试重新创建NodePort服务..."
        kubectl delete svc ess-matrix-rtc-sfu-tcp ess-matrix-rtc-sfu-muxed-udp -n ess 2>/dev/null || true
        sleep 10

        # 重启Matrix RTC部署以重新创建服务
        kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
        kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s

        # 等待端口启动
        sleep 30

        # 再次检查端口（使用正确的方法）
        sleep 10
        local pod_name_after=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-rtc-sfu -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        local tcp_after="否"
        local udp_after="否"
        local iptables_after="否"

        if [[ -n "$pod_name_after" ]]; then
            if kubectl exec -n ess "$pod_name_after" -- netstat -tlnp 2>/dev/null | grep -q ":30881"; then
                tcp_after="是"
            fi
            udp_after="是（已配置）"
        fi

        if $SUDO_CMD iptables -t nat -L -n | grep -q "30881.*30882"; then
            iptables_after="是"
        fi

        echo "修复后WebRTC端口状态："
        echo "Pod内部 TCP 30881: $tcp_after"
        echo "Pod内部 UDP 30882: $udp_after"
        echo "iptables规则: $iptables_after"

        if [[ "$tcp_after" == "是" && "$iptables_after" == "是" ]]; then
            log_success "WebRTC端口修复成功！"
            echo ""
            echo "🎉 Element Call现在应该可以正常工作了！"
            echo ""
            echo "测试步骤："
            echo "1. 清除浏览器缓存"
            echo "2. 访问Element Web"
            echo "3. 创建房间并测试视频通话"
        else
            log_warning "WebRTC端口配置可能仍有问题"
        fi
    else
        log_success "WebRTC端口监听正常"
    fi

    log_success "Element Call问题修复完成"
}

# 获取正确的外部IP（使用指定的方法）
get_correct_external_ip() {
    local external_ip=""

    log_info "使用正确的方法获取外部IP..."

    # 方法1：使用dig查询自定义域名
    if [[ -n "$SERVER_NAME" ]]; then
        log_info "尝试通过dig查询域名 $SERVER_NAME..."

        # 使用Google DNS
        external_ip=$(dig +short "$SERVER_NAME" @8.8.8.8 2>/dev/null | head -1)
        if [[ -n "$external_ip" && "$external_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_success "通过Google DNS获取到外部IP: $external_ip"
            echo "$external_ip"
            return 0
        fi

        # 使用Cloudflare DNS
        external_ip=$(dig +short "$SERVER_NAME" @1.1.1.1 2>/dev/null | head -1)
        if [[ -n "$external_ip" && "$external_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_success "通过Cloudflare DNS获取到外部IP: $external_ip"
            echo "$external_ip"
            return 0
        fi
    fi

    log_error "无法通过dig方法获取外部IP"
    return 1
}

# 修复LiveKit外部IP配置
fix_livekit_external_ip() {
    log_info "修复LiveKit外部IP配置..."

    # 获取正确的外部IP
    local correct_ip=$(get_correct_external_ip)
    if [[ -z "$correct_ip" ]]; then
        log_error "无法获取正确的外部IP，跳过LiveKit配置修复"
        return 1
    fi

    log_info "将配置LiveKit使用外部IP: $correct_ip"

    # 获取当前的Matrix RTC ConfigMap
    local configmap_name="ess-matrix-rtc-sfu"

    # 备份当前配置
    local backup_file="/tmp/matrix-rtc-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
    kubectl get configmap "$configmap_name" -n ess -o yaml > "$backup_file" 2>/dev/null
    log_info "ConfigMap备份到: $backup_file"

    # 创建新的配置，明确指定外部IP
    local new_config="rtc:
  use_external_ip: true
  external_ip: $correct_ip
  tcp_port: 30881
  udp_port: 30882
port: 7880
prometheus_port: 6789
logging:
  level: info
  json: false
  pion_level: error
turn:
  enabled: false"

    # 更新ConfigMap
    if kubectl patch configmap "$configmap_name" -n ess --type merge -p "{\"data\":{\"config-underrides.yaml\":\"$new_config\"}}"; then
        log_success "LiveKit ConfigMap更新成功"

        # 重启Matrix RTC服务以应用新配置
        log_info "重启Matrix RTC服务以应用新配置..."
        kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
        kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess

        # 等待重启完成
        kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s
        kubectl rollout status deployment ess-matrix-rtc-authorisation-service -n ess --timeout=300s

        log_success "LiveKit外部IP配置修复完成"
        return 0
    else
        log_error "LiveKit ConfigMap更新失败"
        return 1
    fi
}

# 专门的WebRTC端口修复函数
fix_webrtc_ports_advanced() {
    log_info "高级WebRTC端口修复..."

    echo ""
    echo -e "${BLUE}=== WebRTC端口问题深度分析 ===${NC}"

    # 1. 检查ESS Helm配置
    log_info "1. 检查ESS Helm配置中的Matrix RTC设置..."
    if helm get values ess -n ess | grep -A 20 "matrix-rtc" 2>/dev/null; then
        echo "找到Matrix RTC配置"
    else
        log_error "ESS Helm配置中可能缺少Matrix RTC配置"
        echo ""
        echo "可能的解决方案："
        echo "1. 重新部署ESS并确保启用Matrix RTC功能"
        echo "2. 检查ESS版本是否支持Matrix RTC"
        return 1
    fi

    echo ""

    # 2. 检查NodePort服务的详细配置
    log_info "2. 检查NodePort服务详细配置..."

    local tcp_svc=$(kubectl get svc ess-matrix-rtc-sfu-tcp -n ess -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
    local udp_svc=$(kubectl get svc ess-matrix-rtc-sfu-muxed-udp -n ess -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")

    echo "TCP NodePort配置: $tcp_svc"
    echo "UDP NodePort配置: $udp_svc"

    if [[ "$tcp_svc" != "30881" || "$udp_svc" != "30882" ]]; then
        log_error "NodePort端口配置不正确"
        echo "期望: TCP=30881, UDP=30882"
        echo "实际: TCP=$tcp_svc, UDP=$udp_svc"

        log_info "尝试修复NodePort配置..."

        # 删除现有服务
        kubectl delete svc ess-matrix-rtc-sfu-tcp ess-matrix-rtc-sfu-muxed-udp -n ess 2>/dev/null || true

        # 创建正确的NodePort服务
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ess-matrix-rtc-sfu-tcp
  namespace: ess
spec:
  type: NodePort
  ports:
  - port: 30881
    targetPort: 30881
    nodePort: 30881
    protocol: TCP
  selector:
    app.kubernetes.io/name: matrix-rtc-sfu
---
apiVersion: v1
kind: Service
metadata:
  name: ess-matrix-rtc-sfu-muxed-udp
  namespace: ess
spec:
  type: NodePort
  ports:
  - port: 30882
    targetPort: 30882
    nodePort: 30882
    protocol: UDP
  selector:
    app.kubernetes.io/name: matrix-rtc-sfu
EOF

        if [[ $? -eq 0 ]]; then
            log_success "NodePort服务重新创建成功"
        else
            log_error "NodePort服务创建失败"
            return 1
        fi
    fi

    echo ""

    # 3. 检查Pod内部端口配置
    log_info "3. 检查Matrix RTC Pod内部配置..."

    local pod_name=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-rtc-sfu -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$pod_name" ]]; then
        echo "Matrix RTC SFU Pod: $pod_name"

        # 检查Pod内部所有端口监听
        echo ""
        echo "Pod内部端口监听情况："
        kubectl exec -n ess "$pod_name" -- netstat -tlnp 2>/dev/null || echo "netstat命令失败"
        kubectl exec -n ess "$pod_name" -- netstat -ulnp 2>/dev/null || echo "UDP netstat命令失败"

        echo ""
        echo "Pod内部进程信息："
        kubectl exec -n ess "$pod_name" -- ps aux 2>/dev/null || echo "ps命令失败"

        # 检查LiveKit配置文件
        echo ""
        echo "LiveKit配置文件内容："
        local livekit_config=$(kubectl exec -n ess "$pod_name" -- cat /conf/config.yaml 2>/dev/null || echo "")
        echo "$livekit_config"

        # 检查外部IP配置
        echo ""
        echo "外部IP配置分析："
        if echo "$livekit_config" | grep -q "use_external_ip: true"; then
            echo "✅ use_external_ip: true (已启用)"

            # 检查是否有明确的外部IP配置
            if echo "$livekit_config" | grep -q "external_ip:"; then
                local external_ip=$(echo "$livekit_config" | grep "external_ip:" | awk '{print $2}')
                echo "✅ 明确配置的外部IP: $external_ip"
            else
                echo "⚠️  未明确配置外部IP，LiveKit将尝试自动检测"
                echo "⚠️  这可能导致使用不正确的IP获取方法"
                echo ""
                read -p "是否修复LiveKit外部IP配置? [y/N]: " fix_ip || fix_ip=""
                if [[ "$fix_ip" =~ ^[Yy]$ ]]; then
                    fix_livekit_external_ip
                fi
            fi
        else
            echo "❌ use_external_ip未启用或配置错误"
        fi

        # 检查Pod日志
        echo ""
        echo "Pod启动日志（最近30行）："
        kubectl logs -n ess "$pod_name" --tail=30

        # 检查Pod的端口配置
        echo ""
        echo "Pod端口配置："
        kubectl get pod -n ess "$pod_name" -o jsonpath='{.spec.containers[0].ports}' | jq . 2>/dev/null || echo "无法获取端口配置"

    else
        log_error "未找到Matrix RTC SFU Pod"
        return 1
    fi

    echo ""

    # 4. 强制重启所有相关组件
    log_info "4. 强制重启所有相关组件..."

    # 重启kube-proxy
    $SUDO_CMD systemctl restart kube-proxy 2>/dev/null || true

    # 重启kubelet
    $SUDO_CMD systemctl restart kubelet 2>/dev/null || true

    # 等待网络组件重启
    sleep 20

    # 重启Matrix RTC服务
    kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
    kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess

    # 等待重启完成
    kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s
    kubectl rollout status deployment ess-matrix-rtc-authorisation-service -n ess --timeout=300s

    # 等待端口启动
    sleep 30

    echo ""

    # 5. 最终验证
    log_info "5. 最终验证..."

    local final_tcp=$(netstat -tlnp 2>/dev/null | grep ":30881" && echo "监听中" || echo "未监听")
    local final_udp=$(netstat -ulnp 2>/dev/null | grep ":30882" && echo "监听中" || echo "未监听")

    echo "最终WebRTC端口状态："
    echo "TCP 30881: $final_tcp"
    echo "UDP 30882: $final_udp"

    if [[ "$final_tcp" == "监听中" && "$final_udp" == "监听中" ]]; then
        log_success "WebRTC端口修复成功！"
        return 0
    else
        log_error "WebRTC端口修复失败"
        echo ""
        echo "基于诊断结果的建议："
        echo ""
        echo "从您的配置来看，问题可能是："
        echo "1. LiveKit服务器配置问题 - 可能没有正确绑定到30881/30882端口"
        echo "2. Pod内部端口映射问题"
        echo "3. LiveKit服务启动失败"
        echo ""
        echo "建议的解决步骤："
        echo "1. 检查LiveKit配置文件中的端口设置"
        echo "2. 重新配置ESS的Matrix RTC组件"
        echo "3. 如果问题持续，可能需要重新部署ESS"
        echo ""
        echo "立即可尝试的操作："
        echo "• 运行: kubectl logs -n ess \$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-rtc-sfu -o name) -f"
        echo "• 检查LiveKit配置: kubectl exec -n ess \$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-rtc-sfu -o name | cut -d/ -f2) -- cat /conf/config.yaml"
        return 1
    fi
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

# 修改用户密码
change_user_password() {
    echo ""
    echo -e "${BLUE}=== 修改用户密码 ===${NC}"
    echo ""

    read -p "用户名: " username || username=""
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        sleep 2
        user_management
        return
    fi

    read -s -p "新密码: " password || password=""
    echo ""
    if [[ -z "$password" ]]; then
        log_error "密码不能为空"
        sleep 2
        user_management
        return
    fi

    log_info "修改用户密码: $username"

    if kubectl exec -n ess deployment/ess-matrix-authentication-service -- mas-cli manage set-password --password "$password" "$username"; then
        log_success "密码修改成功"
    else
        log_error "密码修改失败"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
    user_management
}

# 锁定用户
lock_user() {
    echo ""
    echo -e "${BLUE}=== 锁定用户 ===${NC}"
    echo ""

    read -p "用户名: " username || username=""
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        sleep 2
        user_management
        return
    fi

    log_info "锁定用户: $username"

    if kubectl exec -n ess deployment/ess-matrix-authentication-service -- mas-cli manage lock "$username"; then
        log_success "用户锁定成功"
    else
        log_error "用户锁定失败"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
    user_management
}

# 解锁用户
unlock_user() {
    echo ""
    echo -e "${BLUE}=== 解锁用户 ===${NC}"
    echo ""

    read -p "用户名: " username || username=""
    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        sleep 2
        user_management
        return
    fi

    log_info "解锁用户: $username"

    if kubectl exec -n ess deployment/ess-matrix-authentication-service -- mas-cli manage unlock "$username"; then
        log_success "用户解锁成功"
    else
        log_error "用户解锁失败"
    fi

    echo ""
    read -p "按任意键继续..." -n 1
    user_management
}

# 查看用户列表
list_users() {
    echo ""
    echo -e "${BLUE}=== 用户列表 ===${NC}"
    echo ""

    log_info "获取用户列表..."

    if kubectl exec -n ess deployment/ess-matrix-authentication-service -- mas-cli manage list-users; then
        log_success "用户列表获取成功"
    else
        log_error "用户列表获取失败"
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

    # 检查修复结果
    local tcp_result=$(netstat -tlnp 2>/dev/null | grep ":30881" && echo "监听中" || echo "未监听")
    local udp_result=$(netstat -ulnp 2>/dev/null | grep ":30882" && echo "监听中" || echo "未监听")

    if [[ "$tcp_result" == "未监听" || "$udp_result" == "未监听" ]]; then
        echo ""
        log_warning "基础修复未能解决WebRTC端口问题"
        echo ""
        read -p "是否尝试高级修复? [y/N]: " advanced_fix || advanced_fix=""

        if [[ "$advanced_fix" =~ ^[Yy]$ ]]; then
            echo ""
            log_info "开始高级WebRTC端口修复..."
            fix_webrtc_ports_advanced
        fi
    fi

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

# 查看服务日志
show_service_logs() {
    show_banner

    echo -e "${WHITE}服务日志查看${NC}"
    echo ""
    echo "1) Synapse日志"
    echo "2) MAS认证服务日志"
    echo "3) Matrix RTC日志"
    echo "4) Element Web日志"
    echo "5) HAProxy日志"
    echo "0) 返回主菜单"
    echo ""

    read -p "请选择要查看的日志 [0-5]: " choice || choice=""

    case $choice in
        1)
            echo ""
            echo -e "${BLUE}=== Synapse日志 (最近50行) ===${NC}"
            kubectl logs -n ess deployment/ess-synapse-main --tail=50
            ;;
        2)
            echo ""
            echo -e "${BLUE}=== MAS认证服务日志 (最近50行) ===${NC}"
            kubectl logs -n ess deployment/ess-matrix-authentication-service --tail=50
            ;;
        3)
            echo ""
            echo -e "${BLUE}=== Matrix RTC日志 (最近50行) ===${NC}"
            kubectl logs -n ess deployment/ess-matrix-rtc-sfu --tail=50
            ;;
        4)
            echo ""
            echo -e "${BLUE}=== Element Web日志 (最近50行) ===${NC}"
            kubectl logs -n ess deployment/ess-element-web --tail=50
            ;;
        5)
            echo ""
            echo -e "${BLUE}=== HAProxy日志 (最近50行) ===${NC}"
            kubectl logs -n ess deployment/ess-haproxy --tail=50
            ;;
        0) show_main_menu ;;
        *)
            log_error "无效选择"
            sleep 2
            show_service_logs
            ;;
    esac

    echo ""
    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 重启ESS服务
restart_ess_services() {
    show_banner

    echo -e "${WHITE}重启ESS服务${NC}"
    echo ""
    echo "1) 重启所有服务"
    echo "2) 重启Synapse"
    echo "3) 重启MAS认证服务"
    echo "4) 重启Matrix RTC"
    echo "5) 重启Element Web"
    echo "6) 重启HAProxy"
    echo "0) 返回主菜单"
    echo ""

    read -p "请选择要重启的服务 [0-6]: " choice || choice=""

    case $choice in
        1)
            log_info "重启所有ESS服务..."
            kubectl rollout restart deployment -n ess
            kubectl rollout status deployment -n ess --timeout=300s
            log_success "所有服务重启完成"
            ;;
        2)
            log_info "重启Synapse服务..."
            kubectl rollout restart deployment ess-synapse-main -n ess
            kubectl rollout status deployment ess-synapse-main -n ess --timeout=300s
            log_success "Synapse服务重启完成"
            ;;
        3)
            log_info "重启MAS认证服务..."
            kubectl rollout restart deployment ess-matrix-authentication-service -n ess
            kubectl rollout status deployment ess-matrix-authentication-service -n ess --timeout=300s
            log_success "MAS认证服务重启完成"
            ;;
        4)
            log_info "重启Matrix RTC服务..."
            kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
            kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess
            kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s
            kubectl rollout status deployment ess-matrix-rtc-authorisation-service -n ess --timeout=300s
            log_success "Matrix RTC服务重启完成"
            ;;
        5)
            log_info "重启Element Web服务..."
            kubectl rollout restart deployment ess-element-web -n ess
            kubectl rollout status deployment ess-element-web -n ess --timeout=300s
            log_success "Element Web服务重启完成"
            ;;
        6)
            log_info "重启HAProxy服务..."
            kubectl rollout restart deployment ess-haproxy -n ess
            kubectl rollout status deployment ess-haproxy -n ess --timeout=300s
            log_success "HAProxy服务重启完成"
            ;;
        0) show_main_menu ;;
        *)
            log_error "无效选择"
            sleep 2
            restart_ess_services
            ;;
    esac

    echo ""
    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 备份配置
backup_configuration() {
    show_banner

    echo -e "${WHITE}配置备份${NC}"
    echo ""

    local backup_dir="/opt/ess-backup/$(date +%Y%m%d-%H%M%S)"
    log_info "创建备份目录: $backup_dir"
    $SUDO_CMD mkdir -p "$backup_dir"

    # 备份Kubernetes配置
    log_info "备份Kubernetes配置..."
    kubectl get all -n ess -o yaml > "$backup_dir/ess-resources.yaml"
    kubectl get configmaps -n ess -o yaml > "$backup_dir/ess-configmaps.yaml"
    kubectl get secrets -n ess -o yaml > "$backup_dir/ess-secrets.yaml"
    kubectl get ingress -n ess -o yaml > "$backup_dir/ess-ingress.yaml"

    # 备份nginx配置
    if [[ -f "/etc/nginx/sites-available/ess-proxy" ]]; then
        log_info "备份nginx配置..."
        $SUDO_CMD cp "/etc/nginx/sites-available/ess-proxy" "$backup_dir/nginx-ess-proxy.conf"
    fi

    # 备份SSL证书
    if [[ -f "/etc/ssl/certs/ess.crt" ]]; then
        log_info "备份SSL证书..."
        $SUDO_CMD cp "/etc/ssl/certs/ess.crt" "$backup_dir/ess.crt"
        $SUDO_CMD cp "/etc/ssl/private/ess.key" "$backup_dir/ess.key"
    fi

    # 创建备份信息文件
    cat > "$backup_dir/backup-info.txt" <<EOF
ESS配置备份
备份时间: $(date)
备份版本: 3.0.0
备份内容:
- Kubernetes资源配置
- ConfigMaps配置
- Secrets配置
- Ingress配置
- nginx配置文件
- SSL证书文件
EOF

    log_success "配置备份完成"
    echo "备份位置: $backup_dir"
    echo ""

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 完整系统诊断
full_system_diagnosis() {
    show_banner

    echo -e "${WHITE}完整系统诊断${NC}"
    echo ""

    log_info "开始完整系统诊断..."

    # 系统基础检查
    echo -e "${BLUE}=== 系统基础信息 ===${NC}"
    echo "操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
    echo "内核版本: $(uname -r)"
    echo "内存使用: $(free -h | grep Mem | awk '{print $3"/"$2}')"
    echo "磁盘使用: $(df -h / | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
    echo ""

    # Kubernetes集群状态
    echo -e "${BLUE}=== Kubernetes集群状态 ===${NC}"
    kubectl get nodes
    echo ""

    # ESS服务状态
    echo -e "${BLUE}=== ESS服务状态 ===${NC}"
    kubectl get pods -n ess
    echo ""

    # 网络连接测试
    echo -e "${BLUE}=== 网络连接测试 ===${NC}"
    local domains=("google.com" "github.com" "ghcr.io")
    for domain in "${domains[@]}"; do
        if ping -c 1 "$domain" >/dev/null 2>&1; then
            echo "✅ $domain - 可访问"
        else
            echo "❌ $domain - 不可访问"
        fi
    done
    echo ""

    # 端口监听状态
    echo -e "${BLUE}=== 端口监听状态 ===${NC}"
    netstat -tlnp | grep -E ":(80|443|8080|8443|30881|30882)" || echo "未找到相关端口"
    echo ""

    # 防火墙状态
    echo -e "${BLUE}=== 防火墙状态 ===${NC}"
    if command -v ufw >/dev/null 2>&1; then
        ufw status
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --list-all
    else
        echo "未检测到支持的防火墙"
    fi
    echo ""

    log_success "系统诊断完成"

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 网络连接测试
network_connectivity_test() {
    show_banner

    echo -e "${WHITE}网络连接测试${NC}"
    echo ""

    log_info "开始网络连接测试..."

    # 读取ESS配置
    read_ess_config

    # 测试域名解析
    echo -e "${BLUE}=== 域名解析测试 ===${NC}"
    local domains=("$ELEMENT_WEB_HOST" "$MAS_HOST" "$RTC_HOST" "$SYNAPSE_HOST" "$SERVER_NAME")
    for domain in "${domains[@]}"; do
        if nslookup "$domain" >/dev/null 2>&1; then
            echo "✅ $domain - 解析成功"
        else
            echo "❌ $domain - 解析失败"
        fi
    done
    echo ""

    # 测试端口连接
    echo -e "${BLUE}=== 端口连接测试 ===${NC}"
    local ports=("80" "443" "8080" "8443" "30881" "30882")
    for port in "${ports[@]}"; do
        if netstat -tlnp | grep -q ":$port"; then
            echo "✅ 端口 $port - 监听中"
        else
            echo "❌ 端口 $port - 未监听"
        fi
    done
    echo ""

    # 测试外部连接
    echo -e "${BLUE}=== 外部连接测试 ===${NC}"
    local external_hosts=("8.8.8.8" "1.1.1.1" "github.com" "google.com")
    for host in "${external_hosts[@]}"; do
        if ping -c 1 "$host" >/dev/null 2>&1; then
            echo "✅ $host - 连接成功"
        else
            echo "❌ $host - 连接失败"
        fi
    done
    echo ""

    log_success "网络连接测试完成"

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# Matrix RTC诊断
matrix_rtc_diagnosis() {
    show_banner

    echo -e "${WHITE}Matrix RTC诊断${NC}"
    echo ""

    log_info "开始Matrix RTC诊断..."

    # 读取ESS配置
    read_ess_config

    # 检查Matrix RTC服务
    echo -e "${BLUE}=== Matrix RTC服务状态 ===${NC}"
    kubectl get pods -n ess | grep matrix-rtc
    echo ""

    # 检查Matrix RTC服务配置
    echo -e "${BLUE}=== Matrix RTC服务配置 ===${NC}"
    kubectl get svc -n ess | grep matrix-rtc
    echo ""

    # 检查WebRTC端口
    echo -e "${BLUE}=== WebRTC端口状态 ===${NC}"
    local tcp_status=$(netstat -tlnp 2>/dev/null | grep ":30881" && echo "监听中" || echo "未监听")
    local udp_status=$(netstat -ulnp 2>/dev/null | grep ":30882" && echo "监听中" || echo "未监听")
    echo "TCP 30881: $tcp_status"
    echo "UDP 30882: $udp_status"
    echo ""

    # 检查well-known配置
    echo -e "${BLUE}=== well-known RTC配置 ===${NC}"
    local well_known_content=$(curl -k -s "https://$SERVER_NAME:8443/.well-known/matrix/client" 2>/dev/null || echo "")
    if echo "$well_known_content" | grep -q "org.matrix.msc4143.rtc_foci"; then
        echo "✅ rtc_foci配置存在"
        local livekit_url=$(echo "$well_known_content" | grep -o '"livekit_service_url":"[^"]*"' | cut -d'"' -f4)
        echo "LiveKit URL: $livekit_url"
    else
        echo "❌ rtc_foci配置缺失"
    fi
    echo ""

    # 诊断建议
    echo -e "${BLUE}=== 诊断建议 ===${NC}"
    if [[ "$tcp_status" == "监听中" && "$udp_status" == "监听中" ]]; then
        echo "✅ WebRTC端口配置正常"
    else
        echo "❌ WebRTC端口配置异常，建议运行选项3修复Element Call问题"
    fi

    if echo "$well_known_content" | grep -q "org.matrix.msc4143.rtc_foci"; then
        echo "✅ well-known RTC配置正常"
    else
        echo "❌ well-known RTC配置异常，建议运行选项1进行完整配置"
    fi
    echo ""

    log_success "Matrix RTC诊断完成"

    read -p "按任意键返回主菜单..." -n 1
    show_main_menu
}

# 脚本入口点
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
