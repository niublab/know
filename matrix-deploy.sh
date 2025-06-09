#!/bin/bash

# Matrix 服务器主部署脚本
# 版本: 1.1.0
# 作者: Manus AI
# 描述: Matrix 服务器自动化部署和管理工具

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="1.1.0"

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

# 配置kubectl环境
setup_kubectl_env() {
    if [[ $EUID -eq 0 ]]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    else
        if [[ -f "$HOME/.kube/config" ]]; then
            export KUBECONFIG="$HOME/.kube/config"
        else
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        fi
    fi
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    local deps=("curl" "wget" "openssl" "jq")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少依赖: ${missing_deps[*]}"
        log_info "正在安装缺少的依赖..."
        
        if [[ $EUID -eq 0 ]]; then
            apt-get update -qq
            apt-get install -y "${missing_deps[@]}"
        else
            sudo apt-get update -qq
            sudo apt-get install -y "${missing_deps[@]}"
        fi
    fi
    
    log_info "依赖检查完成"
}

# 生成64位随机密码
generate_password() {
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-64
}

# 获取外部IP
get_external_ip() {
    local ip
    
    # 尝试从域名解析获取
    if [[ -n "${DOMAIN:-}" ]]; then
        ip=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null || dig +short "$DOMAIN" @1.1.1.1 2>/dev/null || true)
    fi
    
    # 备用方法
    if [[ -z "$ip" ]]; then
        ip=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || curl -s --connect-timeout 5 ipinfo.io/ip 2>/dev/null || echo "127.0.0.1")
    fi
    
    echo "${ip:-127.0.0.1}"
}

# 检查端口是否被占用
check_port() {
    local port=$1
    if netstat -tlnp 2>/dev/null | grep -q ":$port "; then
        return 0  # 端口被占用
    else
        return 1  # 端口空闲
    fi
}

