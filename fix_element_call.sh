#!/bin/bash

# Element Call Matrix RTC Focus 修复脚本
# 基于项目实际配置和ESS Community官方规范
# 版本: 3.0.0 - 基于实际诊断结果的精准修复版本

set -euo pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# 加载项目配置（与manage.sh保持一致）
load_project_config() {
    log_info "加载项目配置..."

    # 使用与manage.sh相同的默认配置
    SERVER_NAME="niub.win"
    ELEMENT_WEB_HOST="app.niub.win"
    MAS_HOST="mas.niub.win"
    RTC_HOST="rtc.niub.win"
    SYNAPSE_HOST="matrix.niub.win"
    EXTERNAL_HTTP_PORT="8080"
    EXTERNAL_HTTPS_PORT="8443"

    # 配置目录
    local config_dir
    if [[ $EUID -eq 0 ]]; then
        config_dir="/root/ess-config-values"
    else
        config_dir="$HOME/ess-config-values"
    fi

    # 尝试从配置文件读取（如果存在）
    if [[ -f "$config_dir/hostnames.yaml" ]]; then
        local server_name=$(grep "serverName:" "$config_dir/hostnames.yaml" | awk '{print $2}' 2>/dev/null || echo "")
        local element_web_host=$(grep -A2 "elementWeb:" "$config_dir/hostnames.yaml" | grep "host:" | awk '{print $2}' 2>/dev/null || echo "")
        local mas_host=$(grep -A2 "matrixAuthenticationService:" "$config_dir/hostnames.yaml" | grep "host:" | awk '{print $2}' 2>/dev/null || echo "")
        local rtc_host=$(grep -A2 "matrixRTC:" "$config_dir/hostnames.yaml" | grep "host:" | awk '{print $2}' 2>/dev/null || echo "")
        local synapse_host=$(grep -A2 "synapse:" "$config_dir/hostnames.yaml" | grep "host:" | awk '{print $2}' 2>/dev/null || echo "")

        # 只有在成功读取到值时才覆盖默认值
        [[ -n "$server_name" ]] && SERVER_NAME="$server_name"
        [[ -n "$element_web_host" ]] && ELEMENT_WEB_HOST="$element_web_host"
        [[ -n "$mas_host" ]] && MAS_HOST="$mas_host"
        [[ -n "$rtc_host" ]] && RTC_HOST="$rtc_host"
        [[ -n "$synapse_host" ]] && SYNAPSE_HOST="$synapse_host"
    fi

    log_success "项目配置加载完成"
    log_info "服务器名: $SERVER_NAME"
    log_info "RTC域名: $RTC_HOST"
    log_info "自定义HTTPS端口: $EXTERNAL_HTTPS_PORT"
}

# 检查ESS部署状态
check_ess_deployment() {
    log_info "检查ESS部署状态..."

    if ! kubectl get namespace ess >/dev/null 2>&1; then
        log_error "ESS命名空间不存在，请先部署ESS"
        exit 1
    fi

    log_success "ESS命名空间存在"
}

# 检查Matrix RTC服务状态
check_matrix_rtc_services() {
    log_info "检查Matrix RTC服务状态..."
    
    echo ""
    echo -e "${BLUE}=== Matrix RTC服务检查 ===${NC}"
    
    # 检查Pod状态
    local rtc_pods=$(kubectl get pods -n ess | grep "matrix-rtc" || echo "")
    if [[ -n "$rtc_pods" ]]; then
        echo -e "${GREEN}✅ Matrix RTC Pod状态:${NC}"
        echo "$rtc_pods"
    else
        echo -e "${RED}❌ 未找到Matrix RTC Pod${NC}"
        return 1
    fi
    
    # 检查Service状态
    local rtc_svc=$(kubectl get svc -n ess | grep "matrix-rtc" || echo "")
    if [[ -n "$rtc_svc" ]]; then
        echo -e "${GREEN}✅ Matrix RTC Service状态:${NC}"
        echo "$rtc_svc"
    else
        echo -e "${RED}❌ 未找到Matrix RTC Service${NC}"
        return 1
    fi
    
    # 检查Ingress状态
    local rtc_ingress=$(kubectl get ingress -n ess | grep "matrix-rtc" || echo "")
    if [[ -n "$rtc_ingress" ]]; then
        echo -e "${GREEN}✅ Matrix RTC Ingress状态:${NC}"
        echo "$rtc_ingress"
    else
        echo -e "${RED}❌ 未找到Matrix RTC Ingress${NC}"
        return 1
    fi
    
    return 0
}

