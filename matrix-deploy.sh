#!/bin/bash

# Matrix 服务器自动化部署脚本
# 版本: 1.0.0
# 作者: Manus AI
# 描述: 基于 Element Server Suite Community Edition 的自动化部署工具

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="1.0.0"

# 默认配置
DEFAULT_INSTALL_DIR="/opt/matrix"
DEFAULT_HTTP_PORT="8080"
DEFAULT_HTTPS_PORT="8443"
DEFAULT_WEBRTC_TCP_PORT="30881"
DEFAULT_WEBRTC_UDP_PORT="30882"
DEFAULT_NAMESPACE="ess"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 生成64位随机密码/密钥
generate_secret() {
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-64
}

# 生成随机字符串（字母数字）
generate_random_string() {
    local length=${1:-64}
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
}

# 检查命令是否存在
check_command() {
    if ! command -v "$1" &> /dev/null; then
        log_error "命令 '$1' 未找到，请先安装"
        return 1
    fi
}

# 检查系统要求
check_system_requirements() {
    log_info "检查系统要求..."
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测操作系统版本"
        return 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        log_warn "检测到非 Debian/Ubuntu 系统: $PRETTY_NAME"
        log_warn "脚本主要针对 Debian 系统测试，可能需要手动调整"
    fi
    
    # 检查内存
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        log_warn "系统内存少于 2GB，可能影响性能"
    fi
    
    # 检查磁盘空间
    local disk_gb=$(df -BG "$PWD" | awk 'NR==2{print $4}' | sed 's/G//')
    if [[ $disk_gb -lt 10 ]]; then
        log_warn "可用磁盘空间少于 10GB，可能不足"
    fi
    
    log_info "系统要求检查完成"
}

# 安装依赖包
install_dependencies() {
    log_info "安装系统依赖..."
    
    # 更新包列表
    sudo apt-get update -qq
    
    # 安装基础依赖
    local packages=(
        "curl"
        "wget"
        "git"
        "openssl"
        "jq"
        "dnsutils"
        "net-tools"
        "unzip"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log_info "安装 $package..."
            sudo apt-get install -y "$package"
        fi
    done
    
    log_info "系统依赖安装完成"
}

# 安装 K3s (配置自定义端口)
install_k3s() {
    log_info "安装 K3s Kubernetes (配置自定义端口)..."
    
    if command -v k3s &> /dev/null; then
        log_info "K3s 已安装，检查配置..."
        check_k3s_ports
        return 0
    fi
    
    # 读取端口配置
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        HTTP_PORT="$DEFAULT_HTTP_PORT"
        HTTPS_PORT="$DEFAULT_HTTPS_PORT"
    fi
    
    log_info "使用自定义端口: HTTP=$HTTP_PORT, HTTPS=$HTTPS_PORT"
    
    # 安装 K3s (禁用默认的 Traefik，我们将手动配置)
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -
    
    # 配置 kubeconfig
    mkdir -p ~/.kube
    export KUBECONFIG=~/.kube/config
    sudo k3s kubectl config view --raw > "$KUBECONFIG"
    chmod 600 "$KUBECONFIG"
    chown "$USER:$USER" "$KUBECONFIG"
    
    # 添加到 bashrc
    if ! grep -q "KUBECONFIG" ~/.bashrc; then
        echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
    fi
    
    # 等待 K3s 启动
    log_info "等待 K3s 启动..."
    sleep 10
    
    # 安装自定义端口的 Traefik
    install_custom_traefik
    
    log_info "K3s 安装完成"
}

# 检查 K3s 端口配置
check_k3s_ports() {
    log_info "检查 K3s 端口配置..."
    
    # 检查 Traefik 服务
    if kubectl get svc -n kube-system traefik &>/dev/null; then
        local current_ports=$(kubectl get svc -n kube-system traefik -o jsonpath='{.spec.ports[*].port}')
        log_info "当前 Traefik 端口: $current_ports"
        
        # 检查是否使用了标准端口
        if echo "$current_ports" | grep -q "80\|443"; then
            log_warn "检测到使用标准端口，需要重新配置"
            reconfigure_traefik_ports
        fi
    else
        log_info "未找到 Traefik 服务，将安装自定义配置"
        install_custom_traefik
    fi
}

# 安装自定义端口的 Traefik
install_custom_traefik() {
    log_info "安装自定义端口的 Traefik..."
    
    # 读取端口配置
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        HTTP_PORT="$DEFAULT_HTTP_PORT"
        HTTPS_PORT="$DEFAULT_HTTPS_PORT"
    fi
    
    # 创建 Traefik 配置目录
    local traefik_dir="$SCRIPT_DIR/config/traefik"
    mkdir -p "$traefik_dir"
    
    # 创建 Traefik 配置文件
    cat > "$traefik_dir/traefik-config.yaml" << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: traefik-system
---
apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: traefik
  namespace: kube-system
spec:
  chart: traefik
  repo: https://traefik.github.io/charts
  targetNamespace: traefik-system
  valuesContent: |-
    ports:
      web:
        port: $HTTP_PORT
        exposedPort: $HTTP_PORT
        nodePort: 30080
      websecure:
        port: $HTTPS_PORT
        exposedPort: $HTTPS_PORT
        nodePort: 30443
    service:
      type: NodePort
      spec:
        externalIPs:
          - "$(get_external_ip)"
    ingressRoute:
      dashboard:
        enabled: false
    providers:
      kubernetesCRD:
        enabled: true
      kubernetesIngress:
        enabled: true
    certificatesResolvers:
      letsencrypt:
        acme:
          email: ${CERT_EMAIL:-admin@example.com}
          storage: /data/acme.json
          dnsChallenge:
            provider: cloudflare
            resolvers:
              - "1.1.1.1:53"
              - "8.8.8.8:53"
    env:
      - name: CF_API_TOKEN
        value: "${CLOUDFLARE_TOKEN:-}"
EOF
    
    # 应用配置
    kubectl apply -f "$traefik_dir/traefik-config.yaml"
    
    log_info "等待 Traefik 启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik-system --timeout=300s
    
    log_info "Traefik 安装完成，使用端口: $HTTP_PORT/$HTTPS_PORT"
}

# 重新配置 Traefik 端口
reconfigure_traefik_ports() {
    log_info "重新配置 Traefik 端口..."
    
    # 删除现有的 Traefik
    kubectl delete helmchart traefik -n kube-system --ignore-not-found=true
    kubectl delete namespace traefik-system --ignore-not-found=true
    
    # 等待清理完成
    sleep 10
    
    # 重新安装
    install_custom_traefik
}

# 获取外部IP
get_external_ip() {
    # 尝试多种方法获取外部IP
    local ip
    
    # 方法1: 从配置文件读取域名并解析
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        if [[ -n "$DOMAIN" ]]; then
            ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null || dig +short "$DOMAIN" @1.1.1.1 2>/dev/null)
        fi
    fi
    
    # 方法2: 使用公共服务获取
    if [[ -z "$ip" ]]; then
        ip=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || curl -s icanhazip.com 2>/dev/null)
    fi
    
    # 方法3: 使用本地网络接口
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null)
    fi
    
    echo "${ip:-127.0.0.1}"
}

