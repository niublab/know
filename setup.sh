#!/bin/bash

# ESS Community 自动部署脚本 - 第一步：基于官方最新规范的基础部署
# 版本: 1.0.0
# 基于: Element Server Suite Community Edition 25.6.1
# 许可证: AGPL-3.0 (仅限非商业用途)

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 全局变量
SCRIPT_VERSION="1.0.0"
ESS_VERSION="25.6.1"
NAMESPACE="ess"
CONFIG_DIR="$HOME/ess-config-values"

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
    echo -e "${YELLOW}ESS Community 许可证声明${NC}"
    echo -e "${YELLOW}================================${NC}"
    echo "Element Server Suite Community Edition"
    echo "版本: $ESS_VERSION"
    echo "许可证: AGPL-3.0"
    echo ""
    echo -e "${RED}重要提醒: 此软件仅限非商业用途使用${NC}"
    echo "- 个人使用: ✓ 允许"
    echo "- 学习研究: ✓ 允许"
    echo "- 商业用途: ✗ 禁止"
    echo ""
    echo "继续使用即表示您同意遵守 AGPL-3.0 许可证条款"
    echo -e "${YELLOW}================================${NC}"
    echo ""
}

# 检查系统要求
check_system_requirements() {
    log_info "检查系统要求..."
    
    # 检查操作系统
    if [[ ! -f /etc/debian_version ]]; then
        log_error "此脚本仅支持 Debian 系列操作系统"
        exit 1
    fi
    
    # 检查 sudo 权限
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要以 root 用户运行此脚本，请使用具有 sudo 权限的普通用户"
        exit 1
    fi
    
    if ! sudo -n true 2>/dev/null; then
        log_error "当前用户没有 sudo 权限"
        exit 1
    fi
    
    # 检查内存和CPU
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    
    if [[ $mem_gb -lt 2 ]]; then
        log_warning "系统内存少于 2GB，可能影响性能"
    fi
    
    if [[ $cpu_cores -lt 2 ]]; then
        log_warning "系统CPU核心少于 2 个，可能影响性能"
    fi
    
    log_success "系统要求检查完成"
}

# 检查网络连通性
check_network() {
    log_info "检查网络连通性..."
    
    local test_urls=(
        "https://get.k3s.io"
        "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
        "https://charts.jetstack.io"
        "https://ghcr.io"
    )
    
    for url in "${test_urls[@]}"; do
        if ! curl -s --connect-timeout 10 "$url" >/dev/null; then
            log_error "无法连接到 $url"
            log_error "请检查网络连接和防火墙设置"
            exit 1
        fi
    done
    
    log_success "网络连通性检查完成"
}

# 安装 K3s
install_k3s() {
    log_info "安装 K3s..."
    
    if command -v k3s >/dev/null 2>&1; then
        log_warning "K3s 已安装，跳过安装步骤"
        return 0
    fi
    
    # 安装 K3s
    curl -sfL https://get.k3s.io | sh -
    
    # 配置 kubeconfig
    mkdir -p ~/.kube
    export KUBECONFIG=~/.kube/config
    sudo k3s kubectl config view --raw > "$KUBECONFIG"
    chmod 600 "$KUBECONFIG"
    chown "$USER:$USER" "$KUBECONFIG"
    
    # 添加到 bashrc
    if ! grep -q "export KUBECONFIG=~/.kube/config" ~/.bashrc; then
        echo "export KUBECONFIG=~/.kube/config" >> ~/.bashrc
    fi
    
    # 等待 K3s 启动
    log_info "等待 K3s 启动..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if kubectl get nodes >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((retries--))
    done
    
    if [[ $retries -eq 0 ]]; then
        log_error "K3s 启动超时"
        exit 1
    fi
    
    log_success "K3s 安装完成"
}