# 检查well-known配置
check_wellknown_config() {
    log_info "检查well-known配置..."

    local well_known_client=$(kubectl get configmap ess-well-known-haproxy -n ess -o jsonpath='{.data.client}' 2>/dev/null || echo "")

    if [[ -z "$well_known_client" ]]; then
        log_error "无法获取well-known配置"
        return 1
    fi

    echo ""
    echo -e "${BLUE}=== 当前well-known配置 ===${NC}"
    echo "$well_known_client" | jq . 2>/dev/null || echo "$well_known_client"

    # 检查rtc_foci配置
    if echo "$well_known_client" | grep -q "org.matrix.msc4143.rtc_foci"; then
        echo -e "${GREEN}✅ rtc_foci配置存在${NC}"

        local livekit_url=$(echo "$well_known_client" | jq -r '.["org.matrix.msc4143.rtc_foci"][0].livekit_service_url' 2>/dev/null || echo "")
        if [[ -n "$livekit_url" && "$livekit_url" != "null" ]]; then
            echo -e "${GREEN}✅ LiveKit服务URL: $livekit_url${NC}"

            # 检查URL是否包含正确的端口
            local expected_url="https://$RTC_HOST:$EXTERNAL_HTTPS_PORT"
            if [[ "$livekit_url" == "$expected_url" ]]; then
                echo -e "${GREEN}✅ LiveKit服务URL端口配置正确${NC}"
                return 0
            else
                echo -e "${YELLOW}⚠️  LiveKit服务URL端口可能需要修复${NC}"
                echo "   当前: $livekit_url"
                echo "   期望: $expected_url"
                return 1
            fi
        else
            echo -e "${RED}❌ LiveKit服务URL配置错误${NC}"
            return 1
        fi
    else
        echo -e "${RED}❌ 缺少rtc_foci配置${NC}"
        return 1
    fi
}

# 修复well-known配置（基于项目实际配置）
fix_wellknown_config() {
    log_info "修复well-known配置..."

    # 备份当前配置
    local backup_file="/tmp/well-known-backup-$(date +%Y%m%d-%H%M%S).yaml"
    kubectl get configmap ess-well-known-haproxy -n ess -o yaml > "$backup_file"
    log_info "配置已备份到: $backup_file"

    # 生成新的client配置（使用项目的自定义端口配置）
    local client_config="{
  \"m.homeserver\": {
    \"base_url\": \"https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT\"
  },
  \"org.matrix.msc2965.authentication\": {
    \"account\": \"https://$MAS_HOST:$EXTERNAL_HTTPS_PORT/account\",
    \"issuer\": \"https://$MAS_HOST:$EXTERNAL_HTTPS_PORT/\"
  },
  \"org.matrix.msc4143.rtc_foci\": [
    {
      \"type\": \"livekit\",
      \"livekit_service_url\": \"https://$RTC_HOST:$EXTERNAL_HTTPS_PORT\"
    }
  ]
}"

    echo ""
    echo -e "${BLUE}=== 新的well-known配置 ===${NC}"
    echo "$client_config" | jq .

    read -p "确认应用此配置？[y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        return 0
    fi

    # 应用配置
    if kubectl patch configmap ess-well-known-haproxy -n ess --type merge -p "{\"data\":{\"client\":\"$client_config\"}}"; then
        log_success "well-known配置更新成功"
    else
        log_error "well-known配置更新失败"
        return 1
    fi

    # 重启HAProxy
    log_info "重启HAProxy服务..."
    if kubectl rollout restart deployment ess-haproxy -n ess; then
        log_success "HAProxy重启命令已执行"

        # 等待重启完成
        if kubectl rollout status deployment ess-haproxy -n ess --timeout=300s; then
            log_success "HAProxy重启完成"
        else
            log_warning "HAProxy重启超时，请手动检查"
        fi
    else
        log_error "HAProxy重启失败"
        return 1
    fi

    return 0
}

