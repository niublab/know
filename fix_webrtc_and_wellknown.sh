#!/bin/bash

# WebRTC端口和well-known配置专项修复脚本
# 基于实际问题的针对性修复

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
echo -e "${BLUE}WebRTC端口和well-known专项修复${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# 1. 深度检查WebRTC端口问题
log_info "1. 深度检查WebRTC端口问题..."
echo ""

echo "当前端口监听状态："
echo "TCP 30881: $(netstat -tlnp 2>/dev/null | grep :30881 || echo '未监听')"
echo "UDP 30882: $(netstat -ulnp 2>/dev/null | grep :30882 || echo '未监听')"
echo ""

echo "Matrix RTC服务状态："
kubectl get pods -n ess | grep matrix-rtc
echo ""

echo "Matrix RTC服务配置："
kubectl get svc -n ess | grep matrix-rtc
echo ""

# 检查NodePort服务的详细配置
log_info "检查NodePort服务详细配置..."
echo ""
echo "=== Matrix RTC SFU TCP服务 ==="
kubectl describe svc ess-matrix-rtc-sfu-tcp -n ess 2>/dev/null || echo "服务不存在"
echo ""
echo "=== Matrix RTC SFU UDP服务 ==="
kubectl describe svc ess-matrix-rtc-sfu-muxed-udp -n ess 2>/dev/null || echo "服务不存在"
echo ""

# 2. 检查well-known配置问题
log_info "2. 检查well-known配置问题..."
echo ""

echo "测试不同域名的well-known配置："
domains=("niub.win" "app.niub.win" "matrix.niub.win" "mas.niub.win" "rtc.niub.win")

for domain in "${domains[@]}"; do
    echo -n "$domain: "
    status=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$domain:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        echo -e "${GREEN}HTTP $status ✅${NC}"
    else
        echo -e "${RED}HTTP $status ❌${NC}"
    fi
done
echo ""

# 3. 检查nginx配置
log_info "3. 检查nginx配置..."
echo ""

echo "nginx配置测试："
if nginx -t 2>/dev/null; then
    echo -e "${GREEN}✅ nginx配置语法正确${NC}"
else
    echo -e "${RED}❌ nginx配置有语法错误${NC}"
    nginx -t
fi
echo ""

echo "nginx server_name配置："
grep "server_name" /etc/nginx/sites-available/ess-proxy 2>/dev/null || echo "配置文件不存在"
echo ""

# 4. 修复WebRTC端口问题
log_info "4. 修复WebRTC端口问题..."
echo ""

read -p "是否重启Matrix RTC服务以修复端口问题? [y/N]: " fix_rtc
if [[ "$fix_rtc" =~ ^[Yy]$ ]]; then
    echo ""
    log_info "重启Matrix RTC服务..."
    
    kubectl rollout restart deployment ess-matrix-rtc-sfu -n ess
    kubectl rollout restart deployment ess-matrix-rtc-authorisation-service -n ess
    
    log_info "等待服务重启完成..."
    kubectl rollout status deployment ess-matrix-rtc-sfu -n ess --timeout=300s
    kubectl rollout status deployment ess-matrix-rtc-authorisation-service -n ess --timeout=300s
    
    log_info "等待端口启动..."
    sleep 20
    
    echo ""
    echo "重启后端口状态："
    echo "TCP 30881: $(netstat -tlnp 2>/dev/null | grep :30881 || echo '未监听')"
    echo "UDP 30882: $(netstat -ulnp 2>/dev/null | grep :30882 || echo '未监听')"
    echo ""
fi

# 5. 修复nginx配置问题
log_info "5. 修复nginx配置问题..."
echo ""

read -p "是否重新生成nginx配置以修复app.niub.win问题? [y/N]: " fix_nginx
if [[ "$fix_nginx" =~ ^[Yy]$ ]]; then
    echo ""
    log_info "备份当前nginx配置..."
    cp /etc/nginx/sites-available/ess-proxy /etc/nginx/sites-available/ess-proxy.backup.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
    
    log_info "重新生成nginx配置..."
    # 这里需要重新运行nginx配置生成
    echo "请运行以下命令重新生成nginx配置："
    echo "bash <(curl -fsSL https://raw.githubusercontent.com/niublab/know/main/manage.sh)"
    echo "选择选项1进行完整配置"
    echo ""