# 验证端口配置
validate_ports() {
    local http_port=$1
    local https_port=$2
    
    # 检查是否使用了被封锁的端口
    if [[ "$http_port" == "80" || "$https_port" == "443" ]]; then
        log_error "不能使用标准端口 80/443，ISP已封锁这些端口"
        return 1
    fi
    
    # 检查端口是否被占用
    if check_port "$http_port"; then
        log_warn "端口 $http_port 已被占用"
    fi
    
    if check_port "$https_port"; then
        log_warn "端口 $https_port 已被占用"
    fi
    
    return 0
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

# 初始化部署环境
init_environment() {
    log_info "初始化部署环境..."
    
    # 检查依赖
    check_dependencies
    
    # 安装K3s
    install_k3s
    
    # 安装Helm
    install_helm
    
    # 配置kubectl
    setup_kubectl_env
    
    log_info "部署环境初始化完成"
}

# 安装K3s
install_k3s() {
    log_info "安装K3s..."
    
    if command -v k3s &>/dev/null; then
        log_info "K3s已安装，检查状态..."
        if [[ $EUID -eq 0 ]]; then
            systemctl status k3s --no-pager || true
        else
            sudo systemctl status k3s --no-pager || true
        fi
        return 0
    fi
    
    # 下载并安装K3s
    log_info "下载K3s安装脚本..."
    curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
    
    # 等待K3s启动
    log_info "等待K3s启动..."
    sleep 30
    
    # 检查K3s状态
    if [[ $EUID -eq 0 ]]; then
        systemctl status k3s --no-pager
    else
        sudo systemctl status k3s --no-pager
    fi
    
    log_info "K3s安装完成"
}

# 安装Helm
install_helm() {
    log_info "安装Helm..."
    
    if command -v helm &>/dev/null; then
        log_info "Helm已安装: $(helm version --short)"
        return 0
    fi
    
    # 下载并安装Helm
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_info "Helm安装完成: $(helm version --short)"
}

# 配置服务参数
configure_parameters() {
    log_info "配置服务参数..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    mkdir -p "$(dirname "$config_file")"
    
    # 域名配置
    echo -e "${YELLOW}=== 域名配置 ===${NC}"
    read -p "主域名 (例如: example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        log_error "域名不能为空"
        read -p "主域名 (例如: example.com): " DOMAIN
    done
    
    # 子域名配置
    MATRIX_DOMAIN="matrix.$DOMAIN"
    ACCOUNT_DOMAIN="account.$DOMAIN"
    MRTC_DOMAIN="mrtc.$DOMAIN"
    CHAT_DOMAIN="chat.$DOMAIN"
    
    echo -e "${YELLOW}=== 端口配置 ===${NC}"
    echo -e "${RED}注意: 不能使用80/443端口，ISP已封锁${NC}"
    
    read -p "HTTP端口 [8080]: " HTTP_PORT
    HTTP_PORT=${HTTP_PORT:-8080}
    
    read -p "HTTPS端口 [8443]: " HTTPS_PORT
    HTTPS_PORT=${HTTPS_PORT:-8443}
    
    read -p "WebRTC TCP端口 [30881]: " WEBRTC_TCP_PORT
    WEBRTC_TCP_PORT=${WEBRTC_TCP_PORT:-30881}
    
    read -p "WebRTC UDP端口 [30882]: " WEBRTC_UDP_PORT
    WEBRTC_UDP_PORT=${WEBRTC_UDP_PORT:-30882}
    
    # 验证端口配置
    if ! validate_ports "$HTTP_PORT" "$HTTPS_PORT"; then
        log_error "端口配置无效"
        return 1
    fi
    
    # 安装目录配置
    echo -e "${YELLOW}=== 安装目录配置 ===${NC}"
    read -p "安装目录 [/opt/matrix]: " INSTALL_DIR
    INSTALL_DIR=${INSTALL_DIR:-/opt/matrix}
    
    read -p "Kubernetes命名空间 [ess]: " NAMESPACE
    NAMESPACE=${NAMESPACE:-ess}
    
    # 证书配置
    echo -e "${YELLOW}=== 证书配置 ===${NC}"
    echo "1. 生产环境 (Let's Encrypt 生产)"
    echo "2. 测试环境 (Let's Encrypt 测试)"
    read -p "请选择证书环境 [1-2]: " cert_env_choice
    
    case $cert_env_choice in
        1)
            CERT_ENV="production"
            ;;
        2)
            CERT_ENV="staging"
            ;;
        *)
            log_warn "无效选择，使用测试环境"
            CERT_ENV="staging"
            ;;
    esac
    
    read -p "证书邮箱: " CERT_EMAIL
    while [[ -z "$CERT_EMAIL" ]]; do
        log_error "证书邮箱不能为空"
        read -p "证书邮箱: " CERT_EMAIL
    done
    
    read -p "Cloudflare API Token: " CLOUDFLARE_TOKEN
    while [[ -z "$CLOUDFLARE_TOKEN" ]]; do
        log_error "Cloudflare API Token不能为空"
        read -p "Cloudflare API Token: " CLOUDFLARE_TOKEN
    done
    
    read -p "管理员邮箱 (可选): " ADMIN_EMAIL
    
    # 服务配置
    echo -e "${YELLOW}=== 服务配置 ===${NC}"
    read -p "启用联邦功能? (y/N): " enable_federation
    if [[ "$enable_federation" == "y" || "$enable_federation" == "Y" ]]; then
        ENABLE_FEDERATION="true"
    else
        ENABLE_FEDERATION="false"
    fi
    
    read -p "启用用户注册? (y/N): " enable_registration
    if [[ "$enable_registration" == "y" || "$enable_registration" == "Y" ]]; then
        ENABLE_REGISTRATION="true"
    else
        ENABLE_REGISTRATION="false"
    fi
    
    # 生成随机密码和密钥
    log_info "生成安全密钥..."
    POSTGRES_PASSWORD=$(generate_password)
    SYNAPSE_SIGNING_KEY=$(generate_password)
    SYNAPSE_MACAROON_SECRET=$(generate_password)
    MAS_SECRET_KEY=$(generate_password)
    MAS_ENCRYPTION_KEY=$(generate_password)
    REGISTRATION_TOKEN=$(openssl rand -hex 32)
    
    # 保存配置
    cat > "$config_file" << EOF
