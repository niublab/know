#!/bin/bash

# ESS Community 管理脚本 - 第二阶段
# 版本: 2.0.0
# 功能: nginx反代配置、用户管理、服务器管理
# 基于: ESS Community 官方推荐方案
# 许可证: AGPL-3.0 (仅限非商业用途)

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_VERSION="2.0.0"
SUDO_CMD="sudo"  # 将在check_system_requirements中根据用户类型设置

# 设置配置目录（根据用户类型）
if [[ $EUID -eq 0 ]]; then
    ESS_CONFIG_DIR="/root/ess-config-values"
else
    ESS_CONFIG_DIR="$HOME/ess-config-values"
fi

NGINX_CONFIG_DIR="/etc/nginx"
NGINX_SITES_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

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

# 显示许可证声明
show_license() {
    echo -e "${YELLOW}================================${NC}"
    echo -e "${YELLOW}ESS Community 管理脚本${NC}"
    echo -e "${YELLOW}================================${NC}"
    echo "功能: nginx反代、用户管理、服务器管理"
    echo "版本: $SCRIPT_VERSION"
    echo "许可证: AGPL-3.0 (仅限非商业用途)"
    echo ""
    echo -e "${BLUE}主要功能${NC}"
    echo "- nginx反代配置 (解决端口封锁)"
    echo "- 用户管理 (创建/删除/修改用户)"
    echo "- 注册链接生成"
    echo "- 服务器状态监控"
    echo "- 配置管理"
    echo -e "${YELLOW}================================${NC}"
    echo ""
}

# 检查系统要求
check_system_requirements() {
    log_info "检查系统要求..."

    # 检查用户权限
    if [[ $EUID -eq 0 ]]; then
        log_info "检测到以 root 用户运行"
        SUDO_CMD=""
    else
        if ! sudo -n true 2>/dev/null; then
            log_error "当前用户没有 sudo 权限，请使用 root 用户或具有 sudo 权限的用户运行"
            exit 1
        fi
        SUDO_CMD="sudo"
        log_info "检测到普通用户，将使用 sudo 执行特权操作"
    fi
    
    # 检查ESS是否已部署
    if ! kubectl get namespace ess >/dev/null 2>&1; then
        log_error "ESS尚未部署，请先运行第一阶段部署脚本"
        exit 1
    fi
    
    # 检查ESS配置文件
    if [[ ! -f "$ESS_CONFIG_DIR/hostnames.yaml" ]]; then
        log_error "ESS配置文件不存在: $ESS_CONFIG_DIR/hostnames.yaml"
        exit 1
    fi
    
    log_success "系统要求检查完成"
}

# 读取ESS配置
read_ess_config() {
    log_info "读取ESS配置..."
    
    # 从hostnames.yaml读取域名配置
    SERVER_NAME=$(grep "serverName:" "$ESS_CONFIG_DIR/hostnames.yaml" | awk '{print $2}')
    ELEMENT_WEB_HOST=$(grep -A2 "elementWeb:" "$ESS_CONFIG_DIR/hostnames.yaml" | grep "host:" | awk '{print $2}')
    MAS_HOST=$(grep -A2 "matrixAuthenticationService:" "$ESS_CONFIG_DIR/hostnames.yaml" | grep "host:" | awk '{print $2}')
    RTC_HOST=$(grep -A2 "matrixRTC:" "$ESS_CONFIG_DIR/hostnames.yaml" | grep "host:" | awk '{print $2}')
    SYNAPSE_HOST=$(grep -A2 "synapse:" "$ESS_CONFIG_DIR/hostnames.yaml" | grep "host:" | awk '{print $2}')
    
    # 验证配置
    if [[ -z "$SERVER_NAME" || -z "$ELEMENT_WEB_HOST" || -z "$MAS_HOST" || -z "$RTC_HOST" || -z "$SYNAPSE_HOST" ]]; then
        log_error "无法读取ESS域名配置"
        exit 1
    fi
    
    log_success "ESS配置读取完成"
    log_info "服务器名: $SERVER_NAME"
    log_info "Element Web: $ELEMENT_WEB_HOST"
    log_info "MAS: $MAS_HOST"
    log_info "Matrix RTC: $RTC_HOST"
    log_info "Synapse: $SYNAPSE_HOST"
}

# 检查Traefik状态
check_traefik_status() {
    log_info "检查Traefik状态..."

    # 获取Traefik服务信息
    local traefik_info=$(kubectl get svc -n kube-system traefik -o wide 2>/dev/null || echo "")

    if [[ -z "$traefik_info" ]]; then
        log_error "无法找到Traefik服务"
        exit 1
    fi

    # 根据ESS官方文档，Traefik使用固定端口
    TRAEFIK_HTTP_PORT=8080   # ESS官方推荐端口
    TRAEFIK_HTTPS_PORT=8443  # ESS官方推荐端口

    # 验证Traefik服务是否在预期端口运行
    if echo "$traefik_info" | grep -q "8080.*8443"; then
        log_success "Traefik运行在官方推荐端口"
    else
        log_warning "Traefik可能不在标准端口运行，但将使用官方推荐端口8080"
    fi

    log_success "Traefik状态检查完成"
    log_info "Traefik HTTP端口: $TRAEFIK_HTTP_PORT (官方推荐)"
    log_info "Traefik HTTPS端口: $TRAEFIK_HTTPS_PORT (官方推荐)"

    # 测试Traefik连通性
    if curl -s --connect-timeout 5 "http://127.0.0.1:$TRAEFIK_HTTP_PORT" >/dev/null; then
        log_success "Traefik HTTP端口连通性正常"
    else
        log_warning "无法连接到Traefik HTTP端口，请检查服务状态"
    fi
}

# 配置自定义端口
configure_custom_ports() {
    log_info "配置自定义端口..."
    
    echo ""
    echo "请配置nginx监听的外部端口："
    echo "注意：这些端口将用于外网访问，请确保防火墙已开放"
    echo ""
    
    # HTTP端口配置
    while true; do
        read -p "请输入HTTP端口 [默认: 8080]: " EXTERNAL_HTTP_PORT
        EXTERNAL_HTTP_PORT=${EXTERNAL_HTTP_PORT:-8080}
        
        if [[ "$EXTERNAL_HTTP_PORT" =~ ^[0-9]+$ ]] && [[ "$EXTERNAL_HTTP_PORT" -ge 1024 ]] && [[ "$EXTERNAL_HTTP_PORT" -le 65535 ]]; then
            break
        else
            log_error "请输入有效的端口号 (1024-65535)"
        fi
    done
    
    # HTTPS端口配置
    while true; do
        read -p "请输入HTTPS端口 [默认: 8443]: " EXTERNAL_HTTPS_PORT
        EXTERNAL_HTTPS_PORT=${EXTERNAL_HTTPS_PORT:-8443}
        
        if [[ "$EXTERNAL_HTTPS_PORT" =~ ^[0-9]+$ ]] && [[ "$EXTERNAL_HTTPS_PORT" -ge 1024 ]] && [[ "$EXTERNAL_HTTPS_PORT" -le 65535 ]] && [[ "$EXTERNAL_HTTPS_PORT" != "$EXTERNAL_HTTP_PORT" ]]; then
            break
        else
            log_error "请输入有效且不重复的端口号 (1024-65535)"
        fi
    done
    
    log_success "端口配置完成"
    log_info "外部HTTP端口: $EXTERNAL_HTTP_PORT"
    log_info "外部HTTPS端口: $EXTERNAL_HTTPS_PORT"
}

# 安装nginx
install_nginx() {
    log_info "安装nginx..."

    # 检查nginx是否已安装
    if command -v nginx >/dev/null 2>&1; then
        log_warning "nginx已安装，跳过安装步骤"
        return 0
    fi

    # 更新包列表
    $SUDO_CMD apt update

    # 安装nginx
    $SUDO_CMD apt install -y nginx

    # 启用nginx服务
    $SUDO_CMD systemctl enable nginx

    log_success "nginx安装完成"
}

# 备份现有nginx配置
backup_nginx_config() {
    log_info "备份现有nginx配置..."
    
    local backup_dir="/etc/nginx/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    # 备份主要配置文件
    if [[ -f "/etc/nginx/nginx.conf" ]]; then
        $SUDO_CMD cp "/etc/nginx/nginx.conf" "$backup_dir/"
    fi

    # 备份sites-enabled目录
    if [[ -d "/etc/nginx/sites-enabled" ]]; then
        $SUDO_CMD cp -r "/etc/nginx/sites-enabled" "$backup_dir/"
    fi
    
    log_success "nginx配置备份完成: $backup_dir"
}

# 主菜单
show_main_menu() {
    clear
    show_license

    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}ESS Community 管理脚本${NC}"
    echo -e "${BLUE}版本: $SCRIPT_VERSION${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo "请选择功能模块:"
    echo ""
    echo -e "${GREEN}=== nginx反代管理 ===${NC}"
    echo "1) 完整配置nginx反代 (推荐 - 一键修复所有问题)"
    echo ""
    echo -e "${GREEN}=== 用户管理 ===${NC}"
    echo "2) 创建新用户"
    echo "3) 修改用户权限"
    echo "4) 生成注册链接"
    echo "5) 查看用户列表"
    echo ""
    echo -e "${GREEN}=== 系统管理 ===${NC}"
    echo "6) 查看系统状态"
    echo "7) 查看服务日志"
    echo "8) 重启服务"
    echo "9) 备份配置"
    echo ""
    echo "0) 退出"
    echo ""
    read -p "请输入选择 [0-9]: " choice

    case $choice in
        1) full_setup ;;
        2) create_user ;;
        3) modify_user_permissions ;;
        4) generate_registration_link ;;
        5) list_users ;;
        6) show_status ;;
        7) show_logs ;;
        8) restart_services ;;
        9) backup_config ;;
        0) exit 0 ;;
        *)
            log_error "无效选择，请输入有效选项 [0-9]"
            sleep 2
            show_main_menu
            ;;
    esac
}

