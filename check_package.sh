#!/bin/bash

# Element ESS v2.1 部署包完整性检查脚本

echo "🔍 检查 Element ESS v2.1 部署包完整性..."

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 检查计数器
total_checks=0
passed_checks=0

# 检查函数
check_file() {
    local file_path="$1"
    local description="$2"
    
    total_checks=$((total_checks + 1))
    
    if [[ -f "$file_path" ]]; then
        echo -e "${GREEN}✅${NC} $description: $file_path"
        passed_checks=$((passed_checks + 1))
    else
        echo -e "${RED}❌${NC} $description: $file_path (缺失)"
    fi
}

check_dir() {
    local dir_path="$1"
    local description="$2"
    
    total_checks=$((total_checks + 1))
    
    if [[ -d "$dir_path" ]]; then
        echo -e "${GREEN}✅${NC} $description: $dir_path"
        passed_checks=$((passed_checks + 1))
    else
        echo -e "${RED}❌${NC} $description: $dir_path (缺失)"
    fi
}

echo ""
echo "📋 核心文件检查:"

# 核心配置文件
check_file ".env.template" "环境变量配置模板"
check_file "README.md" "主要说明文档"
check_file "RELEASE_NOTES_v2.1.md" "版本发布说明"
check_file "FINAL_DEPLOYMENT_PACKAGE.md" "最终部署指南"

echo ""
echo "🖥️ 内部服务器文件检查:"

# 内部服务器核心文件
check_file "internal_server/auto_deploy.sh" "自动部署脚本"
check_file "internal_server/docker-compose.yml" "Docker Compose配置"

# 脚本文件
check_file "internal_server/scripts/admin" "系统管理命令"
check_file "internal_server/scripts/element_admin.py" "Web管理工具"
check_file "internal_server/scripts/wan_ip_monitor.py" "WAN IP监控脚本"
check_file "internal_server/scripts/wan-ip-monitor.service" "WAN IP监控服务"

# 配置模板
check_dir "internal_server/configs" "配置模板目录"
check_file "internal_server/configs/nginx.conf.template" "Nginx配置模板"
check_file "internal_server/configs/livekit.yaml.template" "LiveKit配置模板"
check_file "internal_server/configs/element-web-config.json.template" "Element Web配置模板"
check_file "internal_server/configs/homeserver.yaml.template" "Synapse配置模板"
check_file "internal_server/configs/coturn.conf.template" "Coturn配置模板"

echo ""
echo "🌐 外部服务器文件检查:"

# 外部服务器文件
check_file "external_server/manual_deployment_guide.md" "外部服务器部署指南"
check_file "external_server/nginx.conf.template" "外部服务器Nginx配置"

echo ""
echo "📡 RouterOS文件检查:"

# RouterOS文件
check_file "routeros/ddns_setup_guide.md" "DDNS设置指南"
check_file "routeros/cloudflare_ddns_v2.rsc" "Cloudflare DDNS脚本"

echo ""
echo "📚 文档文件检查:"

# 文档文件
check_file "docs/deployment_guide_v2.1.md" "详细部署指南"
check_file "docs/turn_services_comparison.md" "TURN服务对比文档"

echo ""
echo "🔧 执行权限检查:"

# 检查执行权限
if [[ -x "internal_server/auto_deploy.sh" ]]; then
    echo -e "${GREEN}✅${NC} auto_deploy.sh 具有执行权限"
    passed_checks=$((passed_checks + 1))
else
    echo -e "${YELLOW}⚠️${NC}  auto_deploy.sh 缺少执行权限 (运行 chmod +x internal_server/auto_deploy.sh)"
fi
total_checks=$((total_checks + 1))

if [[ -x "internal_server/scripts/admin" ]]; then
    echo -e "${GREEN}✅${NC} admin 命令具有执行权限"
    passed_checks=$((passed_checks + 1))
else
    echo -e "${YELLOW}⚠️${NC}  admin 命令缺少执行权限 (运行 chmod +x internal_server/scripts/admin)"
fi
total_checks=$((total_checks + 1))

if [[ -x "check_package.sh" ]]; then
    echo -e "${GREEN}✅${NC} check_package.sh 具有执行权限"
    passed_checks=$((passed_checks + 1))
else
    echo -e "${YELLOW}⚠️${NC}  check_package.sh 缺少执行权限"
fi
total_checks=$((total_checks + 1))

echo ""
echo "📊 检查结果总结:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "总检查项: ${BLUE}$total_checks${NC}"
echo -e "通过检查: ${GREEN}$passed_checks${NC}"
echo -e "失败检查: ${RED}$((total_checks - passed_checks))${NC}"

if [[ $passed_checks -eq $total_checks ]]; then
    echo ""
    echo -e "${GREEN}🎉 恭喜！部署包完整性检查全部通过！${NC}"
    echo -e "${GREEN}📦 Element ESS v2.1 部署包已准备就绪${NC}"
    echo ""
    echo "🚀 快速开始:"
    echo "1. cp .env.template .env"
    echo "2. nano .env  # 填写域名和API Token"
    echo "3. cd internal_server && sudo ./auto_deploy.sh"
    echo ""
elif [[ $passed_checks -gt $((total_checks * 3 / 4)) ]]; then
    echo ""
    echo -e "${YELLOW}⚠️  部署包基本完整，但有少量问题需要处理${NC}"
    echo -e "${YELLOW}🔧 请修复上述缺失的文件后再进行部署${NC}"
else
    echo ""
    echo -e "${RED}❌ 部署包存在重要文件缺失，请检查并修复${NC}"
    echo -e "${RED}🛠️  建议重新下载完整的部署包${NC}"
fi

echo ""
echo -e "${BLUE}📋 Element ESS v2.1 部署包检查完成${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
