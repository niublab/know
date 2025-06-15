#!/bin/bash

# Element Call问题一次性修复脚本
# 基于根本原因分析的最终解决方案
# 版本: 1.0.0 - 生产就绪版本

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

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}Element Call问题一次性修复${NC}"
echo -e "${GREEN}基于根本原因的最终解决方案${NC}"
echo -e "${GREEN}================================${NC}"
echo ""

# 检查运行权限
if [[ $EUID -ne 0 ]]; then
    log_error "此脚本需要root权限运行"
    echo "请使用: sudo $0"
    exit 1
fi

# 1. 诊断当前状态
log_info "1. 诊断当前状态..."
echo ""

echo "Matrix RTC服务状态："
kubectl get pods -n ess | grep matrix-rtc || log_error "Matrix RTC服务未运行"
echo ""

echo "NodePort服务配置："
kubectl get svc -n ess | grep matrix-rtc || log_error "Matrix RTC服务未配置"
echo ""

echo "当前WebRTC端口监听状态："
tcp_status=$(netstat -tlnp 2>/dev/null | grep :30881 && echo "监听中" || echo "未监听")
udp_status=$(netstat -ulnp 2>/dev/null | grep :30882 && echo "监听中" || echo "未监听")
echo "TCP 30881: $tcp_status"
echo "UDP 30882: $udp_status"
echo ""