# 安装 Helm
install_helm() {
    log_info "安装 Helm..."
    
    if command -v helm >/dev/null 2>&1; then
        log_warning "Helm 已安装，跳过安装步骤"
        return 0
    fi
    
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    
    log_success "Helm 安装完成"
}

# 创建命名空间
create_namespace() {
    log_info "创建 Kubernetes 命名空间..."
    
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        log_warning "命名空间 $NAMESPACE 已存在"
    else
        kubectl create namespace "$NAMESPACE"
        log_success "命名空间 $NAMESPACE 创建完成"
    fi
}

# 创建配置目录
create_config_directory() {
    log_info "创建配置目录..."
    
    mkdir -p "$CONFIG_DIR"
    log_success "配置目录创建完成: $CONFIG_DIR"
}

# 安装 cert-manager
install_cert_manager() {
    log_info "安装 cert-manager..."
    
    # 检查是否已安装
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        log_warning "cert-manager 已安装，跳过安装步骤"
        return 0
    fi
    
    # 添加 Helm 仓库
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update
    
    # 安装 cert-manager
    helm install \
        cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.17.0 \
        --set crds.enabled=true \
        --wait
    
    log_success "cert-manager 安装完成"
}

# 配置 Let's Encrypt ClusterIssuer
configure_letsencrypt() {
    log_info "配置 Let's Encrypt ClusterIssuer..."

    read -p "请输入用于证书申请的邮箱地址: " cert_email

    if [[ -z "$cert_email" ]]; then
        log_error "邮箱地址不能为空"
        return 1
    fi

    # 创建 ClusterIssuer
    kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $cert_email
    privateKeySecretRef:
      name: letsencrypt-prod-private-key
    solvers:
      - http01:
          ingress:
            class: traefik
EOF

    log_success "Let's Encrypt ClusterIssuer 配置完成"
}

# 创建基础配置文件
create_basic_config() {
    log_info "创建基础配置文件..."

    # 获取用户输入
    read -p "请输入服务器域名 (例如: example.com): " server_name
    read -p "请输入 Synapse 域名 (例如: matrix.example.com): " synapse_host
    read -p "请输入认证服务域名 (例如: account.example.com): " auth_host
    read -p "请输入 RTC 服务域名 (例如: mrtc.example.com): " rtc_host
    read -p "请输入 Web 客户端域名 (例如: chat.example.com): " web_host

    # 验证输入
    if [[ -z "$server_name" || -z "$synapse_host" || -z "$auth_host" || -z "$rtc_host" || -z "$web_host" ]]; then
        log_error "所有域名都不能为空"
        return 1
    fi

    # 创建主机名配置文件
    cat > "$CONFIG_DIR/hostnames.yaml" <<EOF
# Copyright 2024-2025 New Vector Ltd
# SPDX-License-Identifier: AGPL-3.0-only

serverName: $server_name

elementWeb:
  ingress:
    host: $web_host

matrixAuthenticationService:
  ingress:
    host: $auth_host

matrixRTC:
  ingress:
    host: $rtc_host

synapse:
  ingress:
    host: $synapse_host

wellKnownDelegation:
  ingress:
    host: $server_name
EOF

    # 创建 TLS 配置文件
    cat > "$CONFIG_DIR/tls.yaml" <<EOF
# Copyright 2025 New Vector Ltd
# SPDX-License-Identifier: AGPL-3.0-only

certManager:
  clusterIssuer: letsencrypt-prod
EOF

    log_success "基础配置文件创建完成"
}

# 部署 ESS
deploy_ess() {
    log_info "部署 ESS Community..."

    # 检查配置文件
    if [[ ! -f "$CONFIG_DIR/hostnames.yaml" ]]; then
        log_error "配置文件不存在，请先创建配置"
        return 1
    fi

    # 部署 ESS
    helm upgrade --install --namespace "$NAMESPACE" ess \
        oci://ghcr.io/element-hq/ess-helm/matrix-stack \
        -f "$CONFIG_DIR/hostnames.yaml" \
        -f "$CONFIG_DIR/tls.yaml" \
        --wait \
        --timeout=10m

    if [[ $? -eq 0 ]]; then
        log_success "ESS Community 部署完成"
    else
        log_error "ESS Community 部署失败"
        return 1
    fi
}

