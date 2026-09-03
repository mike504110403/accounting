/// 購物清單分頁：依店家分組、勾選跳結帳、長按多選、已完成折疊區、滑動刪除。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'checkout.dart';

class ShoppingTab extends ConsumerWidget {
  const ShoppingTab({
    super.key,
    required this.selecting,
    required this.selectedIds,
    required this.onLongPressItem,
    required this.onToggleSelected,
    required this.onCheckoutOne,
  });

  final bool selecting;
  final Set<String> selectedIds;
  final void Function(String id) onLongPressItem;
  final void Function(String id) onToggleSelected;
  final void Function(ListItem item) onCheckoutOne;

  /// 確認對話框在前，remove 失敗就不讓 Dismissible 收掉這一列（避免「已 dismiss 但資料還在」不一致）。
  Future<bool> _confirmAndDelete(BuildContext context, WidgetRef ref, String id, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除項目'),
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
    final entries = ref.watch(entriesProvider);
    final categories = {for (final c in ref.watch(categoriesProvider)) c.id: c};
    final members = {for (final m in ref.watch(membersProvider)) m.id: m};

    final shopping = all.where((i) => i.categoryId != null).toList();
    if (shopping.isEmpty) {
      return const Center(child: Text('目前沒有購物項目'));
    }

    final notDone = shopping.where((i) => !i.isDone).toList();
    final done = shopping.where((i) => i.isDone).toList()
      ..sort((a, b) => (b.doneAt ?? DateTime(0)).compareTo(a.doneAt ?? DateTime(0)));
    final groups = groupByStore(notDone);

    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Text(
              group.key.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final item in group.value)
                  _ShoppingRow(
                    key: ValueKey('shopping-${item.id}'),
                    item: item,
                    category: categories[item.categoryId],
                    assignee: item.assigneeId == null ? null : members[item.assigneeId],
                    selecting: selecting,
                    selected: selectedIds.contains(item.id),
                    onTap: () => selecting ? onToggleSelected(item.id) : onCheckoutOne(item),
                    onLongPress: selecting ? null : () => onLongPressItem(item.id),
                    onConfirmDelete: () => _confirmAndDelete(context, ref, item.id, item.title),
                  ),
              ],
            ),
          ),
        ],
        if (done.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              title: Text('已完成 ${done.length}'),
              children: [for (final item in done) _DoneRow(item: item, entries: entries, allItems: all)],
            ),
          ),
      ],
    );
  }
}

class _ShoppingRow extends StatelessWidget {
  const _ShoppingRow({
    super.key,
    required this.item,
    required this.category,
    required this.assignee,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onConfirmDelete,
  });

  final ListItem item;
  final Category? category;
  final Member? assignee;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Future<bool> Function() onConfirmDelete;

  @override
  Widget build(BuildContext context) {
    final accessory = _accessory(context);
    return Dismissible(
      key: ValueKey('dismiss-shopping-${item.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => onConfirmDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Theme.of(context).colorScheme.errorContainer,
        child: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.onErrorContainer),
      ),
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: Checkbox(value: selecting && selected, onChanged: (_) => onTap()),
        // 資訊密度：核取框｜名稱｜（分類或負責人擇一，縮成 16px 小圖示）｜預估金額，單行。
        title: Row(
          children: [
            Expanded(child: Text(item.title, overflow: TextOverflow.ellipsis)),
            if (accessory != null) Padding(padding: const EdgeInsets.only(left: 8), child: accessory),
            const SizedBox(width: 8),
            Text(fmtMoney(item.estimated ?? 0), style: _tabularAmount),
          ],
        ),
      ),
    );
  }

  /// 分類與負責人同時最多顯示一個：優先顯示負責人（誰要去買，比分類更關鍵），沒指派才退回分類小圖示。
  Widget? _accessory(BuildContext context) {
    if (assignee != null) {
      return CircleAvatar(
        radius: 8, // 16px 圓
        child: Text(_assigneeInitial(assignee), style: const TextStyle(fontSize: 9)),
      );
    }
    if (category != null) {
      return Icon(categoryIcon(category!.icon), size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant);
    }
    return null;
  }
}

class _DoneRow extends StatelessWidget {
  const _DoneRow({required this.item, required this.entries, required this.allItems});
  final ListItem item;
  final List<Entry> entries;

  /// 完整購物清單（含其他已完成項目），resolveDoneAmount 用來在同一筆 entry 下對應同名細項。
  final List<ListItem> allItems;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary),
      title: Text(item.title, style: const TextStyle(decoration: TextDecoration.lineThrough)),
      subtitle: Text(item.doneAt == null ? '' : fmtDate(item.doneAt!)),
      trailing: Text(fmtMoney(resolveDoneAmount(item, entries, allItems)), style: _tabularAmount),
    );
  }
}

/// 金額用等寬數字，避免列表中的數字寬度跳動。
const _tabularAmount = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

/// 負責人頭像首字；沒指派回空字串，指派了但姓名剛好是空字串則回 '?' 避免 substring RangeError。
String _assigneeInitial(Member? assignee) {
  if (assignee == null) return '';
  return assignee.displayName.isEmpty ? '?' : assignee.displayName.substring(0, 1);
}
