#!/bin/bash

# Matrix 服务器部署包创建脚本
# 版本: 1.0.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="matrix-server-deployment-v1.0.0"
PACKAGE_DIR="/tmp/$PACKAGE_NAME"

echo "创建 Matrix 服务器部署包..."

# 清理并创建包目录
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

# 复制主要脚本
echo "复制脚本文件..."
cp "$SCRIPT_DIR/matrix-deploy.sh" "$PACKAGE_DIR/"
cp "$SCRIPT_DIR/cert-manager.sh" "$PACKAGE_DIR/"
cp "$SCRIPT_DIR/config-templates.sh" "$PACKAGE_DIR/"
cp "$SCRIPT_DIR/test-deployment.sh" "$PACKAGE_DIR/"

# 复制文档
echo "复制文档文件..."
cp "$SCRIPT_DIR/README.md" "$PACKAGE_DIR/"

# 创建安装脚本
cat > "$PACKAGE_DIR/install.sh" << 'EOF'
#!/bin/bash

# Matrix 服务器部署工具安装脚本

set -euo pipefail

INSTALL_DIR="/opt/matrix-deploy"
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "安装 Matrix 服务器部署工具..."

# 检查权限
if [[ $EUID -eq 0 ]]; then
    echo "错误: 请不要以 root 用户运行安装脚本"
    exit 1
fi

# 检查 sudo 权限
if ! sudo -n true 2>/dev/null; then
    echo "错误: 需要 sudo 权限"
    exit 1
fi

# 创建安装目录
echo "创建安装目录: $INSTALL_DIR"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER:$USER" "$INSTALL_DIR"

# 复制文件
echo "复制文件..."
cp "$CURRENT_DIR"/*.sh "$INSTALL_DIR/"
cp "$CURRENT_DIR/README.md" "$INSTALL_DIR/"

# 设置权限
chmod +x "$INSTALL_DIR"/*.sh

# 创建符号链接
echo "创建符号链接..."
sudo ln -sf "$INSTALL_DIR/matrix-deploy.sh" /usr/local/bin/matrix-deploy
sudo ln -sf "$INSTALL_DIR/cert-manager.sh" /usr/local/bin/matrix-cert
sudo ln -sf "$INSTALL_DIR/test-deployment.sh" /usr/local/bin/matrix-test

echo "安装完成！"
echo
echo "使用方法:"
echo "  matrix-deploy    # 启动主部署工具"
echo "  matrix-cert      # 启动证书管理工具"
echo "  matrix-test      # 运行测试脚本"
echo
echo "或者直接运行:"
echo "  cd $INSTALL_DIR && ./matrix-deploy.sh"
EOF

chmod +x "$PACKAGE_DIR/install.sh"

# 创建卸载脚本
cat > "$PACKAGE_DIR/uninstall.sh" << 'EOF'
#!/bin/bash

# Matrix 服务器部署工具卸载脚本

set -euo pipefail

INSTALL_DIR="/opt/matrix-deploy"

echo "卸载 Matrix 服务器部署工具..."

# 检查权限
if ! sudo -n true 2>/dev/null; then
    echo "错误: 需要 sudo 权限"
    exit 1
fi

# 删除符号链接
echo "删除符号链接..."
sudo rm -f /usr/local/bin/matrix-deploy
sudo rm -f /usr/local/bin/matrix-cert
sudo rm -f /usr/local/bin/matrix-test

# 询问是否删除安装目录
read -p "是否删除安装目录 $INSTALL_DIR? (y/N): " confirm
if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    sudo rm -rf "$INSTALL_DIR"
    echo "安装目录已删除"
else
    echo "保留安装目录: $INSTALL_DIR"
fi

echo "卸载完成！"
EOF

chmod +x "$PACKAGE_DIR/uninstall.sh"

# 创建快速开始指南
cat > "$PACKAGE_DIR/QUICKSTART.md" << 'EOF'
# Matrix 服务器部署工具 - 快速开始

## 安装

```bash
# 解压部署包
tar -xzf matrix-server-deployment-v1.0.0.tar.gz
cd matrix-server-deployment-v1.0.0

# 运行安装脚本
./install.sh
```

## 快速部署

```bash
# 启动部署工具
matrix-deploy

# 或者
cd /opt/matrix-deploy && ./matrix-deploy.sh
```

## 部署步骤

1. **初始化环境** - 选择菜单项 1
2. **配置参数** - 选择菜单项 2
3. **部署服务** - 选择菜单项 3
4. **配置证书** - 选择菜单项 4

## 重要提醒

### 网络配置
- 确保路由器已配置端口转发
- 确保域名 A 记录指向公网 IP
- 确保 DDNS 服务正常运行

### 证书配置
- 准备 Cloudflare API Token
- 选择合适的证书环境（生产/测试）

### 端口配置
- HTTP: 8080
- HTTPS: 8443
- WebRTC TCP: 30881
- WebRTC UDP: 30882

## 故障排除

如遇问题，请：
1. 运行测试脚本: `matrix-test`
2. 查看详细文档: `less /opt/matrix-deploy/README.md`
3. 检查服务状态: 主菜单 -> 服务管理 -> 查看服务状态

## 卸载

```bash
cd /opt/matrix-deploy
./uninstall.sh
```
EOF

# 创建版本信息文件
cat > "$PACKAGE_DIR/VERSION" << EOF
Matrix 服务器自动化部署工具
版本: 1.0.0
发布日期: $(date +%Y-%m-%d)
兼容性: Element Server Suite Community Edition 25.6.0+
支持平台: Debian 11+, Ubuntu 20.04+

主要特性:
- ISP 端口封锁适配
- 自动化部署和配置
- 完整的证书管理
- 服务监控和维护
- 用户管理
- 数据备份恢复

文件清单:
- matrix-deploy.sh      # 主部署脚本
- cert-manager.sh       # 证书管理脚本
- config-templates.sh   # 配置模板脚本
- test-deployment.sh    # 测试脚本
- install.sh           # 安装脚本
- uninstall.sh         # 卸载脚本
- README.md            # 详细文档
- QUICKSTART.md        # 快速开始指南
- VERSION              # 版本信息
EOF

# 创建校验和文件
echo "生成校验和..."
cd "$PACKAGE_DIR"
sha256sum *.sh *.md VERSION > SHA256SUMS

# 创建压缩包
echo "创建压缩包..."
cd /tmp
tar -czf "$PACKAGE_NAME.tar.gz" "$PACKAGE_NAME"

echo "部署包创建完成: /tmp/$PACKAGE_NAME.tar.gz"
echo
echo "包内容:"
tar -tzf "$PACKAGE_NAME.tar.gz"
echo
echo "包大小: $(du -h "$PACKAGE_NAME.tar.gz" | cut -f1)"
echo "校验和: $(sha256sum "$PACKAGE_NAME.tar.gz" | cut -d' ' -f1)"