# 创建初始用户
create_initial_user() {
    log_info "创建初始用户..."

    # 检查 ESS 是否已部署
    if ! helm list -n "$NAMESPACE" | grep -q "ess"; then
        log_error "ESS 尚未部署，请先部署 ESS"
        return 1
    fi

    # 等待 MAS 服务启动
    log_info "等待 Matrix Authentication Service 启动..."
    if ! kubectl wait --for=condition=available --timeout=300s deployment/ess-matrix-authentication-service -n "$NAMESPACE"; then
        log_error "Matrix Authentication Service 启动超时"
        return 1
    fi

    # 创建用户
    log_info "请按照提示创建初始用户..."
    kubectl exec -n "$NAMESPACE" -it deploy/ess-matrix-authentication-service -- mas-cli manage register-user

    log_success "初始用户创建完成"
}

# 验证部署
verify_deployment() {
    log_info "验证 ESS 部署..."

    # 检查所有 Pod 状态
    log_info "检查 Pod 状态..."
    kubectl get pods -n "$NAMESPACE"

    # 检查 Ingress 状态
    log_info "检查 Ingress 状态..."
    kubectl get ingress -n "$NAMESPACE"

    # 检查证书状态
    log_info "检查证书状态..."
    kubectl get certificates -n "$NAMESPACE"

    # 显示访问信息
    if [[ -f "$CONFIG_DIR/hostnames.yaml" ]]; then
        local web_host=$(grep -A2 "elementWeb:" "$CONFIG_DIR/hostnames.yaml" | grep "host:" | awk '{print $2}')
        local server_name=$(grep "serverName:" "$CONFIG_DIR/hostnames.yaml" | awk '{print $2}')

        echo ""
        echo -e "${GREEN}================================${NC}"
        echo -e "${GREEN}部署验证完成${NC}"
        echo -e "${GREEN}================================${NC}"
        echo "Web 客户端访问地址: https://$web_host"
        echo "Matrix 服务器名: $server_name"
        echo ""
        echo "建议验证步骤:"
        echo "1. 访问 Web 客户端并登录"
        echo "2. 使用 Matrix Federation Tester 验证联邦功能"
        echo "3. 使用 Element X 移动客户端测试"
        echo -e "${GREEN}================================${NC}"
    fi

    log_success "部署验证完成"
}

# 主菜单
show_main_menu() {
    clear
    show_license

    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}ESS Community 自动部署脚本${NC}"
    echo -e "${BLUE}版本: $SCRIPT_VERSION${NC}"
    echo -e "${BLUE}ESS版本: $ESS_VERSION${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo "请选择操作:"
    echo "1) 完整安装 (推荐)"
    echo "2) 检查系统环境"
    echo "3) 安装基础组件 (K3s + Helm + cert-manager)"
    echo "4) 配置 ESS 部署"
    echo "5) 部署 ESS Community"
    echo "6) 创建初始用户"
    echo "7) 验证部署"
    echo "8) 查看安装状态"
    echo "0) 退出"
    echo ""
    read -p "请输入选择 [0-8]: " choice

    case $choice in
        1) full_install ;;
        2) check_environment ;;
        3) install_base_components ;;
        4) configure_ess ;;
        5) deploy_ess_only ;;
        6)
            create_initial_user
            read -p "按任意键返回主菜单..."
            show_main_menu
            ;;
        7)
            verify_deployment
            read -p "按任意键返回主菜单..."
            show_main_menu
            ;;
        8) show_status ;;
        0) exit 0 ;;
        *)
            log_error "无效选择"
            sleep 2
            show_main_menu
            ;;
    esac
}

