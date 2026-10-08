# macOS 签名与 Touch ID

更新：2026-10-07，0.1.36 (37)。Bundle ID 保持 `dev.wterm.wterm`。当前脚本使用用户创建的自签名身份 **W Term Vault Code Signing**，保留 Xcode 中已有的个人团队配置。

## 本次修复：自签名版本的 -34018

0.1.35 放行了自签名预检，但实际保存仍使用 Data Protection Keychain，用户实测被系统拒绝（`-34018`）。单独放宽签名判断无法修复这一存储权限问题。

0.1.36 的 macOS 快速解锁改用 **CryptoKit Secure Enclave + 本机加密凭证**，不再调用旧快速解锁项的 `SecItem` 读写/删除。系统钥匙串授权不再是这条路径的依赖，也不采用“先弹 Touch ID，再读普通明文凭证”的方案。

- Secure Enclave P-256 私钥使用 `privateKeyUsage + biometryCurrentSet`，只允许当前指纹集合授权使用。
- 随机临时 P-256 密钥与硬件公钥做 ECDH，经 HKDF-SHA256 派生 AES-256-GCM 密钥加密主密码；临时私钥不持久化。
- 文件只包含硬件包裹的私钥表示、公钥、随机盐和认证密文，不包含明文主密码或可导出的硬件私钥。Apple 说明这类表示只能由同一 Secure Enclave 恢复：[CryptoKit 密钥存储](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain)。
- 启用时先用恢复后的硬件密钥执行一次真实 Touch ID 解密，成功后原子写入文件。取消或认证失败不会先删除旧登记。
- 每次解锁使用新 `LAContext`，不设置认证复用时间；取消/锁定/指纹变化后仍可使用主密码。没有 Secure Enclave 时不降级为软件密钥。
- 文件位于应用容器的 `Library/Application Support/dev.wterm.wterm/biometric-unlock-v2.json`，权限 0600，排除系统备份，不进入应用加密备份或 GitHub 同步。

**升级后需要用主密码解锁，再重新启用一次 Touch ID。** macOS 不再读取旧 `vault-master-v1` 钥匙串项和旧标记；已存在的旧钥匙串项不自动迁移或删除，以免再次被 -34018 阻塞。新版本关闭快速解锁会删除 v2 文件；旧版本遗留项仅能供旧实现使用，若曾成功启用旧实现，可在拥有访问权限的旧签名版本中关闭它。iOS 的 Face ID/Keychain 路径保持原样。

## 放宽后的签名准入

- 保留 unsigned/ad-hoc 拦截，以及证书存在、应用标识与签名完整性检查。
- Apple Development、Developer ID、自签名身份均可使用。
- 不检查 Team ID、Apple 专属权限，不再要求 designated requirement 必须与系统默认值一致。
- 建议后续更新持续使用同一证书；不需要每次创建证书或申请 Apple provisioning。

## 编译签名版

沿用用户已经验证成功的脚本：

```bash
bash scripts/build-macos-signed.sh

# 指定本机已有签名身份
WTERM_SIGNING_IDENTITY='证书名称' bash scripts/build-macos-signed.sh
```

默认产物：`build/macos-signed/Build/Products/Release/W Term.app`。脚本先编译，再签署内嵌代码和 App；不启动、安装或替换用户应用。当前脚本为自签名流程，会移除 Apple 专用权限，不执行 Developer ID 分发公证。已有 Xcode 团队配置保留。

## 已验证与待验证

- 本机自签名沙盒测试 App **仅带 App Sandbox 权限**，没有 Team ID/Keychain group：成功创建、序列化并恢复真实 Secure Enclave 密钥；关闭交互时解密返回 `LAError.notInteractive (-1004)`，没有出现 -34018。全程不弹指纹窗口、不接触真实保险库。
- 加密往返、字段篡改、错误密钥、未知版本、超大记录、持久化重开、0600 权限、删除后不可读测试通过。
- Flutter 测试覆盖原生调用、取消保留旧登记、旧钥匙串不回退、缺少原生实现与保险库生命周期。
- 仍需用户实测：启用时指纹成功、取消、手动锁定后解锁、完全退出重开、指纹录入变化及跨版本复用。硬件拒绝未认证读取的自动测试不等于已经验证真人认证成功。

复现自动化检查：

```bash
bash scripts/test-macos-quick-unlock.sh
# 需要有 Touch ID/已录入指纹的 Mac 和本机签名身份，不弹认证窗口
bash scripts/test-macos-quick-unlock.sh --hardware
bash scripts/test-macos-signing.sh 'build/macos-signed/Build/Products/Release/W Term.app'
source scripts/env.sh
flutter test test/quick_unlock_signing_test.dart test/vault_gate_test.dart
```
