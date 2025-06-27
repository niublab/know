#!/bin/bash

# Element ESS 内部服务器自动部署脚本 v2.0
# 此脚本将自动部署完整的Element ESS服务栈到内部服务器

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_FILE="/var/log/ess-deploy.log"
DOCKER_COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

warn() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
    exit 1
}

info() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

# 检查是否以root权限运行
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本需要root权限运行。请使用: sudo $0"
    fi
}

# 加载环境变量
load_env() {
    if [[ ! -f "$PACKAGE_ROOT/.env" ]]; then
        error "未找到.env配置文件。请先复制.env.template为.env并填入配置。"
    fi
    
    log "加载环境变量配置..."
    set -a  # 自动导出变量
    source "$PACKAGE_ROOT/.env"
    set +a
    
    # 验证必需的环境变量
    required_vars=(
        "MAIN_DOMAIN"
        "MATRIX_SUBDOMAIN" 
        "ELEMENT_SUBDOMAIN"
        "LIVEKIT_SUBDOMAIN"
        "CLOUDFLARE_API_TOKEN"
        "CLOUDFLARE_EMAIL"
        "LETSENCRYPT_EMAIL"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error "必需的环境变量 $var 未设置"
        fi
    done
}

# 检查系统环境
check_system() {
    log "检查系统环境..."
    
    # 检查操作系统
    if ! grep -q "ID=debian\|ID=ubuntu" /etc/os-release; then
        warn "此脚本主要为Debian/Ubuntu系统设计，其他系统可能需要手动调整"
    fi
    
    # 检查内存
    total_mem=$(free -m | awk 'NR==2{print $2}')
    if [[ $total_mem -lt 2048 ]]; then
        warn "建议至少4GB内存以获得最佳性能 (当前: ${total_mem}MB)"
    fi
    
    # 检查磁盘空间
    available_space=$(df / | awk 'NR==2 {print $4}')
    if [[ $available_space -lt 10485760 ]]; then  # 10GB in KB
        warn "建议至少20GB可用磁盘空间 (当前: $((available_space/1024/1024))GB)"
    fi
    
    # 检查网络连接
    if ! ping -c 1 8.8.8.8 > /dev/null 2>&1; then
        error "无法连接到互联网，请检查网络配置"
    fi
}

# 安装必要软件
install_dependencies() {
    log "安装系统依赖..."
    
    # 更新软件包列表
    apt update
    
    # 安装基础软件
    apt install -y \
        curl \
        wget \
        git \
        unzip \
        python3 \
        python3-pip \
        python3-venv \
        jq \
        openssl \
        ca-certificates \
        gnupg \
        lsb-release \
        apt-transport-https \
        software-properties-common
    
    # 安装Docker
    if ! command -v docker &> /dev/null; then
        log "安装Docker..."
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable docker
        systemctl start docker
    else
        log "Docker已安装"
    fi
    
    # 安装Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        log "安装Docker Compose..."
        curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    else
        log "Docker Compose已安装"
    fi
    
    # 安装certbot for DNS验证
    apt install -y certbot python3-certbot-dns-cloudflare
}

# 自动生成邮箱地址
generate_email_addresses() {
    log "生成邮箱地址..."
    
    # 生成Cloudflare邮箱
    if [[ "${CLOUDFLARE_EMAIL}" == "auto_generate" ]]; then
        CLOUDFLARE_EMAIL="acme@${MAIN_DOMAIN}"
        info "已生成Cloudflare邮箱: $CLOUDFLARE_EMAIL"
    fi
    
    # 生成Let's Encrypt邮箱
    if [[ "${LETSENCRYPT_EMAIL}" == "auto_generate" ]]; then
        LETSENCRYPT_EMAIL="acme@${MAIN_DOMAIN}"
        info "已生成Let's Encrypt邮箱: $LETSENCRYPT_EMAIL"
    fi
    
    # 更新.env文件
    sed -i "s/CLOUDFLARE_EMAIL=auto_generate/CLOUDFLARE_EMAIL=${CLOUDFLARE_EMAIL}/" "$PACKAGE_ROOT/.env"
    sed -i "s/LETSENCRYPT_EMAIL=auto_generate/LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}/" "$PACKAGE_ROOT/.env"
}

# 环境检测和系统优化
detect_and_optimize_environment() {
    log "检测和优化系统环境..."
    
    # 检测系统类型
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        SYSTEM_NAME="$NAME"
        SYSTEM_VERSION="$VERSION_ID"
        info "检测到系统: $SYSTEM_NAME $SYSTEM_VERSION"
    fi
    
    # 检测虚拟化环境
    if command -v systemd-detect-virt &> /dev/null; then
        VIRT_TYPE=$(systemd-detect-virt)
        if [[ "$VIRT_TYPE" != "none" ]]; then
            info "检测到虚拟化环境: $VIRT_TYPE"
        fi
    fi
    
    # 检测容器环境
    if [[ -f /.dockerenv ]]; then
        warn "检测到Docker容器环境，某些功能可能受限"
    fi
    
    # 检测网络环境
    if command -v ip &> /dev/null; then
        DEFAULT_ROUTE=$(ip route | grep default | head -n 1)
        if [[ -n "$DEFAULT_ROUTE" ]]; then
            DEFAULT_INTERFACE=$(echo "$DEFAULT_ROUTE" | awk '{print $5}')
            info "默认网络接口: $DEFAULT_INTERFACE"
        fi
    fi
    
    # 系统性能调优
    optimize_system_performance
}

# 系统性能优化
optimize_system_performance() {
    log "优化系统性能..."
    
    # 调整内核参数
    cat >> /etc/sysctl.conf << EOF

# Element ESS性能优化
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 10
fs.file-max = 65536
EOF
    
    sysctl -p &>/dev/null || warn "部分内核参数设置失败"
    
    # 调整ulimit
    cat >> /etc/security/limits.conf << EOF

# Element ESS资源限制
* soft nofile 65536
* hard nofile 65536
* soft nproc 32768
* hard nproc 32768
EOF
    
    info "系统性能优化完成"
}

# 智能依赖安装
install_dependencies_smart() {
    log "智能检测和安装系统依赖..."
    
    # 检测包管理器
    if command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
        UPDATE_CMD="apt update"
        INSTALL_CMD="apt install -y"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
        UPDATE_CMD="yum update -y"
        INSTALL_CMD="yum install -y"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
        UPDATE_CMD="dnf update -y"
        INSTALL_CMD="dnf install -y"
    else
        error "未找到支持的包管理器"
    fi
    
    info "检测到包管理器: $PKG_MANAGER"
    
    # 更新软件包列表
    if [[ "${AUTO_INSTALL_DEPENDENCIES}" == "true" ]]; then
        log "更新软件包列表..."
        $UPDATE_CMD
    fi
    
    # 基础软件包
    BASIC_PACKAGES=(
        curl
        wget
        git
        unzip
        python3
        python3-pip
        jq
        openssl
        ca-certificates
        gnupg
        lsb-release
        apt-transport-https
        software-properties-common
    )
    
    # 检测并安装缺失的包
    MISSING_PACKAGES=()
    for package in "${BASIC_PACKAGES[@]}"; do
        if ! command -v "$package" &> /dev/null && ! dpkg -l | grep -q "^ii  $package "; then
            MISSING_PACKAGES+=("$package")
        fi
    done
    
    if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
        log "安装缺失的软件包: ${MISSING_PACKAGES[*]}"
        if [[ "${AUTO_INSTALL_DEPENDENCIES}" == "true" ]]; then
            $INSTALL_CMD "${MISSING_PACKAGES[@]}"
        else
            warn "需要安装以下软件包: ${MISSING_PACKAGES[*]}"
            read -p "是否现在安装? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                $INSTALL_CMD "${MISSING_PACKAGES[@]}"
            else
                error "无法继续安装，缺少必要的依赖"
            fi
        fi
    else
        info "所有基础软件包已安装"
    fi
    
    # 安装Docker (智能检测)
    install_docker_smart
    
    # 安装Docker Compose
    install_docker_compose_smart
    
    # 安装certbot
    install_certbot_smart
    
    # 安装Python依赖
    install_python_dependencies
}

# 智能Docker安装
install_docker_smart() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version | cut -d' ' -f3 | tr -d ',')
        info "Docker已安装，版本: $DOCKER_VERSION"
        
        # 检查Docker是否运行
        if ! systemctl is-active --quiet docker; then
            log "启动Docker服务..."
            systemctl start docker
            systemctl enable docker
        fi
        return
    fi
    
    log "安装Docker..."
    
    # 根据系统类型安装Docker
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        # 添加Docker官方GPG密钥
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # 添加Docker仓库
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        # 安装Docker
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    else
        # 使用通用安装脚本
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm get-docker.sh
    fi
    
    # 启动并启用Docker
    systemctl enable docker
    systemctl start docker
    
    # 验证安装
    if docker --version &> /dev/null; then
        info "Docker安装成功: $(docker --version)"
    else
        error "Docker安装失败"
    fi
}