# 配置 ESS
configure_ess() {
    log_info "配置 ESS 部署..."

    configure_letsencrypt
    create_basic_config

    log_success "ESS 配置完成"
    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 仅部署 ESS
deploy_ess_only() {
    deploy_ess

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 完整安装
full_install() {
    log_info "开始完整安装..."

    check_system_requirements
    check_network
    install_k3s
    install_helm
    create_namespace
    create_config_directory
    install_cert_manager

    log_info "基础组件安装完成，开始配置 ESS..."

    configure_letsencrypt
    create_basic_config
    deploy_ess

    log_success "ESS Community 完整安装完成！"
    log_info "请使用选项 6 创建初始用户"

    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 检查环境
check_environment() {
    check_system_requirements
    check_network
    
    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 安装基础组件
install_base_components() {
    install_k3s
    install_helm
    create_namespace
    create_config_directory
    install_cert_manager
    
    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 显示状态
show_status() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}系统状态检查${NC}"
    echo -e "${BLUE}================================${NC}"

    # 检查 K3s
    if command -v k3s >/dev/null 2>&1; then
        echo -e "K3s: ${GREEN}已安装${NC}"
        if kubectl get nodes >/dev/null 2>&1; then
            echo -e "K3s 状态: ${GREEN}运行中${NC}"
        else
            echo -e "K3s 状态: ${RED}未运行${NC}"
        fi
    else
        echo -e "K3s: ${RED}未安装${NC}"
    fi

    # 检查 Helm
    if command -v helm >/dev/null 2>&1; then
        echo -e "Helm: ${GREEN}已安装${NC}"
    else
        echo -e "Helm: ${RED}未安装${NC}"
    fi

    # 检查 cert-manager
    if kubectl get namespace cert-manager >/dev/null 2>&1; then
        echo -e "cert-manager: ${GREEN}已安装${NC}"
        if kubectl get pods -n cert-manager | grep -q "Running"; then
            echo -e "cert-manager 状态: ${GREEN}运行中${NC}"
        else
            echo -e "cert-manager 状态: ${RED}未运行${NC}"
        fi
    else
        echo -e "cert-manager: ${RED}未安装${NC}"
    fi

    # 检查命名空间
    if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo -e "ESS 命名空间: ${GREEN}已创建${NC}"
    else
        echo -e "ESS 命名空间: ${RED}未创建${NC}"
    fi

    # 检查 ESS 部署
    if helm list -n "$NAMESPACE" | grep -q "ess"; then
        echo -e "ESS Community: ${GREEN}已部署${NC}"

        # 检查各组件状态
        local components=("synapse" "matrix-authentication-service" "matrix-rtc" "element-web")
        for component in "${components[@]}"; do
            if kubectl get deployment "ess-$component" -n "$NAMESPACE" >/dev/null 2>&1; then
                local ready=$(kubectl get deployment "ess-$component" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                local desired=$(kubectl get deployment "ess-$component" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
                if [[ "$ready" == "$desired" && "$ready" != "0" ]]; then
                    echo -e "  - $component: ${GREEN}运行中 ($ready/$desired)${NC}"
                else
                    echo -e "  - $component: ${YELLOW}启动中 ($ready/$desired)${NC}"
                fi
            else
                echo -e "  - $component: ${RED}未找到${NC}"
            fi
        done
    else
        echo -e "ESS Community: ${RED}未部署${NC}"
    fi

    # 检查配置文件
    if [[ -f "$CONFIG_DIR/hostnames.yaml" ]]; then
        echo -e "配置文件: ${GREEN}已创建${NC}"
    else
        echo -e "配置文件: ${RED}未创建${NC}"
    fi

    echo ""
    read -p "按任意键返回主菜单..."
    show_main_menu
}

# 主程序入口
main() {
    # 设置环境变量
    export KUBECONFIG=~/.kube/config
    
    # 显示主菜单
    show_main_menu
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
