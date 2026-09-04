/// 新增購物項目的底部 sheet（待辦已整組拿掉——Mike 手測裁示 2026-09-03）。
library;

import 'package:flutter/cupertino.dart' show CupertinoPicker, CupertinoTheme, CupertinoThemeData;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/category_wheel.dart';
import '../../app/tutorial.dart';

import '../../domain/mock_data.dart';
import '../../domain/models.dart';

Future<void> showAddShoppingItemSheet({required BuildContext context}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // 開在 root navigator：新手導覽的「下一步」要能從 root maybePop 收掉它。
    useRootNavigator: true,
    builder: (_) => const AddShoppingItemSheet(),
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
  final _storeCtrl = TextEditingController();
  final _estCtrl = TextEditingController();
  String? _categoryId;
  String? _assigneeId;
  int _step = 0;
  bool _submitting = false;
  bool _touched = false;
  String? _error;

  static const _stepCount = 5;
  static const _stepTitles = ['名稱', '店家', '預估金額', '分類', '負責人'];

  @override
  void initState() {
    super.initState();
    final categories = ref.read(categoriesProvider).where((c) => c.kind == EntryKind.expense).toList();
    _categoryId = categories.isEmpty ? null : categories.first.id;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _storeCtrl.dispose();
    _estCtrl.dispose();
    super.dispose();
  }

  void _next() {
    if (_step == 0 && _nameCtrl.text.trim().isEmpty) {
      setState(() => _touched = true);
      return;
    }
    if (_step < _stepCount - 1) {
      setState(() => _step++);
    } else {
      _submit();
    }
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty || _categoryId == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final item = ListItem(
        id: '',
        ledgerId: ref.read(ledgerProvider).id,
        title: _nameCtrl.text.trim(),
        store: _storeCtrl.text.trim().isEmpty ? null : _storeCtrl.text.trim(),
        estimated: int.tryParse(_estCtrl.text),
        categoryId: _categoryId,
        assigneeId: _assigneeId,
      );
      await ref.read(listItemsProvider.notifier).add(item);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // sheet 蓋在最上層，SnackBar 會被擋住看不到：錯誤顯示在 sheet 內。
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e is LedgerException ? e.message : '新增失敗，請稍後再試';
        });
      }
    }
  }

  /// 步驟精靈（Mike 裁示 2026-09-03）：一次只秀一個要填的內容。
  Widget _stepBody(BuildContext context) {
    switch (_step) {
      case 0:
        return TextField(
          key: const Key('add-name-field'),
          controller: _nameCtrl,
          // 導覽進行中不搶焦點：手機鍵盤會蓋住教學卡，web 的 focus 通知也會踩雷。
          autofocus: ref.watch(tutorialProvider) == null,
          decoration: InputDecoration(
            isDense: true,
            errorText: _touched && _nameCtrl.text.trim().isEmpty ? '必填' : null,
          ),
          onSubmitted: (_) => _next(),
        );
      case 1:
        // 步驟精靈裡不用 Autocomplete：overlay 會蓋住下一步鈕；改既有店家 chips 點選帶入。
        final stores = <String>{
          for (final i in ref.watch(listItemsProvider))
            if (i.store != null && i.store!.isNotEmpty) i.store!,
        }.toList()
          ..sort();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('add-store-field'),
              controller: _storeCtrl,
              autofocus: true,
              decoration: const InputDecoration(isDense: true, hintText: '可留空'),
              onSubmitted: (_) => _next(),
            ),
            if (stores.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final st in stores.take(6))
                      ActionChip(label: Text(st), onPressed: () => setState(() => _storeCtrl.text = st)),
                  ],
                ),
              ),
          ],
        );
      case 2:
        return TextField(
          key: const Key('add-est-field'),
          controller: _estCtrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(isDense: true, hintText: '可留空'),
          onSubmitted: (_) => _next(),
        );
      case 3:
        final categories = ref.watch(categoriesProvider).where((c) => c.kind == EntryKind.expense).toList()
          ..sort((a, b) => a.sort.compareTo(b.sort));
        return CategoryWheel(
          key: const Key('add-category-wheel'),
          categories: categories,
          selectedId: _categoryId,
          onSelected: (id) => setState(() => _categoryId = id),
        );
      default:
        final members = ref.watch(membersProvider);
        final options = <(String?, String)>[(null, '未指定'), for (final m in members) (m.id, m.displayName)];
        final initial = options.indexWhere((o) => o.$1 == _assigneeId).clamp(0, options.length - 1);
        return SizedBox(
          height: 108,
          child: CupertinoTheme(
            data: CupertinoThemeData(brightness: Theme.of(context).brightness),
            child: CupertinoPicker(
              key: const Key('add-assignee-wheel'),
              itemExtent: 36,
              scrollController: FixedExtentScrollController(initialItem: initial),
              onSelectedItemChanged: (i) => _assigneeId = options[i].$1,
              children: [for (final o in options) Center(child: Text(o.$2))],
            ),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = _step == _stepCount - 1;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (_step > 0)
                IconButton(
                  key: const Key('add-back-button'),
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _submitting ? null : () => setState(() => _step--),
                )
              else
                const SizedBox(width: 48),
              Expanded(
                child: Text('新增購物項目', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
              ),
              SizedBox(
                width: 48,
                child: Text('${_step + 1}/$_stepCount',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(_stepTitles[_step], style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 12),
          _stepBody(context),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('add-next-button'),
            onPressed: _submitting ? null : _next,
            child: Text(_submitting ? '新增中…' : (last ? '新增' : '下一步')),
          ),
        ],
      ),
    );
  }
}
