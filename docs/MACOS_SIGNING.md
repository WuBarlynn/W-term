# macOS Touch ID 与应用签名

## 当前原因

本机检查结果：`security find-identity -v -p codesigning` 返回 0 个有效签名身份；当前 Debug 应用为临时签名，签名权限中没有应用标识或 Keychain access group。因此，当前构建不能启用使用 Data Protection Keychain 的 Touch ID 快速解锁。

`xattr -rd com.apple.quarantine <App路径>` 只删除下载隔离属性，不创建代码签名、证书或钥匙串权限。无需为此修改系统安全设置，也不应把主密码改存到无生物识别保护的存储中。

参考：[Apple 对 errSecMissingEntitlement 的说明](https://developer.apple.com/documentation/security/errsecmissingentitlement)、[macOS Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)。

## 配置后构建

1. 在 Xcode 中打开 `macos/Runner.xcworkspace`，在账户设置中配置有权使用的 Apple 开发团队。
2. 为 **Runner 应用 target** 配置正确的团队、Apple Development 签名证书及 provisioning；保持当前 bundle ID `dev.wterm.wterm`，避免无意切换应用容器。不要替换成编造的 Team ID。
3. 本项目提供 `Runner/Biometric.entitlements`，包含应用标识与本应用的 Keychain group。Runner 的 `WTERM_ENTITLEMENTS_FILE` 构建设置可选择此文件；普通临时签名构建继续使用原来的 Debug/Release entitlements。
4. 在 Xcode 完成签名与 profile 配置后，也可以运行：

```bash
WTERM_APPLE_TEAM_ID='你的实际团队ID' bash scripts/build-macos-signed.sh
```

脚本使用 Apple Development 签名，不创建证书、不修改系统信任设置，也不会自动登录开发者账户。本机没有签名身份，故签名构建路径尚未实测；普通 Debug 构建单独验证。

5. 打开正确签名的版本，输入主密码并勾选启用 Touch ID，再手动锁定保险库验证解锁。仍失败时，应用会显示签名预检或系统钥匙串错误，而不会把失败当作成功。

## 仍需真机验证

- Touch ID 成功、取消、锁定及重新注册指纹后的失效处理。
- App 重启后读取、关闭快速解锁、主密码修改后的重新启用。
- 开发版到正式签名版本的本地数据与 Keychain 可访问性。
