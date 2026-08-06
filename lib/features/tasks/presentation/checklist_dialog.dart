import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart';
import '../../../core/errors/app_guard.dart';
import '../data/checklist_item_repository_provider.dart';

/// 完成任务前的二次确认（FR-4.1）。
///
/// 任务存在未完成检查项时弹出确认框；返回 true 表示确认继续完成任务
/// （或无需确认），false 表示用户取消。TaskTile 与 _TaskTile 的完成
/// 勾选共用本函数，保证两处行为一致。
Future<bool> confirmCompleteTask(
  BuildContext context,
  WidgetRef ref,
  Task task,
) async {
  final repo = ref.read(checklistItemRepositoryProvider);
  final unfinished = await repo.unfinishedCount(task.id);
  if (unfinished == 0) return true;
  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('完成任务？'),
      content: Text('还有 $unfinished 个检查项未完成。确定完成任务吗？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确定完成'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 检查项管理对话框（FR-4.1）。
///
/// 任务内可排序检查项：顶部输入行 +「添加」；列表按 sortOrder 展示，
/// 每行 Checkbox（勾选划线）+ 标题 + 上移/下移 + 删除；点标题重命名。
/// 所有变更在保存后 invalidate [checklistItemsProvider]（对话框内 watch，
/// 列表即时刷新）。
class ChecklistDialog extends ConsumerStatefulWidget {
  const ChecklistDialog({super.key, required this.task});

  final Task task;

  static Future<void> show(BuildContext context, {required Task task}) {
    return showDialog<void>(
      context: context,
      builder: (_) => ChecklistDialog(task: task),
    );
  }

  @override
  ConsumerState<ChecklistDialog> createState() => _ChecklistDialogState();
}

class _ChecklistDialogState extends ConsumerState<ChecklistDialog> {
  final _inputController = TextEditingController();

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _addItem() async {
    final title = _inputController.text.trim();
    if (title.isEmpty) return;
    final ok = await runDbAction(
      context,
      action: () => ref
          .read(checklistItemRepositoryProvider)
          .create(taskId: widget.task.id, title: title),
    );
    if (!ok) return;
    _inputController.clear();
    ref.invalidate(checklistItemsProvider(widget.task.id));
  }

  Future<void> _renameItem(ChecklistItem item) async {
    final controller = TextEditingController(text: item.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名检查项'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '检查项内容',
            border: OutlineInputBorder(),
          ),
          maxLength: 200,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty || title == item.title) return;
    if (!mounted) return;
    final ok = await runDbAction(
      context,
      action: () => ref.read(checklistItemRepositoryProvider).rename(item.id, title),
    );
    if (!ok) return;
    ref.invalidate(checklistItemsProvider(widget.task.id));
  }

  Future<void> _toggleItem(ChecklistItem item, bool done) async {
    final ok = await runDbAction(
      context,
      action: () => ref.read(checklistItemRepositoryProvider).setDone(item.id, done),
    );
    if (!ok) return;
    ref.invalidate(checklistItemsProvider(widget.task.id));
  }

  Future<void> _deleteItem(ChecklistItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除检查项？'),
        content: Text('将删除「${item.title}」，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ok = await runDbAction(
      context,
      action: () => ref.read(checklistItemRepositoryProvider).delete(item.id),
    );
    if (!ok) return;
    ref.invalidate(checklistItemsProvider(widget.task.id));
  }

  Future<void> _moveItem(ChecklistItem item, int delta) async {
    final ok = await runDbAction(
      context,
      action: () => ref
          .read(checklistItemRepositoryProvider)
          .move(widget.task.id, item.id, delta),
    );
    if (!ok) return;
    ref.invalidate(checklistItemsProvider(widget.task.id));
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(checklistItemsProvider(widget.task.id));
    return AlertDialog(
      title: Text('检查项 · ${widget.task.title}'),
      constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '添加检查项',
                      hintText: '例如：背 100 个单词',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLength: 200,
                    onSubmitted: (_) => _addItem(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: itemsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Center(child: Text('检查项加载失败：$error')),
                data: (items) {
                  if (items.isEmpty) {
                    return const Center(
                      child: Text('还没有检查项，输入内容点「添加」'),
                    );
                  }
                  return ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final done = item.done;
                      return ListTile(
                        dense: true,
                        leading: Checkbox(
                          value: done,
                          semanticLabel:
                              done ? '标记未完成' : '标记完成',
                          onChanged: (value) =>
                              _toggleItem(item, value ?? false),
                        ),
                        title: Text(
                          item.title,
                          style: done
                              ? const TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                )
                              : null,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: '上移',
                              icon: const Icon(Icons.arrow_upward, size: 18),
                              onPressed: index == 0
                                  ? null
                                  : () => _moveItem(item, -1),
                            ),
                            IconButton(
                              tooltip: '下移',
                              icon: const Icon(Icons.arrow_downward, size: 18),
                              onPressed: index == items.length - 1
                                  ? null
                                  : () => _moveItem(item, 1),
                            ),
                            IconButton(
                              tooltip: '重命名',
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _renameItem(item),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline, size: 18),
                              onPressed: () => _deleteItem(item),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
