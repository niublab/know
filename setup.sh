#!/bin/bash

# Matrix server
# 版本: 1.0.2
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/niublab/know/main/setup.sh)

set -euo pipefail

# 脚本配置
VERSION="1.0.2"
WORK_DIR="$HOME/matrix-deploy"
GITHUB_USER="niublab"
GITHUB_REPO="know"
GITHUB_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/$GITHUB_BRANCH"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

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

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 显示横幅
show_banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║           Matrix 服务器自动化部署工具 v$VERSION              ║"
    echo "║                                                              ║"
    echo "║  🚀 专为内网环境和ISP端口封锁设计                            ║"
    echo "║  🔒 支持自定义端口和完整证书管理                             ║"
    echo "║  🎯 一键部署，菜单式交互                                     ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo
}

# 检查系统要求
check_system() {
    log_info "检查系统要求..."
    
    # 检查操作系统
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测操作系统"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
        log_warn "检测到非Ubuntu/Debian系统: $PRETTY_NAME"
        log_warn "脚本可能无法正常工作"
    else
        log_info "操作系统: $PRETTY_NAME ✓"
    fi
    
    # 检查架构
    local arch=$(uname -m)
    if [[ "$arch" != "x86_64" && "$arch" != "aarch64" ]]; then
        log_error "不支持的架构: $arch"
        exit 1
    fi
    log_info "系统架构: $arch ✓"
    
    # 检查内存
    local mem_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $mem_gb -lt 2 ]]; then
        log_warn "内存不足: ${mem_gb}GB (推荐≥2GB)"
    else
        log_info "系统内存: ${mem_gb}GB ✓"
    fi
    
    # 检查磁盘空间
    local disk_gb=$(df -BG "$HOME" | awk 'NR==2{print $4}' | sed 's/G//')
    if [[ $disk_gb -lt 10 ]]; then
        log_warn "磁盘空间不足: ${disk_gb}GB (推荐≥10GB)"
    else
        log_info "可用磁盘: ${disk_gb}GB ✓"
    fi
}

# 检查权限
check_permissions() {
    log_info "检查用户权限..."
    
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要以 root 用户运行此脚本"
        log_info "请切换到普通用户后重新运行:"
        log_info "  su - your_username"
        log_info "  bash <(curl -fsSL $BASE_URL/setup.sh)"
        exit 1
    fi
    
    log_info "当前用户: $(whoami) ✓"
    
    # 检查sudo权限
    if ! sudo -n true 2>/dev/null; then
        log_warn "需要sudo权限，请输入密码"
        if ! sudo -v; then
            log_error "无法获取sudo权限"
            exit 1
        fi
    fi
    log_info "Sudo权限: 可用 ✓"
}

# 检查网络连接
check_network() {
    log_info "检查网络连接..."
    
    local test_urls=(
        "github.com"
        "raw.githubusercontent.com"
        "get.k3s.io"
    )
    
    for url in "${test_urls[@]}"; do
        if ! curl -s --connect-timeout 5 --head "https://$url" >/dev/null; then
            log_error "无法连接到: $url"
            log_error "请检查网络连接"
            exit 1
        fi
    done
    
    log_info "网络连接: 正常 ✓"
}

