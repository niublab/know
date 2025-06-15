# Element Call "MISSING_MATRIX_RTC_FOCUS" 完整解决方案

## 🔍 问题分析（基于项目实际情况）

### 错误信息
```
Call is not supported
The server is not configured to work with Element Call. Please contact your server admin (Domain: niub.win, Error Code: MISSING_MATRIX_RTC_FOCUS).
```

### 项目实际情况（重要更正）
经过仔细检查，您的项目**已经非常完善**：

1. **manage.sh确实包含Matrix RTC诊断功能**：
   - 菜单选项10：`diagnose_matrix_rtc_focus()`
   - 完整的Matrix RTC服务状态检查
   - well-known配置检查和自动修复建议

2. **完善的自定义端口支持**：
   - 项目设计使用自定义端口8443（符合初衷）
   - 所有配置正确使用`$EXTERNAL_HTTPS_PORT`变量
   - 包含完整的端口配置修复功能

3. **统一的配置管理**：
   - `load_config()`函数统一管理所有域名和端口
   - 支持从hostnames.yaml读取配置
   - 导出变量确保全局可用

### 根本原因
基于项目实际配置，此错误的根本原因是：

1. **well-known配置端口问题**：`/.well-known/matrix/client` 中的 `org.matrix.msc4143.rtc_foci` 配置可能缺少正确的端口8443
2. **Matrix RTC服务状态**：需要验证Matrix RTC Backend是否正确部署
3. **ESS ConfigMap端口硬编码**：ESS内部ConfigMap可能仍使用标准端口443而非自定义端口8443

## 🛠️ 解决方案

### 方案一：使用项目现有功能（强烈推荐）

您的项目已经包含了完善的诊断和修复功能：

```bash
# 1. 使用Matrix RTC专门诊断功能
./manage.sh
# 选择菜单选项: 10) 诊断Matrix RTC Focus (Element Call问题)

# 2. 使用统一修复功能（一键解决所有端口问题）
./manage.sh
# 选择菜单选项: 1) 完整配置nginx反代 (推荐 - 修复所有ESS端口配置问题)
```

### 方案二：使用修正后的专门脚本

```bash
# 1. 运行项目完整性检查（了解当前状态）
chmod +x check_project_completeness.sh
./check_project_completeness.sh

# 2. 运行修正后的Element Call修复脚本
chmod +x fix_element_call.sh
./fix_element_call.sh
```

### 方案三：手动修复步骤

#### 1. 检查Matrix RTC服务状态
```bash
kubectl get pods -n ess | grep matrix-rtc
kubectl get svc -n ess | grep matrix-rtc
kubectl get ingress -n ess | grep matrix-rtc
```

#### 2. 检查当前well-known配置
```bash
kubectl get configmap ess-well-known-haproxy -n ess -o jsonpath='{.data.client}' | jq .
```

#### 3. 修复well-known配置
根据您的域名配置，正确的well-known配置应该包含：

```json
{
  "m.homeserver": {
    "base_url": "https://matrix.niub.win:8443"
  },
  "m.identity_server": {
    "base_url": "https://vector.im"
  },
  "org.matrix.msc2965.authentication": {
    "issuer": "https://mas.niub.win:8443/",
    "account": "https://mas.niub.win:8443/account"
  },
  "org.matrix.msc4143.rtc_foci": [
    {
      "type": "livekit",
      "livekit_service_url": "https://rtc.niub.win:8443"
    }
  ]
}
```

#### 4. 应用配置修复
```bash
# 备份当前配置
kubectl get configmap ess-well-known-haproxy -n ess -o yaml > well-known-backup.yaml

# 应用新配置（使用您的实际域名）
kubectl patch configmap ess-well-known-haproxy -n ess --type merge -p '{"data":{"client":"上面的JSON配置"}}'

# 重启HAProxy服务
kubectl rollout restart deployment ess-haproxy -n ess
kubectl rollout status deployment ess-haproxy -n ess --timeout=300s
```

## 🔧 技术细节

### ESS Community Matrix RTC架构
根据官方文档，ESS Community包含以下Matrix RTC组件：
- **Matrix RTC SFU**: 选择性转发单元
- **Matrix RTC Authorization Service**: 授权服务
- **LiveKit Backend**: 实际的WebRTC媒体服务器

### 必需的网络端口
- **TCP 30881**: WebRTC TCP连接
- **UDP 30882**: WebRTC UDP连接（多路复用）
- **HTTPS端口**: 信令和认证（443或8443）

### well-known配置说明
`org.matrix.msc4143.rtc_foci` 字段告诉Matrix客户端：
- 服务器支持Matrix RTC
- LiveKit服务的访问地址
- 使用的RTC后端类型

## 📋 验证步骤

### 1. 验证Matrix RTC服务
```bash
# 检查所有Matrix RTC相关Pod
kubectl get pods -n ess | grep matrix-rtc

# 检查服务状态
kubectl get svc -n ess | grep matrix-rtc
```

### 2. 验证well-known配置
```bash
# 检查配置是否包含rtc_foci
curl -k https://niub.win:8443/.well-known/matrix/client | jq '.["org.matrix.msc4143.rtc_foci"]'
```

### 3. 测试Element Call功能
1. 访问 Element Web: `https://app.niub.win:8443`
2. 登录您的账户
3. 创建或加入一个房间
4. 尝试发起视频通话
5. 确认不再出现 MISSING_MATRIX_RTC_FOCUS 错误

## 🚨 常见问题

### Q1: Matrix RTC Pod不存在
**原因**: ESS部署时可能未包含Matrix RTC组件
**解决**: 检查ESS Helm部署配置，确保包含matrixRTC组件

### Q2: LiveKit服务URL不可访问
**原因**: 端口配置错误或网络问题
**解决**: 
- 检查防火墙设置
- 验证域名解析
- 确认端口配置正确

### Q3: well-known配置修改后不生效
**原因**: HAProxy缓存或重启失败
**解决**:
- 强制重启HAProxy: `kubectl delete pod -n ess -l app.kubernetes.io/name=haproxy`
- 清除浏览器缓存
- 等待DNS传播

## 📚 官方参考资料

- [ESS Community GitHub](https://github.com/element-hq/ess-helm)
- [Matrix RTC规范 MSC4143](https://github.com/matrix-org/matrix-spec-proposals/pull/4143)
- [Element Call官方文档](https://github.com/element-hq/element-call)
- [ESS Community博客文章](https://element.io/blog/end-to-end-encrypted-voice-and-video-for-self-hosted-community-users/)

## 🎯 项目优势

您的项目已经相当完善：

### ✅ 已实现功能
- 完整的ESS自动部署脚本
- nginx反代配置和端口问题修复
- Matrix RTC诊断功能
- 用户管理功能
- 详细的问题记录和解决方案

### 🔄 建议改进
- 添加自动化的Matrix RTC组件检查
- 完善well-known配置的自动修复
- 增加Element Call功能的端到端测试

## 📞 联系支持

如果问题仍然存在：
1. 运行完整诊断: `./check_project_completeness.sh`
2. 查看生成的诊断报告
3. 检查ESS Community官方文档
4. 在ESS Community Matrix房间寻求帮助: `#ess-community:element.io`

---

**注意**: 此解决方案基于ESS Community 25.6.1版本和官方最新文档。确保您的部署使用的是最新稳定版本。