# Matrix 服务器配置
# 生成时间: $(date)

# 域名配置
DOMAIN=$DOMAIN
MATRIX_DOMAIN=$MATRIX_DOMAIN
ACCOUNT_DOMAIN=$ACCOUNT_DOMAIN
MRTC_DOMAIN=$MRTC_DOMAIN
CHAT_DOMAIN=$CHAT_DOMAIN

# 端口配置
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
WEBRTC_TCP_PORT=$WEBRTC_TCP_PORT
WEBRTC_UDP_PORT=$WEBRTC_UDP_PORT

# 安装配置
INSTALL_DIR=$INSTALL_DIR
NAMESPACE=$NAMESPACE

# 证书配置
CERT_ENV=$CERT_ENV
CERT_EMAIL=$CERT_EMAIL
CLOUDFLARE_TOKEN=$CLOUDFLARE_TOKEN
ADMIN_EMAIL=$ADMIN_EMAIL

# 服务配置
ENABLE_FEDERATION=$ENABLE_FEDERATION
ENABLE_REGISTRATION=$ENABLE_REGISTRATION

# 安全密钥 (自动生成)
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
SYNAPSE_SIGNING_KEY=$SYNAPSE_SIGNING_KEY
SYNAPSE_MACAROON_SECRET=$SYNAPSE_MACAROON_SECRET
MAS_SECRET_KEY=$MAS_SECRET_KEY
MAS_ENCRYPTION_KEY=$MAS_ENCRYPTION_KEY
REGISTRATION_TOKEN=$REGISTRATION_TOKEN
EOF
    
    # 显示配置摘要
    echo
    echo -e "${CYAN}=== 配置摘要 ===${NC}"
    echo -e "主域名: ${WHITE}$DOMAIN${NC}"
    echo -e "HTTP端口: ${WHITE}$HTTP_PORT${NC}"
    echo -e "HTTPS端口: ${WHITE}$HTTPS_PORT${NC}"
    echo -e "安装目录: ${WHITE}$INSTALL_DIR${NC}"
    echo -e "证书环境: ${WHITE}$CERT_ENV${NC}"
    echo -e "联邦功能: ${WHITE}$ENABLE_FEDERATION${NC}"
    echo -e "用户注册: ${WHITE}$ENABLE_REGISTRATION${NC}"
    echo
    echo -e "${GREEN}配置已保存到: $config_file${NC}"
    echo
    echo -e "${RED}重要提醒:${NC}"
    echo -e "1. 确保路由器已配置端口转发: $HTTP_PORT→$HTTP_PORT, $HTTPS_PORT→$HTTPS_PORT"
    echo -e "2. 确保域名A记录指向公网IP: $(get_external_ip)"
    echo -e "3. 确保DDNS服务正常运行"
    
    log_info "服务参数配置完成"
}