# 智能Docker Compose安装
install_docker_compose_smart() {
    if command -v docker-compose &> /dev/null; then
        COMPOSE_VERSION=$(docker-compose --version | cut -d' ' -f3 | tr -d ',')
        info "Docker Compose已安装，版本: $COMPOSE_VERSION"
        return
    fi
    
    log "安装Docker Compose..."
    
    # 获取最新版本号
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
    if [[ -z "$COMPOSE_VERSION" || "$COMPOSE_VERSION" == "null" ]]; then
        COMPOSE_VERSION="v2.24.0"  # 备用版本
        warn "无法获取最新版本，使用备用版本: $COMPOSE_VERSION"
    fi
    
    # 下载并安装
    curl -L "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # 验证安装
    if docker-compose --version &> /dev/null; then
        info "Docker Compose安装成功: $(docker-compose --version)"
    else
        error "Docker Compose安装失败"
    fi
}

# 智能certbot安装
install_certbot_smart() {
    if command -v certbot &> /dev/null; then
        info "Certbot已安装"
        return
    fi
    
    log "安装Certbot..."
    
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        apt install -y certbot python3-certbot-dns-cloudflare
    else
        # 使用pip安装
        pip3 install certbot certbot-dns-cloudflare
    fi
    
    # 验证安装
    if certbot --version &> /dev/null; then
        info "Certbot安装成功: $(certbot --version)"
    else
        error "Certbot安装失败"
    fi
}

