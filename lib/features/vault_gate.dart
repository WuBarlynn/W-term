import 'dart:async';

import 'package:flutter/material.dart';

import '../app/errors.dart';
import '../app/app_version_label.dart';
import '../app/quick_unlock.dart';
import '../app/host_store.dart';
import '../app/vault_store.dart';
import '../app/workspace.dart';

// Installed above the Navigator so route dialogs are covered as well.
final vaultPrivacy = ValueNotifier<bool>(false);

class VaultPrivacyShield extends StatelessWidget {
  final Widget child;
  const VaultPrivacyShield({super.key, required this.child});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: vaultPrivacy,
    child: child,
    builder: (_, hidden, child) => Stack(
      children: [
        child!,
        if (hidden)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0xff171c22),
              child: Center(
                child: Icon(Icons.lock_outline, color: Colors.white, size: 36),
              ),
            ),
          ),
      ],
    ),
  );
}

class VaultGate extends StatefulWidget {
  final VaultService? service;
  final HostStore? legacyStore;
  final QuickUnlock? quickUnlock;
  const VaultGate({
    super.key,
    this.service,
    this.legacyStore,
    this.quickUnlock,
  });
  @override
  State<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<VaultGate> with WidgetsBindingObserver {
  late final service = widget.service ?? NativeVaultService();
  late final legacy = widget.legacyStore ?? KeychainHostStore();
  late final quick = widget.quickUnlock ?? QuickUnlock();
  String? biometricType;
  bool quickEnabled = false, enrollQuick = false;
  final form = GlobalKey<FormState>();
  final password = TextEditingController(),
      confirmation = TextEditingController();
  VaultSession? session, openingSession;
  bool loading = true, exists = true, busy = false, hidden = false;
  int generation = 0;
  Future<void>? pendingUnlock;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    inspect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    generation++;
    final current = session ?? openingSession;
    if (current != null) unawaited(current.lock().catchError((Object _) {}));
    vaultPrivacy.value = false;
    password.clear();
    confirmation.clear();
    password.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> inspect() async {
    try {
      final found = await service.exists();
      final type = await quick.availableType();
      var enabled = false;
      try {
        enabled = type != null && await quick.enabled();
      } catch (_) {
        // Quick-unlock preferences must not block master-password access.
      }
      if (mounted) {
        setState(() {
          exists = found;
          biometricType = type;
          quickEnabled = enabled;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '无法读取保险库：${userFacingError(e)}';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (Theme.of(context).platform != TargetPlatform.iOS) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (mounted) {
        setState(() {
          hidden = true;
          vaultPrivacy.value = true;
        });
      }
    } else if (state == AppLifecycleState.resumed && mounted) {
      setState(() {
        hidden = false;
        vaultPrivacy.value = false;
      });
    }
  }

  Future<void> unlock() {
    if (busy || !form.currentState!.validate()) return Future.value();
    final operation = performUnlock();
    pendingUnlock = operation;
    return operation;
  }

  Future<void> performUnlock({bool biometric = false}) async {
    String secret = '';
    String? quickWarning;
    final current = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    VaultSession? opened;
    try {
      secret = biometric ? await quick.read() : password.text;
      if (!mounted || current != generation) return;
      opened = await service.open(secret, create: !exists);
      openingSession = opened;
      password.clear();
      confirmation.clear();
      if (!mounted || current != generation) {
        await opened.lock();
        return;
      }
      if (!opened.legacyImported) {
        final hosts = await legacy.read();
        final source = legacy;
        final folders = source is FolderStore
            ? await (source as FolderStore).readFolders()
            : <String>[];
        await opened.importLegacy(hosts, folders);
      }
      if (!mounted || current != generation) {
        await opened.lock();
        return;
      }
      if (!biometric && enrollQuick && biometricType != null) {
        try {
          await quick.enroll(secret);
          quickEnabled = true;
          enrollQuick = false;
        } catch (e) {
          quickWarning = '保险库已解锁，但快速解锁未启用：${userFacingError(e)}';
        }
      }
      if (!mounted || current != generation) {
        await opened.lock();
        return;
      }
      setState(() {
        session = opened;
        openingSession = null;
        exists = true;
      });
      if (quickWarning != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(quickWarning)));
      }
    } catch (e) {
      if (opened != null) await opened.lock();
      openingSession = null;
      if (mounted && current == generation) {
        setState(() => error = userFacingError(e));
        // Creation can succeed before legacy migration fails. Retry by opening,
        // never by replacing that newly created encrypted database.
        try {
          final found = await service.exists();
          if (mounted) setState(() => exists = found);
        } catch (_) {
          /* retain error */
        }
      }
    } finally {
      secret = '';
      if (mounted) {
        password.clear();
        confirmation.clear();
        if (current == generation) setState(() => busy = false);
      }
    }
  }

  Future<void> biometricUnlock() {
    if (busy || !exists || !quickEnabled) return Future.value();
    final operation = performUnlock(biometric: true);
    pendingUnlock = operation;
    return operation;
  }

  Future<void> lock() async {
    generation++;
    password.clear();
    confirmation.clear();
    final previous = session ?? openingSession;
    openingSession = null;
    // Remove dialogs and dispose Workspace so its SSH sessions are closed.
    if (mounted) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      setState(() {
        session = null;
        busy = true;
        error = null;
      });
    }
    try {
      await previous?.lock();
      await pendingUnlock;
      pendingUnlock = null;
      final found = await service.exists();
      final enabled = biometricType != null && await quick.enabled();
      if (mounted) {
        setState(() {
          exists = found;
          quickEnabled = enabled;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '锁定失败：${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = session != null
        ? Workspace(key: ObjectKey(session), hostStore: session, onLock: lock)
        : Scaffold(
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(28),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: loading
                        ? const CircularProgressIndicator()
                        : Form(
                            key: form,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Icon(
                                  exists
                                      ? Icons.lock_outline
                                      : Icons.enhanced_encryption_outlined,
                                  size: 40,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  exists ? '解锁保险库' : '创建保险库',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  exists ? '输入主密码，访问你的主机和文件夹。' : '设置至少 12 个字符的主密码。已有主机与文件夹会自动导入，原钥匙串配置会保留。',
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 24),
                                if (exists && quickEnabled) ...[
                                  FilledButton.icon(
                                    onPressed: busy ? null : biometricUnlock,
                                    icon: Icon(
                                      biometricType == 'Face ID'
                                          ? Icons.face
                                          : Icons.fingerprint,
                                    ),
                                    label: Text('使用 $biometricType 解锁'),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                                TextFormField(
                                  controller: password,
                                  enabled: !busy,
                                  obscureText: true,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: const InputDecoration(
                                    labelText: '主密码',
                                  ),
                                  validator: (v) => v == null || v.isEmpty
                                      ? '请输入主密码'
                                      : !exists && v.runes.length < 12
                                      ? '至少需要 12 个字符'
                                      : null,
                                  onFieldSubmitted: (_) {
                                    if (exists) unlock();
                                  },
                                ),
                                if (!exists) ...[
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: confirmation,
                                    enabled: !busy,
                                    obscureText: true,
                                    autocorrect: false,
                                    enableSuggestions: false,
                                    decoration: const InputDecoration(
                                      labelText: '再次输入主密码',
                                    ),
                                    validator: (v) =>
                                        v != password.text ? '两次密码不一致' : null,
                                    onFieldSubmitted: (_) => unlock(),
                                  ),
                                  const SizedBox(height: 14),
                                  const Text(
                                    '请妥善保管主密码。此阶段尚无找回功能，忘记密码将无法解密保险库。',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                                if (biometricType != null)
                                  CheckboxListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(
                                      quickEnabled
                                          ? '重新设置 $biometricType 快速解锁'
                                          : '启用 $biometricType 快速解锁',
                                    ),
                                    subtitle: const Text('使用主密码解锁后设置，仅保存在本机'),
                                    value: enrollQuick,
                                    onChanged: busy
                                        ? null
                                        : (v) => setState(
                                            () => enrollQuick = v ?? false,
                                          ),
                                  ),
                                if (error != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: Text(
                                      error!,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 12),
                                const Center(child: AppVersionLabel()),
                                const SizedBox(height: 20),
                                FilledButton(
                                  onPressed: busy ? null : unlock,
                                  child: Text(
                                    busy
                                        ? '处理中…'
                                        : exists
                                        ? '解锁'
                                        : '创建并导入',
                                  ),
                                ),
                                const SizedBox(height: 12),
                                const Text(
                                  '本地 SQLCipher 加密 · 快速解锁凭证受系统生物识别保护',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
          );
    return Stack(
      children: [
        content,
        if (hidden)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0xff171c22),
              child: Center(
                child: Icon(Icons.lock_outline, color: Colors.white, size: 36),
              ),
            ),
          ),
      ],
    );
  }
}