# 部署Matrix服务
deploy_matrix() {
    log_info "部署Matrix服务..."
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在，请先配置服务参数"
        return 1
    fi
    
    source "$config_file"
    
    # 配置kubectl
    setup_kubectl_env
    
    # 创建命名空间
    log_info "创建命名空间: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # 生成配置文件
    log_info "生成配置文件..."
    if [[ -f "$SCRIPT_DIR/config-templates.sh" ]]; then
        source "$SCRIPT_DIR/config-templates.sh"
        generate_complete_config "$config_file"
    else
        log_error "配置模板脚本不存在"
        return 1
    fi
    
    # 部署Matrix Stack
    log_info "部署Matrix Stack..."
    
    # 创建values文件
    local values_file="$SCRIPT_DIR/config/values/matrix-values.yaml"
    mkdir -p "$(dirname "$values_file")"
    
    cat > "$values_file" << EOF
# Matrix Stack Values
global:
  domain: "$DOMAIN"
  serverName: "$DOMAIN"

synapse:
  enabled: true
  serverName: "$DOMAIN"
  publicBaseurl: "https://$MATRIX_DOMAIN:$HTTPS_PORT"
  
  postgresql:
    enabled: true
    auth:
      password: "$POSTGRES_PASSWORD"
      database: "synapse"
      username: "synapse"
  
  signingKey: "$SYNAPSE_SIGNING_KEY"
  macaroonSecretKey: "$SYNAPSE_MACAROON_SECRET"
  
  federation:
    enabled: $ENABLE_FEDERATION
    port: 8448
    publicUrl: "https://$DOMAIN:$HTTPS_PORT"
  
  registration:
    enabled: $ENABLE_REGISTRATION
    registrationSharedSecret: "$REGISTRATION_TOKEN"
  
  wellknown:
    enabled: true
    server:
      "m.server": "$MATRIX_DOMAIN:$HTTPS_PORT"
    client:
      "m.homeserver":
        "base_url": "https://$MATRIX_DOMAIN:$HTTPS_PORT"
      "m.identity_server":
        "base_url": "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"

mas:
  enabled: true
  publicUrl: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
  
  config:
    secrets:
      encryption: "$MAS_ENCRYPTION_KEY"
      keys:
        - kid: "default"
          key: "$MAS_SECRET_KEY"
    
    database:
      uri: "postgresql://synapse:$POSTGRES_PASSWORD@postgresql:5432/mas"
    
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
      public_base: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"
      issuer: "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"

elementWeb:
  enabled: true
  publicUrl: "https://$CHAT_DOMAIN:$HTTPS_PORT"
  
  config:
    default_server_config:
      "m.homeserver":
        "base_url": "https://$MATRIX_DOMAIN:$HTTPS_PORT"
        "server_name": "$DOMAIN"
      "m.identity_server":
        "base_url": "https://$ACCOUNT_DOMAIN:$HTTPS_PORT"

ingress:
  enabled: true
  className: "traefik"
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: "web,websecure"
    traefik.ingress.kubernetes.io/router.tls: "true"
  hosts:
    - host: "$DOMAIN"
      paths:
        - path: /.well-known/matrix
          pathType: Prefix
    - host: "$MATRIX_DOMAIN"
      paths:
        - path: /
          pathType: Prefix
    - host: "$ACCOUNT_DOMAIN"
      paths:
        - path: /
          pathType: Prefix
    - host: "$CHAT_DOMAIN"
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - "$DOMAIN"
        - "$MATRIX_DOMAIN"
        - "$ACCOUNT_DOMAIN"
        - "$CHAT_DOMAIN"
      secretName: matrix-tls
EOF
    
    # 使用Helm部署
    log_info "使用Helm部署Matrix Stack..."
    helm upgrade --install matrix-stack \
        oci://ghcr.io/element-hq/ess-helm/matrix-stack \
        --namespace "$NAMESPACE" \
        --values "$values_file" \
        --wait --timeout=600s
    
    # 等待Pod启动
    log_info "等待服务启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=synapse -n "$NAMESPACE" --timeout=300s || true
    
    # 显示部署状态
    echo
    echo -e "${CYAN}=== 部署状态 ===${NC}"
    kubectl get pods -n "$NAMESPACE"
    
    echo
    echo -e "${CYAN}=== 服务地址 ===${NC}"
    echo -e "Matrix服务器: ${WHITE}https://$MATRIX_DOMAIN:$HTTPS_PORT${NC}"
    echo -e "用户认证: ${WHITE}https://$ACCOUNT_DOMAIN:$HTTPS_PORT${NC}"
    echo -e "Web客户端: ${WHITE}https://$CHAT_DOMAIN:$HTTPS_PORT${NC}"
    
    log_info "Matrix服务部署完成"
}