# 安装Python依赖
install_python_dependencies() {
    log "安装Python依赖..."
    
    # 确保pip是最新版本
    python3 -m pip install --upgrade pip
    
    # 安装管理工具依赖
    pip3 install flask pyjwt requests pyyaml werkzeug
    
    info "Python依赖安装完成"
}

# 自动配置防火墙
configure_firewall_auto() {
    if [[ "${AUTO_CONFIGURE_FIREWALL}" != "true" ]]; then
        return
    fi
    
    log "自动配置防火墙..."
    
    # 检测防火墙类型
    if command -v ufw &> /dev/null; then
        configure_ufw_firewall
    elif command -v firewall-cmd &> /dev/null; then
        configure_firewalld
    elif command -v iptables &> /dev/null; then
        configure_iptables
    else
        warn "未检测到支持的防火墙，跳过防火墙配置"
    fi
}

# 配置UFW防火墙
configure_ufw_firewall() {
    log "配置UFW防火墙..."
    
    # 安装UFW (如果未安装)
    if ! command -v ufw &> /dev/null; then
        $INSTALL_CMD ufw
    fi
    
    # 重置防火墙规则
    ufw --force reset
    
    # 默认策略
    ufw default deny incoming
    ufw default allow outgoing
    
    # 允许SSH
    ufw allow ssh
    
    # 允许HTTP/HTTPS
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # 允许管理工具端口
    ufw allow "${ADMIN_TOOL_PORT:-8888}/tcp"
    
    # 允许TURN端口
    ufw allow "${TURN_PORT:-3478}/udp"
    ufw allow "${TURN_PORT:-3478}/tcp"
    ufw allow "${TURN_TLS_PORT:-5349}/tcp"
    
    # 允许RTC端口范围
    ufw allow 50000:60000/udp
    
    # 启用防火墙
    ufw --force enable
    
    info "UFW防火墙配置完成"
}

# 生成自动密钥
generate_secrets() {
    log "生成应用密钥..."
    
    # 生成PostgreSQL密码
    if [[ "${POSTGRES_PASSWORD}" == "auto_generated" ]]; then
        POSTGRES_PASSWORD=$(openssl rand -base64 32)
        info "已生成PostgreSQL密码"
    fi
    
    # 生成Synapse密钥
    if [[ "${REGISTRATION_SHARED_SECRET:-auto_generated}" == "auto_generated" ]]; then
        REGISTRATION_SHARED_SECRET=$(openssl rand -base64 32)
        info "已生成Synapse注册共享密钥"
    fi
    
    if [[ "${FORM_SECRET:-auto_generated}" == "auto_generated" ]]; then
        FORM_SECRET=$(openssl rand -base64 32)
        info "已生成Synapse表单密钥"
    fi
    
    # 生成LiveKit密钥
    if [[ "${LIVEKIT_API_KEY:-auto_generated}" == "auto_generated" ]]; then
        LIVEKIT_API_KEY=$(openssl rand -hex 16)
        info "已生成LiveKit API密钥"
    fi
    
    if [[ "${LIVEKIT_API_SECRET:-auto_generated}" == "auto_generated" ]]; then
        LIVEKIT_API_SECRET=$(openssl rand -base64 32)
        info "已生成LiveKit API密钥"
    fi
    
    # 生成Admin密码
    if [[ "${ADMIN_PASSWORD:-auto_generated}" == "auto_generated" ]]; then
        ADMIN_PASSWORD=$(openssl rand -base64 16)
        info "已生成Admin密码: $ADMIN_PASSWORD"
    fi
    
    # 生成Admin JWT密钥
    if [[ "${ADMIN_JWT_SECRET:-auto_generated}" == "auto_generated" ]]; then
        ADMIN_JWT_SECRET=$(openssl rand -hex 32)
        info "已生成Admin JWT密钥"
    fi
    
    # 保存生成的密钥到.env文件
    sed -i "s/POSTGRES_PASSWORD=auto_generated/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" "$PACKAGE_ROOT/.env"
    sed -i "s/REGISTRATION_SHARED_SECRET=auto_generated/REGISTRATION_SHARED_SECRET=${REGISTRATION_SHARED_SECRET}/" "$PACKAGE_ROOT/.env"
    sed -i "s/FORM_SECRET=auto_generated/FORM_SECRET=${FORM_SECRET}/" "$PACKAGE_ROOT/.env"
    sed -i "s/LIVEKIT_API_KEY=auto_generated/LIVEKIT_API_KEY=${LIVEKIT_API_KEY}/" "$PACKAGE_ROOT/.env"
    sed -i "s/LIVEKIT_API_SECRET=auto_generated/LIVEKIT_API_SECRET=${LIVEKIT_API_SECRET}/" "$PACKAGE_ROOT/.env"
    sed -i "s/ADMIN_PASSWORD=auto_generated/ADMIN_PASSWORD=${ADMIN_PASSWORD}/" "$PACKAGE_ROOT/.env"
    sed -i "s/ADMIN_JWT_SECRET=auto_generated/ADMIN_JWT_SECRET=${ADMIN_JWT_SECRET}/" "$PACKAGE_ROOT/.env"
}

