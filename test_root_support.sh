#!/bin/bash

# 测试脚本：验证root用户支持
# 此脚本用于测试setup.sh是否正确支持root用户运行

echo "=== ESS Community 部署脚本 Root 用户支持测试 ==="
echo ""

# 检查当前用户
if [[ $EUID -eq 0 ]]; then
    echo "✓ 当前以 root 用户运行测试"
    USER_TYPE="root"
    CONFIG_DIR="/root/ess-config-values"
    KUBE_CONFIG="/root/.kube/config"
    SUDO_CMD=""
else
    echo "✓ 当前以普通用户运行测试"
    USER_TYPE="normal"
    CONFIG_DIR="$HOME/ess-config-values"
    KUBE_CONFIG="$HOME/.kube/config"
    SUDO_CMD="sudo"
fi

echo "用户类型: $USER_TYPE"
echo "配置目录: $CONFIG_DIR"
echo "Kube配置: $KUBE_CONFIG"
echo "Sudo命令: ${SUDO_CMD:-'(无需sudo)'}"
echo ""

# 测试配置目录创建
echo "=== 测试配置目录创建 ==="
if mkdir -p "$CONFIG_DIR" 2>/dev/null; then
    echo "✓ 配置目录创建成功: $CONFIG_DIR"
    ls -la "$CONFIG_DIR" 2>/dev/null || echo "目录为空"
else
    echo "✗ 配置目录创建失败"
fi
echo ""

# 测试kubeconfig目录创建
echo "=== 测试 Kubeconfig 目录创建 ==="
KUBE_DIR=$(dirname "$KUBE_CONFIG")
if mkdir -p "$KUBE_DIR" 2>/dev/null; then
    echo "✓ Kubeconfig目录创建成功: $KUBE_DIR"
    ls -la "$KUBE_DIR" 2>/dev/null || echo "目录为空"
else
    echo "✗ Kubeconfig目录创建失败"
fi
echo ""

# 测试bashrc文件访问
echo "=== 测试 Bashrc 文件访问 ==="
if [[ $EUID -eq 0 ]]; then
    BASHRC_FILE="/root/.bashrc"
else
    BASHRC_FILE="$HOME/.bashrc"
fi

if [[ -f "$BASHRC_FILE" ]]; then
    echo "✓ Bashrc文件存在: $BASHRC_FILE"
    if [[ -w "$BASHRC_FILE" ]]; then
        echo "✓ Bashrc文件可写"
    else
        echo "✗ Bashrc文件不可写"
    fi
else
    echo "! Bashrc文件不存在，将会创建: $BASHRC_FILE"
    if touch "$BASHRC_FILE" 2>/dev/null; then
        echo "✓ Bashrc文件创建成功"
    else
        echo "✗ Bashrc文件创建失败"
    fi
fi
echo ""

# 测试系统命令访问
echo "=== 测试系统命令访问 ==="
commands=("curl" "kubectl" "helm" "k3s")
for cmd in "${commands[@]}"; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "✓ $cmd 命令可用"
    else
        echo "! $cmd 命令不可用（正常，安装后会有）"
    fi
done
echo ""

# 测试网络连接
echo "=== 测试网络连接 ==="
test_urls=(
    "https://get.k3s.io"
    "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
)

for url in "${test_urls[@]}"; do
    if curl -s --connect-timeout 5 "$url" >/dev/null 2>&1; then
        echo "✓ 可以连接到: $url"
    else
        echo "✗ 无法连接到: $url"
    fi
done
echo ""

# 测试权限
echo "=== 测试权限 ==="
if [[ $EUID -eq 0 ]]; then
    echo "✓ Root用户，拥有所有权限"
else
    if sudo -n true 2>/dev/null; then
        echo "✓ 普通用户，有sudo权限"
    else
        echo "✗ 普通用户，无sudo权限"
    fi
fi
echo ""

# 清理测试文件
echo "=== 清理测试文件 ==="
if [[ -d "$CONFIG_DIR" ]] && [[ -z "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]]; then
    rmdir "$CONFIG_DIR" 2>/dev/null && echo "✓ 清理空配置目录"
fi

echo ""
echo "=== 测试完成 ==="
echo "如果以上测试大部分通过，说明系统环境适合运行 ESS Community 部署脚本"
echo ""