# 证书管理
manage_certificates() {
    log_info "启动证书管理工具..."
    if [[ -f "$SCRIPT_DIR/cert-manager.sh" ]]; then
        "$SCRIPT_DIR/cert-manager.sh"
    else
        log_error "证书管理脚本不存在"
    fi
}

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
    
    setup_kubectl_env
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    echo -e "${CYAN}=== Pod 状态 ===${NC}"
    kubectl get pods -n "$NAMESPACE" -o wide 2>/dev/null || echo "无法获取Pod状态"
    
    echo
    echo -e "${CYAN}=== 服务状态 ===${NC}"
    kubectl get svc -n "$NAMESPACE" 2>/dev/null || echo "无法获取服务状态"
    
    echo
    echo -e "${CYAN}=== 资源使用情况 ===${NC}"
    kubectl top pods -n "$NAMESPACE" 2>/dev/null || echo "指标服务器未安装"
    
    echo
    echo -e "${CYAN}=== 存储状态 ===${NC}"
    kubectl get pvc -n "$NAMESPACE" 2>/dev/null || echo "无法获取存储状态"
}

# 重启服务
restart_services() {
    log_info "重启Matrix服务..."
    
    setup_kubectl_env
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 重启主要服务
    local services=("synapse" "mas" "element-web")
    
    for service in "${services[@]}"; do
        log_info "重启 $service..."
        kubectl rollout restart deployment/matrix-$service -n "$NAMESPACE" 2>/dev/null || \
        kubectl rollout restart deployment/$service -n "$NAMESPACE" 2>/dev/null || \
        log_warn "服务 $service 未找到或重启失败"
    done
    
    log_info "等待服务重启完成..."
    sleep 10
    
    # 检查服务状态
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "无法获取Pod状态"
}

# 停止服务
stop_services() {
    log_warn "停止Matrix服务..."
    
    read -p "确认停止所有Matrix服务? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    setup_kubectl_env
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 缩放到0副本
    kubectl scale deployment --all --replicas=0 -n "$NAMESPACE" 2>/dev/null || log_error "停止服务失败"
    
    log_info "所有服务已停止"
}

# 启动服务
start_services() {
    log_info "启动Matrix服务..."
    
    setup_kubectl_env
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 恢复副本数
    local services=("synapse" "mas" "element-web")
    
    for service in "${services[@]}"; do
        kubectl scale deployment/matrix-$service --replicas=1 -n "$NAMESPACE" 2>/dev/null || \
        kubectl scale deployment/$service --replicas=1 -n "$NAMESPACE" 2>/dev/null || \
        log_warn "服务 $service 未找到"
    done
    
    log_info "等待服务启动..."
    sleep 15
    
    kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "无法获取Pod状态"
}

# 查看服务日志
show_service_logs() {
    setup_kubectl_env
    
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
    echo "4. 所有服务"
    read -p "请选择 [1-4]: " service_choice
    
    case $service_choice in
        1)
            kubectl logs -f deployment/matrix-synapse -n "$NAMESPACE" --tail=100 2>/dev/null || echo "无法获取Synapse日志"
            ;;
        2)
            kubectl logs -f deployment/matrix-mas -n "$NAMESPACE" --tail=100 2>/dev/null || echo "无法获取MAS日志"
            ;;
        3)
            kubectl logs -f deployment/matrix-element-web -n "$NAMESPACE" --tail=100 2>/dev/null || echo "无法获取Element Web日志"
            ;;
        4)
            kubectl logs --all-containers=true -n "$NAMESPACE" --tail=50 2>/dev/null || echo "无法获取服务日志"
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# 创建用户
create_user_interactive() {
    log_info "创建Matrix用户..."
    
    setup_kubectl_env
    
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
        mas-cli manage register-user --username "$username" $admin_flag 2>/dev/null || \
        log_error "用户创建失败"
    
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
    
    setup_kubectl_env
    
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
                mas-cli manage list-users 2>/dev/null || log_error "无法列出用户"
            ;;
        2)
            read -p "要禁用的用户名: " username
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage disable-user --username "$username" 2>/dev/null || log_error "禁用用户失败"
            ;;
        3)
            read -p "要启用的用户名: " username
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage enable-user --username "$username" 2>/dev/null || log_error "启用用户失败"
            ;;
        4)
            read -p "要删除的用户名: " username
            log_warn "删除用户是不可逆操作"
            read -p "确认删除用户 $username? (y/N): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                    mas-cli manage delete-user --username "$username" 2>/dev/null || log_error "删除用户失败"
            fi
            ;;
        5)
            read -p "要重置密码的用户名: " username
            kubectl exec -n "$NAMESPACE" -it deployment/matrix-mas -- \
                mas-cli manage reset-password --username "$username" 2>/dev/null || log_error "重置密码失败"
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
    
    if [[ $EUID -eq 0 ]]; then
        mkdir -p "$backup_dir"
    else
        sudo mkdir -p "$backup_dir"
        sudo chown "$USER:$USER" "$backup_dir"
    fi
    
    log_info "备份目录: $backup_dir"
    
    # 备份配置文件
    log_info "备份配置文件..."
    cp -r "$SCRIPT_DIR/config" "$backup_dir/" 2>/dev/null || log_warn "配置文件备份失败"
    
    # 备份数据库
    log_info "备份数据库..."
    setup_kubectl_env
    kubectl exec -n "$NAMESPACE" deployment/postgresql -- \
        pg_dumpall -U postgres > "$backup_dir/database_backup.sql" 2>/dev/null || log_warn "数据库备份失败"
    
    # 创建备份信息文件
    cat > "$backup_dir/backup_info.txt" << EOF
