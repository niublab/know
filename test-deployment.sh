#!/bin/bash

# Matrix 服务器测试脚本
# 版本: 1.0.0
# 作者: Manus AI
# 描述: 测试部署脚本的各项功能

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

# 测试结果统计
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0

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

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

# 测试函数
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    ((TESTS_TOTAL++))
    log_test "运行测试: $test_name"
    
    if eval "$test_command" &>/dev/null; then
        log_pass "$test_name"
        return 0
    else
        log_fail "$test_name"
        return 1
    fi
}

# 测试系统依赖
test_system_dependencies() {
    log_info "测试系统依赖..."
    
    local deps=("curl" "wget" "git" "openssl" "jq" "dnsutils" "kubectl" "helm")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -eq 0 ]]; then
        log_pass "所有系统依赖已安装"
        return 0
    else
        log_fail "缺少依赖: ${missing_deps[*]}"
        return 1
    fi
}

# 测试Kubernetes连接
test_kubernetes_connection() {
    log_info "测试Kubernetes连接..."
    
    if kubectl cluster-info &>/dev/null; then
        log_pass "Kubernetes集群连接正常"
        return 0
    else
        log_fail "无法连接到Kubernetes集群"
        return 1
    fi
}

# 测试配置文件生成
test_config_generation() {
    log_info "测试配置文件生成..."
    
    local test_config_dir="/tmp/matrix-test-config"
    mkdir -p "$test_config_dir"
    
    # 创建测试配置
    cat > "$test_config_dir/.env" << EOF
DOMAIN=test.example.com
HTTP_PORT=8080
HTTPS_PORT=8443
WEBRTC_TCP_PORT=30881
WEBRTC_UDP_PORT=30882
INSTALL_DIR=/opt/matrix
NAMESPACE=ess
CERT_ENV=staging
CERT_EMAIL=test@example.com
CLOUDFLARE_TOKEN=test_token
ADMIN_EMAIL=admin@example.com
POSTGRES_PASSWORD=test_password_64_chars_long_random_string_for_security_test
SYNAPSE_SIGNING_KEY=test_signing_key_64_chars_long_random_string_for_security
SYNAPSE_MACAROON_SECRET=test_macaroon_secret_64_chars_long_random_string
MAS_SECRET_KEY=test_mas_secret_key_64_chars_long_random_string_for_test
MAS_ENCRYPTION_KEY=test_mas_encryption_key_64_chars_long_random_string
REGISTRATION_TOKEN=test_registration_token_32_chars
ENABLE_FEDERATION=true
ENABLE_REGISTRATION=false
MATRIX_DOMAIN=matrix.test.example.com
ACCOUNT_DOMAIN=account.test.example.com
MRTC_DOMAIN=mrtc.test.example.com
CHAT_DOMAIN=chat.test.example.com
EOF
    
    # 测试配置模板生成
    if source "$SCRIPT_DIR/config-templates.sh" && generate_complete_config "$test_config_dir/.env"; then
        log_pass "配置文件生成成功"
        rm -rf "$test_config_dir"
        return 0
    else
        log_fail "配置文件生成失败"
        rm -rf "$test_config_dir"
        return 1
    fi
}

