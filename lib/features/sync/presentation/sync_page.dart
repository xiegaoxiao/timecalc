import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../../../shared/widgets/app_error_view.dart';
import '../../backup/data/credential_store.dart';
import '../../settings/data/settings_repository_provider.dart';
import '../data/webdav_sync_service_provider.dart';

/// WebDAV 整库文件同步设置页（M9）。
///
/// 由设置页「同步」菜单项 push 进入。配置项：
/// - 总开关：**点击即生效**（自动同步，启动拉取/变更推送/退出推送/每 5
///   分钟复查远端），写库失败还原开关；
/// - WebDAV 账号：与自动备份**共享同一账号**（url/用户名/密码，密码经系统
///   凭据存储加密，NFR-3）；「保存并测试连接」先只读探测再保存；记住密码
///   （填过即加密保存，可清除）。
/// - 立即同步：手动执行一次完整同步并展示结果（拉取/推送/跳过/失败）。
/// - 最近同步时间展示与整库文件同步语义说明。
///
/// 与 auto_backup_page 同模式：`.when` + 本地 state + 保存/测试连接 + SnackBar。
class SyncPage extends ConsumerStatefulWidget {
  const SyncPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/sync';

  @override
  ConsumerState<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends ConsumerState<SyncPage> {
  late bool _enabled;
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _initialized = false;
  bool _testing = false;
  bool _runningSync = false;

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// 总开关：点击即写库生效（自动同步，review 修复：此前只改内存、
  /// 必须点保存才落库，与自动备份开关同款问题）。
  Future<void> toggleEnabled(bool value) async {
    if (value == _enabled) return;
    setState(() => _enabled = value); // 即时反馈
    final ok = await runDbAction(
      context,
      action: () async {
        await ref.read(settingsRepositoryProvider).updateSyncEnabled(value);
      },
    );
    if (!ok) {
      // 写库失败：还原开关（runDbAction 已弹「数据保存失败」）。
      if (mounted) {
        final saved =
            ref.read(settingsProvider).valueOrNull?.webdavSyncEnabled ?? false;
        setState(() => _enabled = saved);
      }
      return;
    }
    ref.invalidate(settingsProvider);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(value ? '已启用自动同步，将自动拉取/推送' : '已关闭自动同步'),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// 保存配置；[password] 非空时写入凭据存储并标记已保存（NFR-3）。
  ///
  /// [notify] 为 false 时（保存并测试连接的内部保存）不弹「已保存」
  /// SnackBar，由调用方统一提示结果，避免两条提示排队。
  ///
  /// 记住密码语义：填了密码即加密保存（系统凭据存储，DPAPI），下次打开
  /// 留空即可用已保存密码；改地址后密码标记随之重置（新地址实际无密码，
  /// 不再显示「已保存密码」误导）。
  Future<void> _save({String? password, bool notify = true}) async {
    final repo = ref.read(settingsRepositoryProvider);
    final url = _urlController.text.trim();
    final enteredPassword = password ?? _passwordController.text;
    final previous = await repo.get();
    if (!mounted) return;
    final urlChanged = previous.webdavUrl != url;
    final ok = await runDbAction(
      context,
      action: () async {
        await repo.updateSyncEnabled(_enabled);
        await repo.updateWebDavConfig(
          url: url.isEmpty ? null : url,
          username: _usernameController.text.trim().isEmpty
              ? null
              : _usernameController.text.trim(),
        );
        if (enteredPassword.isNotEmpty) {
          await ref
              .read(webDavCredentialStoreProvider)
              .save(url, enteredPassword);
          await repo.updateWebDavPasswordSaved(true);
        } else if (urlChanged) {
          // 地址变了但未填新密码：新地址没有可用密码，重置「已保存」标记
          // （旧地址密码仍在凭据存储中，供旧地址恢复使用）。
          await repo.updateWebDavPasswordSaved(false);
        }
      },
    );
    if (!ok) return;
    ref.invalidate(settingsProvider);
    if (notify && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('同步设置已保存')));
    }
  }

