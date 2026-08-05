import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
                key: const Key('hourStepField'),
                label: '小时',
                value: _hours,
                min: 0,
                max: 24,
                step: 1,
                onChanged: (v) => setState(() => _hours = v),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _StepField(
                key: const Key('minuteStepField'),
                label: '分钟',
                value: _minutes,
                min: 0,
                max: 59,
                step: 5,
                onChanged: (v) => setState(() => _minutes = v),
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

/// 小时/分钟步进输入：+/- 按钮步进，点击中间数字区域可直接输入编辑。
class _StepField extends StatefulWidget {
  const _StepField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;

  /// 点按 +/- 时单次增减的步长（编辑输入不受步长限制，按 [min]~[max] 收口）。
  final int step;
  final ValueChanged<int> onChanged;

  @override
  State<_StepField> createState() => _StepFieldState();
}

class _StepFieldState extends State<_StepField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _timer;

  /// 当前编辑/步进值。独立于 widget.value 维护，保证连续点击与长按连调
  /// 不依赖帧重建时机。
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
    _controller.text = '$_value';
    // 获得焦点进入编辑态：点击中间数字区域即可输入。
    _focusNode.addListener(_handleFocus);
  }

  @override
  void didUpdateWidget(_StepField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 非编辑态时跟随外部值（如恢复/刷新）；编辑态不打断输入。
    if (!_focusNode.hasFocus && widget.value != _value) {
      _value = widget.value;
      _controller.text = '$_value';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocus);
    _focusNode.dispose();
    _controller.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _handleFocus() {
    if (!_focusNode.hasFocus) {
      _commit();
    }
  }

  /// 提交输入：空值保持原值；解析并夹取到 [min]~[max]，非法字符忽略。
  void _commit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _controller.text = '$_value';
      return;
    }
    final parsed = int.tryParse(text);
    if (parsed == null) {
      _controller.text = '$_value';
      return;
    }
    _apply(parsed);
  }

  void _stepBy(int delta) {
    // 编辑中按 +/-：先提交当前输入，再基于其结果步进。
    if (_focusNode.hasFocus) {
      _commit();
    }
    _apply(_value + delta);
  }

  void _apply(int raw) {
    final clamped = _clamp(raw, widget.min, widget.max);
    _value = clamped;
    _controller.text = '$clamped';
    if (clamped != widget.value) {
      widget.onChanged(clamped);
    }
  }

  void _startAutoStep() {
    _stepBy(widget.step);
    // 长按 400ms 后进入连续步进（每 100ms 一次）。
    _timer = Timer(const Duration(milliseconds: 400), () {
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) _stepBy(widget.step);
      });
    });
  }

  void _stopAutoStep() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canDecrement = _value > widget.min;
    final canIncrement = _value < widget.max;
    final editing = _focusNode.hasFocus;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: editing ? scheme.primary : scheme.outlineVariant,
              width: editing ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _StepButton(
                tooltip: '${widget.label}减',
                icon: Icons.remove,
                onPressed: canDecrement
                    ? () {
                        _stepBy(-widget.step);
                        _stopAutoStep();
                      }
                    : null,
                onLongPressStart: canDecrement
                    ? (_) {
                        _stepBy(-widget.step);
                        _startAutoStep();
                      }
                    : null,
                onLongPressEnd: (_) => _stopAutoStep(),
                onLongPressCancel: _stopAutoStep,
              ),
              // 点击中间数字区域进入编辑：获得焦点即可直接输入。
              Expanded(
                child: InkWell(
                  onTap: () => _focusNode.requestFocus(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      style: Theme.of(context).textTheme.titleMedium,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '0',
                      ),
                      // 回车确认并失焦。
                      onSubmitted: (_) => _focusNode.unfocus(),
                    ),
                  ),
                ),
              ),
              _StepButton(
                tooltip: '${widget.label}加',
                icon: Icons.add,
                onPressed: canIncrement
                    ? () {
                        _stepBy(widget.step);
                        _stopAutoStep();
                      }
                    : null,
                onLongPressStart: canIncrement
                    ? (_) {
                        _stepBy(widget.step);
                        _startAutoStep();
                      }
                    : null,
                onLongPressEnd: (_) => _stopAutoStep(),
                onLongPressCancel: _stopAutoStep,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static int _clamp(int value, int min, int max) =>
      value < min ? min : (value > max ? max : value);
}

/// 步进按钮：普通点击 + 长按连续触发（长按 400ms 后每 100ms 一次）。
class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tooltip,
    required this.icon,
    this.onPressed,
    this.onLongPressStart,
    this.onLongPressEnd,
    this.onLongPressCancel,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: onLongPressStart,
      onLongPressEnd: onLongPressEnd,
      onLongPressCancel: onLongPressCancel,
      child: IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onPressed,
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