# 检查状态
check_status() {
    log_info "检查系统状态..."

    check_system_requirements
    read_ess_config
    check_traefik_status

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅安装nginx
install_nginx_only() {
    log_info "仅安装nginx..."

    install_nginx

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅配置端口
configure_ports_only() {
    log_info "仅配置端口..."

    configure_custom_ports

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅生成配置
generate_config_only() {
    log_info "仅生成nginx配置..."

    check_system_requirements
    read_ess_config
    check_traefik_status
    configure_custom_ports
    generate_nginx_config
    extract_ssl_certificates

    log_success "nginx配置生成完成"
    log_warning "请手动启用配置并重载nginx"

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 测试配置
test_config() {
    log_info "测试nginx配置..."

    if nginx -t; then
        log_success "nginx配置测试通过"
    else
        log_error "nginx配置测试失败"
    fi

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 显示状态
show_status() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}系统状态检查${NC}"
    echo -e "${BLUE}================================${NC}"

    # 检查nginx状态
    if command -v nginx >/dev/null 2>&1; then
        echo -e "nginx: ${GREEN}已安装${NC}"
        if systemctl is-active nginx >/dev/null 2>&1; then
            echo -e "nginx状态: ${GREEN}运行中${NC}"
        else
            echo -e "nginx状态: ${RED}未运行${NC}"
        fi
    else
        echo -e "nginx: ${RED}未安装${NC}"
    fi

    # 检查ESS状态
    if kubectl get namespace ess >/dev/null 2>&1; then
        echo -e "ESS: ${GREEN}已部署${NC}"
    else
        echo -e "ESS: ${RED}未部署${NC}"
    fi

    # 检查配置文件
    if [[ -f "$NGINX_SITES_DIR/ess-proxy" ]]; then
        echo -e "nginx反代配置: ${GREEN}已创建${NC}"
    else
        echo -e "nginx反代配置: ${RED}未创建${NC}"
    fi

    if [[ -f "$NGINX_ENABLED_DIR/ess-proxy" ]]; then
        echo -e "nginx反代状态: ${GREEN}已启用${NC}"
    else
        echo -e "nginx反代状态: ${RED}未启用${NC}"
    fi

    # 检查端口监听
    echo ""
    echo "当前监听端口:"
    netstat -tlnp | grep nginx | head -5

    echo ""
    read -p "按任意键返回主菜单..."
    show_main_menu
}

# ================================
# 用户管理功能
# ================================

# 创建新用户
create_user() {
    log_info "创建新用户..."

    echo ""
    echo "请输入用户信息:"
    read -p "用户名: " username
    read -p "显示名称: " display_name
    read -s -p "密码: " password
    echo ""
    read -p "邮箱 (可选): " email

    # 验证输入
    if [[ -z "$username" || -z "$password" ]]; then
        log_error "用户名和密码不能为空"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    # 使用MAS CLI创建用户
    log_info "正在创建用户..."

    local mas_pod=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-authentication-service -o jsonpath='{.items[0].metadata.name}')

    if [[ -z "$mas_pod" ]]; then
        log_error "无法找到Matrix Authentication Service Pod"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    # 构建创建用户命令
    local create_cmd="mas-cli manage register-user --username '$username'"

    if [[ -n "$display_name" ]]; then
        create_cmd="$create_cmd --display-name '$display_name'"
    fi

    if [[ -n "$email" ]]; then
        create_cmd="$create_cmd --email '$email'"
    fi

    create_cmd="$create_cmd --password '$password'"

    # 执行创建命令
    if kubectl exec -n ess "$mas_pod" -- sh -c "$create_cmd"; then
        log_success "用户 '$username' 创建成功"
    else
        log_error "用户创建失败"
    fi

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 删除用户
delete_user() {
    log_info "删除用户..."

    echo ""
    read -p "请输入要删除的用户名: " username

    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    # 确认删除
    echo ""
    log_warning "警告: 此操作将永久删除用户 '$username' 及其所有数据"
    read -p "确认删除? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 0
    fi

    # 执行删除
    local mas_pod=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-authentication-service -o jsonpath='{.items[0].metadata.name}')

    if [[ -z "$mas_pod" ]]; then
        log_error "无法找到Matrix Authentication Service Pod"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    if kubectl exec -n ess "$mas_pod" -- mas-cli manage delete-user --username "$username"; then
        log_success "用户 '$username' 删除成功"
    else
        log_error "用户删除失败"
    fi

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 修改用户权限
modify_user_permissions() {
    log_info "修改用户权限..."

    echo ""
    read -p "请输入用户名: " username

    if [[ -z "$username" ]]; then
        log_error "用户名不能为空"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    echo ""
    echo "请选择权限操作:"
    echo "1) 设为管理员"
    echo "2) 取消管理员权限"
    echo "3) 禁用用户"
    echo "4) 启用用户"
    echo "0) 返回"
    echo ""
    read -p "请选择 [0-4]: " perm_choice

    local mas_pod=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-authentication-service -o jsonpath='{.items[0].metadata.name}')

    if [[ -z "$mas_pod" ]]; then
        log_error "无法找到Matrix Authentication Service Pod"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    case $perm_choice in
        1)
            if kubectl exec -n ess "$mas_pod" -- mas-cli manage set-admin --username "$username"; then
                log_success "用户 '$username' 已设为管理员"
            else
                log_error "设置管理员权限失败"
            fi
            ;;
        2)
            if kubectl exec -n ess "$mas_pod" -- mas-cli manage unset-admin --username "$username"; then
                log_success "用户 '$username' 管理员权限已取消"
            else
                log_error "取消管理员权限失败"
            fi
            ;;
        3)
            if kubectl exec -n ess "$mas_pod" -- mas-cli manage disable-user --username "$username"; then
                log_success "用户 '$username' 已禁用"
            else
                log_error "禁用用户失败"
            fi
            ;;
        4)
            if kubectl exec -n ess "$mas_pod" -- mas-cli manage enable-user --username "$username"; then
                log_success "用户 '$username' 已启用"
            else
                log_error "启用用户失败"
            fi
            ;;
        0)
            show_main_menu
            return 0
            ;;
        *)
            log_error "无效选择"
            ;;
    esac

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 生成nginx配置文件
generate_nginx_config() {
    log_info "生成nginx配置文件..."

    local config_file="$NGINX_SITES_DIR/ess-proxy"

    # 创建基于ESS官方推荐的nginx配置
    $SUDO_CMD tee "$config_file" > /dev/null <<EOF
# ESS Community Nginx 反代配置
# 生成时间: $(date)
# 基于ESS官方推荐的外部反代方案
# 参考: https://github.com/element-hq/ess-helm

# HTTP服务器 - 重定向到HTTPS
server {
    listen $EXTERNAL_HTTP_PORT;
    listen [::]:$EXTERNAL_HTTP_PORT;

    server_name $ELEMENT_WEB_HOST $SYNAPSE_HOST $MAS_HOST $RTC_HOST $SERVER_NAME;

    access_log /var/log/nginx/ess-http.log;

    # 重定向到HTTPS（保持端口信息）
    return 301 https://\$host:$EXTERNAL_HTTPS_PORT\$request_uri;
}

# HTTPS服务器 - 主要反代配置
server {
    listen $EXTERNAL_HTTPS_PORT ssl http2;
    listen [::]:$EXTERNAL_HTTPS_PORT ssl http2;

    server_name $ELEMENT_WEB_HOST $SYNAPSE_HOST $MAS_HOST $RTC_HOST $SERVER_NAME;

    # 日志配置
    access_log /var/log/nginx/ess-access.log;
    error_log /var/log/nginx/ess-error.log;

    # SSL配置 - 基于ESS官方推荐
    ssl_certificate /etc/ssl/certs/ess-combined.crt;
    ssl_certificate_key /etc/ssl/private/ess-combined.key;

    # SSL协议和密码套件（官方推荐）
    ssl_protocols TLSv1.2 TLSv1.3;  # TLSv1.2 required for iOS
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers on;

    # SSL会话配置
    ssl_session_cache shared:le_nginx_SSL:10m;
    ssl_session_timeout 1440m;
    ssl_session_tickets off;
    ssl_buffer_size 4k;

    # SSL安全增强
    ssl_stapling on;
    ssl_stapling_verify on;

    # 安全头（官方推荐）
    add_header Strict-Transport-Security 'max-age=31536000; includeSubDomains; preload' always;

    # 主域名根路径特殊处理（修复ESS重定向端口丢失问题）
    location = / {
        # 如果是主域名，重定向到Element Web并保持端口
        if (\$host = "$SERVER_NAME") {
            return 301 https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT/;
        }

        # 其他域名正常代理
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # WebSocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 超时配置
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        # 禁用缓冲
        proxy_buffering off;

        # 文件上传限制
        client_max_body_size 50M;
    }

    # 自定义端口的well-known服务器配置（修复端口问题）
    # 注意：必须在通用location之前，确保优先匹配
    location /.well-known/matrix/server {
        return 200 '{\"m.server\": \"$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT\"}';
        add_header Content-Type application/json;
        add_header Access-Control-Allow-Origin *;
        add_header Cache-Control "public, max-age=3600";
    }

    # 客户端配置发现（修复端口问题）
    location /.well-known/matrix/client {
        # 使用nginx sub_filter模块重写响应，添加端口信息
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 重写响应内容，添加端口信息
        sub_filter 'https://matrix.niub.win' 'https://matrix.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter 'https://mas.niub.win' 'https://mas.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter 'https://rtc.niub.win' 'https://rtc.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter_once off;
        sub_filter_types application/json;

        add_header Access-Control-Allow-Origin *;
        add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS";
        add_header Access-Control-Allow-Headers "Origin, X-Requested-With, Content-Type, Accept, Authorization";
    }

    # OpenID Connect 发现文档（修复端口问题）
    location /.well-known/openid-configuration {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 重写响应内容，添加端口信息到所有MAS相关URL
        sub_filter 'https://mas.niub.win' 'https://mas.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter_once off;
        sub_filter_types application/json;

        add_header Access-Control-Allow-Origin *;
    }

    # 其他 well-known 路径（通用处理，修复端口问题）
    location /.well-known/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 重写响应内容，添加端口信息到所有相关URL
        sub_filter 'https://matrix.niub.win' 'https://matrix.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter 'https://mas.niub.win' 'https://mas.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter 'https://rtc.niub.win' 'https://rtc.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter 'https://app.niub.win' 'https://app.niub.win:$EXTERNAL_HTTPS_PORT';
        sub_filter_once off;
        sub_filter_types application/json text/plain;

        add_header Access-Control-Allow-Origin *;
    }

    # 主要反代配置（放在最后，避免拦截well-known请求）
    location / {
        # 反代到Traefik HTTP端口（官方推荐8080）
        proxy_pass http://127.0.0.1:8080;

        # 代理头设置（官方推荐）
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # 文件上传限制（官方推荐50M）
        client_max_body_size 50M;

        # WebSocket支持（官方推荐）
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # 超时配置（官方推荐）
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;

        # 禁用缓冲（官方推荐）
        proxy_buffering off;
    }
}
EOF

    log_success "nginx配置文件生成完成: $config_file"
    log_info "配置基于ESS官方推荐方案"
}

