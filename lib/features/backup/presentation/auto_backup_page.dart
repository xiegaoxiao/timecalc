import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../data/auto_backup_service_provider.dart';
import '../data/backup_folder_picker.dart';
import '../data/credential_store.dart';
import '../../settings/data/settings_repository_provider.dart';

/// 自动备份设置页（FR-9.4，M8）。
///
/// 由设置页「自动备份」菜单项 push 进入。配置项：
/// - 总开关：启用后应用运行期间每日自动备份（启动检查 + 每小时复查）；
/// - 本地目录：选择文件夹，备份写入该目录；
/// - WebDAV：服务器地址 / 用户名 / 密码，保存时写入系统凭据存储
///   （NFR-3，Windows DPAPI），可「保存并测试连接」；
/// - 立即备份：force 执行一次并展示结果。
///
/// 与 close_behavior_page 同模式：`.when` + 本地 state + 保存 + SnackBar。
class AutoBackupPage extends ConsumerStatefulWidget {
  const AutoBackupPage({super.key});

  /// 设置子路由（设置页菜单 push 进入，app_router 注册）。
  static const String route = '/settings/auto-backup';

  @override
  ConsumerState<AutoBackupPage> createState() => _AutoBackupPageState();
}

class _AutoBackupPageState extends ConsumerState<AutoBackupPage> {
  late bool _enabled;
  String? _localFolder;
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _initialized = false;
  bool _testing = false;
  bool _runningBackup = false;

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _pickFolder() async {
    final picked = await ref.read(backupFolderPickerProvider).pickFolder();
    if (picked == null || picked.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _localFolder = picked);
  }

  /// 保存配置；password 非空时写入凭据存储并标记已保存。
  ///
  /// [notify] 为 false 时（保存并测试连接的内部保存）不弹「已保存」
  /// SnackBar，由调用方统一提示结果，避免两条提示排队。
  Future<void> _save({String? password, bool notify = true}) async {
    final repo = ref.read(settingsRepositoryProvider);
    final url = _urlController.text.trim();
    final ok = await runDbAction(
      context,
      action: () async {
        await repo.updateAutoBackupEnabled(_enabled);
        await repo.updateLocalBackupFolder(
          _localFolder == null || _localFolder!.trim().isEmpty
              ? null
              : _localFolder!.trim(),
        );
        await repo.updateWebDavConfig(
          url: url.isEmpty ? null : url,
          username: _usernameController.text.trim().isEmpty
              ? null
              : _usernameController.text.trim(),
        );
        if (password != null && password.isNotEmpty) {
          await ref
              .read(webDavCredentialStoreProvider)
              .save(url, password);
          await repo.updateWebDavPasswordSaved(true);
        }
      },
    );
    if (!ok) return;
    ref.invalidate(settingsProvider);
    if (notify && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('自动备份设置已保存')),
      );
    }
  }

  /// 保存并测试 WebDAV 连接（只读探测：建目录 + 列目录）。
  Future<void> _saveAndTest() async {
    final url = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (url.isEmpty || username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请完整填写 WebDAV 地址、用户名与密码')),
      );
      return;
    }
    setState(() => _testing = true);
    try {
      final service = ref.read(autoBackupServiceProvider);
      await service.testWebDavConnection(
        url: url,
        username: username,
        password: password,
      );
      await _save(password: password, notify: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('连接成功，WebDAV 配置已保存')),
      );
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('连接失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 立即备份（force）：无论距上次多久都执行一次。
  Future<void> _backupNow() async {
    setState(() => _runningBackup = true);
    try {
      final result = await ref.read(autoBackupServiceProvider).run(force: true);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      ref.invalidate(settingsProvider);
      if (result.skipped) {
        messenger.showSnackBar(SnackBar(content: Text('未执行：${result.skipReason}')));
      } else if (result.succeeded) {
        messenger.showSnackBar(
          SnackBar(content: Text('自动备份完成：${result.uploadedTargets} 个目的地')),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text('自动备份失败：${result.errors.join('；')}')),
        );
      }
    } finally {
      if (mounted) setState(() => _runningBackup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('自动备份')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (settings) {
          if (!_initialized) {
            _enabled = settings.autoBackupEnabled;
            _localFolder = settings.localBackupFolder;
            _urlController.text = settings.webdavUrl ?? '';
            _usernameController.text = settings.webdavUsername ?? '';
            _initialized = true;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '每日自动备份全部业务数据到本地目录与/或 WebDAV（FR-9.4）。'
                '应用运行期间生效：启动时检查一次、之后每小时复查；'
                '距离上次备份不足 24 小时自动跳过。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile(
                  title: const Text('启用每日自动备份'),
                  subtitle: const Text('备份文件保留最近 7 份'),
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('本地目录',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    ListTile(
                      leading: const Icon(Icons.folder_outlined),
                      title: Text(
                        _localFolder == null || _localFolder!.trim().isEmpty
                            ? '未选择（本地目的地不启用）'
                            : _localFolder!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: FilledButton.tonal(
                        onPressed: _pickFolder,
                        child: const Text('选择目录…'),
                      ),
                    ),
                  ],
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
                          Icon(Icons.cloud_outlined,
                              size: 20, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('WebDAV',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
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
                              ? '已保存密码，留空保持原密码'
                              : '密码经系统凭据存储加密保存（不进备份文件）',
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: _testing ? null : _saveAndTest,
                            icon: const Icon(Icons.cloud_done_outlined, size: 18),
                            label: Text(_testing ? '测试中…' : '保存并测试连接'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => _save(),
                            icon: const Icon(Icons.save_outlined, size: 18),
                            label: const Text('仅保存'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('立即备份'),
                  subtitle: Text(_lastBackupText(settings)),
                  trailing: _runningBackup
                      ? const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton(
                          onPressed: _backupNow,
                          child: const Text('立即备份'),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'WebDAV 密码使用系统凭据存储（Windows DPAPI）加密保存，'
                '不进入业务数据库与备份文件（NFR-3 / FR-9.5）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
        },
      ),
    );
  }

  String _lastBackupText(Setting settings) {
    final last = settings.lastAutoBackupAt;
    if (last == null) return '尚未执行过自动备份';
    return '上次成功：${DateFormat('yyyy-MM-dd HH:mm').format(last.toLocal())}';
  }
}