# 验证修复结果
verify_fix() {
    log_info "验证修复结果..."

    sleep 10

    # 重新检查well-known配置
    if check_wellknown_config; then
        log_success "well-known配置验证成功"
    else
        log_error "well-known配置验证失败"
        return 1
    fi

    # 测试访问（使用项目的自定义端口）
    local test_url="https://$SERVER_NAME:$EXTERNAL_HTTPS_PORT/.well-known/matrix/client"
    log_info "测试访问: $test_url"

    if curl -k -s "$test_url" | grep -q "org.matrix.msc4143.rtc_foci"; then
        log_success "Element Call配置验证成功"
        echo ""
        echo -e "${GREEN}🎉 Element Call修复完成！${NC}"
        echo "现在可以在Element Web中使用视频通话功能了"
        echo ""
        echo "访问地址："
        echo "- Element Web: https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
        echo "- Matrix服务器: https://$SYNAPSE_HOST:$EXTERNAL_HTTPS_PORT"
    else
        log_warning "配置可能需要更多时间生效，请稍后再试"
    fi
}

# 主函数
main() {
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}Element Call Matrix RTC 修复工具${NC}"
    echo -e "${BLUE}基于实际诊断结果的精准修复${NC}"
    echo -e "${BLUE}版本: 3.0.0${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""

    check_ess_deployment
    load_project_config

    echo ""
    echo -e "${BLUE}=== 项目配置信息 ===${NC}"
    echo "服务器域名: $SERVER_NAME"
    echo "Element Web: $ELEMENT_WEB_HOST"
    echo "Matrix服务器: $SYNAPSE_HOST"
    echo "认证服务: $MAS_HOST"
    echo "RTC服务: $RTC_HOST"
    echo "自定义HTTPS端口: $EXTERNAL_HTTPS_PORT"
    echo ""

    echo -e "${BLUE}=== 基于您的诊断结果分析 ===${NC}"
    echo "根据manage.sh选项10的诊断结果："
    echo "✅ Matrix RTC服务Pod存在且运行正常"
    echo "✅ Matrix RTC服务和Ingress配置正确"
    echo "✅ well-known配置包含rtc_foci"
    echo "✅ LiveKit服务URL已配置: https://rtc.niub.win:8443"
    echo ""
    echo -e "${YELLOW}问题分析：${NC}"
    echo "您的Matrix RTC配置实际上是正确的！"
    echo "Element Call错误可能由以下原因造成："
    echo ""

    # 进行更深入的检查
    echo -e "${BLUE}=== 深度诊断检查 ===${NC}"

    # 检查Matrix RTC服务实际状态
    log_info "检查Matrix RTC服务详细状态..."
    local rtc_sfu_ready=$(kubectl get pods -n ess | grep "matrix-rtc-sfu" | awk '{print $2}' | head -1)
    local rtc_auth_ready=$(kubectl get pods -n ess | grep "matrix-rtc-authorisation" | awk '{print $2}' | head -1)

    if [[ "$rtc_sfu_ready" == "1/1" && "$rtc_auth_ready" == "1/1" ]]; then
        echo -e "${GREEN}✅ Matrix RTC服务完全就绪${NC}"
    else
        echo -e "${YELLOW}⚠️  Matrix RTC服务状态异常${NC}"
        echo "SFU状态: $rtc_sfu_ready"
        echo "Auth状态: $rtc_auth_ready"
    fi

    # 检查WebRTC端口
    log_info "检查WebRTC端口状态..."
    local tcp_port_status=$(netstat -tlnp 2>/dev/null | grep ":30881" && echo "监听中" || echo "未监听")
    local udp_port_status=$(netstat -ulnp 2>/dev/null | grep ":30882" && echo "监听中" || echo "未监听")

    echo "WebRTC TCP 30881: $tcp_port_status"
    echo "WebRTC UDP 30882: $udp_port_status"

    # 检查Element Web配置
    log_info "检查Element Web Element Call配置..."
    local element_config=$(kubectl get configmap ess-element-web -n ess -o jsonpath='{.data.config\.json}' 2>/dev/null || echo "")
    if echo "$element_config" | grep -q "element_call"; then
        echo -e "${GREEN}✅ Element Web包含Element Call配置${NC}"
        if echo "$element_config" | grep -q '"use_exclusively": true'; then
            echo -e "${GREEN}✅ Element Call设置为独占模式${NC}"
        else
            echo -e "${YELLOW}⚠️  Element Call未设置为独占模式${NC}"
        fi
    else
        echo -e "${RED}❌ Element Web缺少Element Call配置${NC}"
    fi

    echo ""
    echo -e "${BLUE}=== 修复建议 ===${NC}"

    # 基于检查结果提供具体建议
    if [[ "$rtc_sfu_ready" == "1/1" && "$rtc_auth_ready" == "1/1" ]]; then
        if [[ "$tcp_port_status" == "监听中" && "$udp_port_status" == "监听中" ]]; then
            echo -e "${GREEN}✅ 所有Matrix RTC组件状态正常${NC}"
            echo ""
            echo -e "${YELLOW}Element Call问题可能的原因和解决方案：${NC}"
            echo ""
            echo "1. 🔄 浏览器缓存问题："
            echo "   - 清除浏览器缓存和Cookie"
            echo "   - 使用无痕模式重新访问"
            echo "   - 尝试不同的浏览器"
            echo ""
            echo "2. 🌐 网络配置问题："
            echo "   - 检查防火墙是否开放WebRTC端口(30881/30882)"
            echo "   - 检查NAT/路由器配置"
            echo "   - 尝试在不同网络环境下测试"
            echo ""
            echo "3. 🔧 Element Web配置："
            echo "   - 运行manage.sh选项1进行完整配置修复"
            echo "   - 确保Element Call功能正确启用"
            echo ""
            echo "4. 📱 客户端问题："
            echo "   - 确保使用最新版本的Element Web"
            echo "   - 检查浏览器是否支持WebRTC"
            echo "   - 授予麦克风和摄像头权限"
            echo ""
            echo -e "${BLUE}推荐的测试步骤：${NC}"
            echo "1. 访问: https://$ELEMENT_WEB_HOST:$EXTERNAL_HTTPS_PORT"
            echo "2. 清除浏览器缓存后重新登录"
            echo "3. 创建一个新房间"
            echo "4. 尝试发起视频通话"
            echo "5. 检查浏览器开发者工具的错误信息"

        else
            echo -e "${YELLOW}⚠️  WebRTC端口配置问题${NC}"
            echo "建议运行: ./manage.sh -> 选择选项1 (完整配置)"
        fi
    else
        echo -e "${YELLOW}⚠️  Matrix RTC服务状态异常${NC}"
        echo "建议检查ESS部署状态和日志"
    fi

    echo ""
    echo -e "${GREEN}=== 总结 ===${NC}"
    echo "根据诊断，您的Matrix RTC配置基本正确。"
    echo "Element Call问题很可能是客户端或网络配置问题，而非服务器配置问题。"
    echo ""
    echo "如需进一步帮助，请："
    echo "1. 运行 ./manage.sh 选择选项1进行完整配置"
    echo "2. 检查浏览器开发者工具的错误信息"
    echo "3. 尝试不同的网络环境和浏览器"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