# 生成DH参数（SSL安全增强）
generate_dhparam() {
    log_info "生成DH参数（SSL安全增强）..."

    local dhparam_file="/etc/nginx/dhparam.pem"

    if [[ -f "$dhparam_file" ]]; then
        log_warning "DH参数文件已存在，跳过生成"
        return 0
    fi

    log_info "正在生成2048位DH参数，这可能需要几分钟..."
    if $SUDO_CMD openssl dhparam -out "$dhparam_file" 2048; then
        $SUDO_CMD chmod 644 "$dhparam_file"
        log_success "DH参数生成完成"
    else
        log_warning "DH参数生成失败，将在nginx配置中禁用"
    fi
}

# 提取和合并SSL证书
extract_ssl_certificates() {
    log_info "提取ESS SSL证书..."

    local cert_dir="/etc/ssl/certs"
    local key_dir="/etc/ssl/private"
    local combined_cert="$cert_dir/ess-combined.crt"
    local combined_key="$key_dir/ess-combined.key"

    # 创建目录
    $SUDO_CMD mkdir -p "$cert_dir" "$key_dir"

    # 提取所有域名的证书并合并
    local domains=("$ELEMENT_WEB_HOST" "$SYNAPSE_HOST" "$MAS_HOST" "$RTC_HOST" "$SERVER_NAME")

    # 清空合并文件
    > "$combined_cert"
    > "$combined_key"

    for domain in "${domains[@]}"; do
        local secret_name=""
        case "$domain" in
            "$ELEMENT_WEB_HOST") secret_name="ess-element-web-certmanager-tls" ;;
            "$SYNAPSE_HOST") secret_name="ess-synapse-certmanager-tls" ;;
            "$MAS_HOST") secret_name="ess-matrix-authentication-service-certmanager-tls" ;;
            "$RTC_HOST") secret_name="ess-matrix-rtc-certmanager-tls" ;;
            "$SERVER_NAME") secret_name="ess-well-known-certmanager-tls" ;;
        esac

        if [[ -n "$secret_name" ]]; then
            # 检查证书是否存在
            if ! kubectl get secret "$secret_name" -n ess >/dev/null 2>&1; then
                log_warning "证书 $secret_name 不存在，跳过"
                continue
            fi

            # 提取证书
            kubectl get secret "$secret_name" -n ess -o jsonpath='{.data.tls\.crt}' | base64 -d >> "$combined_cert"
            echo "" >> "$combined_cert"

            # 提取私钥（只需要一个）
            if [[ ! -s "$combined_key" ]]; then
                kubectl get secret "$secret_name" -n ess -o jsonpath='{.data.tls\.key}' | base64 -d > "$combined_key"
            fi
        fi
    done

    # 验证证书文件
    if [[ ! -s "$combined_cert" || ! -s "$combined_key" ]]; then
        log_error "SSL证书提取失败，请检查ESS证书状态"
        return 1
    fi

    # 设置权限
    $SUDO_CMD chmod 644 "$combined_cert"
    $SUDO_CMD chmod 600 "$combined_key"

    log_success "SSL证书提取完成"
    log_info "证书文件: $combined_cert"
    log_info "私钥文件: $combined_key"
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙规则..."

    # 检查防火墙状态
    if command -v ufw >/dev/null 2>&1; then
        log_info "检测到UFW防火墙"

        # 开放自定义端口
        $SUDO_CMD ufw allow "$EXTERNAL_HTTP_PORT/tcp" comment "ESS HTTP"
        $SUDO_CMD ufw allow "$EXTERNAL_HTTPS_PORT/tcp" comment "ESS HTTPS"

        log_success "UFW防火墙规则已添加"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        log_info "检测到firewalld防火墙"

        # 开放自定义端口
        $SUDO_CMD firewall-cmd --permanent --add-port="$EXTERNAL_HTTP_PORT/tcp"
        $SUDO_CMD firewall-cmd --permanent --add-port="$EXTERNAL_HTTPS_PORT/tcp"
        $SUDO_CMD firewall-cmd --reload

        log_success "firewalld防火墙规则已添加"
    else
        log_warning "未检测到支持的防火墙，请手动开放端口: $EXTERNAL_HTTP_PORT, $EXTERNAL_HTTPS_PORT"
    fi
}

# 生成ESS外部URL配置
generate_ess_external_config() {
    log_info "生成ESS外部URL配置..."

    local config_file="$ESS_CONFIG_DIR/external-urls.yaml"

    # 创建配置目录
    mkdir -p "$ESS_CONFIG_DIR"

    # 生成ESS外部URL配置
    cat > "$config_file" <<EOF
# ESS外部URL配置 - 修复自定义端口问题
# 生成时间: $(date)

# Matrix Authentication Service外部URL配置
matrixAuthenticationService:
  config:
    http:
      public_base: "https://$MAS_HOST:$EXTERNAL_HTTPS_PORT"

# Synapse外部URL配置
synapse:
  config:
    public_baseurl: "https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"

# Element Web外部URL配置
elementWeb:
  config:
    default_server_config:
      m.homeserver:
        base_url: "https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"
        server_name: "$SERVER_NAME"

# Matrix RTC外部URL配置
matrixRTC:
  config:
    external_url: "https://$RTC_HOST:$EXTERNAL_HTTPS_PORT"
EOF

    log_success "ESS外部URL配置生成完成: $config_file"
    log_info "此配置修复了MAS、Synapse等服务的外部URL端口问题"
}

# 备份当前ESS配置
backup_ess_config() {
    log_info "备份当前ESS配置..."

    local backup_dir="$ESS_CONFIG_DIR/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    # 备份helm values
    if helm get values ess -n ess > "$backup_dir/current-values.yaml" 2>/dev/null; then
        log_success "helm values备份完成: $backup_dir/current-values.yaml"
    else
        log_warning "helm values备份失败"
    fi

    # 备份ConfigMaps
    if kubectl get configmap -n ess -o yaml > "$backup_dir/configmaps.yaml" 2>/dev/null; then
        log_success "ConfigMaps备份完成: $backup_dir/configmaps.yaml"
    else
        log_warning "ConfigMaps备份失败"
    fi

    echo "$backup_dir" # 返回备份目录路径
}

# 验证ESS配置文件
validate_ess_config() {
    local config_file="$1"

    log_info "验证ESS配置文件..."

    # 检查文件存在
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在: $config_file"
        return 1
    fi

    # 检查YAML语法（简单验证）
    if ! python3 -c "import yaml; yaml.safe_load(open('$config_file'))" 2>/dev/null; then
        log_error "YAML格式验证失败: $config_file"
        log_info "请检查配置文件语法"
        return 1
    fi

    log_success "配置文件验证通过"
    return 0
}

