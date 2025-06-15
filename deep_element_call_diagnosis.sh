#!/bin/bash

# Element Call深度诊断脚本
# 专门解决MISSING_MATRIX_RTC_FOCUS错误
# 版本: 1.0.0

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}Element Call深度诊断工具${NC}"
echo -e "${BLUE}专门解决MISSING_MATRIX_RTC_FOCUS${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# 1. 检查well-known配置的实际访问
log_info "1. 检查well-known配置实际访问情况..."
echo ""
echo -e "${YELLOW}=== well-known/matrix/client 配置 ===${NC}"
if command -v python3 >/dev/null 2>&1; then
    curl -k -s https://niub.win:8443/.well-known/matrix/client | python3 -m json.tool || curl -k -s https://niub.win:8443/.well-known/matrix/client
else
    curl -k -s https://niub.win:8443/.well-known/matrix/client
fi
echo ""

# 2. 检查Element Web访问的well-known
log_info "2. 检查Element Web域名的well-known配置..."
echo ""
echo -e "${YELLOW}=== app.niub.win well-known配置 ===${NC}"
if command -v python3 >/dev/null 2>&1; then
    curl -k -s https://app.niub.win:8443/.well-known/matrix/client | python3 -m json.tool || curl -k -s https://app.niub.win:8443/.well-known/matrix/client
else
    curl -k -s https://app.niub.win:8443/.well-known/matrix/client
fi
echo ""

# 3. 检查Matrix RTC服务详细状态
log_info "3. 检查Matrix RTC服务详细状态..."
echo ""
echo -e "${YELLOW}=== Matrix RTC SFU Pod状态 ===${NC}"
kubectl describe pod -n ess -l app.kubernetes.io/name=matrix-rtc-sfu | head -30
echo ""

echo -e "${YELLOW}=== Matrix RTC Auth Service Pod状态 ===${NC}"
kubectl describe pod -n ess -l app.kubernetes.io/name=matrix-rtc-authorisation-service | head -30
echo ""

# 4. 检查Matrix RTC服务日志
log_info "4. 检查Matrix RTC服务日志..."
echo ""
echo -e "${YELLOW}=== Matrix RTC SFU 最近日志 ===${NC}"
kubectl logs -n ess -l app.kubernetes.io/name=matrix-rtc-sfu --tail=20 || echo "无法获取SFU日志"
echo ""

echo -e "${YELLOW}=== Matrix RTC Auth Service 最近日志 ===${NC}"
kubectl logs -n ess -l app.kubernetes.io/name=matrix-rtc-authorisation-service --tail=20 || echo "无法获取Auth Service日志"
echo ""

# 5. 检查Synapse配置
log_info "5. 检查Synapse experimental_features配置..."
echo ""
echo -e "${YELLOW}=== Synapse ConfigMap检查 ===${NC}"
kubectl get configmap -n ess | grep synapse
echo ""

echo -e "${YELLOW}=== Synapse experimental_features配置 ===${NC}"
kubectl get configmap ess-synapse-main -n ess -o yaml | grep -A 20 -B 5 experimental || echo "未找到experimental_features配置"
echo ""

# 6. 检查Matrix RTC Ingress详细信息
log_info "6. 检查Matrix RTC Ingress详细配置..."
echo ""
echo -e "${YELLOW}=== Matrix RTC Ingress详细信息 ===${NC}"
kubectl describe ingress ess-matrix-rtc -n ess || echo "无法获取Matrix RTC Ingress信息"
echo ""

# 7. 测试Matrix RTC服务连通性
log_info "7. 测试Matrix RTC服务连通性..."
echo ""
echo -e "${YELLOW}=== Matrix RTC服务连通性测试 ===${NC}"
echo "测试rtc.niub.win:8443连通性..."
if curl -k -s --connect-timeout 10 https://rtc.niub.win:8443 >/dev/null 2>&1; then
    echo -e "${GREEN}✅ rtc.niub.win:8443 可访问${NC}"
else
    echo -e "${RED}❌ rtc.niub.win:8443 不可访问${NC}"
fi

# 8. 检查WebRTC端口状态
log_info "8. 检查WebRTC端口状态..."
echo ""
echo -e "${YELLOW}=== WebRTC端口监听状态 ===${NC}"
echo "TCP 30881: $(netstat -tlnp 2>/dev/null | grep :30881 || echo '未监听')"
echo "UDP 30882: $(netstat -ulnp 2>/dev/null | grep :30882 || echo '未监听')"
echo ""

# 9. 生成修复建议
log_info "9. 生成修复建议..."
echo ""
echo -e "${BLUE}=== 修复建议 ===${NC}"

# 检查well-known是否包含rtc_foci
well_known_content=$(curl -k -s https://niub.win:8443/.well-known/matrix/client)
if echo "$well_known_content" | grep -q "org.matrix.msc4143.rtc_foci"; then
    echo -e "${GREEN}✅ well-known配置包含rtc_foci${NC}"
    
    # 检查LiveKit URL
    if echo "$well_known_content" | grep -q "https://rtc.niub.win:8443"; then
        echo -e "${GREEN}✅ LiveKit URL配置正确${NC}"
        
        echo ""
        echo -e "${YELLOW}配置看起来正确，但Element Call仍不工作。可能的原因：${NC}"
        echo ""
        echo "1. 🔄 Synapse experimental_features未启用："
        echo "   需要在Synapse配置中启用MSC3266和相关实验性功能"
        echo ""
        echo "2. 🔄 服务重启问题："
        echo "   Matrix RTC服务可能需要重启以正确注册到Synapse"
        echo ""
        echo "3. 🔄 时序问题："
        echo "   服务启动顺序可能导致Matrix RTC未正确注册"
        echo ""
        echo -e "${BLUE}建议的修复步骤：${NC}"
        echo "1. 重启Matrix RTC服务："
        echo "   kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess"
        echo "   kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess"
        echo ""
        echo "2. 重启Synapse服务："
        echo "   kubectl rollout restart deployment ess-synapse-main -n ess"
        echo ""
        echo "3. 等待所有服务完全启动后测试"
        echo ""
        echo "4. 如果仍有问题，检查Synapse日志："
        echo "   kubectl logs -n ess deployment/ess-synapse-main --tail=50"
        
    else
        echo -e "${RED}❌ LiveKit URL配置错误${NC}"
        echo "需要修复well-known配置中的LiveKit URL"
    fi
else
    echo -e "${RED}❌ well-known配置缺少rtc_foci${NC}"
    echo "需要修复well-known配置"
fi

echo ""
echo -e "${BLUE}=== 诊断完成 ===${NC}"
echo "请根据上述建议进行修复，或将此诊断结果提供给技术支持。"
