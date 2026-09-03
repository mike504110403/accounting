import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/category_icon.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';

/// 分類管理：支出／收入兩段，可新增、編輯、刪除（使用中禁刪）、拖曳排序。
/// 獨立頁面用（見 category_page.dart），不自帶外層 Card／標題。
class CategoryManagementSection extends ConsumerWidget {
  const CategoryManagementSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider);
    final expense =
        categories.where((c) => c.kind == EntryKind.expense).toList()
          ..sort((a, b) => a.sort.compareTo(b.sort));
    final income = categories.where((c) => c.kind == EntryKind.income).toList()
      ..sort((a, b) => a.sort.compareTo(b.sort));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(context, '支出', EntryKind.expense),
        _CategoryReorderList(categories: expense, kind: EntryKind.expense),
        const SizedBox(height: 12),
        _sectionHeader(context, '收入', EntryKind.income),
        _CategoryReorderList(categories: income, kind: EntryKind.income),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String label, EntryKind kind) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        IconButton(
          key: ValueKey('add-category-${kind.name}'),
          icon: const Icon(Icons.add_circle_outline),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => _CategoryEditorSheet(kind: kind),
          ),
        ),
      ],
    );
  }
}

class _CategoryReorderList extends ConsumerWidget {
  const _CategoryReorderList({required this.categories, required this.kind});
  final List<Category> categories;
  final EntryKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (categories.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('尚無分類'),
      );
    }
    return ReorderableListView(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) => ref
          .read(categoriesStateProvider.notifier)
          .reorder(kind, oldIndex, newIndex),
      children: [
        for (var i = 0; i < categories.length; i++)
          ListTile(
            key: ValueKey(categories[i].id),
            leading: Icon(categoryIcon(categories[i].icon)),
            title: Text(categories[i].name),
            subtitle: categories[i].rollover ? const Text('累計 rollover') : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (_) => _CategoryEditorSheet(
                      existing: categories[i],
                      kind: kind,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _delete(context, ref, categories[i]),
                ),
                ReorderableDragStartListener(
                  index: i,
                  child: const Icon(Icons.drag_handle),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _delete(BuildContext context, WidgetRef ref, Category c) {
    final inUse = ref.read(entriesProvider).any((e) => e.categoryId == c.id);
    if (inUse) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('此分類已有帳目使用，無法刪除')));
      return;
    }
    try {
      ref.read(categoriesStateProvider.notifier).remove(c.id);
    } catch (_) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('刪除失敗，請重試')));
    }
  }
}

/// 新增／編輯分類的 bottom sheet（spec v1.1：表單一律 bottom sheet，不用 dialog）。
class _CategoryEditorSheet extends ConsumerStatefulWidget {
  const _CategoryEditorSheet({this.existing, required this.kind});
  final Category? existing;
  final EntryKind kind;

  @override
  ConsumerState<_CategoryEditorSheet> createState() =>
      _CategoryEditorSheetState();
}

class _CategoryEditorSheetState extends ConsumerState<_CategoryEditorSheet> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _icon = widget.existing?.icon ?? categoryIconNames.first;
  late bool _rollover = widget.existing?.rollover ?? false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '請輸入名稱');
      return;
    }
    final kind = widget.existing?.kind ?? widget.kind;
    // sheet 蓋在上面時 SnackBar 會被擋住看不到（MAJOR-2）：錯誤改 sheet 內一行；成功直接 pop（本來就不彈 SnackBar）。
    try {
      final notifier = ref.read(categoriesStateProvider.notifier);
      if (widget.existing != null) {
        final c = widget.existing!;
        notifier.update(
          Category(
            id: c.id,
            ledgerId: c.ledgerId,
            kind: kind,
            name: name,
            icon: _icon,
            sort: c.sort,
            rollover: _rollover,
          ),
        );
      } else {
        final all = ref.read(categoriesProvider);
        final nextSort = all.where((c) => c.kind == kind).length;
        notifier.add(
          Category(
            id: 'c-${DateTime.now().microsecondsSinceEpoch}',
            ledgerId: kLedgerId,
            kind: kind,
            name: name,
            icon: _icon,
            sort: nextSort,
            rollover: _rollover,
          ),
        );
      }
      Navigator.of(context).pop();
    } catch (_) {
      setState(() => _error = '儲存失敗，請重試');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      // 內容含 160px 圖示格＋鍵盤彈起時可用高度不夠會 overflow（MAJOR-A）：包一層可捲動。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null ? '新增分類' : '編輯分類',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('category-name-field'),
              controller: _nameController,
              decoration: const InputDecoration(labelText: '名稱'),
              autofocus: true,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: GridView.count(
                crossAxisCount: 6,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  for (final name in categoryIconNames)
                    InkWell(
                      onTap: () => setState(() => _icon = name),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _icon == name
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(categoryIcon(name)),
                      ),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('累計 rollover'),
              value: _rollover,
              onChanged: (v) => setState(() => _rollover = v),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('save-category-button'),
                onPressed: _save,
                child: const Text('儲存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