# 安装 Helm
install_helm() {
    log_info "安装 Helm..."
    
    if command -v helm &> /dev/null; then
        log_info "Helm 已安装，跳过安装步骤"
        return 0
    fi
    
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_info "Helm 安装完成"
}

# 获取公网IP
get_public_ip() {
    local domain="$1"
    local ip
    
    # 使用用户指定的方法获取公网IP
    ip=$(dig +short "$domain" @8.8.8.8 2>/dev/null || dig +short "$domain" @1.1.1.1 2>/dev/null)
    
    if [[ -z "$ip" ]]; then
        log_error "无法获取公网IP地址"
        return 1
    fi
    
    echo "$ip"
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}  Matrix 服务器自动化部署工具${NC}"
    echo -e "${WHITE}  版本: $VERSION${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} 初始化部署环境"
    echo -e "${GREEN}2.${NC} 配置服务参数"
    echo -e "${GREEN}3.${NC} 部署 Matrix 服务"
    echo -e "${GREEN}4.${NC} 证书管理"
    echo -e "${GREEN}5.${NC} 服务管理"
    echo -e "${GREEN}6.${NC} 系统维护"
    echo -e "${GREEN}7.${NC} 查看状态"
    echo -e "${GREEN}8.${NC} 查看日志"
    echo -e "${RED}0.${NC} 退出"
    echo
    echo -e "${YELLOW}请选择操作:${NC} "
}

# 显示环境初始化菜单
show_init_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}     环境初始化${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} 检查系统要求"
    echo -e "${GREEN}2.${NC} 安装系统依赖"
    echo -e "${GREEN}3.${NC} 安装 K3s"
    echo -e "${GREEN}4.${NC} 安装 Helm"
    echo -e "${GREEN}5.${NC} 一键完整初始化"
    echo -e "${RED}0.${NC} 返回主菜单"
    echo
    echo -e "${YELLOW}请选择操作:${NC} "
}

# 处理环境初始化
handle_init_menu() {
    while true; do
        show_init_menu
        read -r choice
        
        case $choice in
            1)
                check_system_requirements
                read -p "按回车键继续..."
                ;;
            2)
                install_dependencies
                read -p "按回车键继续..."
                ;;
            3)
                install_k3s
                read -p "按回车键继续..."
                ;;
            4)
                install_helm
                read -p "按回车键继续..."
                ;;
            5)
                log_info "开始完整环境初始化..."
                check_system_requirements
                install_dependencies
                install_k3s
                install_helm
                log_info "环境初始化完成！"
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                log_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 配置向导
configure_deployment() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}     部署配置向导${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    
    # 创建配置目录
    local config_dir="$SCRIPT_DIR/config"
    mkdir -p "$config_dir"
    
    # 环境变量文件
    local env_file="$config_dir/.env"
    
    log_info "开始配置部署参数..."
    
    # 域名配置
    echo -e "${YELLOW}=== 域名配置 ===${NC}"
    read -p "请输入您的主域名 (例如: example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        log_error "域名不能为空"
        read -p "请输入您的主域名: " DOMAIN
    done
    
    # 端口配置
    echo -e "${YELLOW}=== 端口配置 ===${NC}"
    echo -e "${RED}注意: 由于ISP封锁，将使用非标准端口${NC}"
    
    read -p "HTTP 端口 [默认: $DEFAULT_HTTP_PORT]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}
    
    # 验证不是标准端口
    while [[ "$HTTP_PORT" == "80" ]]; do
        log_error "不能使用端口80 (ISP封锁)，请选择其他端口"
        read -p "HTTP 端口 [推荐: $DEFAULT_HTTP_PORT]: " HTTP_PORT
        HTTP_PORT=${HTTP_PORT:-$DEFAULT_HTTP_PORT}
    done
    
    read -p "HTTPS 端口 [默认: $DEFAULT_HTTPS_PORT]: " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-$DEFAULT_HTTPS_PORT}
    
    # 验证不是标准端口
    while [[ "$HTTPS_PORT" == "443" ]]; do
        log_error "不能使用端口443 (ISP封锁)，请选择其他端口"
        read -p "HTTPS 端口 [推荐: $DEFAULT_HTTPS_PORT]: " HTTPS_PORT
        HTTPS_PORT=${HTTPS_PORT:-$DEFAULT_HTTPS_PORT}
    done
    
    read -p "WebRTC TCP 端口 [默认: $DEFAULT_WEBRTC_TCP_PORT]: " WEBRTC_TCP_PORT
    WEBRTC_TCP_PORT=${WEBRTC_TCP_PORT:-$DEFAULT_WEBRTC_TCP_PORT}
    
    read -p "WebRTC UDP 端口 [默认: $DEFAULT_WEBRTC_UDP_PORT]: " WEBRTC_UDP_PORT
    WEBRTC_UDP_PORT=${WEBRTC_UDP_PORT:-$DEFAULT_WEBRTC_UDP_PORT}
    
    # 安装目录
    echo -e "${YELLOW}=== 安装目录 ===${NC}"
    read -p "安装目录 [默认: $DEFAULT_INSTALL_DIR]: " INSTALL_DIR
    INSTALL_DIR=${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}
    
    # 证书配置
    echo -e "${YELLOW}=== 证书配置 ===${NC}"
    echo "1. 生产环境证书 (Let's Encrypt 生产)"
    echo "2. 测试环境证书 (Let's Encrypt 测试)"
    read -p "请选择证书类型 [1-2]: " CERT_TYPE
    
    case $CERT_TYPE in
        1)
            CERT_ENV="production"
            ;;
        2)
            CERT_ENV="staging"
            ;;
        *)
            log_warn "无效选择，使用测试环境证书"
            CERT_ENV="staging"
            ;;
    esac
    
    read -p "证书邮箱地址: " CERT_EMAIL
    while [[ -z "$CERT_EMAIL" ]]; do
        log_error "证书邮箱不能为空"
        read -p "证书邮箱地址: " CERT_EMAIL
    done
    
    read -p "Cloudflare API Token: " CLOUDFLARE_TOKEN
    while [[ -z "$CLOUDFLARE_TOKEN" ]]; do
        log_error "Cloudflare API Token 不能为空"
        read -p "Cloudflare API Token: " CLOUDFLARE_TOKEN
    done
    
    # 可选配置
    echo -e "${YELLOW}=== 可选配置 ===${NC}"
    read -p "服务管理员邮箱 (可选): " ADMIN_EMAIL
    
    # 生成随机密码和密钥
    log_info "生成安全密钥..."
    
    local POSTGRES_PASSWORD=$(generate_secret)
    local SYNAPSE_SIGNING_KEY=$(generate_secret)
    local SYNAPSE_MACAROON_SECRET=$(generate_secret)
    local MAS_SECRET_KEY=$(generate_secret)
    local MAS_ENCRYPTION_KEY=$(generate_secret)
    local REGISTRATION_TOKEN=$(generate_random_string 32)
    
    # 保存配置到 .env 文件
    cat > "$env_file" << EOF
