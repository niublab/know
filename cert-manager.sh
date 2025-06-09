#!/bin/bash

# Matrix 证书管理脚本
# 版本: 1.0.0
# 作者: Manus AI
# 描述: 独立的证书申请、更新和撤销管理工具

set -euo pipefail

# 脚本配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
VERSION="1.0.0"

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

# 检查依赖
check_dependencies() {
    local deps=("kubectl" "openssl" "dig" "curl")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_error "依赖 '$dep' 未安装"
            return 1
        fi
    done
    
    # 检查Kubernetes连接
    if ! kubectl cluster-info &>/dev/null; then
        log_error "无法连接到Kubernetes集群"
        return 1
    fi
    
    log_info "依赖检查通过"
}

# 加载配置
load_config() {
    local config_file="$SCRIPT_DIR/config/.env"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "配置文件不存在: $config_file"
        log_error "请先运行主部署脚本进行配置"
        return 1
    fi
    
    source "$config_file"
    
    # 验证必要配置
    if [[ -z "${DOMAIN:-}" || -z "${CLOUDFLARE_TOKEN:-}" || -z "${CERT_EMAIL:-}" ]]; then
        log_error "配置文件缺少必要参数"
        return 1
    fi
    
    log_info "配置加载完成"
}

# 安装 cert-manager
install_cert_manager() {
    log_info "安装 cert-manager..."
    
    # 检查是否已安装
    if kubectl get namespace cert-manager &>/dev/null; then
        log_info "cert-manager 已安装"
        return 0
    fi
    
    # 添加 Jetstack Helm 仓库
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update
    
    # 安装 cert-manager
    helm install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --create-namespace \
        --version v1.17.0 \
        --set crds.enabled=true
    
    # 等待 cert-manager 启动
    log_info "等待 cert-manager 启动..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=300s
    
    log_info "cert-manager 安装完成"
}

# 创建 ClusterIssuer
create_cluster_issuer() {
    local env="$1"  # production 或 staging
    
    log_info "创建 ClusterIssuer ($env)..."
    
    local server_url
    if [[ "$env" == "production" ]]; then
        server_url="https://acme-v02.api.letsencrypt.org/directory"
    else
        server_url="https://acme-staging-v02.api.letsencrypt.org/directory"
    fi
    
    # 创建 Cloudflare API Token Secret
    kubectl create secret generic cloudflare-api-token \
        --from-literal=api-token="$CLOUDFLARE_TOKEN" \
        --namespace=cert-manager \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # 创建 ClusterIssuer
    cat << EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-$env
spec:
  acme:
    server: $server_url
    email: $CERT_EMAIL
    privateKeySecretRef:
      name: letsencrypt-$env-private-key
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
      selector:
        dnsZones:
        - "$DOMAIN"
EOF
    
    log_info "ClusterIssuer letsencrypt-$env 创建完成"
}

