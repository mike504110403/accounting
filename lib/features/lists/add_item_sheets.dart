/// 新增購物項目／新增待辦的底部 sheet。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'checkout.dart';

Future<void> showAddShoppingItemSheet({required BuildContext context}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const AddShoppingItemSheet(),
  );
}

Future<void> showAddTodoItemSheet({required BuildContext context}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const AddTodoItemSheet(),
  );
}

/// 新增購物項目：名稱、店家（既有店家 Autocomplete）、預估金額、分類、負責人。
class AddShoppingItemSheet extends ConsumerStatefulWidget {
  const AddShoppingItemSheet({super.key});

  @override
  ConsumerState<AddShoppingItemSheet> createState() => _AddShoppingItemSheetState();
}

class _AddShoppingItemSheetState extends ConsumerState<AddShoppingItemSheet> {
  final _nameCtrl = TextEditingController();
  final _estCtrl = TextEditingController();
  String _store = '';
  String? _categoryId;
  String? _assigneeId;
  bool _submitting = false;
  bool _touched = false;

  @override
  void initState() {
    super.initState();
    final categories = ref.read(categoriesProvider).where((c) => c.kind == EntryKind.expense).toList();
    _categoryId = categories.isEmpty ? null : categories.first.id;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _estCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _touched = true);
    if (_nameCtrl.text.trim().isEmpty || _categoryId == null) return;
    setState(() => _submitting = true);
    try {
      final item = ListItem(
        id: newListId('l'),
        ledgerId: ref.read(ledgerProvider).id,
        title: _nameCtrl.text.trim(),
        store: _store.trim().isEmpty ? null : _store.trim(),
        estimated: int.tryParse(_estCtrl.text),
        categoryId: _categoryId,
        assigneeId: _assigneeId,
      );
      ref.read(listItemsProvider.notifier).add(item);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('新增失敗，請稍後再試')));
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).where((c) => c.kind == EntryKind.expense).toList();
    final members = ref.watch(membersProvider);
    final stores = <String>{
      for (final i in ref.watch(listItemsProvider))
        if (i.store != null && i.store!.isNotEmpty) i.store!,
    }.toList()
      ..sort();

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新增購物項目', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _fieldRow(
              '名稱',
              TextField(
                controller: _nameCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  errorText: _touched && _nameCtrl.text.trim().isEmpty ? '必填' : null,
                ),
              ),
            ),
            _fieldRow(
              '店家',
              Autocomplete<String>(
                optionsBuilder: (v) => v.text.isEmpty ? stores : stores.where((s) => s.contains(v.text)),
                onSelected: (s) => _store = s,
                fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: const InputDecoration(isDense: true),
                    onChanged: (v) => _store = v,
                  );
                },
              ),
            ),
            _fieldRow(
              '預估',
              TextField(controller: _estCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true)),
            ),
            _fieldRow(
              '分類',
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                isDense: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            ),
            _fieldRow(
              '負責人',
              DropdownButtonFormField<String?>(
                initialValue: _assigneeId,
                isDense: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('未指定')),
                  for (final m in members) DropdownMenuItem<String?>(value: m.id, child: Text(m.displayName)),
                ],
                onChanged: (v) => setState(() => _assigneeId = v),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _submitting ? null : _submit, child: const Text('新增')),
          ],
        ),
      ),
    );
  }
}

/// 新增待辦：標題、負責人、到期日。
class AddTodoItemSheet extends ConsumerStatefulWidget {
  const AddTodoItemSheet({super.key});

  @override
  ConsumerState<AddTodoItemSheet> createState() => _AddTodoItemSheetState();
}

class _AddTodoItemSheetState extends ConsumerState<AddTodoItemSheet> {
  final _titleCtrl = TextEditingController();
  String? _assigneeId;
  DateTime? _dueOn;
  bool _submitting = false;
  bool _touched = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueOn ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _dueOn = picked);
  }

  Future<void> _submit() async {
    setState(() => _touched = true);
    if (_titleCtrl.text.trim().isEmpty) return;
    setState(() => _submitting = true);
    try {
      final item = ListItem(
        id: newListId('l'),
        ledgerId: ref.read(ledgerProvider).id,
        title: _titleCtrl.text.trim(),
        assigneeId: _assigneeId,
        dueOn: _dueOn,
      );
      ref.read(listItemsProvider.notifier).add(item);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('新增失敗，請稍後再試')));
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新增待辦', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _fieldRow(
              '標題',
              TextField(
                controller: _titleCtrl,
                decoration: InputDecoration(isDense: true, errorText: _touched && _titleCtrl.text.trim().isEmpty ? '必填' : null),
              ),
            ),
            _fieldRow(
              '負責人',
              DropdownButtonFormField<String?>(
                initialValue: _assigneeId,
                isDense: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('未指定')),
                  for (final m in members) DropdownMenuItem<String?>(value: m.id, child: Text(m.displayName)),
                ],
                onChanged: (v) => setState(() => _assigneeId = v),
              ),
            ),
            _dateFieldRow('到期日', _dueOn == null ? '未設定' : fmtDate(_dueOn!), _pickDate, key: const Key('todo-due-row')),
            const SizedBox(height: 12),
            FilledButton(onPressed: _submitting ? null : _submit, child: const Text('新增')),
          ],
        ),
      ),
    );
  }
}

/// 資訊密度：欄位標籤在左、輸入在右，單行（跟 checkout_sheet.dart 同款式，各自私有避免跨檔耦合）。
Widget _fieldRow(String label, Widget input) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(child: input),
      ],
    ),
  );
}

/// 可點的欄位列（如到期日）：整列（含標籤）都能點開選擇器，且點擊高度至少 44px（點擊目標最小尺寸）。
Widget _dateFieldRow(String label, String value, VoidCallback onTap, {Key? key}) {
  return InkWell(
    key: key,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          SizedBox(width: 56, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    ),
  );
}