# Matrix 服务器部署配置
# 生成时间: $(date)

# 域名配置
DOMAIN=$DOMAIN
SERVER_NAME=$DOMAIN

# 子域名配置
MATRIX_DOMAIN=matrix.$DOMAIN
ACCOUNT_DOMAIN=account.$DOMAIN
MRTC_DOMAIN=mrtc.$DOMAIN
CHAT_DOMAIN=chat.$DOMAIN

# 端口配置
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
WEBRTC_TCP_PORT=$WEBRTC_TCP_PORT
WEBRTC_UDP_PORT=$WEBRTC_UDP_PORT

# 安装配置
INSTALL_DIR=$INSTALL_DIR
NAMESPACE=$DEFAULT_NAMESPACE

# 证书配置
CERT_ENV=$CERT_ENV
CERT_EMAIL=$CERT_EMAIL
CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN

# 管理员配置
ADMIN_EMAIL=$ADMIN_EMAIL

# 数据库配置
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# Synapse 配置
SYNAPSE_SIGNING_KEY=$SYNAPSE_SIGNING_KEY
SYNAPSE_MACAROON_SECRET=$SYNAPSE_MACAROON_SECRET

# MAS 配置
MAS_SECRET_KEY=$MAS_SECRET_KEY
MAS_ENCRYPTION_KEY=$MAS_ENCRYPTION_KEY

# 注册令牌
REGISTRATION_TOKEN=$REGISTRATION_TOKEN

# 功能开关
ENABLE_FEDERATION=true
ENABLE_REGISTRATION=false
EOF
    
    log_info "配置已保存到: $env_file"
    
    # 显示配置摘要
    echo
    echo -e "${CYAN}=== 配置摘要 ===${NC}"
    echo -e "主域名: ${GREEN}$DOMAIN${NC}"
    echo -e "HTTP 端口: ${GREEN}$HTTP_PORT${NC} ${YELLOW}(非标准端口，避免ISP封锁)${NC}"
    echo -e "HTTPS 端口: ${GREEN}$HTTPS_PORT${NC} ${YELLOW}(非标准端口，避免ISP封锁)${NC}"
    echo -e "WebRTC TCP: ${GREEN}$WEBRTC_TCP_PORT${NC}"
    echo -e "WebRTC UDP: ${GREEN}$WEBRTC_UDP_PORT${NC}"
    echo -e "安装目录: ${GREEN}$INSTALL_DIR${NC}"
    echo -e "证书类型: ${GREEN}$CERT_ENV${NC}"
    echo -e "证书邮箱: ${GREEN}$CERT_EMAIL${NC}"
    echo -e "注册令牌: ${GREEN}$REGISTRATION_TOKEN${NC}"
    echo
    echo -e "${YELLOW}重要提醒:${NC}"
    echo -e "- 请确保路由器已配置端口转发: $HTTP_PORT -> 内网服务器:$HTTP_PORT"
    echo -e "- 请确保路由器已配置端口转发: $HTTPS_PORT -> 内网服务器:$HTTPS_PORT"
    echo -e "- 请确保路由器已配置端口转发: $WEBRTC_TCP_PORT -> 内网服务器:$WEBRTC_TCP_PORT"
    echo -e "- 请确保路由器已配置端口转发: $WEBRTC_UDP_PORT -> 内网服务器:$WEBRTC_UDP_PORT (UDP)"
    echo
    
    read -p "按回车键继续..."
}