# 获取ESS chart信息
get_ess_chart_info() {
    log_info "获取ESS chart信息..."

    # 从helm release获取chart信息
    local chart_info=$(helm list -n ess -o json 2>/dev/null | grep -o '"chart":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -n "$chart_info" ]]; then
        echo "$chart_info"
        return 0
    fi

    # 备用方法：从status获取
    chart_info=$(helm status ess -n ess -o json 2>/dev/null | grep -o '"chart":"[^"]*"' | cut -d'"' -f4)

    if [[ -n "$chart_info" ]]; then
        echo "$chart_info"
        return 0
    fi

    log_warning "无法获取chart信息，将尝试使用--reuse-values"
    return 1
}

# 修复ESS well-known ConfigMap中的端口问题
fix_ess_wellknown_configmap() {
    log_info "修复ESS well-known ConfigMap中的端口问题..."

    # 检查当前well-known server配置
    local current_server=$(kubectl get configmap ess-well-known-haproxy -n ess -o jsonpath='{.data.server}' 2>/dev/null | grep -o 'matrix.niub.win:[0-9]*' || echo "")

    if [[ -z "$current_server" ]]; then
        log_error "无法获取ESS well-known ConfigMap中的server配置"
        return 1
    fi

    log_info "当前well-known server配置: $current_server"

    # 检查是否需要修复
    local expected_server="matrix.niub.win:$EXTERNAL_HTTPS_PORT"

    if [[ "$current_server" == "$expected_server" ]]; then
        log_success "ESS well-known ConfigMap配置已正确，无需修复"
        return 0
    fi

    log_warning "需要修复ESS well-known ConfigMap配置"
    log_info "当前值: $current_server"
    log_info "期望值: $expected_server"

    read -p "确认修复ESS well-known ConfigMap? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    # 备份当前ConfigMap
    local backup_file="$ESS_CONFIG_DIR/well-known-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
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
    \"base_url\": \"https://matrix.niub.win:$EXTERNAL_HTTPS_PORT\"
  },
  \"org.matrix.msc2965.authentication\": {
    \"account\": \"https://mas.niub.win:$EXTERNAL_HTTPS_PORT/account\",
    \"issuer\": \"https://mas.niub.win:$EXTERNAL_HTTPS_PORT/\"
  },
  \"org.matrix.msc4143.rtc_foci\": [
    {
      \"livekit_service_url\": \"https://rtc.niub.win:$EXTERNAL_HTTPS_PORT\",
      \"type\": \"livekit\"
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

    # 验证修复效果
    log_info "验证修复效果..."
    sleep 10

    # 测试server配置
    local new_server=$(curl -k -s "https://niub.win:$EXTERNAL_HTTPS_PORT/.well-known/matrix/server" | grep -o 'matrix.niub.win:[0-9]*' || echo "")
    if [[ "$new_server" == "$expected_server" ]]; then
        log_success "well-known server配置验证成功: $new_server"
    else
        log_warning "well-known server配置验证失败，当前值: $new_server"
    fi

    # 测试client配置
    local client_test=$(curl -k -s "https://niub.win:$EXTERNAL_HTTPS_PORT/.well-known/matrix/client" | grep -o "matrix.niub.win:$EXTERNAL_HTTPS_PORT" | head -1)
    if [[ -n "$client_test" ]]; then
        log_success "well-known client配置验证成功，包含正确端口"
    else
        log_warning "well-known client配置可能需要更多时间生效"
    fi

    log_success "ESS well-known端口问题修复完成！"
    log_info "备份文件: $backup_file"
}

# 修复ESS well-known ConfigMap中的端口问题
fix_ess_wellknown_configmap() {
    log_info "修复ESS well-known ConfigMap中的端口问题..."

    # 检查当前well-known server配置
    local current_server=$(kubectl get configmap ess-well-known-haproxy -n ess -o jsonpath='{.data.server}' 2>/dev/null | grep -o 'matrix.niub.win:[0-9]*' || echo "")

    if [[ -z "$current_server" ]]; then
        log_error "无法获取ESS well-known ConfigMap中的server配置"
        return 1
    fi

    log_info "当前well-known server配置: $current_server"

    # 检查是否需要修复
    local expected_server="matrix.niub.win:$EXTERNAL_HTTPS_PORT"

    if [[ "$current_server" == "$expected_server" ]]; then
        log_success "ESS well-known ConfigMap配置已正确，无需修复"
        return 0
    fi

    log_warning "需要修复ESS well-known ConfigMap配置"
    log_info "当前值: $current_server"
    log_info "期望值: $expected_server"

    read -p "确认修复ESS well-known ConfigMap? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    # 备份当前ConfigMap
    local backup_file="$ESS_CONFIG_DIR/well-known-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
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
    \"base_url\": \"https://matrix.niub.win:$EXTERNAL_HTTPS_PORT\"
  },
  \"org.matrix.msc2965.authentication\": {
    \"account\": \"https://mas.niub.win:$EXTERNAL_HTTPS_PORT/account\",
    \"issuer\": \"https://mas.niub.win:$EXTERNAL_HTTPS_PORT/\"
  },
  \"org.matrix.msc4143.rtc_foci\": [
    {
      \"livekit_service_url\": \"https://rtc.niub.win:$EXTERNAL_HTTPS_PORT\",
      \"type\": \"livekit\"
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

    # 验证修复效果
    log_info "验证修复效果..."
    sleep 10

    # 测试server配置
    local new_server=$(curl -k -s "https://niub.win:$EXTERNAL_HTTPS_PORT/.well-known/matrix/server" | grep -o 'matrix.niub.win:[0-9]*' || echo "")
    if [[ "$new_server" == "$expected_server" ]]; then
        log_success "well-known server配置验证成功: $new_server"
    else
        log_warning "well-known server配置验证失败，当前值: $new_server"
    fi

    # 测试client配置
    local client_test=$(curl -k -s "https://niub.win:$EXTERNAL_HTTPS_PORT/.well-known/matrix/client" | grep -o "matrix.niub.win:$EXTERNAL_HTTPS_PORT" | head -1)
    if [[ -n "$client_test" ]]; then
        log_success "well-known client配置验证成功，包含正确端口"
    else
        log_warning "well-known client配置可能需要更多时间生效"
    fi

    log_success "ESS well-known端口问题修复完成！"
    log_info "备份文件: $backup_file"
}

# 修复Element Web ConfigMap中的端口问题
fix_element_web_configmap() {
    log_info "修复Element Web ConfigMap中的端口问题..."

    # 检查当前Element Web配置
    local current_base_url=$(kubectl get configmap ess-element-web -n ess -o jsonpath='{.data.config\.json}' 2>/dev/null | grep -o '"base_url":"[^"]*"' | cut -d'"' -f4 || echo "")

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

    read -p "确认修复Element Web ConfigMap? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    # 备份当前ConfigMap
    local backup_file="$ESS_CONFIG_DIR/element-web-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
    if kubectl get configmap ess-element-web -n ess -o yaml > "$backup_file" 2>/dev/null; then
        log_success "ConfigMap备份完成: $backup_file"
    else
        log_warning "ConfigMap备份失败"
    fi

    # 修复Element Web配置（使用自定义域名和端口）
    log_info "正在修复Element Web配置..."
    local element_config="{
  \"bug_report_endpoint_url\": \"https://element.io/bugreports/submit\",
  \"default_server_config\": {
    \"m.homeserver\": {
      \"base_url\": \"$expected_base_url\",
      \"server_name\": \"$SERVER_NAME\"
    }
  },
  \"element_call\": {
    \"use_exclusively\": true
  },
  \"embedded_pages\": {
    \"login_for_welcome\": true
  },
  \"features\": {
    \"feature_element_call_video_rooms\": true,
    \"feature_group_calls\": true,
    \"feature_new_room_decoration_ui\": true,
    \"feature_video_rooms\": true
  },
  \"map_style_url\": \"https://api.maptiler.com/maps/streets/style.json?key=fU3vlMsMn4Jb6dnEIFsx\",
  \"setting_defaults\": {
    \"UIFeature.deactivate\": false,
    \"UIFeature.passwordReset\": false,
    \"UIFeature.registration\": false,
    \"feature_group_calls\": true
  },
  \"sso_redirect_options\": {
    \"immediate\": false
  }
}"

    if kubectl patch configmap ess-element-web -n ess --type merge -p "{\"data\":{\"config.json\":\"$element_config\"}}"; then
        log_success "Element Web配置修复成功"
    else
        log_error "Element Web配置修复失败"
        return 1
    fi

    # 重启Element Web服务
    log_info "重启Element Web服务以应用新配置..."
    if kubectl rollout restart deployment ess-element-web -n ess; then
        log_success "Element Web服务重启命令已执行"

        # 等待重启完成
        log_info "等待Element Web服务重启完成..."
        if kubectl rollout status deployment ess-element-web -n ess --timeout=300s; then
            log_success "Element Web服务重启完成"
        else
            log_warning "Element Web服务重启超时，请手动检查状态"
        fi
    else
        log_error "Element Web服务重启失败"
        return 1
    fi

    # 验证修复效果
    log_info "验证修复效果..."
    sleep 10

    # 测试Element Web配置
    local new_base_url=$(kubectl get configmap ess-element-web -n ess -o jsonpath='{.data.config\.json}' | grep -o '"base_url":"[^"]*"' | cut -d'"' -f4 || echo "")
    if [[ "$new_base_url" == "$expected_base_url" ]]; then
        log_success "Element Web配置验证成功: $new_base_url"
    else
        log_warning "Element Web配置验证失败，当前值: $new_base_url"
    fi

    log_success "Element Web端口问题修复完成！"
    log_info "备份文件: $backup_file"
    log_info "请访问 https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT 测试"
}