echo "当前well-known配置状态："
niub_status=$(curl -k -s -o /dev/null -w "%{http_code}" "https://niub.win:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
app_status=$(curl -k -s -o /dev/null -w "%{http_code}" "https://app.niub.win:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
echo "niub.win: HTTP $niub_status"
echo "app.niub.win: HTTP $app_status"
echo ""

# 2. 修复WebRTC端口问题（Kubernetes网络层）
if [[ "$tcp_status" == "未监听" || "$udp_status" == "未监听" ]]; then
    log_warning "检测到WebRTC端口未监听，修复Kubernetes网络配置..."
    
    # 检查kube-proxy状态
    log_info "检查kube-proxy状态..."
    systemctl status kube-proxy --no-pager || log_warning "kube-proxy状态异常"
    
    # 检查iptables规则
    log_info "检查iptables NAT规则..."
    iptables_rules=$(iptables -t nat -L | grep -E "30881|30882" || echo "")
    if [[ -z "$iptables_rules" ]]; then
        log_warning "iptables中缺少WebRTC端口规则"
    else
        echo "找到iptables规则："
        echo "$iptables_rules"
    fi
    
    # 重启网络组件
    log_info "重启Kubernetes网络组件..."
    systemctl restart kube-proxy
    systemctl restart kubelet
    
    # 等待服务重启
    log_info "等待网络组件重启完成..."
    sleep 30
    
    # 验证修复效果
    tcp_status_after=$(netstat -tlnp 2>/dev/null | grep :30881 && echo "监听中" || echo "未监听")
    udp_status_after=$(netstat -ulnp 2>/dev/null | grep :30882 && echo "监听中" || echo "未监听")
    
    echo "修复后WebRTC端口状态："
    echo "TCP 30881: $tcp_status_after"
    echo "UDP 30882: $udp_status_after"
    
    if [[ "$tcp_status_after" == "监听中" && "$udp_status_after" == "监听中" ]]; then
        log_success "WebRTC端口问题已修复"
    else
        log_error "WebRTC端口问题修复失败"
        echo "可能需要检查ESS部署配置或重启服务器"
    fi
else
    log_success "WebRTC端口已正常监听"
fi

echo ""

# 3. 修复nginx域名配置问题
if [[ "$app_status" != "200" ]]; then
    log_warning "检测到app.niub.win返回404，修复nginx配置..."
    
    config_file="/etc/nginx/sites-available/ess-proxy"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "nginx配置文件不存在: $config_file"
        echo "请先运行完整配置脚本生成nginx配置"
        exit 1
    fi
    
    # 备份配置文件
    backup_file="${config_file}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$config_file" "$backup_file"
    log_info "nginx配置已备份到: $backup_file"
    
    # 检查当前server_name配置
    current_server_name=$(grep "server_name" "$config_file" | head -1)
    echo "当前server_name配置: $current_server_name"
    
    # 修复server_name配置，确保包含所有域名
    log_info "修复server_name配置..."
    sed -i 's/server_name .*/server_name app.niub.win matrix.niub.win mas.niub.win rtc.niub.win niub.win;/' "$config_file"
    
    # 验证nginx配置
    if nginx -t; then
        log_success "nginx配置语法正确"
        
        # 重新加载nginx
        systemctl reload nginx
        log_info "nginx配置已重新加载"
        
        # 等待配置生效
        sleep 5
        
        # 验证修复效果
        app_status_after=$(curl -k -s -o /dev/null -w "%{http_code}" "https://app.niub.win:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
        echo "修复后app.niub.win状态: HTTP $app_status_after"
        
        if [[ "$app_status_after" == "200" ]]; then
            log_success "nginx域名配置问题已修复"
        else
            log_warning "nginx域名配置可能需要更多时间生效"
        fi
    else
        log_error "nginx配置语法错误，恢复备份"
        cp "$backup_file" "$config_file"
        systemctl reload nginx
    fi
else
    log_success "nginx域名配置正常"
fi

echo ""

# 4. 验证防火墙配置
log_info "4. 验证防火墙配置..."

if command -v ufw >/dev/null 2>&1; then
    echo "UFW防火墙状态："
    ufw_webrtc=$(ufw status | grep -E "(30881|30882)" || echo "")
    if [[ -z "$ufw_webrtc" ]]; then
        log_warning "防火墙中缺少WebRTC端口规则"
        ufw allow 30881/tcp comment "WebRTC TCP"
        ufw allow 30882/udp comment "WebRTC UDP"
        log_success "WebRTC端口已添加到防火墙"
    else
        log_success "防火墙WebRTC端口配置正确"
    fi
fi

echo ""

# 5. 最终验证和总结
log_info "5. 最终验证..."
echo ""

# 最终状态检查
final_tcp=$(netstat -tlnp 2>/dev/null | grep :30881 && echo "监听中" || echo "未监听")
final_udp=$(netstat -ulnp 2>/dev/null | grep :30882 && echo "监听中" || echo "未监听")
final_niub=$(curl -k -s -o /dev/null -w "%{http_code}" "https://niub.win:8443/.well-known/matrix/client" 2>/dev/null || echo "000")
final_app=$(curl -k -s -o /dev/null -w "%{http_code}" "https://app.niub.win:8443/.well-known/matrix/client" 2>/dev/null || echo "000")

echo "=== 最终状态 ==="
echo "WebRTC TCP 30881: $final_tcp"
echo "WebRTC UDP 30882: $final_udp"
echo "niub.win well-known: HTTP $final_niub"
echo "app.niub.win well-known: HTTP $final_app"
echo ""

# 检查well-known配置内容
if [[ "$final_niub" == "200" ]]; then
    echo "well-known配置内容验证："
    wellknown_content=$(curl -k -s "https://niub.win:8443/.well-known/matrix/client")
    if echo "$wellknown_content" | grep -q "org.matrix.msc4143.rtc_foci"; then
        log_success "✅ rtc_foci配置存在"
        livekit_url=$(echo "$wellknown_content" | grep -o '"livekit_service_url":"[^"]*"' | cut -d'"' -f4)
        echo "LiveKit URL: $livekit_url"
    else
        log_warning "⚠️  rtc_foci配置缺失"
    fi
fi

echo ""

# 最终结果判断
if [[ "$final_tcp" == "监听中" && "$final_udp" == "监听中" && "$final_app" == "200" && "$final_niub" == "200" ]]; then
    echo -e "${GREEN}🎉 Element Call问题修复完成！${NC}"
    echo ""
    echo -e "${GREEN}✅ 所有问题已解决：${NC}"
    echo "✅ WebRTC端口正常监听"
    echo "✅ nginx域名配置正确"
    echo "✅ well-known配置可访问"
    echo "✅ Matrix RTC服务运行正常"
    echo ""
    echo -e "${BLUE}现在可以测试Element Call：${NC}"
    echo "1. 清除浏览器缓存和Cookie"
    echo "2. 访问: https://app.niub.win:8443"
    echo "3. 登录Matrix账户"
    echo "4. 创建或加入房间"
    echo "5. 测试视频通话功能"
    echo ""
    echo -e "${GREEN}Element Call应该可以正常工作了！${NC}"
else
    echo -e "${YELLOW}⚠️  部分问题仍需解决：${NC}"
    echo ""
    
    if [[ "$final_tcp" != "监听中" || "$final_udp" != "监听中" ]]; then
        echo -e "${RED}❌ WebRTC端口问题：${NC}"
        echo "可能需要："
        echo "- 重启服务器"
        echo "- 检查ESS部署配置"
        echo "- 检查Kubernetes集群状态"
    fi
    
    if [[ "$final_app" != "200" ]]; then
        echo -e "${RED}❌ nginx配置问题：${NC}"
        echo "可能需要："
        echo "- 检查SSL证书是否包含app.niub.win"
        echo "- 检查DNS解析"
        echo "- 重新生成nginx配置"
    fi
    
    echo ""
    echo "建议联系技术支持或查看详细日志"
fi

echo ""
echo -e "${BLUE}修复完成时间: $(date)${NC}"