# 主函数
main() {
    # 检查是否以 root 运行
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要以 root 用户运行此脚本"
        exit 1
    fi
    
    # 检查 sudo 权限
    if ! sudo -n true 2>/dev/null; then
        log_error "此脚本需要 sudo 权限，请确保当前用户在 sudoers 中"
        exit 1
    fi
    
    while true; do
        show_main_menu
        read -r choice
        
        case $choice in
            1)
                handle_init_menu
                ;;
            2)
                configure_deployment
                ;;
            3)
                handle_deploy_menu
                ;;
            4)
                log_info "启动证书管理工具..."
                if [[ -f "$SCRIPT_DIR/cert-manager.sh" ]]; then
                    "$SCRIPT_DIR/cert-manager.sh"
                else
                    log_error "证书管理脚本不存在"
                fi
                ;;
            5)
                handle_service_menu
                ;;
            6)
                handle_maintenance_menu
                ;;
            7)
                log_info "状态查看功能开发中..."
                read -p "按回车键继续..."
                ;;
            8)
                log_info "日志查看功能开发中..."
                read -p "按回车键继续..."
                ;;
            0)
                log_info "感谢使用 Matrix 服务器自动化部署工具！"
                exit 0
                ;;
            *)
                log_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi


# 创建Matrix服务配置模板
create_matrix_values() {
    log_info "创建Matrix服务配置模板..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在，请先运行配置向导"
        return 1
    fi
    
    source "$config_file"
    
    local values_dir="$SCRIPT_DIR/config/values"
    mkdir -p "$values_dir"
    
    # 创建主配置文件
    cat > "$values_dir/matrix-values.yaml" << EOF
# Matrix Stack 配置文件
# 自动生成时间: $(date)

# 全局配置
global:
  serverName: "$DOMAIN"
  
# Ingress 配置 - 关键：明确指定端口避免自动跳转到标准端口
ingress:
  enabled: true
  className: "traefik"
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: "letsencrypt"
    # 强制指定端口，避免自动跳转到标准端口
    traefik.ingress.kubernetes.io/router.rule: "Host(\`$DOMAIN\`) || Host(\`$MATRIX_DOMAIN\`) || Host(\`$ACCOUNT_DOMAIN\`) || Host(\`$MRTC_DOMAIN\`) || Host(\`$CHAT_DOMAIN\`)"
    # 自定义重定向规则，确保使用正确端口
    traefik.ingress.kubernetes.io/router.middlewares: "default-redirect-https@kubernetescrd"
  tls:
    enabled: true
    secretName: "matrix-tls"
  hosts:
    - host: "$DOMAIN"
      paths:
        - path: /
          pathType: Prefix
    - host: "$MATRIX_DOMAIN"
      paths:
        - path: /
          pathType: Prefix
    - host: "$ACCOUNT_DOMAIN"
      paths:
        - path: /
          pathType: Prefix
    - host: "$MRTC_DOMAIN"
      paths:
        - path: /
          pathType: Prefix
    - host: "$CHAT_DOMAIN"
      paths:
        - path: /
          pathType: Prefix

# Synapse 配置
synapse:
  enabled: true
  serverName: "$DOMAIN"
  # 明确指定公网访问URL，包含端口信息
  publicBaseurl: "https://$MATRIX_DOMAIN:$HTTPS_PORT"
  
  # 数据库配置
  postgresql:
    enabled: true
    auth:
      password: "$POSTGRES_PASSWORD"
      database: "synapse"
      username: "synapse"
  
  # 签名密钥
  signingKey: "$SYNAPSE_SIGNING_KEY"
  
  # Macaroon 密钥
  macaroonSecretKey: "$SYNAPSE_MACAROON_SECRET"
  
  # 联邦配置
  federation:
    enabled: $ENABLE_FEDERATION
    # 联邦端口也需要明确指定
    port: 8448
    # 联邦公网URL
    publicUrl: "https://$DOMAIN:$HTTPS_PORT"
  
  # 注册配置
  registration:
    enabled: $ENABLE_REGISTRATION
    registrationSharedSecret: "$REGISTRATION_TOKEN"
  
  # Well-known 配置 - 关键：指定正确的端口
  wellknown:
    enabled: true
    server:
      "m.server": "$MATRIX_DOMAIN:$HTTPS_PORT"
    client:
      "m.homeserver":
        "base_url": "https://$MATRIX_DOMAIN:$HTTPS_PORT"
      "m.identity_server":
        "base_url": "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
      "org.matrix.msc3575.proxy":
        "url": "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"

# Matrix Authentication Service (MAS) 配置
mas:
  enabled: true
  # MAS 公网访问URL
  publicUrl: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
  
  # MAS 密钥配置
  config:
    secrets:
      encryption: "$MAS_ENCRYPTION_KEY"
      keys:
        - kid: "default"
          key: "$MAS_SECRET_KEY"
    
    # 数据库配置
    database:
      uri: "postgresql://synapse:$POSTGRES_PASSWORD@postgresql:5432/mas"
    
    # HTTP 配置 - 明确指定监听端口
    http:
      listeners:
        - name: "web"
          resources:
            - name: "discovery"
            - name: "human"
            - name: "oauth"
            - name: "compat"
          binds:
            - address: "0.0.0.0:8080"
      # 公网访问配置
      public_base: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
      issuer: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
    
    # 上游配置 - 指向 Synapse
    upstream:
      name: "synapse"
      oidc_discovery_url: "https://$MATRIX_DOMAIN:$HTTPS_PORT/_matrix/client/unstable/org.matrix.msc2965/auth_issuer"

# Element Web 配置
elementWeb:
  enabled: true
  # Element Web 公网访问URL
  publicUrl: "https://$CHAT_DOMAIN:$HTTPS_PORT"
  
  config:
    default_server_config:
      "m.homeserver":
        "base_url": "https://$MATRIX_DOMAIN:$HTTPS_PORT"
        "server_name": "$DOMAIN"
      "m.identity_server":
        "base_url": "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
    
    # 集成管理器配置
    integrations_ui_url: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
    integrations_rest_url: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
    
    # Element Call 配置
    element_call:
      url: "https://$MRTC_DOMAIN:$HTTPS_PORT"

# Matrix RTC 配置
matrixRtc:
  enabled: true
  # RTC 公网访问URL
  publicUrl: "https://$MRTC_DOMAIN:$HTTPS_PORT"
  
  # WebRTC 端口配置
  webrtc:
    tcp_port: $WEBRTC_TCP_PORT
    udp_port: $WEBRTC_UDP_PORT
    # 公网IP配置
    external_ip: "$(get_external_ip)"

# 证书配置
certificates:
  issuer: "letsencrypt-$CERT_ENV"
  email: "$CERT_EMAIL"
  dnsChallenge:
    provider: "cloudflare"
    cloudflare:
      apiToken: "$CLOUDFLARE_TOKEN"

# 服务配置
service:
  type: "NodePort"
  # 明确指定服务端口
  ports:
    http: $HTTP_PORT
    https: $HTTPS_PORT
    webrtc_tcp: $WEBRTC_TCP_PORT
    webrtc_udp: $WEBRTC_UDP_PORT
EOF

    # 创建HTTPS重定向中间件配置
    cat > "$values_dir/redirect-middleware.yaml" << EOF
apiVersion: traefik.containo.us/v1alpha1
kind: Middleware
metadata:
  name: redirect-https
  namespace: default
spec:
  redirectScheme:
    scheme: https
    port: "$HTTPS_PORT"
    permanent: true
EOF

    # 创建端口特定的 Ingress 配置
    cat > "$values_dir/custom-ingress.yaml" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: matrix-custom-ingress
  namespace: $NAMESPACE
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: "letsencrypt"
    # 自定义重定向，确保使用正确端口
    traefik.ingress.kubernetes.io/router.middlewares: "default-redirect-https@kubernetescrd"
    # 强制指定端口
    traefik.ingress.kubernetes.io/router.rule: "Host(\`$DOMAIN\`) && Port(\`$HTTPS_PORT\`)"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - "$DOMAIN"
        - "$MATRIX_DOMAIN"
        - "$ACCOUNT_DOMAIN"
        - "$MRTC_DOMAIN"
        - "$CHAT_DOMAIN"
      secretName: matrix-tls
  rules:
    - host: "$DOMAIN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-synapse
                port:
                  number: 8008
    - host: "$MATRIX_DOMAIN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-synapse
                port:
                  number: 8008
    - host: "$ACCOUNT_DOMAIN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-mas
                port:
                  number: 8080
    - host: "$MRTC_DOMAIN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-rtc
                port:
                  number: 8080
    - host: "$CHAT_DOMAIN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: matrix-element-web
                port:
                  number: 8080
EOF

    log_info "Matrix配置模板创建完成"
    log_info "配置文件位置:"
    log_info "  - 主配置: $values_dir/matrix-values.yaml"
    log_info "  - 重定向中间件: $values_dir/redirect-middleware.yaml"
    log_info "  - 自定义Ingress: $values_dir/custom-ingress.yaml"
}