# 创建目录结构
create_directories() {
    log "创建目录结构..."
    
    # 创建数据目录
    mkdir -p /opt/element-ess/{data,config,logs,certs,backups}
    mkdir -p /opt/element-ess/data/{synapse,postgres,livekit,element-web}
    mkdir -p /opt/element-ess/config/{synapse,livekit,element-web,nginx}
    mkdir -p /opt/element-ess/logs/{synapse,livekit,nginx}
    
    # 设置权限
    chown -R 991:991 /opt/element-ess/data/synapse
    chown -R 999:999 /opt/element-ess/data/postgres
    chmod -R 755 /opt/element-ess
}

# 配置Cloudflare DNS验证
setup_cloudflare_dns() {
    log "配置Cloudflare DNS验证..."
    
    # 创建Cloudflare凭据文件
    mkdir -p /root/.secrets
    cat > /root/.secrets/cloudflare.ini << EOF
# Cloudflare API credentials
dns_cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
EOF
    chmod 600 /root/.secrets/cloudflare.ini
    
    # 申请子域名证书
    log "申请子域名证书..."
    
    domains=(
        "${MATRIX_SUBDOMAIN}"
        "${ELEMENT_SUBDOMAIN}" 
        "${LIVEKIT_SUBDOMAIN}"
    )
    
    # 如果启用了MAS，添加认证服务域名
    if [[ -n "${MAS_SUBDOMAIN:-}" ]]; then
        domains+=("${MAS_SUBDOMAIN}")
    fi
    
    # 构建域名参数
    domain_args=""
    for domain in "${domains[@]}"; do
        domain_args="$domain_args -d $domain"
    done
    
    # 选择证书环境
    if [[ "${CERT_ENVIRONMENT}" == "production" ]]; then
        cert_args=""
        log "申请生产环境证书..."
    else
        cert_args="--staging"
        log "申请测试环境证书..."
    fi
    
    # 申请证书 (拒绝暴露邮箱)
    local certbot_args="--dns-cloudflare --dns-cloudflare-credentials /root/.secrets/cloudflare.ini --email ${LETSENCRYPT_EMAIL} --agree-tos --no-eff-email"
    
    # 如果设置了拒绝暴露邮箱，添加相应参数
    if [[ "${CERTBOT_NO_EFF_EMAIL:-true}" == "true" ]]; then
        certbot_args="$certbot_args --no-eff-email"
    fi
    
    certbot certonly $certbot_args $cert_args $domain_args
    
    # 设置自动续期
    cat > /etc/cron.d/certbot-renewal << EOF
# 自动续期证书并重启相关服务
0 2 * * * root certbot renew --quiet && docker-compose -f ${DOCKER_COMPOSE_FILE} restart nginx
EOF
}

