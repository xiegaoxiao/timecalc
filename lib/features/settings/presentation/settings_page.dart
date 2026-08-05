import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../services/duration_format.dart';
import '../data/settings_repository.dart';
import '../data/settings_repository_provider.dart';

/// 设置页：M2 交付「计划偏好」（PRD §5.1 / §9 Settings）；
/// 其余设置项（外观、备份、快捷键）随后续里程碑提供。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载失败：$error')),
        data: (settings) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _PlanPreferenceSection(settings: settings),
            const Divider(height: 32),
            const _PlaceholderTile(
              icon: Icons.palette_outlined,
              title: '外观',
              note: 'M3 起提供主题切换',
            ),
            const Divider(height: 8),
            const _PlaceholderTile(
              icon: Icons.backup_outlined,
              title: '备份与恢复',
              note: 'M3 起提供手动备份/恢复',
            ),
            const Divider(height: 8),
            const _PlaceholderTile(
              icon: Icons.keyboard_outlined,
              title: '快捷键',
              note: 'P1 功能，后续迭代提供',
            ),
          ],
        ),
      ),
    );
  }
}

/// 计划偏好：每日可用时长（小时/分钟步进）+ 每周可用日（FR-5.3 负载计算数据来源）。
class _PlanPreferenceSection extends ConsumerStatefulWidget {
  const _PlanPreferenceSection({required this.settings});

  final Setting settings;

  @override
  ConsumerState<_PlanPreferenceSection> createState() =>
      _PlanPreferenceSectionState();
}

class _PlanPreferenceSectionState extends ConsumerState<_PlanPreferenceSection> {
  late int _hours;
  late int _minutes;
  late Set<int> _weekdays;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final total = widget.settings.dailyAvailableMinutes;
    _hours = total ~/ 60;
    _minutes = total % 60;
    _weekdays = SettingsRepository.decodeWeekdays(
      widget.settings.availableWeekdays,
    );
  }

  Future<void> _save() async {
    final total = _hours * 60 + _minutes;
    if (total < 1) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('每日可用时长至少 1 分钟')),
        );
      }
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      await repo.updateDailyAvailableMinutes(total);
      await repo.updateAvailableWeekdays(_weekdays);
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

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('计划偏好', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '用于计算每日负载与「超出」提示；默认每天 2 小时、每周 7 天（PRD §5.1）。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Text(
          '每日可用时长',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StepField(
                label: '小时',
                value: _hours,
                min: 0,
                max: 24,
                onDecrement: () => setState(() => _hours = _clamp(_hours - 1, 0, 24)),
                onIncrement: () => setState(() => _hours = _clamp(_hours + 1, 0, 24)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _StepField(
                label: '分钟',
                value: _minutes,
                min: 0,
                max: 59,
                onDecrement: () => setState(() => _minutes = _clamp(_minutes - 5, 0, 59)),
                onIncrement: () => setState(() => _minutes = _clamp(_minutes + 5, 0, 59)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '当前共 ${DurationFormat.minutes(_hours * 60 + _minutes)}（1～1440 分钟）',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
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
                selected: _weekdays.contains(day),
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _weekdays.add(day);
                    } else {
                      _weekdays.remove(day);
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
  }

  static int _clamp(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);

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

/// 小时/分钟步进输入：数值 + 上/下按钮（长按连续调整）。
class _StepField extends StatelessWidget {
  const _StepField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onDecrement,
    required this.onIncrement,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canDecrement = value > min;
    final canIncrement = value < max;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _StepButton(
                tooltip: '$label减',
                icon: Icons.remove,
                onPressed: canDecrement ? onDecrement : null,
              ),
              Expanded(
                child: Text(
                  '$value',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              _StepButton(
                tooltip: '$label加',
                icon: Icons.add,
                onPressed: canIncrement ? onIncrement : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 步进按钮：普通点击 + 长按连续触发（长按 400ms 后每 100ms 一次）。
class _StepButton extends StatefulWidget {
  const _StepButton({
    required this.tooltip,
    required this.icon,
    this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _start() {
    widget.onPressed?.call();
    // 长按 400ms 后进入连续步进（每 100ms 一次）。
    _timer = Timer(const Duration(milliseconds: 400), () {
      if (widget.onPressed == null) return;
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) widget.onPressed?.call();
      });
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: widget.onPressed == null ? null : (_) => _start(),
      onLongPressEnd: widget.onPressed == null ? null : (_) => _stop(),
      onLongPressCancel: widget.onPressed == null ? null : _stop,
      child: IconButton(
        tooltip: widget.tooltip,
        icon: Icon(widget.icon),
        onPressed: widget.onPressed == null
            ? null
            : () {
                _start();
                _stop();
              },
      ),
    );
  }
}

/// 尚未交付的设置项占位（PRD §8：不做纯说明页，提供明确后续计划）。
class _PlaceholderTile extends StatelessWidget {
  const _PlaceholderTile({
    required this.icon,
    required this.title,
    required this.note,
  });

  final IconData icon;
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(note),
      enabled: false,
    );
  }
}