# 部署Matrix服务
deploy_matrix() {
    log_info "开始部署Matrix服务..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在，请先运行配置向导"
        return 1
    fi
    
    source "$config_file"
    
    # 检查Kubernetes连接
    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群，请检查K3s是否正常运行"
        return 1
    fi
    
    # 创建命名空间
    log_info "创建命名空间: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建配置模板
    create_matrix_values
    
    # 应用重定向中间件
    log_info "应用HTTPS重定向中间件..."
    kubectl apply -f "$SCRIPT_DIR/config/values/redirect-middleware.yaml"
    
    # 部署Matrix Stack (使用新的OCI方式)
    log_info "部署Matrix Stack..."
    local values_dir="$SCRIPT_DIR/config/values"
    
    helm upgrade --install \
        --namespace "$NAMESPACE" \
        --values "$values_dir/matrix-values.yaml" \
        matrix-stack \
        oci://ghcr.io/element-hq/ess-helm/matrix-stack
    
    # 等待部署完成
    log_info "等待Matrix服务启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=synapse -n "$NAMESPACE" --timeout=600s
    
    # 应用自定义Ingress配置
    log_info "应用自定义Ingress配置..."
    kubectl apply -f "$values_dir/custom-ingress.yaml"
    
    log_info "Matrix服务部署完成！"
    
    # 显示访问信息
    echo
    echo -e "${CYAN}=== 服务访问信息 ===${NC}"
    echo -e "Matrix服务器: ${GREEN}https://$MATRIX_DOMAIN:$HTTPS_PORT${NC}"
    echo -e "用户认证: ${GREEN}https://$ACCOUNT_DOMAIN:$HTTPS_PORT${NC}"
    echo -e "Web客户端: ${GREEN}https://$CHAT_DOMAIN:$HTTPS_PORT${NC}"
    echo -e "视频通话: ${GREEN}https://$MRTC_DOMAIN:$HTTPS_PORT${NC}"
    echo
    echo -e "${YELLOW}注意: 所有URL都包含端口号，避免自动跳转到标准端口${NC}"
}

# 显示部署菜单
show_deploy_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}     Matrix 服务部署${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} 创建配置模板"
    echo -e "${GREEN}2.${NC} 部署Matrix服务"
    echo -e "${GREEN}3.${NC} 检查部署状态"
    echo -e "${GREEN}4.${NC} 创建管理员用户"
    echo -e "${GREEN}5.${NC} 验证服务功能"
    echo -e "${RED}0.${NC} 返回主菜单"
    echo
    echo -e "${YELLOW}请选择操作:${NC} "
}

