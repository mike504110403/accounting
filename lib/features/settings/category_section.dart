import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../app/circle_slide_action.dart';
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
      onReorderItem: (oldIndex, newIndex) => _reorder(context, ref, oldIndex, newIndex),
      children: [
        // 左滑顯示編輯／刪除（Mike 手測回饋 2026-09-03），列上只留拖曳把手。
        for (var i = 0; i < categories.length; i++)
          Slidable(
            key: ValueKey(categories[i].id),
            endActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.34,
              children: [
                // 圓形 icon、無文字（Mike 裁示 2026-09-03）。
                CircleSlideAction(
                  icon: Icons.edit_outlined,
                  background: Theme.of(context).colorScheme.secondaryContainer,
                  foreground: Theme.of(context).colorScheme.onSecondaryContainer,
                  tooltip: '編輯',
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
                CircleSlideAction(
                  icon: Icons.delete_outline,
                  background: Theme.of(context).colorScheme.errorContainer,
                  foreground: Theme.of(context).colorScheme.onErrorContainer,
                  tooltip: '刪除',
                  onPressed: () => _delete(context, ref, categories[i]),
                ),
              ],
            ),
            child: ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: Icon(categoryIcon(categories[i].icon), size: 20),
              title: Text(categories[i].name),
              trailing: ReorderableDragStartListener(
                index: i,
                child: const Icon(Icons.drag_handle),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _reorder(BuildContext context, WidgetRef ref, int oldIndex, int newIndex) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(categoriesStateProvider.notifier).reorder(kind, oldIndex, newIndex);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is LedgerException ? e.message : '排序儲存失敗，請重試')),
      );
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Category c) async {
    final messenger = ScaffoldMessenger.of(context);
    final inUse = ref.read(entriesProvider).any((e) => e.categoryId == c.id);
    if (inUse) {
      messenger.showSnackBar(const SnackBar(content: Text('此分類已有帳目使用，無法刪除')));
      return;
    }
    try {
      await ref.read(categoriesStateProvider.notifier).remove(c.id);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is LedgerException ? e.message : '刪除失敗，請重試')),
      );
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
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '請輸入名稱');
      return;
    }
    final kind = widget.existing?.kind ?? widget.kind;
    setState(() {
      _saving = true;
      _error = null;
    });
    // sheet 蓋在上面時 SnackBar 會被擋住看不到（MAJOR-2）：錯誤改 sheet 內一行；成功直接 pop（本來就不彈 SnackBar）。
    try {
      final notifier = ref.read(categoriesStateProvider.notifier);
      if (widget.existing != null) {
        final c = widget.existing!;
        await notifier.update(
          Category(
            id: c.id,
            ledgerId: c.ledgerId,
            kind: kind,
            name: name,
            icon: _icon,
            sort: c.sort,
          ),
        );
      } else {
        final all = ref.read(categoriesProvider);
        final nextSort = all.where((c) => c.kind == kind).length;
        await notifier.add(
          Category(
            // id 留空＝新筆，由 repository（Supabase 由 DB）產生。
            id: '',
            ledgerId: ref.read(ledgerProvider).id,
            kind: kind,
            name: name,
            icon: _icon,
            sort: nextSort,
          ),
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is LedgerException ? e.message : '儲存失敗，請重試';
      });
    }
  }

  /// 步驟精靈（Mike 裁示 2026-09-03）：一次只秀一個要填的內容——步驟 0 名稱、步驟 1 圖示。
  int _step = 0;

  void _next() {
    if (_step == 0) {
      if (_nameController.text.trim().isEmpty) {
        setState(() => _error = '請輸入名稱');
        return;
      }
      setState(() {
        _error = null;
        _step = 1;
      });
      return;
    }
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final last = _step == 1;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_step > 0)
                  IconButton(
                    key: const ValueKey('category-back-button'),
                    icon: const Icon(Icons.arrow_back),
                    onPressed: _saving ? null : () => setState(() => _step = 0),
                  )
                else
                  const SizedBox(width: 48),
                Expanded(
                  child: Text(
                    widget.existing == null ? '新增分類' : '編輯分類',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text('${_step + 1}/2',
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(_step == 0 ? '名稱' : '圖示', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 12),
            if (_step == 0)
              TextField(
                key: const ValueKey('category-name-field'),
                controller: _nameController,
                decoration: const InputDecoration(isDense: true),
                autofocus: true,
                onSubmitted: (_) => _next(),
              )
            else
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('save-category-button'),
                onPressed: _saving ? null : _next,
                child: Text(_saving ? '儲存中…' : (last ? '儲存' : '下一步')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