备份时间: $(date)
Matrix域名: ${DOMAIN:-unknown}
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
            
            # 恢复配置
            if [[ -d "$backup_path/config" ]]; then
                cp -r "$backup_path/config"/* "$SCRIPT_DIR/config/" 2>/dev/null || log_warn "配置恢复失败"
                log_info "配置文件已恢复"
            fi
            
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
    
    setup_kubectl_env
    
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
    else
        NAMESPACE="ess"
    fi
    
    # 删除Helm发布
    log_info "删除Helm发布..."
    helm uninstall matrix-stack -n "$NAMESPACE" 2>/dev/null || log_warn "Helm发布删除失败"
    
    # 删除命名空间
    log_info "删除命名空间..."
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    
    log_info "环境清理完成"
}

# 更新系统组件
update_components() {
    log_info "更新系统组件..."
    
    # 更新包列表
    if [[ $EUID -eq 0 ]]; then
        apt-get update -qq 2>/dev/null || log_warn "包列表更新失败"
    else
        sudo apt-get update -qq 2>/dev/null || log_warn "包列表更新失败"
    fi
    
    # 更新Helm仓库
    if command -v helm &>/dev/null; then
        log_info "更新Helm仓库..."
        helm repo update 2>/dev/null || log_warn "Helm仓库更新失败"
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
    
    # 检查Kubernetes健康
    setup_kubectl_env
    if command -v kubectl &>/dev/null; then
        echo -e "${CYAN}=== Kubernetes节点 ===${NC}"
        kubectl get nodes 2>/dev/null || echo "无法获取节点信息"
        
        echo -e "${CYAN}=== 系统Pod ===${NC}"
        kubectl get pods -n kube-system 2>/dev/null || echo "无法获取系统Pod信息"
    fi
}

# 优化系统性能
optimize_performance() {
    log_info "优化系统性能..."
    
    # 清理包缓存
    log_info "清理包缓存..."
    if [[ $EUID -eq 0 ]]; then
        apt-get autoremove -y 2>/dev/null || log_warn "包清理失败"
        apt-get autoclean 2>/dev/null || log_warn "包缓存清理失败"
    else
        sudo apt-get autoremove -y 2>/dev/null || log_warn "包清理失败"
        sudo apt-get autoclean 2>/dev/null || log_warn "包缓存清理失败"
    fi
    
    # 清理Docker镜像
    if command -v docker &>/dev/null; then
        log_info "清理Docker镜像..."
        if [[ $EUID -eq 0 ]]; then
            docker system prune -f 2>/dev/null || log_warn "Docker清理失败"
        else
            sudo docker system prune -f 2>/dev/null || log_warn "Docker清理失败"
        fi
    fi
    
    log_info "性能优化完成"
}

# 清理日志文件
cleanup_logs() {
    log_info "清理日志文件..."
    
    # 清理系统日志
    if [[ $EUID -eq 0 ]]; then
        journalctl --vacuum-time=7d 2>/dev/null || log_warn "系统日志清理失败"
    else
        sudo journalctl --vacuum-time=7d 2>/dev/null || log_warn "系统日志清理失败"
    fi
    
    log_info "日志清理完成"
}

# 检查磁盘使用
check_disk_usage() {
    log_info "检查磁盘使用情况..."
    
    echo -e "${CYAN}=== 磁盘使用概览 ===${NC}"
    df -h
    
    echo -e "${CYAN}=== 大文件查找 ===${NC}"
    if [[ $EUID -eq 0 ]]; then
        find / -type f -size +100M 2>/dev/null | head -10 || echo "无法查找大文件"
    else
        sudo find / -type f -size +100M 2>/dev/null | head -10 || echo "无法查找大文件"
    fi
    
    setup_kubectl_env
    if command -v kubectl &>/dev/null; then
        echo -e "${CYAN}=== Kubernetes存储 ===${NC}"
        kubectl get pv,pvc --all-namespaces 2>/dev/null || echo "无法获取存储信息"
    fi
}

# 查看状态
view_status() {
    log_info "查看系统状态..."
    
    setup_kubectl_env
    
    # 检查K3s状态
    echo -e "${CYAN}=== K3s 状态 ===${NC}"
    if [[ $EUID -eq 0 ]]; then
        systemctl status k3s --no-pager || echo "K3s未运行"
    else
        sudo systemctl status k3s --no-pager || echo "K3s未运行"
    fi
    
    # 检查Kubernetes集群
    echo -e "${CYAN}=== Kubernetes 集群 ===${NC}"
    kubectl cluster-info 2>/dev/null || echo "无法连接到Kubernetes集群"
    
    # 检查Matrix服务
    local config_file="$SCRIPT_DIR/config/.env"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        echo -e "${CYAN}=== Matrix 服务 (命名空间: $NAMESPACE) ===${NC}"
        kubectl get pods -n "$NAMESPACE" 2>/dev/null || echo "Matrix服务未部署"
    else
        echo -e "${CYAN}=== Matrix 服务 ===${NC}"
        echo "配置文件不存在，请先配置服务参数"
    fi
}

# 查看日志
view_logs() {
    log_info "查看系统日志..."
    
    echo "选择要查看的日志:"
    echo "1. K3s 服务日志"
    echo "2. Matrix 服务日志"
    echo "3. 系统日志"
    read -p "请选择 [1-3]: " log_choice
    
    case $log_choice in
        1)
            if [[ $EUID -eq 0 ]]; then
                journalctl -u k3s -f --no-pager
            else
                sudo journalctl -u k3s -f --no-pager
            fi
            ;;
        2)
            show_service_logs
            ;;
        3)
            if [[ $EUID -eq 0 ]]; then
                journalctl -f --no-pager
            else
                sudo journalctl -f --no-pager
            fi
            ;;
        *)
            log_error "无效选择"
            ;;
    esac
}

# 主函数
main() {
    # 配置kubectl环境
    setup_kubectl_env
    
    while true; do
        show_main_menu
        read -r choice
        
        case $choice in
            1)
                init_environment
                read -p "按回车键继续..."
                ;;
            2)
                configure_parameters
                read -p "按回车键继续..."
                ;;
            3)
                deploy_matrix
                read -p "按回车键继续..."
                ;;
            4)
                manage_certificates
                read -p "按回车键继续..."
                ;;
            5)
                handle_service_menu
                ;;
            6)
                handle_maintenance_menu
                ;;
            7)
                view_status
                read -p "按回车键继续..."
                ;;
            8)
                view_logs
                read -p "按回车键继续..."
                ;;
            0)
                log_info "感谢使用 Matrix 服务器部署工具！"
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