# 处理部署菜单
handle_deploy_menu() {
    while true; do
        show_deploy_menu
        read -r choice
        
        case $choice in
            1)
                create_matrix_values
                read -p "按回车键继续..."
                ;;
            2)
                deploy_matrix
                read -p "按回车键继续..."
                ;;
            3)
                check_deployment_status
                read -p "按回车键继续..."
                ;;
            4)
                create_admin_user
                read -p "按回车键继续..."
                ;;
            5)
                verify_services
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                log_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 检查部署状态
check_deployment_status() {
    log_info "检查Matrix服务部署状态..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="$DEFAULT_NAMESPACE"
    fi
    
    echo -e "${CYAN}=== Pod 状态 ===${NC}"
    kubectl get pods -n "$NAMESPACE" -o wide
    
    echo
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    kubectl get svc -n "$NAMESPACE"
    
    echo
    echo -e "${CYAN}=== Ingress 状态 ===${NC}"
    kubectl get ingress -n "$NAMESPACE"
    
    echo
    echo -e "${CYAN}=== 证书状态 ===${NC}"
    kubectl get certificates -n "$NAMESPACE" 2>/dev/null || echo "未找到证书资源"
}

# 创建管理员用户
create_admin_user() {
    log_info "创建Matrix管理员用户..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    source "$config_file"
    
    read -p "请输入管理员用户名: " admin_username
    while [[ -z "$admin_username" ]]; do
        log_error "用户名不能为空"
        read -p "请输入管理员用户名: " admin_username
    done
    
    # 使用MAS创建用户
    log_info "使用MAS创建用户: $admin_username"
    kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
        mas-cli manage register-user --username "$admin_username"
    
    log_info "管理员用户创建完成"
    log_info "用户ID: @$admin_username:$DOMAIN"
}

# 验证服务功能
verify_services() {
    log_info "验证Matrix服务功能..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    source "$config_file"
    
    echo -e "${CYAN}=== 服务连通性测试 ===${NC}"
    
    # 测试Matrix服务器
    echo -n "测试Matrix服务器... "
    if curl -s -k "https://$MATRIX_DOMAIN:$HTTPS_PORT/_matrix/client/versions" >/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    
    # 测试Well-known
    echo -n "测试Well-known配置... "
    if curl -s -k "https://$DOMAIN:$HTTPS_PORT/.well-known/matrix/server" >/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    
    # 测试MAS
    echo -n "测试认证服务... "
    if curl -s -k "https://$ACCOUNT_DOMAIN:$HTTPS_PORT/.well-known/openid_configuration" >/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    
    # 测试Element Web
    echo -n "测试Web客户端... "
    if curl -s -k "https://$CHAT_DOMAIN:$HTTPS_PORT" >/dev/null; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
    
    echo
    echo -e "${YELLOW}注意: 所有测试都使用自定义端口，避免ISP封锁${NC}"
}


# 添加服务管理和维护功能到主脚本

# 服务管理菜单
show_service_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}     服务管理${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} 查看服务状态"
    echo -e "${GREEN}2.${NC} 重启服务"
    echo -e "${GREEN}3.${NC} 停止服务"
    echo -e "${GREEN}4.${NC} 启动服务"
    echo -e "${GREEN}5.${NC} 查看服务日志"
    echo -e "${GREEN}6.${NC} 创建用户"
    echo -e "${GREEN}7.${NC} 管理用户"
    echo -e "${GREEN}8.${NC} 备份数据"
    echo -e "${GREEN}9.${NC} 恢复数据"
    echo -e "${RED}0.${NC} 返回主菜单"
    echo
    echo -e "${YELLOW}请选择操作:${NC} "
}

# 处理服务管理
handle_service_menu() {
    while true; do
        show_service_menu
        read -r choice
        
        case $choice in
            1)
                show_service_status
                read -p "按回车键继续..."
                ;;
            2)
                restart_services
                read -p "按回车键继续..."
                ;;
            3)
                stop_services
                read -p "按回车键继续..."
                ;;
            4)
                start_services
                read -p "按回车键继续..."
                ;;
            5)
                show_service_logs
                read -p "按回车键继续..."
                ;;
            6)
                create_user_interactive
                read -p "按回车键继续..."
                ;;
            7)
                manage_users
                read -p "按回车键继续..."
                ;;
            8)
                backup_data
                read -p "按回车键继续..."
                ;;
            9)
                restore_data
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                log_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 显示服务状态
show_service_status() {
    log_info "查看Matrix服务状态..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    echo -e "${CYAN}=== Pod 状态 ===${NC}"
    kubectl get pods -n "$NAMESPACE" -o wide
    
    echo
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    kubectl get svc -n "$NAMESPACE"
    
    echo
    echo -e "${CYAN}=== 资源使用情况 ===${NC}"
    kubectl top pods -n "$NAMESPACE" 2>/dev/null || echo "指标服务器未安装"
    
    echo
    echo -e "${CYAN}=== 存储状态 ===${NC}"
    kubectl get pvc -n "$NAMESPACE"
}

# 重启服务
restart_services() {
    log_info "重启Matrix服务..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 重启主要服务
    local services=("synapse" "mas" "element-web" "matrix-rtc")
    
    for service in "${services[@]}"; do
        log_info "重启 $service..."
        kubectl rollout restart deployment/matrix-$service -n "$NAMESPACE" 2>/dev/null || \
        kubectl rollout restart deployment/$service -n "$NAMESPACE" 2>/dev/null || \
        log_warn "服务 $service 未找到或重启失败"
    done
    
    log_info "等待服务重启完成..."
    sleep 10
    
    # 检查服务状态
    kubectl get pods -n "$NAMESPACE"
}

# 停止服务
stop_services() {
    log_warn "停止Matrix服务..."
    
    read -p "确认停止所有Matrix服务? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 缩放到0副本
    kubectl scale deployment --all --replicas=0 -n "$NAMESPACE"
    
    log_info "所有服务已停止"
}