# 安装基础依赖
install_dependencies() {
    log_info "安装基础依赖..."
    
    # 更新包列表
    sudo apt-get update -qq
    
    # 安装必要的包
    local packages=(
        "curl"
        "wget"
        "git"
        "openssl"
        "jq"
        "dnsutils"
        "ca-certificates"
        "gnupg"
        "lsb-release"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            log_info "安装: $package"
            sudo apt-get install -y "$package" >/dev/null 2>&1
        fi
    done
    
    log_info "基础依赖安装完成 ✓"
}

# 创建工作目录
create_work_directory() {
    log_info "创建工作目录: $WORK_DIR"
    
    # 如果目录已存在，询问是否覆盖
    if [[ -d "$WORK_DIR" ]]; then
        log_warn "工作目录已存在: $WORK_DIR"
        read -p "是否覆盖现有目录? (y/N): " overwrite
        if [[ "$overwrite" == "y" || "$overwrite" == "Y" ]]; then
            rm -rf "$WORK_DIR"
        else
            log_error "部署已取消"
            exit 1
        fi
    fi
    
    mkdir -p "$WORK_DIR"
    mkdir -p "$WORK_DIR/config"
    cd "$WORK_DIR"
    
    log_info "工作目录创建完成 ✓"
}

# 下载部署脚本
download_scripts() {
    log_info "下载部署脚本..."
    
    local scripts=(
        "matrix-deploy.sh"
        "cert-manager.sh"
        "config-templates.sh"
        "test-deployment.sh"
    )
    
    local docs=(
        "README.md"
    )
    
    # 下载脚本文件
    for script in "${scripts[@]}"; do
        log_info "下载: $script"
        if ! curl -fsSL "$BASE_URL/$script" -o "$script"; then
            log_error "下载失败: $script"
            log_error "请检查GitHub仓库是否存在该文件"
            exit 1
        fi
        chmod +x "$script"
    done
    
    # 下载文档文件
    for doc in "${docs[@]}"; do
        log_info "下载: $doc"
        curl -fsSL "$BASE_URL/$doc" -o "$doc" 2>/dev/null || log_warn "文档下载失败: $doc"
    done
    
    log_info "脚本下载完成 ✓"
}

# 修复脚本配置
fix_script_config() {
    log_info "配置脚本环境..."
    
    # 修改脚本中的路径引用
    if [[ -f "matrix-deploy.sh" ]]; then
        sed -i "s|SCRIPT_DIR=\".*\"|SCRIPT_DIR=\"$WORK_DIR\"|g" "matrix-deploy.sh"
    fi
    
    if [[ -f "cert-manager.sh" ]]; then
        sed -i "s|SCRIPT_DIR=\".*\"|SCRIPT_DIR=\"$WORK_DIR\"|g" "cert-manager.sh"
    fi
    
    log_info "脚本配置完成 ✓"
}

# 验证安装
verify_installation() {
    log_info "验证安装..."
    
    local required_files=(
        "matrix-deploy.sh"
        "cert-manager.sh"
        "config-templates.sh"
        "test-deployment.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            log_error "缺少文件: $file"
            exit 1
        fi
        
        if [[ ! -x "$file" ]]; then
            log_error "文件不可执行: $file"
            exit 1
        fi
    done
    
    log_info "安装验证完成 ✓"
}

# 显示使用说明
show_usage() {
    echo
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                        ${GREEN}部署完成！${NC}                           ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${WHITE}工作目录:${NC} $WORK_DIR"
    echo
    echo -e "${YELLOW}🚀 快速开始:${NC}"
    echo -e "   ${BLUE}cd $WORK_DIR${NC}"
    echo -e "   ${BLUE}./matrix-deploy.sh${NC}"
    echo
    echo -e "${YELLOW}📋 部署步骤:${NC}"
    echo -e "   1. 初始化部署环境 (安装K3s、Helm等)"
    echo -e "   2. 配置服务参数 (域名、端口、证书等)"
    echo -e "   3. 部署Matrix服务 (自动部署所有组件)"
    echo -e "   4. 证书管理 (申请和配置SSL证书)"
    echo
    echo -e "${YELLOW}🛠️ 其他工具:${NC}"
    echo -e "   ${BLUE}./cert-manager.sh${NC}     # 证书管理工具"
    echo -e "   ${BLUE}./test-deployment.sh${NC}  # 部署测试工具"
    echo -e "   ${BLUE}less README.md${NC}        # 查看详细文档"
    echo
    echo -e "${RED}⚠️  部署前准备:${NC}"
    echo -e "   • 确保域名A记录指向公网IP"
    echo -e "   • 配置路由器端口转发 (8080→8080, 8443→8443)"
    echo -e "   • 准备Cloudflare API Token"
    echo -e "   • 确保DDNS服务正常运行"
    echo
    echo -e "${GREEN}📖 详细文档:${NC} https://github.com/$GITHUB_USER/$GITHUB_REPO"
    echo
}

# 询问是否立即开始
ask_start_deployment() {
    echo -e "${YELLOW}是否立即开始部署? (y/N):${NC} "
    read -r start_now
    
    if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
        echo
        log_info "启动Matrix部署工具..."
        exec ./matrix-deploy.sh
    else
        echo
        log_success "准备完成！请运行以下命令开始部署:"
        echo -e "  ${BLUE}cd $WORK_DIR && ./matrix-deploy.sh${NC}"
    fi
}

# 错误处理
handle_error() {
    local exit_code=$?
    echo
    log_error "部署脚本执行失败 (退出码: $exit_code)"
    log_error "请检查上述错误信息并重试"
    echo
    log_info "如需帮助，请访问: https://github.com/$GITHUB_USER/$GITHUB_REPO/issues"
    exit $exit_code
}

# 主函数
main() {
    # 设置错误处理
    trap handle_error ERR
    
    # 显示横幅
    show_banner
    
    # 系统检查
    check_system
    check_permissions
    check_network
    
    # 安装和配置
    install_dependencies
    create_work_directory
    download_scripts
    fix_script_config
    verify_installation
    
    # 显示使用说明
    show_usage
    
    # 询问是否开始部署
    ask_start_deployment
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