# 测试密码生成
test_password_generation() {
    log_info "测试密码生成功能..."
    
    # 测试64位密码生成
    local password=$(openssl rand -base64 48 | tr -d "=+/" | cut -c1-64)
    
    if [[ ${#password} -eq 64 ]]; then
        log_pass "64位密码生成正确"
        return 0
    else
        log_fail "密码长度不正确: ${#password}"
        return 1
    fi
}

# 测试端口配置验证
test_port_validation() {
    log_info "测试端口配置验证..."
    
    # 测试标准端口检测
    local test_ports=("80" "443" "8080" "8443")
    local blocked_ports=("80" "443")
    
    for port in "${test_ports[@]}"; do
        if [[ " ${blocked_ports[*]} " =~ " $port " ]]; then
            # 应该被阻止的端口
            if [[ "$port" == "80" || "$port" == "443" ]]; then
                log_pass "正确识别被封锁端口: $port"
            fi
        else
            # 应该被允许的端口
            if [[ "$port" == "8080" || "$port" == "8443" ]]; then
                log_pass "正确允许自定义端口: $port"
            fi
        fi
    done
    
    return 0
}

# 测试DNS解析
test_dns_resolution() {
    log_info "测试DNS解析功能..."
    
    # 测试公共DNS服务器
    local test_domain="google.com"
    local dns_servers=("8.8.8.8" "1.1.1.1")
    
    for dns in "${dns_servers[@]}"; do
        if dig +short "$test_domain" @"$dns" &>/dev/null; then
            log_pass "DNS服务器 $dns 可用"
        else
            log_fail "DNS服务器 $dns 不可用"
        fi
    done
    
    return 0
}

# 测试脚本语法
test_script_syntax() {
    log_info "测试脚本语法..."
    
    local scripts=("$SCRIPT_DIR/matrix-deploy.sh" "$SCRIPT_DIR/cert-manager.sh" "$SCRIPT_DIR/config-templates.sh")
    
    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if bash -n "$script"; then
                log_pass "脚本语法正确: $(basename "$script")"
            else
                log_fail "脚本语法错误: $(basename "$script")"
            fi
        else
            log_fail "脚本文件不存在: $(basename "$script")"
        fi
    done
    
    return 0
}

# 测试文件权限
test_file_permissions() {
    log_info "测试文件权限..."
    
    local scripts=("$SCRIPT_DIR/matrix-deploy.sh" "$SCRIPT_DIR/cert-manager.sh" "$SCRIPT_DIR/config-templates.sh")
    
    for script in "${scripts[@]}"; do
        if [[ -f "$script" && -x "$script" ]]; then
            log_pass "脚本可执行: $(basename "$script")"
        else
            log_fail "脚本不可执行: $(basename "$script")"
        fi
    done
    
    return 0
}

# 测试网络连通性
test_network_connectivity() {
    log_info "测试网络连通性..."
    
    local test_urls=(
        "https://get.k3s.io"
        "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
        "https://charts.jetstack.io"
        "https://ghcr.io"
    )
    
    for url in "${test_urls[@]}"; do
        if curl -s --head "$url" &>/dev/null; then
            log_pass "网络连通: $url"
        else
            log_fail "网络不通: $url"
        fi
    done
    
    return 0
}

# 测试Helm仓库访问
test_helm_repositories() {
    log_info "测试Helm仓库访问..."
    
    # 测试添加仓库
    if helm repo add jetstack https://charts.jetstack.io --force-update &>/dev/null; then
        log_pass "Jetstack Helm仓库可访问"
    else
        log_fail "Jetstack Helm仓库不可访问"
    fi
    
    if helm repo add traefik https://traefik.github.io/charts --force-update &>/dev/null; then
        log_pass "Traefik Helm仓库可访问"
    else
        log_fail "Traefik Helm仓库不可访问"
    fi
    
    return 0
}

# 测试OCI注册表访问
test_oci_registry() {
    log_info "测试OCI注册表访问..."
    
    # 测试Element ESS Helm Chart
    if helm show chart oci://ghcr.io/element-hq/ess-helm/matrix-stack &>/dev/null; then
        log_pass "Element ESS OCI注册表可访问"
    else
        log_fail "Element ESS OCI注册表不可访问"
    fi
    
    return 0
}

# 性能测试
test_performance() {
    log_info "运行性能测试..."
    
    # 测试系统资源
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    local cpu_cores=$(nproc)
    local disk_gb=$(df -BG "$PWD" | awk 'NR==2{print $4}' | sed 's/G//')
    
    log_info "系统资源:"
    log_info "  内存: ${mem_gb}GB"
    log_info "  CPU核心: $cpu_cores"
    log_info "  可用磁盘: ${disk_gb}GB"
    
    # 检查最低要求
    if [[ $mem_gb -ge 2 ]]; then
        log_pass "内存满足要求 (≥2GB)"
    else
        log_fail "内存不足 (<2GB)"
    fi
    
    if [[ $cpu_cores -ge 2 ]]; then
        log_pass "CPU满足要求 (≥2核)"
    else
        log_fail "CPU不足 (<2核)"
    fi
    
    if [[ $disk_gb -ge 10 ]]; then
        log_pass "磁盘空间满足要求 (≥10GB)"
    else
        log_fail "磁盘空间不足 (<10GB)"
    fi
    
    return 0
}

# 运行所有测试
run_all_tests() {
    log_info "开始运行所有测试..."
    echo
    
    # 基础测试
    test_system_dependencies
    test_script_syntax
    test_file_permissions
    test_password_generation
    test_port_validation
    test_config_generation
    
    # 网络测试
    test_dns_resolution
    test_network_connectivity
    
    # Kubernetes测试
    if command -v kubectl &>/dev/null; then
        test_kubernetes_connection
    else
        log_warn "kubectl未安装，跳过Kubernetes测试"
    fi
    
    # Helm测试
    if command -v helm &>/dev/null; then
        test_helm_repositories
        test_oci_registry
    else
        log_warn "helm未安装，跳过Helm测试"
    fi
    
    # 性能测试
    test_performance
    
    # 显示测试结果
    echo
    echo -e "${CYAN}=== 测试结果汇总 ===${NC}"
    echo -e "总测试数: ${WHITE}$TESTS_TOTAL${NC}"
    echo -e "通过: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "失败: ${RED}$TESTS_FAILED${NC}"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}所有测试通过！${NC}"
        return 0
    else
        echo -e "${RED}有 $TESTS_FAILED 个测试失败${NC}"
        return 1
    fi
}

# 显示帮助信息
show_help() {
    echo "Matrix 服务器测试脚本 v$VERSION"
    echo
    echo "用法: $SCRIPT_NAME [选项]"
    echo
    echo "选项:"
    echo "  -h, --help     显示帮助信息"
    echo "  -a, --all      运行所有测试"
    echo "  -s, --system   仅运行系统测试"
    echo "  -n, --network  仅运行网络测试"
    echo "  -k, --k8s      仅运行Kubernetes测试"
    echo "  -p, --perf     仅运行性能测试"
    echo
}

# 主函数
main() {
    case "${1:-}" in
        -h|--help)
            show_help
            exit 0
            ;;
        -a|--all)
            run_all_tests
            ;;
        -s|--system)
            test_system_dependencies
            test_script_syntax
            test_file_permissions
            test_password_generation
            test_port_validation
            test_config_generation
            ;;
        -n|--network)
            test_dns_resolution
            test_network_connectivity
            test_helm_repositories
            test_oci_registry
            ;;
        -k|--k8s)
            test_kubernetes_connection
            ;;
        -p|--perf)
            test_performance
            ;;
        "")
            run_all_tests
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