# 启动服务
start_services() {
    log_info "启动Matrix服务..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 恢复副本数
    local services=("synapse" "mas" "element-web" "matrix-rtc")
    
    for service in "${services[@]}"; do
        kubectl scale deployment/matrix-$service --replicas=1 -n "$NAMESPACE" 2>/dev/null || \
        kubectl scale deployment/$service --replicas=1 -n "$NAMESPACE" 2>/dev/null || \
        log_warn "服务 $service 未找到"
    done
    
    log_info "等待服务启动..."
    sleep 15
    
    kubectl get pods -n "$NAMESPACE"
}

# 查看服务日志
show_service_logs() {
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    echo "选择要查看日志的服务:"
    echo "1. Synapse"
    echo "2. MAS"
    echo "3. Element Web"
    echo "4. Matrix RTC"
    echo "5. 所有服务"
    read -p "请选择 [1-5]: " service_choice
    
    case $service_choice in
        1)
            kubectl logs -f deployment/matrix-synapse -n "$NAMESPACE" --tail=100
            ;;
        2)
            kubectl logs -f deployment/matrix-mas -n "$NAMESPACE" --tail=100
            ;;
        3)
            kubectl logs -f deployment/matrix-element-web -n "$NAMESPACE" --tail=100
            ;;
        4)
            kubectl logs -f deployment/matrix-rtc -n "$NAMESPACE" --tail=100
            ;;
        5)
            kubectl logs --all-containers=true -n "$NAMESPACE" --tail=50
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# 交互式创建用户
create_user_interactive() {
    log_info "创建Matrix用户..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在"
        return 1
    fi
    
    source "$config_file"
    
    read -p "用户名: " username
    while [[ -z "$username" ]]; do
        log_error "用户名不能为空"
        read -p "用户名: " username
    done
    
    read -p "是否为管理员? (y/N): " is_admin
    
    local admin_flag=""
    if [[ "$is_admin" == "y" || "$is_admin" == "Y" ]]; then
        admin_flag="--admin"
    fi
    
    # 使用MAS创建用户
    log_info "创建用户: $username"
    kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
        mas-cli manage register-user --username "$username" $admin_flag
    
    log_info "用户创建完成"
    log_info "用户ID: @$username:$DOMAIN"
}

# 用户管理
manage_users() {
    log_info "用户管理功能..."
    
    echo "用户管理选项:"
    echo "1. 列出所有用户"
    echo "2. 禁用用户"
    echo "3. 启用用户"
    echo "4. 删除用户"
    echo "5. 重置用户密码"
    read -p "请选择 [1-5]: " user_action
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    case $user_action in
        1)
            log_info "列出所有用户..."
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage list-users
            ;;
        2)
            read -p "要禁用的用户名: " username
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage disable-user --username "$username"
            ;;
        3)
            read -p "要启用的用户名: " username
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage enable-user --username "$username"
            ;;
        4)
            read -p "要删除的用户名: " username
            log_warn "删除用户是不可逆操作"
            read -p "确认删除用户 $username? (y/N): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                    mas-cli manage delete-user --username "$username"
            fi
            ;;
        5)
            read -p "要重置密码的用户名: " username
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage reset-password --username "$username"
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# 备份数据
backup_data() {
    log_info "备份Matrix数据..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
        INSTALL_DIR="/opt/matrix"
    fi
    
    local backup_dir="$INSTALL_DIR/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    log_info "备份目录: $backup_dir"
    
    # 备份配置文件
    log_info "备份配置文件..."
    cp -r "$SCRIPT_DIR/config" "$backup_dir/"
    
    # 备份数据库
    log_info "备份数据库..."
    kubectl exec -n "$NAMESPACE" deployment/postgresql -- \
        pg_dumpall -U postgres > "$backup_dir/database_backup.sql"
    
    # 备份媒体文件
    log_info "备份媒体文件..."
    kubectl cp "$NAMESPACE/matrix-synapse:/data/media" "$backup_dir/media" 2>/dev/null || \
        log_warn "媒体文件备份失败或不存在"
    
    # 创建备份信息文件
    cat > "$backup_dir/backup_info.txt" << EOF
备份时间: $(date)
Matrix域名: $DOMAIN
命名空间: $NAMESPACE
备份版本: $VERSION
EOF
    
    log_info "数据备份完成: $backup_dir"
}

