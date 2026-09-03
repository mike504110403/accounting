/// 待辦分頁：依到期日升冪（null 最後）、勾選完成、滑動刪除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'checkout.dart';

class TodoTab extends ConsumerWidget {
  const TodoTab({super.key});

  void _toggleDone(BuildContext context, WidgetRef ref, ListItem item) {
    try {
      ref.read(listItemsProvider.notifier).update(withDone(item, item.isDone ? null : DateTime.now()));
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('更新失敗，請稍後再試')));
    }
  }

  Future<bool> _confirmAndDelete(BuildContext context, WidgetRef ref, String id, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除待辦'),
        content: Text('確定刪除「$title」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true) return false;
    try {
      ref.read(listItemsProvider.notifier).remove(id);
      return true;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('刪除失敗，請稍後再試')));
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(listItemsProvider);
    final members = {for (final m in ref.watch(membersProvider)) m.id: m};
    final todos = all.where((i) => i.categoryId == null).toList()
      ..sort((a, b) {
        if (a.dueOn == null && b.dueOn == null) return 0;
        if (a.dueOn == null) return 1;
        if (b.dueOn == null) return -1;
        return a.dueOn!.compareTo(b.dueOn!);
      });

    if (todos.isEmpty) {
      return const Center(child: Text('目前沒有待辦'));
    }

    final now = DateTime.now();
    final colors = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: todos.length,
      itemBuilder: (context, i) {
        final item = todos[i];
        final assignee = item.assigneeId == null ? null : members[item.assigneeId];
        final status = dueStatus(item.dueOn, now);
        final dueColor = switch (status) {
          DueStatus.overdue => colors.error,
          DueStatus.soon => colors.tertiary,
          _ => null,
        };
        final dueLabel = switch (status) {
          DueStatus.overdue => '已過期',
          DueStatus.soon => '即將到期',
          DueStatus.normal => fmtDate(item.dueOn!),
          DueStatus.none => null,
        };
        return Dismissible(
          key: ValueKey('dismiss-todo-${item.id}'),
          direction: DismissDirection.endToStart,
          confirmDismiss: (_) => _confirmAndDelete(context, ref, item.id, item.title),
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            color: colors.errorContainer,
            child: Icon(Icons.delete_outline, color: colors.onErrorContainer),
          ),
          child: Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Checkbox(value: item.isDone, onChanged: (_) => _toggleDone(context, ref, item)),
              // 資訊密度：核取框｜標題｜負責人（16px 小圓）｜到期標籤，單行。
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.title,
                      overflow: TextOverflow.ellipsis,
                      style: item.isDone ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                    ),
                  ),
                  if (assignee != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: CircleAvatar(
                        radius: 8, // 16px 圓
                        child: Text(_assigneeInitial(assignee), style: const TextStyle(fontSize: 9)),
                      ),
                    ),
                  if (dueLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(dueLabel, style: TextStyle(color: dueColor, fontWeight: dueColor == null ? null : FontWeight.bold)),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 負責人頭像首字；姓名剛好是空字串則回 '?' 避免 substring RangeError。
String _assigneeInitial(Member assignee) => assignee.displayName.isEmpty ? '?' : assignee.displayName.substring(0, 1);