# 申请证书
request_certificate() {
    local cert_name="$1"
    local domains="$2"
    local env="${3:-staging}"
    
    log_info "申请证书: $cert_name (环境: $env)"
    log_info "域名: $domains"
    
    # 将域名字符串转换为数组
    IFS=',' read -ra domain_array <<< "$domains"
    
    # 构建域名列表
    local dns_names=""
    for domain in "${domain_array[@]}"; do
        domain=$(echo "$domain" | xargs)  # 去除空格
        dns_names="$dns_names  - $domain"$'\n'
    done
    
    # 创建证书请求
    cat << EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $cert_name
  namespace: ${NAMESPACE:-ess}
spec:
  secretName: $cert_name-tls
  issuerRef:
    name: letsencrypt-$env
    kind: ClusterIssuer
  dnsNames:
$dns_names
EOF
    
    log_info "证书请求已提交"
    
    # 等待证书签发
    log_info "等待证书签发..."
    local timeout=600
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        local status=$(kubectl get certificate "$cert_name" -n "${NAMESPACE:-ess}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        
        if [[ "$status" == "True" ]]; then
            log_info "证书签发成功！"
            return 0
        elif [[ "$status" == "False" ]]; then
            local reason=$(kubectl get certificate "$cert_name" -n "${NAMESPACE:-ess}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
            log_warn "证书签发失败，原因: $reason"
            log_info "查看详细错误信息:"
            kubectl describe certificate "$cert_name" -n "${NAMESPACE:-ess}"
            return 1
        fi
        
        echo -n "."
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_error "证书签发超时"
    return 1
}

# 更新证书
renew_certificate() {
    local cert_name="$1"
    
    log_info "更新证书: $cert_name"
    
    # 删除现有证书以触发重新签发
    kubectl delete certificate "$cert_name" -n "${NAMESPACE:-ess}" --ignore-not-found=true
    
    # 等待一段时间
    sleep 5
    
    # 重新创建证书（需要从原始配置重新创建）
    log_warn "请重新运行证书申请命令以完成更新"
}

# 撤销证书
revoke_certificate() {
    local cert_name="$1"
    
    log_warn "撤销证书: $cert_name"
    read -p "确认撤销证书? (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "操作已取消"
        return 0
    fi
    
    # 删除证书资源
    kubectl delete certificate "$cert_name" -n "${NAMESPACE:-ess}" --ignore-not-found=true
    
    # 删除证书密钥
    kubectl delete secret "$cert_name-tls" -n "${NAMESPACE:-ess}" --ignore-not-found=true
    
    log_info "证书已撤销"
}

# 查看证书状态
show_certificate_status() {
    log_info "证书状态概览:"
    
    echo -e "${CYAN}=== ClusterIssuer 状态 ===${NC}"
    kubectl get clusterissuer
    
    echo
    echo -e "${CYAN}=== 证书状态 ===${NC}"
    kubectl get certificates -n "${NAMESPACE:-ess}" -o wide
    
    echo
    echo -e "${CYAN}=== 证书详细信息 ===${NC}"
    local certs=$(kubectl get certificates -n "${NAMESPACE:-ess}" -o name 2>/dev/null || true)
    
    if [[ -n "$certs" ]]; then
        for cert in $certs; do
            local cert_name=$(echo "$cert" | cut -d'/' -f2)
            echo -e "${YELLOW}证书: $cert_name${NC}"
            kubectl describe certificate "$cert_name" -n "${NAMESPACE:-ess}" | grep -E "(Status|Events)" -A 10
            echo
        done
    else
        echo "未找到证书"
    fi
}

# 显示主菜单
show_main_menu() {
    clear
    echo -e "${CYAN}================================${NC}"
    echo -e "${WHITE}    Matrix 证书管理工具${NC}"
    echo -e "${WHITE}    版本: $VERSION${NC}"
    echo -e "${CYAN}================================${NC}"
    echo
    echo -e "${GREEN}1.${NC} 安装 cert-manager"
    echo -e "${GREEN}2.${NC} 创建证书签发器"
    echo -e "${GREEN}3.${NC} 申请新证书"
    echo -e "${GREEN}4.${NC} 更新证书"
    echo -e "${GREEN}5.${NC} 撤销证书"
    echo -e "${GREEN}6.${NC} 查看证书状态"
    echo -e "${GREEN}7.${NC} 快速部署Matrix证书"
    echo -e "${RED}0.${NC} 退出"
    echo
    echo -e "${YELLOW}请选择操作:${NC} "
}

# 快速部署Matrix证书
quick_deploy_matrix_certs() {
    log_info "快速部署Matrix证书..."
    
    # 安装 cert-manager
    install_cert_manager
    
    # 创建签发器
    create_cluster_issuer "$CERT_ENV"
    
    # 申请Matrix证书
    local domains="$DOMAIN,$MATRIX_DOMAIN,$ACCOUNT_DOMAIN,$MRTC_DOMAIN,$CHAT_DOMAIN"
    request_certificate "matrix-tls" "$domains" "$CERT_ENV"
    
    log_info "Matrix证书部署完成！"
}

# 交互式申请证书
interactive_request_certificate() {
    echo -e "${YELLOW}=== 申请新证书 ===${NC}"
    
    read -p "证书名称: " cert_name
    while [[ -z "$cert_name" ]]; do
        log_error "证书名称不能为空"
        read -p "证书名称: " cert_name
    done
    
    read -p "域名列表 (用逗号分隔): " domains
    while [[ -z "$domains" ]]; do
        log_error "域名不能为空"
        read -p "域名列表 (用逗号分隔): " domains
    done
    
    echo "证书环境:"
    echo "1. 生产环境 (Let's Encrypt 生产)"
    echo "2. 测试环境 (Let's Encrypt 测试)"
    read -p "请选择 [1-2]: " env_choice
    
    local env
    case $env_choice in
        1)
            env="production"
            ;;
        2)
            env="staging"
            ;;
        *)
            log_warn "无效选择，使用测试环境"
            env="staging"
            ;;
    esac
    
    request_certificate "$cert_name" "$domains" "$env"
}