# 恢复数据
restore_data() {
    log_warn "恢复Matrix数据..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        INSTALL_DIR="/opt/matrix"
    fi
    
    # 列出可用备份
    local backup_base="$INSTALL_DIR/backups"
    if [[ ! -d "$backup_base" ]]; then
        log_error "备份目录不存在: $backup_base"
        return 1
    fi
    
    echo "可用备份:"
    local backups=($(ls -1 "$backup_base" 2>/dev/null | sort -r))
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        log_error "未找到任何备份"
        return 1
    fi
    
    local i=1
    for backup in "${backups[@]}"; do
        echo "$i. $backup"
        ((i++))
    done
    
    read -p "选择要恢复的备份 [1-$((i-1))]: " backup_choice
    
    if [[ "$backup_choice" -ge 1 && "$backup_choice" -le $((i-1)) ]]; then
        local selected_backup="${backups[$((backup_choice-1))]}"
        local backup_path="$backup_base/$selected_backup"
        
        log_warn "即将恢复备份: $selected_backup"
        log_warn "这将覆盖当前所有数据！"
        read -p "确认恢复? (y/N): " confirm
        
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            log_info "恢复数据中..."
            
            # 停止服务
            stop_services
            
            # 恢复配置
            if [[ -d "$backup_path/config" ]]; then
                cp -r "$backup_path/config"/* "$SCRIPT_DIR/config/"
                log_info "配置文件已恢复"
            fi
            
            # 恢复数据库
            if [[ -f "$backup_path/database_backup.sql" ]]; then
                kubectl exec -i -n "$NAMESPACE" deployment/postgresql -- \
                    psql -U postgres < "$backup_path/database_backup.sql"
                log_info "数据库已恢复"
            fi
            
            # 启动服务
            start_services
            
            log_info "数据恢复完成"
        else
            log_info "恢复操作已取消"
        fi
    else
        log_error "无效选择"
    fi
}

# 系统维护菜单
show_maintenance_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}     系统维护${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} 清理部署环境"
    echo -e "${GREEN}2.${NC} 更新系统组件"
    echo -e "${GREEN}3.${NC} 检查系统健康"
    echo -e "${GREEN}4.${NC} 优化系统性能"
    echo -e "${GREEN}5.${NC} 清理日志文件"
    echo -e "${GREEN}6.${NC} 检查磁盘使用"
    echo -e "${GREEN}7.${NC} 运行测试脚本"
    echo -e "${RED}0.${NC} 返回主菜单"
    echo
    echo -e "${YELLOW}请选择操作:${NC} "
}

# 处理系统维护
handle_maintenance_menu() {
    while true; do
        show_maintenance_menu
        read -r choice
        
        case $choice in
            1)
                cleanup_deployment
                read -p "按回车键继续..."
                ;;
            2)
                update_components
                read -p "按回车键继续..."
                ;;
            3)
                check_system_health
                read -p "按回车键继续..."
                ;;
            4)
                optimize_performance
                read -p "按回车键继续..."
                ;;
            5)
                cleanup_logs
                read -p "按回车键继续..."
                ;;
            6)
                check_disk_usage
                read -p "按回车键继续..."
                ;;
            7)
                if [[ -f "$SCRIPT_DIR/test-deployment.sh" ]]; then
                    "$SCRIPT_DIR/test-deployment.sh"
                else
                    log_error "测试脚本不存在"
                fi
                read -p "按回车键继续..."
                ;;
            0)
                return
                ;;
            *)
                log_error "无效选择，请重新输入"
                sleep 1
                ;;
        esac
    done
}

# 清理部署环境
cleanup_deployment() {
    log_warn "清理Matrix部署环境..."
    
    read -p "确认清理所有Matrix服务和数据? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 删除Helm发布
    log_info "删除Helm发布..."
    helm uninstall matrix-stack -n "$NAMESPACE" 2>/dev/null || true
    
    # 删除命名空间
    log_info "删除命名空间..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    
    # 删除证书
    log_info "删除证书..."
    kubectl delete clusterissuer --all --ignore-not-found=true
    
    # 删除PVC
    log_info "删除持久卷..."
    kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found=true
    
    log_info "环境清理完成"
}

# 更新系统组件
update_components() {
    log_info "更新系统组件..."
    
    # 更新包列表
    sudo apt-get update -qq
    
    # 更新Helm仓库
    if command -v helm &>/dev/null; then
        log_info "更新Helm仓库..."
        helm repo update
    fi
    
    # 检查K3s更新
    if command -v k3s &>/dev/null; then
        log_info "检查K3s版本..."
        local current_version=$(k3s --version | head -n1)
        log_info "当前K3s版本: $current_version"
    fi
    
    log_info "组件更新检查完成"
}

# 检查系统健康
check_system_health() {
    log_info "检查系统健康状态..."
    
    # 检查系统负载
    echo -e "${CYAN}=== 系统负载 ===${NC}"
    uptime
    
    # 检查内存使用
    echo -e "${CYAN}=== 内存使用 ===${NC}"
    free -h
    
    # 检查磁盘使用
    echo -e "${CYAN}=== 磁盘使用 ===${NC}"
    df -h
    
    # 检查网络连接
    echo -e "${CYAN}=== 网络连接 ===${NC}"
    ss -tuln | head -10
    
    # 检查Kubernetes健康
    if command -v kubectl &>/dev/null; then
        echo -e "${CYAN}=== Kubernetes节点 ===${NC}"
        kubectl get nodes
        
        echo -e "${CYAN}=== 系统Pod ===${NC}"
        kubectl get pods -n kube-system
    fi
}

# 优化系统性能
optimize_performance() {
    log_info "优化系统性能..."
    
    # 清理包缓存
    log_info "清理包缓存..."
    sudo apt-get autoremove -y
    sudo apt-get autoclean
    
    # 清理Docker镜像
    if command -v docker &>/dev/null; then
        log_info "清理Docker镜像..."
        sudo docker system prune -f
    fi
    
    # 清理Kubernetes资源
    if command -v kubectl &>/dev/null; then
        log_info "清理Kubernetes资源..."
        kubectl delete pods --field-selector=status.phase=Succeeded --all-namespaces
        kubectl delete pods --field-selector=status.phase=Failed --all-namespaces
    fi
    
    log_info "性能优化完成"
}

# 清理日志文件
cleanup_logs() {
    log_info "清理日志文件..."
    
    # 清理系统日志
    sudo journalctl --vacuum-time=7d
    
    # 清理旧日志文件
    sudo find /var/log -name "*.log" -mtime +7 -delete 2>/dev/null || true
    
    log_info "日志清理完成"
}

# 检查磁盘使用
check_disk_usage() {
    log_info "检查磁盘使用情况..."
    
    echo -e "${CYAN}=== 磁盘使用概览 ===${NC}"
    df -h
    
    echo -e "${CYAN}=== 大文件查找 ===${NC}"
    sudo find / -type f -size +100M 2>/dev/null | head -10
    
    echo -e "${CYAN}=== 目录大小 ===${NC}"
    du -sh /var/log /tmp /opt 2>/dev/null || true
    
    if command -v kubectl &>/dev/null; then
        echo -e "${CYAN}=== Kubernetes存储 ===${NC}"
        kubectl get pv,pvc --all-namespaces
    fi
}