fi

# 6. 检查防火墙配置
log_info "6. 检查防火墙配置..."
echo ""

if command -v ufw >/dev/null 2>&1; then
    echo "UFW状态："
    ufw status | grep -E "(30881|30882|8443)" || echo "WebRTC端口未在防火墙中开放"
    echo ""
    
    read -p "是否开放WebRTC端口到防火墙? [y/N]: " fix_firewall
    if [[ "$fix_firewall" =~ ^[Yy]$ ]]; then
        ufw allow 30881/tcp comment "WebRTC TCP"
        ufw allow 30882/udp comment "WebRTC UDP"
        log_success "防火墙规则已添加"
    fi
fi

# 7. 最终验证
echo ""
log_info "7. 最终验证..."
echo ""

echo "=== 最终WebRTC端口状态 ==="
tcp_final=$(netstat -tlnp 2>/dev/null | grep :30881 && echo "监听中" || echo "未监听")
udp_final=$(netstat -ulnp 2>/dev/null | grep :30882 && echo "监听中" || echo "未监听")
echo "TCP 30881: $tcp_final"
echo "UDP 30882: $udp_final"
echo ""

echo "=== 最终well-known状态 ==="
for domain in "${domains[@]}"; do
    echo -n "$domain: "
    status=$(curl -k -s -o /dev/null -w "%{http_code}" "https://$domain:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
    if [[ "$status" == "200" ]]; then
        echo -e "${GREEN}HTTP $status ✅${NC}"
    else
        echo -e "${RED}HTTP $status ❌${NC}"
    fi
done
echo ""

# 8. 提供修复建议
echo ""
echo -e "${BLUE}=== 修复建议 ===${NC}"

if [[ "$tcp_final" == "监听中" && "$udp_final" == "监听中" ]]; then
    echo -e "${GREEN}✅ WebRTC端口问题已解决${NC}"
else
    echo -e "${RED}❌ WebRTC端口仍有问题${NC}"
    echo ""
    echo "可能的原因："
    echo "1. ESS部署配置问题 - Matrix RTC服务的NodePort配置错误"
    echo "2. Kubernetes网络问题 - 集群网络配置问题"
    echo "3. 资源不足 - 服务无法正常启动"
    echo ""
    echo "建议检查："
    echo "- kubectl describe pod -n ess -l app.kubernetes.io/name=matrix-rtc-sfu"
    echo "- kubectl logs -n ess -l app.kubernetes.io/name=matrix-rtc-sfu"
    echo "- kubectl get svc -n ess -o yaml | grep -A 20 matrix-rtc"
fi

# 检查app.niub.win状态
app_status=$(curl -k -s -o /dev/null -w "%{http_code}" "https://app.niub.win:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
if [[ "$app_status" == "200" ]]; then
    echo -e "${GREEN}✅ app.niub.win well-known问题已解决${NC}"
else
    echo -e "${RED}❌ app.niub.win well-known仍返回HTTP $app_status${NC}"
    echo ""
    echo "可能的原因："
    echo "1. nginx配置问题 - server_name不包含app.niub.win"
    echo "2. DNS解析问题 - app.niub.win没有正确解析"
    echo "3. SSL证书问题 - 证书不包含app.niub.win域名"
    echo ""
    echo "建议检查："
    echo "- nslookup app.niub.win"
    echo "- openssl s_client -connect app.niub.win:8443 -servername app.niub.win"
    echo "- nginx配置中的server_name设置"
fi

echo ""
echo -e "${BLUE}=== 总结 ===${NC}"
echo "WebRTC端口: $tcp_final (TCP) / $udp_final (UDP)"
echo "app.niub.win: HTTP $app_status"
echo ""
echo "如果问题仍然存在，建议："
echo "1. 检查ESS部署的Matrix RTC配置"
echo "2. 重新运行完整配置脚本"
echo "3. 检查DNS和SSL证书配置"
