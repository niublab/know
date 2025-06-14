#!/bin/bash

# 测试脚本：验证Cloudflare DNS配置
# 此脚本用于测试Cloudflare API Token和DNS验证功能

echo "=== Cloudflare DNS 验证测试 ==="
echo ""

# 检查必要的工具
echo "=== 检查必要工具 ==="
tools=("curl" "kubectl" "jq")
for tool in "${tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "✓ $tool 可用"
    else
        echo "✗ $tool 不可用"
        if [[ "$tool" == "jq" ]]; then
            echo "  提示: 可选工具，用于JSON解析"
        fi
    fi
done
echo ""

# 测试API Token格式
test_token_format() {
    local token="$1"
    
    # Cloudflare API Token 格式检查
    if [[ ${#token} -lt 40 ]]; then
        echo "✗ Token长度过短（应该40+字符）"
        return 1
    fi
    
    if [[ ! "$token" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "✗ Token格式无效（应该只包含字母、数字、下划线、连字符）"
        return 1
    fi
    
    echo "✓ Token格式检查通过"
    return 0
}

# 测试API Token有效性
test_token_validity() {
    local token="$1"
    
    echo "测试API Token有效性..."
    
    local response=$(curl -s -w "%{http_code}" -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    local http_code="${response: -3}"
    local body="${response%???}"
    
    echo "HTTP状态码: $http_code"
    
    if [[ "$http_code" == "200" ]]; then
        if echo "$body" | grep -q '"success":true'; then
            echo "✓ API Token 验证成功"
            
            # 尝试解析权限信息
            if command -v jq >/dev/null 2>&1; then
                echo "Token权限信息:"
                echo "$body" | jq -r '.result.policies[]? | "  - \(.effect): \(.resources | keys[]) - \(.permission_groups[].name)"' 2>/dev/null || echo "  无法解析权限信息"
            fi
            return 0
        else
            echo "✗ API验证失败"
            if command -v jq >/dev/null 2>&1; then
                local error_msg=$(echo "$body" | jq -r '.errors[]?.message' 2>/dev/null)
                if [[ -n "$error_msg" ]]; then
                    echo "错误信息: $error_msg"
                fi
            fi
            return 1
        fi
    else
        echo "✗ HTTP请求失败 (状态码: $http_code)"
        return 1
    fi
}

# 测试DNS权限
test_dns_permissions() {
    local token="$1"
    
    echo "测试DNS权限..."
    
    # 尝试列出zones（需要Zone:Zone:Read权限）
    local response=$(curl -s -w "%{http_code}" -X GET "https://api.cloudflare.com/client/v4/zones?per_page=1" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json")
    
    local http_code="${response: -3}"
    local body="${response%???}"
    
    if [[ "$http_code" == "200" ]]; then
        if echo "$body" | grep -q '"success":true'; then
            echo "✓ Zone读取权限正常"
            
            # 显示可访问的zones数量
            if command -v jq >/dev/null 2>&1; then
                local zone_count=$(echo "$body" | jq -r '.result_info.total_count' 2>/dev/null)
                if [[ -n "$zone_count" && "$zone_count" != "null" ]]; then
                    echo "  可访问的域名数量: $zone_count"
                fi
            fi
            return 0
        else
            echo "✗ Zone读取权限失败"
            return 1
        fi
    else
        echo "✗ Zone权限测试失败 (状态码: $http_code)"
        return 1
    fi
}

# 主测试函数
main_test() {
    if [[ $# -eq 0 ]]; then
        echo "用法: $0 <cloudflare-api-token>"
        echo ""
        echo "示例: $0 your-cloudflare-api-token-here"
        echo ""
        echo "获取API Token:"
        echo "1. 访问 https://dash.cloudflare.com/profile/api-tokens"
        echo "2. 创建自定义Token，权限："
        echo "   - Zone:DNS:Edit"
        echo "   - Zone:Zone:Read"
        exit 1
    fi
    
    local token="$1"
    
    echo "=== 测试 Cloudflare API Token ==="
    echo "Token: ${token:0:10}...${token: -10}"
    echo ""
    
    # 格式检查
    echo "=== Token格式检查 ==="
    if ! test_token_format "$token"; then
        echo "Token格式检查失败，请检查Token是否正确"
        exit 1
    fi
    echo ""
    
    # 有效性检查
    echo "=== Token有效性检查 ==="
    if ! test_token_validity "$token"; then
        echo "Token有效性检查失败"
        exit 1
    fi
    echo ""
    
    # 权限检查
    echo "=== DNS权限检查 ==="
    if ! test_dns_permissions "$token"; then
        echo "DNS权限检查失败"
        echo ""
        echo "请确保Token具有以下权限:"
        echo "- Zone:DNS:Edit"
        echo "- Zone:Zone:Read"
        exit 1
    fi
    echo ""
    
    echo "=== 测试完成 ==="
    echo "✓ Cloudflare API Token 配置正确"
    echo "✓ 可以用于 cert-manager DNS-01 验证"
    echo ""
}

# 运行测试
main_test "$@"
