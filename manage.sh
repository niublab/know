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
    echo "1) 完整配置nginx反代 (推荐)"
    echo "2) 仅安装nginx"
    echo "3) 配置自定义端口"
    echo "4) 生成nginx配置"
    echo "5) 测试nginx配置"
    echo ""
    echo -e "${GREEN}=== 用户管理 ===${NC}"
    echo "6) 创建新用户"
    echo "7) 删除用户"
    echo "8) 修改用户权限"
    echo "9) 生成注册链接"
    echo "10) 查看用户列表"
    echo ""
    echo -e "${GREEN}=== ESS配置管理 ===${NC}"
    echo "11) 生成ESS外部URL配置"
    echo "12) 应用ESS外部URL配置"
    echo ""
    echo -e "${GREEN}=== 系统管理 ===${NC}"
    echo "13) 查看系统状态"
    echo "14) 查看服务日志"
    echo "15) 重启服务"
    echo "16) 备份配置"
    echo ""
    echo "0) 退出"
    echo ""
    read -p "请输入选择 [0-16]: " choice

    case $choice in
        1) full_setup ;;
        2) install_nginx_only ;;
        3) configure_ports_only ;;
        4) generate_config_only ;;
        5) test_config ;;
        6) create_user ;;
        7) delete_user ;;
        8) modify_user_permissions ;;
        9) generate_registration_link ;;
        10) list_users ;;
        11) generate_ess_config_only ;;
        12) apply_ess_config_only ;;
        13) show_status ;;
        14) show_logs ;;
        15) restart_services ;;
        16) backup_config ;;
        0) exit 0 ;;
        *)
            log_error "无效选择"
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

# 应用ESS配置
apply_ess_config() {
    log_info "应用ESS外部URL配置..."

    local config_file="$ESS_CONFIG_DIR/external-urls.yaml"

    if [[ ! -f "$config_file" ]]; then
        log_error "ESS外部URL配置文件不存在: $config_file"
        return 1
    fi

    # 检查helm是否可用
    if ! command -v helm >/dev/null 2>&1; then
        log_error "helm命令不可用，无法应用ESS配置"
        log_info "请手动应用配置文件: $config_file"
        return 1
    fi

    # 查找ESS helm release
    local ess_release=$(helm list -n ess -o json | jq -r '.[0].name' 2>/dev/null || echo "")

    if [[ -z "$ess_release" ]]; then
        log_error "无法找到ESS helm release"
        log_info "请手动应用配置文件: $config_file"
        return 1
    fi

    log_info "找到ESS release: $ess_release"
    log_warning "即将重新部署ESS以应用外部URL配置"
    log_warning "这将重启ESS服务，可能造成短暂中断"

    read -p "确认继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        log_info "配置文件已生成: $config_file"
        log_info "您可以稍后手动应用此配置"
        return 0
    fi

    # 应用配置
    log_info "正在应用ESS配置..."
    if helm upgrade "$ess_release" -n ess \
        -f "$ESS_CONFIG_DIR/hostnames.yaml" \
        -f "$config_file" \
        --reuse-values; then
        log_success "ESS配置应用成功"
        log_info "等待ESS服务重启..."
        sleep 30
        log_info "请检查ESS服务状态: kubectl get pods -n ess"
    else
        log_error "ESS配置应用失败"
        log_info "请检查配置文件并手动应用: $config_file"
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

        # 生成ESS外部URL配置
        generate_ess_external_config

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
        echo "- ✅ ESS外部URL配置生成"
        echo ""
        echo -e "${YELLOW}重要提醒：${NC}"
        echo "1. nginx反代配置已完成"
        echo "2. ESS外部URL配置已生成但未应用"
        echo "3. 需要应用ESS配置以修复MAS等服务的URL问题"
        echo ""
        read -p "是否现在应用ESS外部URL配置? [y/N]: " apply_now
        if [[ "$apply_now" =~ ^[Yy]$ ]]; then
            apply_ess_config
        else
            log_info "ESS外部URL配置已生成: $ESS_CONFIG_DIR/external-urls.yaml"
            log_info "您可以稍后选择菜单选项来应用此配置"
        fi

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

# 仅生成ESS配置
generate_ess_config_only() {
    log_info "仅生成ESS外部URL配置..."

    check_system_requirements
    read_ess_config
    configure_custom_ports
    generate_ess_external_config

    log_success "ESS外部URL配置生成完成"
    log_info "配置文件位置: $ESS_CONFIG_DIR/external-urls.yaml"
    log_info "请选择菜单选项12来应用此配置"

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

# 其他占位符函数（待实现）
generate_registration_link() {
    log_warning "注册链接生成功能待实现"
    read -p "按任意键返回主菜单..."
    show_main_menu
}

list_users() {
    log_warning "用户列表查看功能待实现"
    read -p "按任意键返回主菜单..."
    show_main_menu
}

show_logs() {
    log_warning "服务日志查看功能待实现"
    read -p "按任意键返回主菜单..."
    show_main_menu
}

restart_services() {
    log_warning "服务重启功能待实现"
    read -p "按任意键返回主菜单..."
    show_main_menu
}

backup_config() {
    log_warning "配置备份功能待实现"
    read -p "按任意键返回主菜单..."
    show_main_menu
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