# 交互式更新证书
interactive_renew_certificate() {
    echo -e "${YELLOW}=== 更新证书 ===${NC}"
    
    # 显示现有证书
    local certs=$(kubectl get certificates -n "${NAMESPACE:-ess}" -o name 2>/dev/null | cut -d'/' -f2 || true)
    
    if [[ -z "$certs" ]]; then
        log_error "未找到任何证书"
        return 1
    fi
    
    echo "现有证书:"
    local i=1
    local cert_array=()
    for cert in $certs; do
        echo "$i. $cert"
        cert_array+=("$cert")
        ((i++))
    done
    
    read -p "请选择要更新的证书 [1-$((i-1))]: " choice
    
    if [[ "$choice" -ge 1 && "$choice" -le $((i-1)) ]]; then
        local selected_cert="${cert_array[$((choice-1))]}"
        renew_certificate "$selected_cert"
    else
        log_error "无效选择"
    fi
}

# 交互式撤销证书
interactive_revoke_certificate() {
    echo -e "${YELLOW}=== 撤销证书 ===${NC}"
    
    # 显示现有证书
    local certs=$(kubectl get certificates -n "${NAMESPACE:-ess}" -o name 2>/dev/null | cut -d'/' -f2 || true)
    
    if [[ -z "$certs" ]]; then
        log_error "未找到任何证书"
        return 1
    fi
    
    echo "现有证书:"
    local i=1
    local cert_array=()
    for cert in $certs; do
        echo "$i. $cert"
        cert_array+=("$cert")
        ((i++))
    done
    
    read -p "请选择要撤销的证书 [1-$((i-1))]: " choice
    
    if [[ "$choice" -ge 1 && "$choice" -le $((i-1)) ]]; then
        local selected_cert="${cert_array[$((choice-1))]}"
        revoke_certificate "$selected_cert"
    else
        log_error "无效选择"
    fi
}

# 主函数
main() {
    # 检查依赖
    if ! check_dependencies; then
        exit 1
    fi
    
    # 加载配置
    if ! load_config; then
        exit 1
    fi
    
    while true; do
        show_main_menu
        read -r choice
        
        case $choice in
            1)
                install_cert_manager
                read -p "按回车键继续..."
                ;;
            2)
                echo "选择环境:"
                echo "1. 生产环境"
                echo "2. 测试环境"
                read -p "请选择 [1-2]: " env_choice
                
                case $env_choice in
                    1)
                        create_cluster_issuer "production"
                        ;;
                    2)
                        create_cluster_issuer "staging"
                        ;;
                    *)
                        log_error "无效选择"
                        ;;
                esac
                read -p "按回车键继续..."
                ;;
            3)
                interactive_request_certificate
                read -p "按回车键继续..."
                ;;
            4)
                interactive_renew_certificate
                read -p "按回车键继续..."
                ;;
            5)
                interactive_revoke_certificate
                read -p "按回车键继续..."
                ;;
            6)
                show_certificate_status
                read -p "按回车键继续..."
                ;;
            7)
                quick_deploy_matrix_certs
                read -p "按回车键继续..."
                ;;
            0)
                log_info "感谢使用 Matrix 证书管理工具！"
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