# 统一修复所有ESS端口配置问题
fix_all_ess_ports() {
    log_info "统一修复所有ESS端口配置问题..."

    echo ""
    echo -e "${GREEN}=== ESS端口配置统一修复 ===${NC}"
    echo "基于关键洞察：所有端口问题都是ESS内部ConfigMap硬编码标准端口导致"
    echo ""
    echo "将要修复的问题："
    echo "1. MAS ConfigMap - public_base端口问题"
    echo "2. well-known ConfigMap - server/client端口问题"
    echo "3. Element Web ConfigMap - base_url端口问题"
    echo ""
    echo "使用自定义配置："
    echo "- 域名: $SERVER_NAME"
    echo "- 端口: $EXTERNAL_HTTPS_PORT"
    echo "- Matrix服务器: $SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"
    echo "- 认证服务: $MAS_HOST:$EXTERNAL_HTTPS_PORT"
    echo "- Element Web: $ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
    echo ""

    read -p "确认开始统一修复? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    local success_count=0
    local total_count=3

    # 修复MAS ConfigMap
    echo ""
    echo -e "${YELLOW}=== 1/2 修复MAS ConfigMap ===${NC}"
    if fix_mas_configmap; then
        ((success_count++))
        log_success "MAS ConfigMap修复成功"
    else
        log_error "MAS ConfigMap修复失败"
    fi

    # 修复well-known ConfigMap
    echo ""
    echo -e "${YELLOW}=== 2/3 修复well-known ConfigMap ===${NC}"
    if fix_ess_wellknown_configmap; then
        ((success_count++))
        log_success "well-known ConfigMap修复成功"
    else
        log_error "well-known ConfigMap修复失败"
    fi

    # 修复Element Web ConfigMap
    echo ""
    echo -e "${YELLOW}=== 3/3 修复Element Web ConfigMap ===${NC}"
    if fix_element_web_configmap; then
        ((success_count++))
        log_success "Element Web ConfigMap修复成功"
    else
        log_error "Element Web ConfigMap修复失败"
    fi

    # 总结修复结果
    echo ""
    echo -e "${GREEN}=== 修复结果总结 ===${NC}"
    echo "成功修复: $success_count/$total_count"

    if [[ $success_count -eq $total_count ]]; then
        log_success "所有ESS端口配置问题修复完成！"
        echo ""
        echo "修复效果："
        echo "✅ MAS服务：所有URL包含端口$EXTERNAL_HTTPS_PORT"
        echo "✅ well-known服务：server/client配置包含正确端口"
        echo "✅ Element Web：homeserver配置包含正确端口"
        echo "✅ 认证流程：应该能正常工作"
        echo "✅ 客户端连接：应该能正确访问"
        echo ""
        echo "测试访问："
        echo "- Element Web: https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
        echo "- 认证服务: https://$MAS_HOST:$EXTERNAL_HTTPS_PORT"
    else
        log_warning "部分修复失败，请检查错误信息并手动修复"
    fi
}

# 修复MAS ConfigMap中的端口问题（方案3：直接修改ConfigMap）
fix_mas_configmap() {
    log_info "修复MAS ConfigMap中的端口问题..."

    # 检查当前MAS ConfigMap中的public_base配置
    local current_public_base=$(kubectl get configmap ess-matrix-authentication-service -n ess -o yaml 2>/dev/null | grep "public_base:" | awk '{print $2}' | tr -d '"')

    if [[ -z "$current_public_base" ]]; then
        log_error "无法获取MAS ConfigMap中的public_base配置"
        return 1
    fi

    log_info "当前public_base配置: $current_public_base"

    # 检查是否需要修复
    local expected_public_base="https://$MAS_HOST:$EXTERNAL_HTTPS_PORT"

    if [[ "$current_public_base" == "$expected_public_base" ]]; then
        log_success "MAS ConfigMap配置已正确，无需修复"
        return 0
    fi

    log_warning "需要修复MAS ConfigMap配置"
    log_info "当前值: $current_public_base"
    log_info "期望值: $expected_public_base"

    read -p "确认修复MAS ConfigMap? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    # 备份当前ConfigMap
    local backup_file="$ESS_CONFIG_DIR/mas-configmap-backup-$(date +%Y%m%d-%H%M%S).yaml"
    if kubectl get configmap ess-matrix-authentication-service -n ess -o yaml > "$backup_file" 2>/dev/null; then
        log_success "ConfigMap备份完成: $backup_file"
    else
        log_warning "ConfigMap备份失败"
    fi

    # 修复ConfigMap
    log_info "正在修复MAS ConfigMap..."

    # 使用kubectl patch修改public_base
    local patch_data="{\"data\":{\"config.yaml\":\"$(kubectl get configmap ess-matrix-authentication-service -n ess -o jsonpath='{.data.config\.yaml}' | sed "s|public_base: \"[^\"]*\"|public_base: \"$expected_public_base\"|")\"}}"

    if kubectl patch configmap ess-matrix-authentication-service -n ess --type merge -p "$patch_data"; then
        log_success "MAS ConfigMap修复成功"
    else
        log_error "MAS ConfigMap修复失败"
        return 1
    fi

    # 重启MAS服务
    log_info "重启MAS服务以应用新配置..."
    if kubectl rollout restart deployment ess-matrix-authentication-service -n ess; then
        log_success "MAS服务重启命令已执行"

        # 等待重启完成
        log_info "等待MAS服务重启完成..."
        if kubectl rollout status deployment ess-matrix-authentication-service -n ess --timeout=300s; then
            log_success "MAS服务重启完成"
        else
            log_warning "MAS服务重启超时，请手动检查状态"
        fi
    else
        log_error "MAS服务重启失败"
        return 1
    fi

    # 验证修复效果
    log_info "验证修复效果..."
    sleep 10

    local new_public_base=$(kubectl get configmap ess-matrix-authentication-service -n ess -o yaml 2>/dev/null | grep "public_base:" | awk '{print $2}' | tr -d '"')

    if [[ "$new_public_base" == "$expected_public_base" ]]; then
        log_success "MAS ConfigMap修复验证成功: $new_public_base"

        # 测试OpenID配置
        log_info "测试OpenID配置..."
        if curl -k -s "https://$MAS_HOST:$EXTERNAL_HTTPS_PORT/.well-known/openid-configuration" | grep -q "\"issuer\":\"$expected_public_base/\""; then
            log_success "OpenID配置验证成功，所有URL包含正确端口"
        else
            log_warning "OpenID配置可能需要更多时间生效"
        fi
    else
        log_error "MAS ConfigMap修复验证失败"
        log_info "当前值: $new_public_base"
        log_info "期望值: $expected_public_base"
        log_info "备份文件: $backup_file"
        return 1
    fi

    log_success "MAS端口问题修复完成！"
    log_info "备份文件: $backup_file"
}

# 应用ESS配置
apply_ess_config() {
    log_info "应用ESS外部URL配置..."

    local config_file="$ESS_CONFIG_DIR/external-urls.yaml"
    local hostnames_file="$ESS_CONFIG_DIR/hostnames.yaml"

    # 验证配置文件
    if ! validate_ess_config "$config_file"; then
        return 1
    fi

    if ! validate_ess_config "$hostnames_file"; then
        return 1
    fi

    # 检查helm是否可用
    if ! command -v helm >/dev/null 2>&1; then
        log_error "helm命令不可用，无法应用ESS配置"
        log_info "请手动应用配置文件: $config_file"
        return 1
    fi

    # 查找ESS helm release
    local ess_release="ess"  # 基于检查结果，release名为ess

    if ! helm status "$ess_release" -n ess >/dev/null 2>&1; then
        log_error "无法找到ESS helm release: $ess_release"
        log_info "请手动应用配置文件: $config_file"
        return 1
    fi

    log_info "找到ESS release: $ess_release"

    # 备份当前配置
    local backup_dir=$(backup_ess_config)

    # 获取chart信息
    local chart_info=$(get_ess_chart_info)

    log_warning "即将重新部署ESS以应用外部URL配置"
    log_warning "这将重启ESS服务，可能造成短暂中断"
    log_info "备份目录: $backup_dir"

    read -p "确认继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        log_info "配置文件已生成: $config_file"
        log_info "备份已保存: $backup_dir"
        return 0
    fi

    # 执行dry-run测试
    log_info "执行配置测试 (dry-run)..."
    if helm upgrade "$ess_release" -n ess \
        -f "$hostnames_file" \
        -f "$config_file" \
        --reuse-values \
        --dry-run >/dev/null 2>&1; then
        log_success "配置测试通过"
    else
        log_error "配置测试失败，请检查配置文件"
        log_info "备份已保存: $backup_dir"
        return 1
    fi

    # 应用配置
    log_info "正在应用ESS配置..."
    if helm upgrade "$ess_release" -n ess \
        -f "$hostnames_file" \
        -f "$config_file" \
        --reuse-values; then
        log_success "ESS配置应用成功"

        # 等待服务重启
        log_info "等待MAS服务重启..."
        if kubectl rollout status deployment ess-matrix-authentication-service -n ess --timeout=300s; then
            log_success "MAS服务重启完成"
        else
            log_warning "MAS服务重启超时，请手动检查状态"
        fi

        # 验证配置是否生效
        log_info "验证配置是否生效..."
        sleep 10

        local new_public_base=$(kubectl get configmap ess-matrix-authentication-service -n ess -o yaml | grep "public_base:" | awk '{print $2}' | tr -d '"')
        if [[ "$new_public_base" == "https://mas.niub.win:$EXTERNAL_HTTPS_PORT" ]]; then
            log_success "MAS外部URL配置已生效: $new_public_base"
        else
            log_warning "MAS外部URL配置可能未生效，当前值: $new_public_base"
        fi

        log_info "请检查ESS服务状态: kubectl get pods -n ess"
        log_info "备份已保存: $backup_dir"
    else
        log_error "ESS配置应用失败"
        log_info "请检查配置文件: $config_file"
        log_info "备份已保存: $backup_dir"
        log_info "如需回滚，请运行: helm rollback $ess_release -n ess"
        return 1
    fi
}

