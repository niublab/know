#!/bin/bash

# Element Call Matrix RTC Focus 修复脚本
# 基于项目实际配置和ESS Community官方规范
# 版本: 2.0.0 - 修正版，符合项目自定义端口8443的实际需求

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
    echo -e "${BLUE}基于项目自定义端口8443配置${NC}"
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

    if check_matrix_rtc_services && check_wellknown_config; then
        log_success "Matrix RTC配置正常，无需修复"
        echo ""
        echo -e "${GREEN}✅ Element Call应该可以正常工作${NC}"
        echo "如果仍有问题，建议使用manage.sh的诊断功能："
        echo "./manage.sh -> 选择菜单选项10"
        exit 0
    fi

    echo ""
    log_warning "检测到Matrix RTC配置问题，开始修复..."

    if fix_wellknown_config; then
        verify_fix
    else
        log_error "修复失败，请检查错误信息"
        echo ""
        echo -e "${YELLOW}建议使用项目的完整修复功能：${NC}"
        echo "./manage.sh -> 选择菜单选项1 (完整配置nginx反代)"
        exit 1
    fi
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
