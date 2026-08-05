import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/duration_format.dart';

/// 小时/分钟步进时长输入组件。
///
/// 交互（与设置页每日可用时长一致）：
/// - +/- 按钮步进（小时 ±1、分钟 ±5），长按连续调整；
/// - 点击中间数字区域可直接输入，回车/失焦提交，超出范围自动夹取；
/// - [allowEmpty] 时提供「无时长」开关，勾选后 [onChanged] 回传 null。
///
/// [value] 为当前总分钟数（null 表示未设置）；[onChanged] 回传新值。
/// 步进/编辑结果钳制在 0 ~ [maxMinutes]；总分钟为 0 时的语义由调用方决定
/// （任务表单：保存时按「未设置」处理）。
class DurationStepInput extends StatefulWidget {
  const DurationStepInput({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.allowEmpty = false,
    this.maxMinutes = 1440,
    this.hourFieldKey,
    this.minuteFieldKey,
  });

  final String label;
  final int? value;
  final ValueChanged<int?> onChanged;

  /// 是否允许「无时长」（[value] 可为 null）。
  final bool allowEmpty;
  final int maxMinutes;
  final Key? hourFieldKey;
  final Key? minuteFieldKey;

  @override
  State<DurationStepInput> createState() => _DurationStepInputState();
}

class _DurationStepInputState extends State<DurationStepInput> {
  late int _hours;
  late int _minutes;
  late bool _empty;

  @override
  void initState() {
    super.initState();
    _syncFromValue(widget.value);
  }

  @override
  void didUpdateWidget(covariant DurationStepInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变化（如任务表单重置）时同步；编辑/步进中值一致时不打断。
    final current = _empty ? null : _hours * 60 + _minutes;
    if (widget.value != current) {
      _syncFromValue(widget.value);
    }
  }

  void _syncFromValue(int? minutes) {
    if (minutes == null) {
      // 未设置：可从 0 分起步，步进/编辑按钮保持可用（除非显式「无时长」）。
      _empty = false;
      _hours = 0;
      _minutes = 0;
    } else {
      _empty = false;
      _hours = minutes ~/ 60;
      _minutes = minutes % 60;
    }
  }

  void _notify() {
    widget.onChanged(_empty ? null : _hours * 60 + _minutes);
  }

  /// 统一钳制总分钟到 0 ~ [maxMinutes]，再拆回小时/分钟。
  void _applyTotal(int total) {
    if (total < 0) total = 0;
    if (total > widget.maxMinutes) total = widget.maxMinutes;
    setState(() {
      _empty = false;
      _hours = total ~/ 60;
      _minutes = total % 60;
    });
    _notify();
  }

  void _stepBy(int delta) {
    _applyTotal(_hours * 60 + _minutes + delta);
  }

  void _startAutoStep(int delta) {
    _stepBy(delta);
    // 长按 400ms 后进入连续步进（每 100ms 一次）。
    Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (mounted) _stepBy(delta);
      });
    });
  }

  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _stopAutoStep() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final total = _empty ? null : _hours * 60 + _minutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _StepField(
                key: widget.hourFieldKey,
                label: '小时',
                value: _hours,
                min: 0,
                max: 24,
                enabled: !_empty,
                onChanged: (v) {
                  setState(() => _hours = v);
                  _notify();
                },
                // 小时步进 ±1 小时。
                onStep: (d) => _stepBy(d * 60),
                onStartAutoStep: (d) => _startAutoStep(d * 60),
                onStopAutoStep: _stopAutoStep,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _StepField(
                key: widget.minuteFieldKey,
                label: '分钟',
                value: _minutes,
                min: 0,
                max: 59,
                enabled: !_empty,
                onChanged: (v) {
                  setState(() => _minutes = v);
                  _notify();
                },
                // 分钟步进 ±5 分钟。
                onStep: (d) => _stepBy(d * 5),
                onStartAutoStep: (d) => _startAutoStep(d * 5),
                onStopAutoStep: _stopAutoStep,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                _empty
                    ? '未设置时长'
                    : '当前共 ${DurationFormat.minutes(total!)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
            ),
            if (widget.allowEmpty)
              TextButton(
                onPressed: () {
                  setState(() {
                    _empty = !_empty;
                    _timer?.cancel();
                  });
                  _notify();
                },
                style: _empty
                    ? TextButton.styleFrom(
                        backgroundColor: scheme.secondaryContainer,
                      )
                    : null,
                child: const Text('无时长'),
              ),
          ],
        ),
      ],
    );
  }
}

/// 单个（小时/分钟）步进输入：+/- 按钮 + 点击数字直接编辑。
class _StepField extends StatefulWidget {
  const _StepField({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    required this.onStep,
    required this.onStartAutoStep,
    required this.onStopAutoStep,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onStep;
  final ValueChanged<int> onStartAutoStep;
  final VoidCallback onStopAutoStep;

  @override
  State<_StepField> createState() => _StepFieldState();
}

class _StepFieldState extends State<_StepField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller.text = '${widget.value}';
    _focusNode.addListener(_handleFocus);
  }

  @override
  void didUpdateWidget(_StepField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && _controller.text != '${widget.value}') {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocus);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocus() {
    if (!_focusNode.hasFocus) {
      _commit();
    }
  }

  /// 提交编辑输入：空值/非法保持原值，否则夹取到 min~max。
  void _commit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final parsed = int.tryParse(text);
    if (parsed == null) return;
    final clamped = parsed < widget.min
        ? widget.min
        : (parsed > widget.max ? widget.max : parsed);
    _controller.text = '$clamped';
    if (clamped != widget.value) {
      widget.onChanged(clamped);
    }
  }

  void _handleStep(int delta) {
    widget.onStep(delta);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                onPressed: widget.enabled && widget.value > widget.min
                    ? () {
                        _handleStep(-1);
                        widget.onStopAutoStep();
                      }
                    : null,
                onLongPressStart:
                    widget.enabled && widget.value > widget.min
                        ? (_) {
                            _handleStep(-1);
                            widget.onStartAutoStep(-1);
                          }
                        : null,
                onLongPressEnd: (_) => widget.onStopAutoStep(),
                onLongPressCancel: widget.onStopAutoStep,
              ),
              Expanded(
                child: InkWell(
                  onTap: widget.enabled
                      ? () => _focusNode.requestFocus()
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      enabled: widget.enabled,
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
                      onSubmitted: (_) => _focusNode.unfocus(),
                    ),
                  ),
                ),
              ),
              _StepButton(
                tooltip: '${widget.label}加',
                icon: Icons.add,
                onPressed: widget.enabled && widget.value < widget.max
                    ? () {
                        _handleStep(1);
                        widget.onStopAutoStep();
                      }
                    : null,
                onLongPressStart:
                    widget.enabled && widget.value < widget.max
                        ? (_) {
                            _handleStep(1);
                            widget.onStartAutoStep(1);
                          }
                        : null,
                onLongPressEnd: (_) => widget.onStopAutoStep(),
                onLongPressCancel: widget.onStopAutoStep,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 步进按钮：普通点击 + 长按连续触发。
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