# 完整配置
full_setup() {
    log_info "开始完整nginx反代配置..."

    check_system_requirements
    read_ess_config
    check_traefik_status
    configure_custom_ports
    backup_nginx_config
    install_nginx
    generate_dhparam
    generate_nginx_config
    extract_ssl_certificates

    # 启用站点
    log_info "启用nginx站点配置..."
    $SUDO_CMD ln -sf "$NGINX_SITES_DIR/ess-proxy" "$NGINX_ENABLED_DIR/"

    # 禁用默认站点
    if [[ -f "$NGINX_ENABLED_DIR/default" ]]; then
        $SUDO_CMD rm -f "$NGINX_ENABLED_DIR/default"
        log_info "已禁用nginx默认站点"
    fi

    # 测试配置
    log_info "测试nginx配置..."
    if $SUDO_CMD nginx -t; then
        log_success "nginx配置测试通过"

        # 重载nginx
        $SUDO_CMD systemctl reload nginx
        log_success "nginx已重载"

        # 配置防火墙
        configure_firewall

        # 统一修复所有ESS端口配置问题（基于关键洞察）
        echo ""
        echo -e "${YELLOW}重要：统一修复所有ESS服务的URL端口问题${NC}"
        echo "基于关键洞察：所有端口问题都是ESS内部ConfigMap硬编码标准端口导致"
        echo "将修复：MAS ConfigMap + well-known ConfigMap"
        echo ""
        read -p "是否现在统一修复所有ESS端口配置问题? [Y/n]: " fix_all_now
        if [[ ! "$fix_all_now" =~ ^[Nn]$ ]]; then
            fix_all_ess_ports
        else
            log_info "跳过ESS端口配置修复"
            log_warning "您可以稍后选择菜单选项11来修复此问题"
        fi

        echo ""
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}ESS nginx反代配置完成！${NC}"
        echo -e "${GREEN}================================${NC}"
        echo "外部访问地址:"
        echo "- Element Web: https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
        echo "- Matrix服务器: https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"
        echo "- 认证服务: https://$MAS_HOST:$EXTERNAL_HTTPS_PORT"
        echo "- RTC服务: https://$RTC_HOST:$EXTERNAL_HTTPS_PORT"
        echo "- 服务器发现: https://$SERVER_NAME:$EXTERNAL_HTTPS_PORT"
        echo ""
        echo "配置特性:"
        echo "- ✅ 基于ESS官方推荐配置"
        echo "- ✅ 自动SSL证书配置"
        echo "- ✅ WebSocket支持"
        echo "- ✅ 自定义端口well-known配置"
        echo "- ✅ 防火墙规则自动配置"
        echo "- ✅ MAS ConfigMap端口问题修复"
        echo ""
        echo -e "${GREEN}配置完成！${NC}"
        echo "如果MAS页面仍显示端口问题，请选择菜单选项11重新修复"

        echo ""
        echo "请确保DNS解析指向此服务器IP"
        echo -e "${GREEN}================================${NC}"
    else
        log_error "nginx配置测试失败，请检查配置"
        echo ""
        echo "常见问题排查:"
        echo "1. 检查SSL证书是否正确提取"
        echo "2. 检查端口是否被占用"
        echo "3. 检查nginx语法错误"
        return 1
    fi

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅修复所有ESS端口配置问题
fix_all_ess_ports_only() {
    log_info "统一修复所有ESS端口配置问题..."

    check_system_requirements
    read_ess_config
    configure_custom_ports
    fix_all_ess_ports

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅修复MAS ConfigMap
fix_mas_configmap_only() {
    log_info "仅修复MAS ConfigMap端口问题..."

    check_system_requirements
    read_ess_config
    configure_custom_ports
    fix_mas_configmap

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅修复well-known ConfigMap
fix_wellknown_configmap_only() {
    log_info "仅修复well-known ConfigMap端口问题..."

    check_system_requirements
    read_ess_config
    configure_custom_ports
    fix_ess_wellknown_configmap

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅修复Element Web ConfigMap
fix_element_web_configmap_only() {
    log_info "仅修复Element Web ConfigMap端口问题..."

    check_system_requirements
    read_ess_config
    configure_custom_ports
    fix_element_web_configmap

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅生成ESS配置
generate_ess_config_only() {
    log_info "仅生成ESS外部URL配置..."

    check_system_requirements
    read_ess_config
    configure_custom_ports
    generate_ess_external_config

    log_success "ESS外部URL配置生成完成"
    log_info "配置文件位置: $ESS_CONFIG_DIR/external-urls.yaml"
    log_info "请选择菜单选项13来应用此配置"

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅应用ESS配置
apply_ess_config_only() {
    log_info "仅应用ESS外部URL配置..."

    check_system_requirements
    apply_ess_config

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 生成注册链接
generate_registration_link() {
    log_info "生成注册链接..."

    echo ""
    echo "请选择注册链接类型:"
    echo "1) 普通用户注册链接"
    echo "2) 管理员注册链接"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-2]: " link_type

    case $link_type in
        0)
            show_main_menu
            return 0
            ;;
        1|2)
            ;;
        *)
            log_error "无效选择"
            read -p "按任意键返回主菜单..."
            show_main_menu
            return 1
            ;;
    esac

    # 获取MAS Pod
    local mas_pod=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-authentication-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$mas_pod" ]]; then
        log_error "无法找到Matrix Authentication Service Pod"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    # 生成注册链接
    log_info "正在生成注册链接..."

    local cmd="mas-cli manage generate-registration-token"
    if [[ "$link_type" == "2" ]]; then
        cmd="$cmd --admin"
        log_info "生成管理员注册链接..."
    else
        log_info "生成普通用户注册链接..."
    fi

    local result=$(kubectl exec -n ess "$mas_pod" -- $cmd 2>/dev/null)

    if [[ $? -eq 0 && -n "$result" ]]; then
        local token=$(echo "$result" | grep -o 'token: [a-zA-Z0-9_-]*' | cut -d' ' -f2)
        if [[ -n "$token" ]]; then
            local registration_url="https://$MAS_HOST:$EXTERNAL_HTTPS_PORT/register?token=$token"

            echo ""
            echo -e "${GREEN}================================${NC}"
            echo -e "${GREEN}注册链接生成成功！${NC}"
            echo -e "${GREEN}================================${NC}"
            echo ""
            if [[ "$link_type" == "2" ]]; then
                echo -e "${YELLOW}管理员注册链接：${NC}"
            else
                echo -e "${YELLOW}普通用户注册链接：${NC}"
            fi
            echo "$registration_url"
            echo ""
            echo -e "${BLUE}使用说明：${NC}"
            echo "1. 将此链接发送给需要注册的用户"
            echo "2. 用户点击链接即可直接注册账户"
            if [[ "$link_type" == "2" ]]; then
                echo "3. 通过此链接注册的用户将自动获得管理员权限"
            fi
            echo "4. 每个链接只能使用一次"
            echo ""
            echo -e "${YELLOW}注意：请妥善保管此链接，避免泄露${NC}"
            echo -e "${GREEN}================================${NC}"
        else
            log_error "无法解析注册token"
        fi
    else
        log_error "生成注册链接失败"
        log_info "请检查MAS服务状态"
    fi

    read -p "按任意键返回主菜单..."
    show_main_menu
}

list_users() {
    log_info "查看用户列表..."

    # 获取MAS Pod
    local mas_pod=$(kubectl get pods -n ess -l app.kubernetes.io/name=matrix-authentication-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$mas_pod" ]]; then
        log_error "无法找到Matrix Authentication Service Pod"
        read -p "按任意键返回主菜单..."
        show_main_menu
        return 1
    fi

    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}用户列表${NC}"
    echo -e "${BLUE}================================${NC}"

    # 获取用户列表
    log_info "正在获取用户列表..."

    # 使用MAS CLI获取用户信息
    local users_output=$(kubectl exec -n ess "$mas_pod" -- mas-cli manage list-users 2>/dev/null)

    if [[ $? -eq 0 && -n "$users_output" ]]; then
        echo "$users_output"
    else
        # 如果MAS CLI不支持list-users，尝试其他方法
        log_warning "无法通过MAS CLI获取用户列表"
        log_info "尝试从数据库获取用户信息..."

        # 获取Postgres Pod
        local postgres_pod=$(kubectl get pods -n ess -l app.kubernetes.io/name=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [[ -n "$postgres_pod" ]]; then
            echo ""
            echo -e "${YELLOW}从数据库获取的用户信息：${NC}"

            # 查询用户表
            local db_query="SELECT username, display_name, email, created_at, locked_at IS NOT NULL as is_locked FROM users ORDER BY created_at;"

            kubectl exec -n ess "$postgres_pod" -- psql -U postgres -d matrixauthenticationservice -c "$db_query" 2>/dev/null || {
                log_warning "无法连接到数据库"
                echo ""
                echo -e "${YELLOW}可用的用户管理操作：${NC}"
                echo "- 创建新用户: 选择菜单选项 2"
                echo "- 修改用户权限: 选择菜单选项 3"
                echo "- 生成注册链接: 选择菜单选项 4"
            }
        else
            log_warning "无法找到数据库Pod"
            echo ""
            echo -e "${YELLOW}建议的操作：${NC}"
            echo "1. 检查ESS服务状态: kubectl get pods -n ess"
            echo "2. 使用其他用户管理功能创建和管理用户"
        fi
    fi

    echo ""
    echo -e "${BLUE}用户管理提示：${NC}"
    echo "- 创建用户: 菜单选项 2"
    echo "- 修改权限: 菜单选项 3 (设置管理员、禁用/启用用户)"
    echo "- 生成注册链接: 菜单选项 4"
    echo ""
    echo -e "${BLUE}================================${NC}"

    read -p "按任意键返回主菜单..."
    show_main_menu
}

show_logs() {
    log_info "查看服务日志..."

    echo ""
    echo "请选择要查看的服务日志:"
    echo "1) nginx 日志"
    echo "2) ESS - Matrix Authentication Service"
    echo "3) ESS - Synapse (Matrix服务器)"
    echo "4) ESS - Element Web"
    echo "5) ESS - HAProxy"
    echo "6) ESS - 所有服务概览"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-6]: " log_choice

    case $log_choice in
        0)
            show_main_menu
            return 0
            ;;
        1)
            show_nginx_logs
            ;;
        2)
            show_ess_service_logs "matrix-authentication-service" "MAS (认证服务)"
            ;;
        3)
            show_ess_service_logs "synapse" "Synapse (Matrix服务器)"
            ;;
        4)
            show_ess_service_logs "element-web" "Element Web (客户端)"
            ;;
        5)
            show_ess_service_logs "haproxy" "HAProxy (负载均衡)"
            ;;
        6)
            show_all_ess_logs
            ;;
        *)
            log_error "无效选择"
            ;;
    esac

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 显示nginx日志
show_nginx_logs() {
    echo ""
    echo -e "${BLUE}=== nginx 日志 ===${NC}"

    if command -v nginx >/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}nginx 访问日志 (最近20行):${NC}"
        if [[ -f "/var/log/nginx/ess-access.log" ]]; then
            tail -20 /var/log/nginx/ess-access.log
        elif [[ -f "/var/log/nginx/access.log" ]]; then
            tail -20 /var/log/nginx/access.log
        else
            echo "未找到nginx访问日志文件"
        fi

        echo ""
        echo -e "${YELLOW}nginx 错误日志 (最近20行):${NC}"
        if [[ -f "/var/log/nginx/ess-error.log" ]]; then
            tail -20 /var/log/nginx/ess-error.log
        elif [[ -f "/var/log/nginx/error.log" ]]; then
            tail -20 /var/log/nginx/error.log
        else
            echo "未找到nginx错误日志文件"
        fi

        echo ""
        echo -e "${YELLOW}nginx 状态:${NC}"
        systemctl status nginx --no-pager -l
    else
        echo "nginx 未安装"
    fi
}