  /// 保存并测试 WebDAV 连接（只读探测：建目录 + 列目录）。
  ///
  /// 密码可留空（复用已保存密码）；测通后才保存配置，避免「保存了但连不上」。
  Future<void> _saveAndTest() async {
    final url = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (url.isEmpty || username.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请完整填写 WebDAV 地址与用户名')));
      return;
    }
    // 密码留空时用已保存密码（凭据存储）；两者都没有则提示先填密码。
    final effectivePassword = password.isNotEmpty
        ? password
        : await ref.read(webDavCredentialStoreProvider).read(url);
    if (!mounted) return;
    if (effectivePassword == null || effectivePassword.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请填写密码（或使用已保存密码留空）')));
      return;
    }
    setState(() => _testing = true);
    try {
      final service = ref.read(webDavSyncServiceProvider);
      await service.testConnection(
        url: url,
        username: username,
        password: effectivePassword,
      );
      await _save(password: password, notify: false);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('连接成功，WebDAV 配置已保存')));
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('连接失败：$e')));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 清除已保存的 WebDAV 密码（「忘记密码」入口）。
  Future<void> _forgetPassword() async {
    final url = _urlController.text.trim();
    final ok = await runDbAction(
      context,
      action: () async {
        await ref.read(webDavCredentialStoreProvider).delete(url);
        await ref
            .read(settingsRepositoryProvider)
            .updateWebDavPasswordSaved(false);
      },
    );
    if (!ok) return;
    ref.invalidate(settingsProvider);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已清除已保存的密码，请重新填写')));
    }
  }

  /// 手动立即同步：执行一次完整同步（未启用/未配置账号时跳过并说明）。
  Future<void> _syncNow() async {
    setState(() => _runningSync = true);
    try {
      final result = await ref.read(webDavSyncServiceProvider).syncOnce();
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      ref.invalidate(settingsProvider);
      if (result.skipped) {
        messenger.showSnackBar(
          SnackBar(content: Text('未同步：${result.skipReason}')),
        );
      } else if (result.error != null) {
        messenger.showSnackBar(SnackBar(content: Text('同步失败：${result.error}')));
      } else {
        final parts = <String>[
          if (result.pulled) '已从远端拉取并覆盖本地',
          if (result.pushed) '已推送本地数据到远端',
        ];
        final text = parts.isEmpty ? '已是最新，无需同步' : parts.join('，');
        // 分叉提示（M9 增强）：拉取覆盖前本地存在未推送的变更，覆盖后
        // 那些改动已被远端版本取代；安全副本可找回（路径在 result）。
        if (result.localChangesOverwritten) {
          final safetyLine = result.safetyCopyPath == null
              ? ''
              : '；被覆盖前的数据已保存在：\n${result.safetyCopyPath}';
          messenger.showSnackBar(
            SnackBar(
              content: Text('检测到本地有未推送的变更，已被远端版本覆盖'
                  '$safetyLine'),
              duration: const Duration(seconds: 6),
            ),
          );
        } else {
          messenger.showSnackBar(SnackBar(content: Text(text)));
        }
      }
    } finally {
      if (mounted) setState(() => _runningSync = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('同步')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorView(
          error: error,
          onRetry: () => ref.invalidate(settingsProvider),
        ),
        data: (settings) {
          if (!_initialized) {
            _enabled = settings.webdavSyncEnabled;
            _urlController.text = settings.webdavUrl ?? '';
            _usernameController.text = settings.webdavUsername ?? '';
            _initialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '把全部业务数据以整库快照同步到 WebDAV，多台设备共用同一'
                '份数据（M9）。触发时机：启动拉取、数据变更后推送、退出推送、'
                '每 5 分钟复查远端，也可手动「立即同步」。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile(
                  title: const Text('启用 WebDAV 同步'),
                  subtitle: const Text('与自动备份共享同一 WebDAV 账号'),
                  value: _enabled,
                  // 点击即写库生效（自动同步，review 修复）。
                  onChanged: toggleEnabled,
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.cloud_sync_outlined,
                            size: 20,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'WebDAV',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '与「自动备份」共用同一账号；已在自动备份页填写可留空。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _urlController,
                        decoration: const InputDecoration(
                          labelText: '服务器地址',
                          hintText: 'https://dav.example.com/dav',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _usernameController,
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: '密码',
                          helperText: settings.webdavPasswordSaved
                              ? '已记住密码，留空保持原密码'
                              : '密码经系统凭据存储加密保存（不进备份文件）',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      // 记住密码状态（NFR-3：加密存系统凭据存储，可主动清除）。
                      if (settings.webdavPasswordSaved)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                size: 14,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '密码已记住（系统凭据存储）',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                              TextButton(
                                onPressed: _forgetPassword,
                                child: const Text('清除已保存密码'),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 16),
                      // 总开关已点击即写库（toggleEnabled）；这里只需「保存并测试
                      // 连接」——同时保存账号配置与密码（测通才落库）。
                      FilledButton.icon(
                        onPressed: _testing ? null : _saveAndTest,
                        icon: Icon(
                          _testing
                              ? Icons.cloud_sync_outlined
                              : Icons.cloud_done_outlined,
                          size: 18,
                        ),
                        label: Text(_testing ? '测试中…' : '保存并测试连接'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.sync_outlined),
                  title: const Text('立即同步'),
                  subtitle: Text(_lastSyncText(settings)),
                  trailing: _runningSync
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton(
                          onPressed: _runningSync ? null : _syncNow,
                          child: const Text('立即同步'),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '同步语义说明',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '· 远端只保留一份最新快照，后写者胜：同一时间段请在'
                        '一台设备上编辑，避免两台设备同时修改后互相覆盖。\n'
                        '· 拉取覆盖本地前自动创建当前数据的安全副本（可恢复）。\n'
                        '· 计划偏好随快照同步；关闭行为、自动备份与同步自身'
                        '的配置各设备独立保留。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _lastSyncText(Setting settings) {
    final last = settings.lastSyncedAt;
    if (last == null) return '尚未同步过';
    return '上次同步：${DateFormat('yyyy-MM-dd HH:mm').format(last.toLocal())}';
  }
}
