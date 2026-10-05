import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_tokens.dart';
import 'app_dialog.dart';
import 'app_form_field.dart';

/// 桌面时间选择：明确的 24 小时输入、分钟快捷项，取消不改变原值。
Future<TimeOfDay?> showAppTimePicker({
  required BuildContext context,
  required TimeOfDay initialTime,
  String helpText = '选择计划时刻',
}) {
  return showDialog<TimeOfDay>(
    context: context,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.32),
    builder: (_) => _TimePicker(initialTime: initialTime, title: helpText),
  );
}

class _TimePicker extends StatefulWidget {
  const _TimePicker({required this.initialTime, required this.title});

  final TimeOfDay initialTime;
  final String title;

  @override
  State<_TimePicker> createState() => _TimePickerState();
}

class _TimePickerState extends State<_TimePicker> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _hour;
  late final TextEditingController _minute;
  final _minuteFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _hour = TextEditingController(text: _pad(widget.initialTime.hour));
    _minute = TextEditingController(text: _pad(widget.initialTime.minute));
    _hour.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
  }

  String _pad(int value) => value.toString().padLeft(2, '0');

  @override
  void dispose() {
    _hour.dispose();
    _minute.dispose();
    _minuteFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      TimeOfDay(hour: int.parse(_hour.text), minute: int.parse(_minute.text)),
    );
  }

  Widget _field({
    required String label,
    required TextEditingController controller,
    required int max,
    bool isHour = false,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: isHour ? null : _minuteFocus,
      autofocus: isHour,
      textAlign: TextAlign.center,
      style: Theme.of(
        context,
      ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600),
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(2),
      ],
      textInputAction: isHour ? TextInputAction.next : TextInputAction.done,
      decoration: AppFormField.defaultDecoration(
        label: label,
        helperText: '00–${_pad(max)}',
        scheme: Theme.of(context).colorScheme,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 18,
          horizontal: AppTokens.spaceMd,
        ),
      ),
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (text) {
        final value = int.tryParse(text ?? '');
        return value == null || value < 0 || value > max
            ? '请输入 00–${_pad(max)}'
            : null;
      },
      onChanged: (_) => setState(() {}),
      onFieldSubmitted: (_) {
        if (isHour) {
          _minuteFocus.requestFocus();
          _minute.selection = TextSelection(
            baseOffset: 0,
            extentOffset: _minute.text.length,
          );
        } else {
          _submit();
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppDialog(
      title: widget.title,
      titleIcon: Icons.schedule_outlined,
      maxWidth: 420,
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('24 小时制 · 输入小时和分钟', style: theme.textTheme.bodySmall),
            const SizedBox(height: AppTokens.spaceXl),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _field(
                    label: '小时',
                    controller: _hour,
                    max: 23,
                    isHour: true,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
                  child: Text(':', style: theme.textTheme.headlineMedium),
                ),
                Expanded(
                  child: _field(label: '分钟', controller: _minute, max: 59),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.spaceLg),
            Text('快捷分钟', style: theme.textTheme.bodySmall),
            const SizedBox(height: AppTokens.spaceSm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final minute in [0, 15, 30, 45])
                  ChoiceChip(
                    label: Text('${_pad(minute)} 分'),
                    selected: int.tryParse(_minute.text) == minute,
                    showCheckmark: false,
                    onSelected: (_) => setState(() {
                      _minute.text = _pad(minute);
                    }),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
