import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_guard.dart';
import '../../../shared/widgets/duration_step_input.dart';
import '../data/settings_repository.dart';
import '../data/settings_repository_provider.dart';

/// 计划偏好页（进度页入口卡 push 进入）。
///
/// 承载完整计划偏好编辑：每日可用时长（小时/分钟步进）+ 每周可用日
/// （FR-5.3 负载计算数据来源；FR-3.5 今日页「超出」提示的可用时长来源）。
/// 保存后写库并刷新 [settingsProvider]，返回进度页时入口卡摘要同步更新。
class PlanPreferencePage extends ConsumerStatefulWidget {
  const PlanPreferencePage({super.key});

  @override
  ConsumerState<PlanPreferencePage> createState() =>
      _PlanPreferencePageState();
}

class _PlanPreferencePageState extends ConsumerState<PlanPreferencePage> {
  int? _dailyMinutes;
  Set<int>? _weekdays;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('计划偏好')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (settings) {
          // 首次构建时从设置初始化本地编辑状态。
          _dailyMinutes ??= settings.dailyAvailableMinutes;
          _weekdays ??=
              SettingsRepository.decodeWeekdays(settings.availableWeekdays);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '用于计算每日负载与「超出」提示；默认每天 2 小时、每周 7 天（PRD §5.1）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              DurationStepInput(
                label: '每日可用时长',
                value: _dailyMinutes,
                onChanged: (minutes) {
                  if (minutes != null) {
                    setState(() => _dailyMinutes = minutes);
                  }
                },
                hourFieldKey: const Key('hourStepField'),
                minuteFieldKey: const Key('minuteStepField'),
              ),
              const SizedBox(height: 16),
              Text(
                '每周可用日',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final day in const [1, 2, 3, 4, 5, 6, 7])
                    FilterChip(
                      label: Text(_weekdayLabel(day)),
                      selected: _weekdays!.contains(day),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _weekdays!.add(day);
                          } else {
                            _weekdays!.remove(day);
                          }
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _save() async {
    final total = _dailyMinutes;
    if (total == null || total < 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('每日可用时长至少 1 分钟')),
        );
      }
      return;
    }
    setState(() => _saving = true);
    try {
      final ok = await runDbAction(
        context,
        action: () async {
          final repo = ref.read(settingsRepositoryProvider);
          await repo.updateDailyAvailableMinutes(total);
          await repo.updateAvailableWeekdays(_weekdays!);
        },
      );
      if (!ok) return;
      ref.invalidate(settingsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('计划偏好已保存')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _weekdayLabel(int iso) {
    return switch (iso) {
      1 => '周一',
      2 => '周二',
      3 => '周三',
      4 => '周四',
      5 => '周五',
      6 => '周六',
      7 => '周日',
      _ => '未知',
    };
  }
}