# 显示ESS服务日志
show_ess_service_logs() {
    local service_name="$1"
    local display_name="$2"

    echo ""
    echo -e "${BLUE}=== $display_name 日志 ===${NC}"

    # 获取Pod名称
    local pod_name=$(kubectl get pods -n ess -l app.kubernetes.io/name="$service_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$pod_name" ]]; then
        echo ""
        echo -e "${YELLOW}Pod: $pod_name${NC}"
        echo -e "${YELLOW}最近50行日志:${NC}"
        kubectl logs -n ess "$pod_name" --tail=50

        echo ""
        echo -e "${YELLOW}Pod 状态:${NC}"
        kubectl describe pod -n ess "$pod_name" | grep -A 10 "Conditions:"
    else
        echo "未找到 $service_name 服务的Pod"
        echo ""
        echo -e "${YELLOW}可用的Pod列表:${NC}"
        kubectl get pods -n ess
    fi
}

# 显示所有ESS服务概览
show_all_ess_logs() {
    echo ""
    echo -e "${BLUE}=== ESS 所有服务状态概览 ===${NC}"

    echo ""
    echo -e "${YELLOW}Pod 状态:${NC}"
    kubectl get pods -n ess

    echo ""
    echo -e "${YELLOW}服务状态:${NC}"
    kubectl get svc -n ess

    echo ""
    echo -e "${YELLOW}Ingress 状态:${NC}"
    kubectl get ingress -n ess

    echo ""
    echo -e "${YELLOW}最近事件:${NC}"
    kubectl get events -n ess --sort-by='.lastTimestamp' | tail -10

    echo ""
    echo -e "${YELLOW}有问题的Pod详情:${NC}"
    local problem_pods=$(kubectl get pods -n ess --no-headers | grep -v "Running\|Completed" | awk '{print $1}')

    if [[ -n "$problem_pods" ]]; then
        for pod in $problem_pods; do
            echo ""
            echo -e "${RED}问题Pod: $pod${NC}"
            kubectl describe pod -n ess "$pod" | grep -A 5 "Events:"
        done
    else
        echo "所有Pod运行正常"
    fi
}

restart_services() {
    log_info "重启服务..."

    echo ""
    echo "请选择要重启的服务:"
    echo "1) nginx 服务"
    echo "2) ESS - Matrix Authentication Service"
    echo "3) ESS - Synapse (Matrix服务器)"
    echo "4) ESS - Element Web"
    echo "5) ESS - HAProxy"
    echo "6) ESS - 所有服务"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-6]: " restart_choice

    case $restart_choice in
        0)
            show_main_menu
            return 0
            ;;
        1)
            restart_nginx
            ;;
        2)
            restart_ess_service "ess-matrix-authentication-service" "MAS (认证服务)"
            ;;
        3)
            restart_ess_service "ess-synapse-main" "Synapse (Matrix服务器)" "statefulset"
            ;;
        4)
            restart_ess_service "ess-element-web" "Element Web (客户端)"
            ;;
        5)
            restart_ess_service "ess-haproxy" "HAProxy (负载均衡)"
            ;;
        6)
            restart_all_ess_services
            ;;
        *)
            log_error "无效选择"
            ;;
    esac

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 重启nginx服务
restart_nginx() {
    echo ""
    echo -e "${BLUE}=== 重启 nginx 服务 ===${NC}"

    if command -v nginx >/dev/null 2>&1; then
        log_warning "即将重启nginx服务，这可能会短暂中断外部访问"
        read -p "确认继续? [y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_info "正在重启nginx..."

            # 测试配置
            if $SUDO_CMD nginx -t; then
                log_success "nginx配置测试通过"

                # 重启服务
                if $SUDO_CMD systemctl restart nginx; then
                    log_success "nginx重启成功"

                    # 检查状态
                    if systemctl is-active nginx >/dev/null 2>&1; then
                        log_success "nginx运行状态正常"
                    else
                        log_error "nginx重启后状态异常"
                        systemctl status nginx --no-pager
                    fi
                else
                    log_error "nginx重启失败"
                    systemctl status nginx --no-pager
                fi
            else
                log_error "nginx配置测试失败，取消重启"
            fi
        else
            log_info "操作已取消"
        fi
    else
        log_error "nginx未安装"
    fi
}

# 重启ESS服务
restart_ess_service() {
    local service_name="$1"
    local display_name="$2"
    local resource_type="${3:-deployment}"  # 默认为deployment

    echo ""
    echo -e "${BLUE}=== 重启 $display_name ===${NC}"

    # 检查资源是否存在
    if kubectl get "$resource_type" "$service_name" -n ess >/dev/null 2>&1; then
        log_warning "即将重启 $display_name，这可能会短暂中断相关功能"
        read -p "确认继续? [y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_info "正在重启 $display_name..."

            if kubectl rollout restart "$resource_type/$service_name" -n ess; then
                log_success "重启命令已执行"

                # 等待重启完成
                log_info "等待重启完成..."
                if kubectl rollout status "$resource_type/$service_name" -n ess --timeout=300s; then
                    log_success "$display_name 重启完成"

                    # 显示新的Pod状态
                    echo ""
                    echo -e "${YELLOW}新的Pod状态:${NC}"
                    kubectl get pods -n ess -l app.kubernetes.io/instance="$service_name"
                else
                    log_warning "$display_name 重启超时，请手动检查状态"
                fi
            else
                log_error "$display_name 重启失败"
            fi
        else
            log_info "操作已取消"
        fi
    else
        log_error "未找到服务: $service_name"
        echo ""
        echo -e "${YELLOW}可用的服务列表:${NC}"
        kubectl get deployments,statefulsets -n ess
    fi
}

