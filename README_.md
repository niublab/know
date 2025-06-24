# ESS Community 完整管理系统

[![版本](https://img.shields.io/badge/版本-3.0.0-blue.svg)](https://github.com/niublab/know)
[![ESS版本](https://img.shields.io/badge/ESS-25.6.1-green.svg)](https://github.com/element-hq/ess-helm)
[![许可证](https://img.shields.io/badge/许可证-AGPL--3.0-red.svg)](LICENSE)

> 基于ESS官方最新规范的完整Matrix服务器管理解决方案

## 🌟 特性

### ✅ 完整解决方案
- **一键nginx反代配置** - 解决ISP端口封锁问题
- **Element Call完整修复** - 解决视频通话问题
- **用户管理系统** - 创建、管理Matrix用户
- **完整系统诊断** - 自动检测和修复问题

### ✅ 基于官方规范
- 符合ESS Community 25.6.1最新规范
- 基于官方推荐的nginx配置
- 解决所有已知的部署问题
- 支持自定义端口配置

### ✅ 生产就绪
- 完整的SSL配置和安全头
- WebRTC端口自动配置
- 防火墙自动配置
- 配置备份和恢复

## 🚀 快速开始

### 前提条件

1. **已部署的ESS服务**
   ```bash
   # 如果还未部署ESS，请先运行：
   curl -fsSL https://raw.githubusercontent.com/niublab/know/main/setup.sh | bash
   ```

2. **系统要求**
   - Ubuntu 20.04+ / Debian 11+ / CentOS 8+
   - 已安装kubectl、helm、nginx
   - root权限或sudo权限

### 一键运行

```bash
# 下载并运行管理脚本
curl -fsSL https://raw.githubusercontent.com/niublab/know/main/ess-manager.sh | bash
```

或者下载到本地运行：

```bash
# 下载脚本
wget https://raw.githubusercontent.com/niublab/know/main/ess-manager.sh
chmod +x ess-manager.sh

# 运行脚本
./ess-manager.sh
```

## 📋 功能菜单

### 🚀 核心功能
1. **完整配置nginx反代** - 一键解决所有问题
2. **用户管理** - 完整的用户管理功能
3. **Element Call问题修复** - 专门修复视频通话

### 🔧 系统管理
4. **系统状态检查** - 查看所有服务状态
5. **查看服务日志** - 查看详细的服务日志
6. **重启ESS服务** - 安全重启ESS组件
7. **备份配置** - 备份重要配置文件

### 🔍 诊断工具
8. **完整系统诊断** - 全面的系统健康检查
9. **网络连接测试** - 测试网络连接和端口
10. **Matrix RTC诊断** - 专门诊断Element Call问题

## 🎯 解决的问题

### ISP端口封锁问题
- **问题**：ISP封锁80/443端口，无法外网访问
- **解决**：自动配置nginx反代到自定义端口(如8443)

### Element Call无法使用
- **问题**：视频通话显示"MISSING_MATRIX_RTC_FOCUS"错误
- **解决**：自动修复WebRTC端口、well-known配置、Matrix RTC服务

### 配置复杂性
- **问题**：手动配置nginx、SSL、防火墙复杂易错
- **解决**：一键自动化配置，基于官方最佳实践

## 📖 使用说明

### 选项1：完整nginx反代配置（推荐）

这是**推荐的一键解决方案**，会自动：
- 配置nginx反向代理
- 提取和配置SSL证书
- 修复ESS内部端口配置
- 修复Element Call问题
- 配置防火墙规则

### 选项2：用户管理

提供完整的Matrix用户管理功能：
- 创建用户（支持管理员权限）
- 修改用户密码
- 锁定/解锁用户
- 查看用户列表

### 选项3：Element Call修复

专门解决Element Call视频通话问题：
- WebRTC端口检查和修复
- Matrix RTC服务检查
- well-known配置修复

## 🔧 技术特点

- **基于ESS官方推荐配置**
- **完整的SSL安全配置**
- **WebSocket支持**（Element Call必需）
- **自定义端口支持**（1024-65535）
- **防火墙自动配置**

## 🐛 故障排除

### 常见问题

1. **Element Call无法使用** - 运行选项3进行修复
2. **外网无法访问** - 运行选项9进行网络测试
3. **SSL证书问题** - 重新运行选项1

### 日志查看

```bash
# nginx日志
sudo tail -f /var/log/nginx/ess-access.log

# ESS服务日志
kubectl logs -n ess deployment/ess-synapse-main
```

## 📞 支持

- **GitHub Issues**: [提交问题](https://github.com/niublab/know/issues)
- **文档**: [查看完整文档](https://github.com/niublab/know)

## 📄 许可证

本项目采用 AGPL-3.0 许可证，仅限非商业用途。

---

**ESS Community 中文社区** - 让Matrix服务器部署变得简单