# 检测WAN IP
detect_wan_ip() {
    log "检测WAN IP地址..."
    
    # 多种方法检测公网IP
    wan_ip=""
    
    # 方法1: 通过路由器API (如果配置了RouterOS)
    if [[ -n "${ROUTEROS_IP:-}" ]] && [[ -n "${ROUTEROS_USERNAME:-}" ]]; then
        # 这里可以添加RouterOS API调用
        info "尝试通过RouterOS API获取WAN IP..."
    fi
    
    # 方法2: 通过公共服务
    services=(
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
    )
    
    for service in "${services[@]}"; do
        if wan_ip=$(curl -s --connect-timeout 5 "$service" | tr -d '[:space:]'); then
            if [[ $wan_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                log "检测到WAN IP: $wan_ip"
                break
            fi
        fi
    done
    
    if [[ -z "$wan_ip" ]]; then
        error "无法检测WAN IP地址，请手动设置LIVEKIT_NODE_IP环境变量"
    fi
    
    # 更新LiveKit节点IP配置
    if [[ "${LIVEKIT_NODE_IP}" == "auto_detect" ]]; then
        LIVEKIT_NODE_IP="$wan_ip"
        sed -i "s/LIVEKIT_NODE_IP=auto_detect/LIVEKIT_NODE_IP=${wan_ip}/" "$PACKAGE_ROOT/.env"
    fi
}

# 生成配置文件
generate_configs() {
    log "生成应用配置文件..."
    
    # 生成Synapse配置
    cat > /opt/element-ess/config/synapse/homeserver.yaml << EOF
# Element ESS Synapse配置 v2.0
server_name: "${MATRIX_SERVER_NAME}"
pid_file: /data/homeserver.pid
web_client_location: https://${ELEMENT_SUBDOMAIN}/

listeners:
  - port: 8008
    tls: false
    type: http
    x_forwarded: true
    bind_addresses: ['::1', '127.0.0.1', '0.0.0.0']
    resources:
      - names: [client, federation]
        compress: false

database:
  name: psycopg2
  args:
    user: ${POSTGRES_USER}
    password: ${POSTGRES_PASSWORD}
    database: ${POSTGRES_DB}
    host: postgres
    port: 5432
    cp_min: ${DB_CP_MIN}
    cp_max: ${DB_CP_MAX}

log_config: "/config/log.config"
media_store_path: /data/media_store
registration_shared_secret: "${REGISTRATION_SHARED_SECRET}"
form_secret: "${FORM_SECRET}"

report_stats: false
macaroon_secret_key: "${FORM_SECRET}"
signing_key_path: "/data/signing.key"

trusted_key_servers:
  - server_name: "matrix.org"

# 启用注册 (根据配置)
enable_registration: ${ENABLE_REGISTRATION}
enable_registration_without_verification: false

# 联邦配置
federation_domain_whitelist: []

# TURN配置 - 指向LiveKit内置TURN
turn_uris:
  - "turn:${LIVEKIT_SUBDOMAIN}:${TURN_PORT}?transport=udp"
  - "turn:${LIVEKIT_SUBDOMAIN}:${TURN_PORT}?transport=tcp"
  - "turns:${LIVEKIT_SUBDOMAIN}:${TURN_TLS_PORT}?transport=tcp"

turn_shared_secret: "${LIVEKIT_API_SECRET}"
turn_username: "${TURN_USERNAME_PREFIX}"

# Element Call (Matrix RTC) 配置
experimental_features:
  msc3266_enabled: true
  msc3720_enabled: true

# 媒体配置
max_upload_size: "${MAX_UPLOAD_SIZE}M"
url_preview_enabled: ${ENABLE_URL_PREVIEWS}
url_preview_ip_range_blacklist:
  - '127.0.0.0/8'
  - '10.0.0.0/8'
  - '172.16.0.0/12'
  - '192.168.0.0/16'
  - '100.64.0.0/10'
  - '169.254.0.0/16'

# 安全配置
suppress_key_server_warning: true
EOF

    # 生成Synapse日志配置
    cat > /opt/element-ess/config/synapse/log.config << EOF
version: 1

formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'

handlers:
  file:
    class: logging.handlers.TimedRotatingFileHandler
    formatter: precise
    filename: /logs/homeserver.log
    when: midnight
    backupCount: 7
    encoding: utf8

  console:
    class: logging.StreamHandler
    formatter: precise

loggers:
    synapse.storage.SQL:
        level: INFO

root:
    level: ${LOG_LEVEL}
    handlers: [file, console]

disable_existing_loggers: false
EOF

    # 生成LiveKit配置 (启用内置TURN)
    cat > /opt/element-ess/config/livekit/livekit.yaml << EOF
# LiveKit配置 v2.0 - 启用内置TURN
port: ${LIVEKIT_PORT}
bind_addresses:
  - ""  # 监听所有接口

rtc:
  tcp_port: 7881
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
  # 关键：启用外部IP检测和TURN服务
  node_ip: "${LIVEKIT_NODE_IP}"

# 启用内置TURN服务器
turn:
  enabled: ${ENABLE_LIVEKIT_TURN}
  domain: "${LIVEKIT_SUBDOMAIN}"
  cert_file: "/certs/live/${MATRIX_SUBDOMAIN}/fullchain.pem"
  key_file: "/certs/live/${MATRIX_SUBDOMAIN}/privkey.pem"
  tls_port: ${TURN_TLS_PORT}
  udp_port: ${TURN_PORT}
  tcp_port: ${TURN_PORT}

keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}

logging:
  level: ${LOG_LEVEL}
  pion_level: info

development: false
EOF

    # 生成Element Web配置
    cat > /opt/element-ess/config/element-web/config.json << EOF
{
    "default_server_config": {
        "m.homeserver": {
            "base_url": "https://${MATRIX_SUBDOMAIN}",
            "server_name": "${MATRIX_SERVER_NAME}"
        }
    },
    "disable_custom_urls": false,
    "disable_guests": true,
    "disable_login_language_selector": false,
    "disable_3pid_login": false,
    "brand": "${ELEMENT_INSTANCE_NAME}",
    "integrations_ui_url": "https://scalar.vector.im/",
    "integrations_rest_url": "https://scalar.vector.im/api",
    "integrations_widgets_urls": [
        "https://scalar.vector.im/_matrix/integrations/v1",
        "https://scalar.vector.im/api",
        "https://scalar-staging.vector.im/_matrix/integrations/v1",
        "https://scalar-staging.vector.im/api",
        "https://scalar-staging.riot.im/scalar/api"
    ],
    "bug_report_endpoint_url": "https://element.io/bugreports/submit",
    "defaultCountryCode": "CN",
    "showLabsSettings": true,
    "features": {
        "feature_new_room_decoration_ui": true,
        "feature_pinning": true,
        "feature_custom_status": true,
        "feature_custom_tags": true,
        "feature_state_counters": true
    },
    "default_federate": ${ENABLE_FEDERATION},
    "default_theme": "light",
    "roomDirectory": {
        "servers": [
            "${MATRIX_SERVER_NAME}"
        ]
    },
    "enable_presence_by_hs_url": {
        "https://${MATRIX_SUBDOMAIN}": false
    },
    "element_call": {
        "url": "https://${LIVEKIT_SUBDOMAIN}",
        "participant_limit": 8,
        "brand": "Element Call"
    }
}
EOF

    # 生成Nginx配置
    cat > /opt/element-ess/config/nginx/default.conf << EOF
# Nginx配置 - 内部服务器
# 处理所有Element ESS服务的流量

# 限制上传大小
client_max_body_size ${MAX_UPLOAD_SIZE}M;

# Matrix服务 (Synapse)
server {
    listen 443 ssl http2;
    server_name ${MATRIX_SUBDOMAIN};
    
    ssl_certificate /certs/live/${MATRIX_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /certs/live/${MATRIX_SUBDOMAIN}/privkey.pem;
    
    # SSL配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-XSS-Protection "1; mode=block";
    
    location / {
        proxy_pass http://synapse:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

# Element Web客户端
server {
    listen 443 ssl http2;
    server_name ${ELEMENT_SUBDOMAIN};
    
    ssl_certificate /certs/live/${MATRIX_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /certs/live/${MATRIX_SUBDOMAIN}/privkey.pem;
    
    # SSL配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # 安全头
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
    
    location / {
        proxy_pass http://element-web:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

# LiveKit/Matrix-RTC服务
server {
    listen 443 ssl http2;
    server_name ${LIVEKIT_SUBDOMAIN};
    
    ssl_certificate /certs/live/${MATRIX_SUBDOMAIN}/fullchain.pem;
    ssl_certificate_key /certs/live/${MATRIX_SUBDOMAIN}/privkey.pem;
    
    # SSL配置
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # WebSocket支持
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    
    location / {
        proxy_pass http://livekit:${LIVEKIT_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 300s;
        proxy_read_timeout 300s;
    }
}

# HTTP重定向到HTTPS
server {
    listen 80;
    server_name ${MATRIX_SUBDOMAIN} ${ELEMENT_SUBDOMAIN} ${LIVEKIT_SUBDOMAIN};
    return 301 https://\$server_name\$request_uri;
}
EOF
}

# 生成Docker Compose配置
generate_docker_compose() {
    log "生成Docker Compose配置..."
    
    cat > "$DOCKER_COMPOSE_FILE" << 'EOF'
# Element ESS Docker Compose配置 v2.0
version: '3.8'

services:
  # PostgreSQL数据库
  postgres:
    image: postgres:15-alpine
    container_name: element-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: "--encoding=UTF-8 --lc-collate=C --lc-ctype=C"
    volumes:
      - /opt/element-ess/data/postgres:/var/lib/postgresql/data
    networks:
      - element-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 30s
      timeout: 10s
      retries: 3
    mem_limit: ${POSTGRES_MEMORY_LIMIT}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # Synapse Matrix服务器
  synapse:
    image: matrixdotorg/synapse:latest
    container_name: element-synapse
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      SYNAPSE_SERVER_NAME: ${MATRIX_SERVER_NAME}
      SYNAPSE_REPORT_STATS: "no"
    volumes:
      - /opt/element-ess/data/synapse:/data
      - /opt/element-ess/config/synapse:/config
      - /opt/element-ess/logs/synapse:/logs
    networks:
      - element-network
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8008/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    mem_limit: ${SYNAPSE_MEMORY_LIMIT}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # LiveKit SFU服务器 (启用内置TURN)
  livekit:
    image: livekit/livekit-server:latest
    container_name: element-livekit
    restart: unless-stopped
    command: --config /config/livekit.yaml
    volumes:
      - /opt/element-ess/config/livekit:/config
      - /etc/letsencrypt:/certs:ro
    ports:
      # LiveKit HTTP/WebSocket端口
      - "${LIVEKIT_PORT}:${LIVEKIT_PORT}"
      # RTC端口范围
      - "50000-60000:50000-60000/udp"
      # TURN端口 (当启用内置TURN时)
      - "${TURN_PORT}:${TURN_PORT}/udp"
      - "${TURN_PORT}:${TURN_PORT}/tcp"
      - "${TURN_TLS_PORT}:${TURN_TLS_PORT}/tcp"
    networks:
      - element-network
    environment:
      - LIVEKIT_CONFIG=/config/livekit.yaml
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:${LIVEKIT_PORT}/rtc || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    mem_limit: ${LIVEKIT_MEMORY_LIMIT}
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # Element Web客户端
  element-web:
    image: vectorim/element-web:latest
    container_name: element-web
    restart: unless-stopped
    volumes:
      - /opt/element-ess/config/element-web/config.json:/app/config.json:ro
    networks:
      - element-network
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  # Nginx反向代理
  nginx:
    image: nginx:alpine
    container_name: element-nginx
    restart: unless-stopped
    depends_on:
      - synapse
      - livekit
      - element-web
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /opt/element-ess/config/nginx:/etc/nginx/conf.d:ro
      - /etc/letsencrypt:/certs:ro
      - /opt/element-ess/logs/nginx:/var/log/nginx
    networks:
      - element-network
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  element-network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/16
EOF
}

# 部署WAN IP监控脚本
deploy_wan_monitor() {
    log "部署WAN IP监控服务..."
    
    # 复制监控脚本
    cp "$SCRIPT_DIR/scripts/wan_ip_monitor.py" /usr/local/bin/
    cp "$SCRIPT_DIR/scripts/wan-ip-monitor.service" /etc/systemd/system/
    
    # 创建监控配置
    cat > /etc/wan-ip-monitor.conf << EOF
# WAN IP监控配置
[DEFAULT]
check_interval = ${WAN_IP_CHECK_INTERVAL}
routeros_ip = ${ROUTEROS_IP}
routeros_username = ${ROUTEROS_USERNAME}
routeros_password = ${ROUTEROS_PASSWORD}
livekit_config_path = /opt/element-ess/config/livekit/livekit.yaml
docker_compose_path = ${DOCKER_COMPOSE_FILE}
cloudflare_api_token = ${CLOUDFLARE_API_TOKEN}
domains = ${MATRIX_SUBDOMAIN},${ELEMENT_SUBDOMAIN},${LIVEKIT_SUBDOMAIN}
EOF
    
    # 启用监控服务
    systemctl daemon-reload
    systemctl enable wan-ip-monitor
    systemctl start wan-ip-monitor
}

# 部署Admin管理工具
deploy_admin_tool() {
    if [[ "${ENABLE_ADMIN_TOOL}" == "true" ]]; then
        log "部署Admin管理工具..."
        
        # 复制admin脚本
        cp "$SCRIPT_DIR/scripts/element_admin.py" /usr/local/bin/
        chmod +x /usr/local/bin/element_admin.py
        
        # 复制系统命令包装器
        cp "$SCRIPT_DIR/scripts/admin" /usr/local/bin/
        chmod +x /usr/local/bin/admin
        
        # 安装admin工具到系统
        /usr/local/bin/admin install
        
        # 启动admin服务
        if [[ "${AUTO_START_SERVICES}" == "true" ]]; then
            /usr/local/bin/admin start
        fi
        
        info "Admin管理工具部署完成"
        info "管理界面: http://localhost:${ADMIN_TOOL_PORT:-8888}"
        info "默认账户: ${ADMIN_USERNAME:-admin} / ${ADMIN_PASSWORD}"
    fi
}

# 部署备份脚本
deploy_backup_service() {
    if [[ "${ENABLE_BACKUP}" == "true" ]]; then
        log "部署备份服务..."
        
        cat > /usr/local/bin/element-ess-backup.sh << EOF
#!/bin/bash
# Element ESS自动备份脚本

BACKUP_DIR="/opt/element-ess/backups/\$(date +%Y%m%d_%H%M%S)"
mkdir -p "\$BACKUP_DIR"

# 备份数据库
docker exec element-postgres pg_dump -U ${POSTGRES_USER} ${POSTGRES_DB} > "\$BACKUP_DIR/database.sql"

# 备份Synapse数据
tar -czf "\$BACKUP_DIR/synapse_data.tar.gz" -C /opt/element-ess/data synapse

# 备份配置文件
tar -czf "\$BACKUP_DIR/configs.tar.gz" -C /opt/element-ess config

# 清理旧备份
find /opt/element-ess/backups -name "*.tar.gz" -mtime +${BACKUP_RETENTION_DAYS} -delete
find /opt/element-ess/backups -type d -mtime +${BACKUP_RETENTION_DAYS} -exec rm -rf {} +

echo "备份完成: \$BACKUP_DIR"
EOF
        
        chmod +x /usr/local/bin/element-ess-backup.sh
        
        # 添加定时任务
        echo "${BACKUP_TIME} * * * root /usr/local/bin/element-ess-backup.sh" > /etc/cron.d/element-ess-backup
    fi
}

# 启动服务
start_services() {
    log "启动Element ESS服务..."
    
    # 确保配置目录权限正确
    chown -R root:root /opt/element-ess/config
    chmod -R 644 /opt/element-ess/config
    
    # 启动Docker Compose
    cd "$SCRIPT_DIR"
    docker-compose up -d
    
    # 等待服务启动
    log "等待服务启动..."
    sleep 30
    
    # 检查服务状态
    if docker-compose ps | grep -q "Up"; then
        log "服务启动成功"
    else
        error "服务启动失败，请检查日志"
    fi
}

# 验证部署
verify_deployment() {
    log "验证部署结果..."
    
    # 检查服务状态
    log "检查Docker服务状态..."
    docker-compose ps
    
    # 检查健康状态
    sleep 60  # 等待服务完全启动
    
    services=("postgres" "synapse" "livekit" "element-web" "nginx")
    for service in "${services[@]}"; do
        if docker-compose ps "$service" | grep -q "Up (healthy)"; then
            log "✓ $service 服务健康"
        else
            warn "✗ $service 服务状态异常"
        fi
    done
    
    # 测试域名访问
    log "测试域名访问..."
    
    # 测试Matrix服务
    if curl -k -s "https://${MATRIX_SUBDOMAIN}/_matrix/client/versions" | grep -q "versions"; then
        log "✓ Matrix服务可访问"
    else
        warn "✗ Matrix服务访问失败"
    fi
    
    # 测试Element Web
    if curl -k -s "https://${ELEMENT_SUBDOMAIN}" | grep -q "element"; then
        log "✓ Element Web可访问"
    else
        warn "✗ Element Web访问失败"
    fi
    
    # 测试LiveKit服务
    if curl -k -s "https://${LIVEKIT_SUBDOMAIN}/rtc" &>/dev/null; then
        log "✓ LiveKit服务可访问"
    else
        warn "✗ LiveKit服务访问失败"
    fi
}

# 显示部署信息
show_deployment_info() {
    log "部署完成！"
    
    echo
    echo "=========================================="
    echo "      Element ESS 部署信息 v2.0"
    echo "=========================================="
    echo
    echo "🌐 服务地址:"
    echo "   Matrix服务器: https://${MATRIX_SUBDOMAIN}"
    echo "   Element Web:  https://${ELEMENT_SUBDOMAIN}"
    echo "   LiveKit SFU:  https://${LIVEKIT_SUBDOMAIN}"
    echo
    echo "🔧 管理命令:"
    echo "   查看服务状态: docker-compose -f ${DOCKER_COMPOSE_FILE} ps"
    echo "   查看服务日志: docker-compose -f ${DOCKER_COMPOSE_FILE} logs -f [service]"
    echo "   重启服务:    docker-compose -f ${DOCKER_COMPOSE_FILE} restart [service]"
    echo "   停止服务:    docker-compose -f ${DOCKER_COMPOSE_FILE} down"
    echo
    echo "📁 重要目录:"
    echo "   数据目录: /opt/element-ess/data"
    echo "   配置目录: /opt/element-ess/config" 
    echo "   日志目录: /opt/element-ess/logs"
    echo "   备份目录: /opt/element-ess/backups"
    echo
    echo "🔐 证书信息:"
    echo "   证书目录: /etc/letsencrypt/live/${MATRIX_SUBDOMAIN}/"
    echo "   证书环境: ${CERT_ENVIRONMENT}"
    echo "   自动续期: 已启用"
    echo
    echo "📊 监控服务:"
    echo "   WAN IP监控: systemctl status wan-ip-monitor"
    echo "   备份服务: ${ENABLE_BACKUP}"
    echo
    echo "⚠️  下一步操作:"
    echo "   1. 在RouterOS中配置DDNS脚本"
    echo "   2. 配置外部服务器的指路服务"
    echo "   3. 测试Matrix客户端连接"
    echo "   4. 创建管理员用户"
    echo
    echo "📖 文档位置:"
    echo "   RouterOS配置: ../routeros/ddns_setup_guide.md"
    echo "   外部服务器:   ../external_server/manual_deployment_guide.md"
    echo
    echo "=========================================="
}

# 主函数
main() {
    log "开始Element ESS内部服务器自动部署 v2.1"
    
    check_root
    load_env
    
    # 自动生成邮箱地址
    generate_email_addresses
    
    # 环境检测和优化
    detect_and_optimize_environment
    
    check_system
    
    # 智能依赖安装
    if [[ "${AUTO_INSTALL_DEPENDENCIES}" == "true" ]]; then
        install_dependencies_smart
    else
        install_dependencies
    fi
    
    # 自动生成密钥
    if [[ "${AUTO_GENERATE_SECRETS}" == "true" ]]; then
        generate_secrets
    fi
    
    create_directories
    
    # 自动配置防火墙
    configure_firewall_auto
    
    setup_cloudflare_dns
    detect_wan_ip
    generate_configs
    generate_docker_compose
    deploy_wan_monitor
    deploy_admin_tool
    deploy_backup_service
    
    # 自动启动服务
    if [[ "${AUTO_START_SERVICES}" == "true" ]]; then
        start_services
        verify_deployment
    fi
    
    show_deployment_info
    
    log "部署完成！"
}

# 错误处理
trap 'error "脚本执行失败，请检查日志: $LOG_FILE"' ERR

# 执行主函数
main "$@"