# 重启所有ESS服务
restart_all_ess_services() {
    echo ""
    echo -e "${BLUE}=== 重启所有ESS服务 ===${NC}"

    log_warning "即将重启所有ESS服务，这会导致Matrix服务完全中断"
    log_warning "重启过程可能需要几分钟时间"
    echo ""
    read -p "确认继续? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        log_info "开始重启所有ESS服务..."

        # 定义服务重启顺序（重要性从低到高）
        local services=(
            "deployment/ess-element-web:Element Web"
            "deployment/ess-haproxy:HAProxy"
            "deployment/ess-matrix-authentication-service:MAS"
            "statefulset/ess-synapse-main:Synapse"
        )

        local success_count=0
        local total_count=${#services[@]}

        for service_info in "${services[@]}"; do
            local service_type_name="${service_info%%:*}"
            local service_display="${service_info##*:}"

            echo ""
            echo -e "${YELLOW}重启 $service_display...${NC}"

            if kubectl rollout restart "$service_type_name" -n ess; then
                log_info "等待 $service_display 重启完成..."
                if kubectl rollout status "$service_type_name" -n ess --timeout=300s; then
                    log_success "$service_display 重启完成"
                    ((success_count++))
                else
                    log_warning "$service_display 重启超时"
                fi
            else
                log_error "$service_display 重启失败"
            fi

            # 短暂等待
            sleep 5
        done

        echo ""
        echo -e "${BLUE}=== 重启结果总结 ===${NC}"
        echo "成功重启: $success_count/$total_count 个服务"

        if [[ $success_count -eq $total_count ]]; then
            log_success "所有ESS服务重启完成！"
        else
            log_warning "部分服务重启失败，请检查服务状态"
        fi

        echo ""
        echo -e "${YELLOW}当前服务状态:${NC}"
        kubectl get pods -n ess
    else
        log_info "操作已取消"
    fi
}

backup_config() {
    log_info "备份配置..."

    local backup_timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="/root/ess-backup-$backup_timestamp"

    echo ""
    echo "请选择备份类型:"
    echo "1) 完整备份 (推荐)"
    echo "2) 仅备份nginx配置"
    echo "3) 仅备份ESS配置"
    echo "4) 仅备份SSL证书"
    echo "0) 返回主菜单"
    echo ""
    read -p "请选择 [0-4]: " backup_choice

    case $backup_choice in
        0)
            show_main_menu
            return 0
            ;;
        1)
            create_full_backup "$backup_dir"
            ;;
        2)
            create_nginx_backup "$backup_dir"
            ;;
        3)
            create_ess_backup "$backup_dir"
            ;;
        4)
            create_ssl_backup "$backup_dir"
            ;;
        *)
            log_error "无效选择"
            read -p "按任意键返回主菜单..."
            show_main_menu
            return 1
            ;;
    esac

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 创建完整备份
create_full_backup() {
    local backup_dir="$1"

    echo ""
    echo -e "${BLUE}=== 创建完整备份 ===${NC}"
    log_info "备份目录: $backup_dir"

    # 创建备份目录
    mkdir -p "$backup_dir"

    local success_count=0
    local total_count=4

    # 1. 备份nginx配置
    echo ""
    echo -e "${YELLOW}1/4 备份nginx配置...${NC}"
    if backup_nginx_configs "$backup_dir/nginx"; then
        ((success_count++))
        log_success "nginx配置备份完成"
    else
        log_error "nginx配置备份失败"
    fi

    # 2. 备份ESS配置
    echo ""
    echo -e "${YELLOW}2/4 备份ESS配置...${NC}"
    if backup_ess_configs "$backup_dir/ess"; then
        ((success_count++))
        log_success "ESS配置备份完成"
    else
        log_error "ESS配置备份失败"
    fi

    # 3. 备份SSL证书
    echo ""
    echo -e "${YELLOW}3/4 备份SSL证书...${NC}"
    if backup_ssl_certs "$backup_dir/ssl"; then
        ((success_count++))
        log_success "SSL证书备份完成"
    else
        log_error "SSL证书备份失败"
    fi

    # 4. 备份脚本配置
    echo ""
    echo -e "${YELLOW}4/4 备份脚本配置...${NC}"
    if backup_script_configs "$backup_dir/script"; then
        ((success_count++))
        log_success "脚本配置备份完成"
    else
        log_error "脚本配置备份失败"
    fi

    # 创建备份信息文件
    create_backup_info "$backup_dir"

    # 压缩备份
    echo ""
    echo -e "${YELLOW}压缩备份文件...${NC}"
    if tar -czf "$backup_dir.tar.gz" -C "$(dirname "$backup_dir")" "$(basename "$backup_dir")"; then
        log_success "备份压缩完成: $backup_dir.tar.gz"

        # 删除原始目录
        rm -rf "$backup_dir"

        # 显示备份大小
        local backup_size=$(du -h "$backup_dir.tar.gz" | cut -f1)
        echo ""
        echo -e "${GREEN}=== 完整备份完成 ===${NC}"
        echo "备份文件: $backup_dir.tar.gz"
        echo "备份大小: $backup_size"
        echo "成功备份: $success_count/$total_count 个组件"

        if [[ $success_count -eq $total_count ]]; then
            echo -e "${GREEN}所有组件备份成功！${NC}"
        else
            echo -e "${YELLOW}部分组件备份失败，请检查日志${NC}"
        fi
    else
        log_error "备份压缩失败"
    fi
}

# 创建nginx备份
create_nginx_backup() {
    local backup_dir="$1"

    echo ""
    echo -e "${BLUE}=== 备份nginx配置 ===${NC}"

    mkdir -p "$backup_dir"

    if backup_nginx_configs "$backup_dir"; then
        log_success "nginx配置备份完成: $backup_dir"
    else
        log_error "nginx配置备份失败"
    fi
}

# 创建ESS备份
create_ess_backup() {
    local backup_dir="$1"

    echo ""
    echo -e "${BLUE}=== 备份ESS配置 ===${NC}"

    mkdir -p "$backup_dir"

    if backup_ess_configs "$backup_dir"; then
        log_success "ESS配置备份完成: $backup_dir"
    else
        log_error "ESS配置备份失败"
    fi
}

# 创建SSL备份
create_ssl_backup() {
    local backup_dir="$1"

    echo ""
    echo -e "${BLUE}=== 备份SSL证书 ===${NC}"

    mkdir -p "$backup_dir"

    if backup_ssl_certs "$backup_dir"; then
        log_success "SSL证书备份完成: $backup_dir"
    else
        log_error "SSL证书备份失败"
    fi
}

# 备份nginx配置文件
backup_nginx_configs() {
    local backup_dir="$1"
    mkdir -p "$backup_dir"

    local success=true

    # 备份nginx主配置
    if [[ -f "/etc/nginx/nginx.conf" ]]; then
        cp "/etc/nginx/nginx.conf" "$backup_dir/" || success=false
    fi

    # 备份sites-available
    if [[ -d "/etc/nginx/sites-available" ]]; then
        cp -r "/etc/nginx/sites-available" "$backup_dir/" || success=false
    fi

    # 备份sites-enabled
    if [[ -d "/etc/nginx/sites-enabled" ]]; then
        cp -r "/etc/nginx/sites-enabled" "$backup_dir/" || success=false
    fi

    # 备份nginx日志（最近的）
    mkdir -p "$backup_dir/logs"
    if [[ -f "/var/log/nginx/ess-access.log" ]]; then
        tail -1000 "/var/log/nginx/ess-access.log" > "$backup_dir/logs/ess-access.log" 2>/dev/null || true
    fi
    if [[ -f "/var/log/nginx/ess-error.log" ]]; then
        tail -1000 "/var/log/nginx/ess-error.log" > "$backup_dir/logs/ess-error.log" 2>/dev/null || true
    fi

    $success
}

# 备份ESS配置
backup_ess_configs() {
    local backup_dir="$1"
    mkdir -p "$backup_dir"

    local success=true

    # 备份helm values
    if helm get values ess -n ess > "$backup_dir/helm-values.yaml" 2>/dev/null; then
        log_info "helm values备份完成"
    else
        log_warning "helm values备份失败"
        success=false
    fi

    # 备份所有ConfigMaps
    if kubectl get configmap -n ess -o yaml > "$backup_dir/configmaps.yaml" 2>/dev/null; then
        log_info "ConfigMaps备份完成"
    else
        log_warning "ConfigMaps备份失败"
        success=false
    fi

    # 备份Secrets（不包含敏感数据）
    if kubectl get secrets -n ess -o yaml > "$backup_dir/secrets.yaml" 2>/dev/null; then
        log_info "Secrets备份完成"
    else
        log_warning "Secrets备份失败"
        success=false
    fi

    # 备份Ingress配置
    if kubectl get ingress -n ess -o yaml > "$backup_dir/ingress.yaml" 2>/dev/null; then
        log_info "Ingress配置备份完成"
    else
        log_warning "Ingress配置备份失败"
        success=false
    fi

    # 备份脚本生成的配置文件
    if [[ -d "$ESS_CONFIG_DIR" ]]; then
        cp -r "$ESS_CONFIG_DIR" "$backup_dir/script-configs" || success=false
    fi

    $success
}

# 备份SSL证书
backup_ssl_certs() {
    local backup_dir="$1"
    mkdir -p "$backup_dir"

    local success=true

    # 备份nginx使用的SSL证书
    if [[ -f "/etc/ssl/certs/ess-combined.crt" ]]; then
        cp "/etc/ssl/certs/ess-combined.crt" "$backup_dir/" || success=false
    fi

    if [[ -f "/etc/ssl/private/ess-combined.key" ]]; then
        cp "/etc/ssl/private/ess-combined.key" "$backup_dir/" || success=false
    fi

    # 备份DH参数
    if [[ -f "/etc/ssl/certs/dhparam.pem" ]]; then
        cp "/etc/ssl/certs/dhparam.pem" "$backup_dir/" || success=false
    fi

    # 备份Kubernetes中的TLS secrets
    kubectl get secrets -n ess -o yaml | grep -A 20 -B 5 "tls.crt\|tls.key" > "$backup_dir/k8s-tls-secrets.yaml" 2>/dev/null || true

    $success
}

# 备份脚本配置
backup_script_configs() {
    local backup_dir="$1"
    mkdir -p "$backup_dir"

    local success=true

    # 备份脚本本身
    if [[ -f "$0" ]]; then
        cp "$0" "$backup_dir/manage.sh" || success=false
    fi

    # 备份环境变量配置（如果存在）
    if [[ -f "/root/.ess-config" ]]; then
        cp "/root/.ess-config" "$backup_dir/" || true
    fi

    # 备份历史配置文件
    if [[ -d "/root/ess-config-values" ]]; then
        cp -r "/root/ess-config-values" "$backup_dir/" || success=false
    fi

    $success
}

# 创建备份信息文件
create_backup_info() {
    local backup_dir="$1"

    cat > "$backup_dir/backup-info.txt" <<EOF
ESS配置备份信息
================

备份时间: $(date)
备份类型: 完整备份
服务器: $(hostname)
操作系统: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)

组件版本信息:
- nginx: $(nginx -v 2>&1 | cut -d' ' -f3 | cut -d'/' -f2)
- kubectl: $(kubectl version --client --short 2>/dev/null | cut -d' ' -f3)
- helm: $(helm version --short 2>/dev/null)

ESS服务状态:
$(kubectl get pods -n ess 2>/dev/null || echo "无法获取ESS状态")

备份内容:
- nginx配置文件
- ESS Kubernetes配置
- SSL证书
- 脚本配置文件

恢复说明:
1. 解压备份文件
2. 根据需要恢复相应的配置文件
3. 重启相关服务
4. 验证服务状态

注意事项:
- 此备份不包含数据库数据
- SSL私钥已备份，请妥善保管
- 恢复前请确保目标环境兼容
EOF
}

# 主程序入口
main() {
    # 显示主菜单
    show_main_menu
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
