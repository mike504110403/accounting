import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import '../../app/tutorial.dart';
import 'add_item_sheets.dart';
import 'checkout_sheet.dart';
import 'shopping_tab.dart';

/// 清單頁＝購物清單（待辦 tab 已拿掉——Mike 手測裁示 2026-09-03）；長按多選後一次結帳。
class ListsPage extends ConsumerStatefulWidget {
  const ListsPage({super.key});

  @override
  ConsumerState<ListsPage> createState() => _ListsPageState();
}

class _ListsPageState extends ConsumerState<ListsPage> {
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  void _enterSelecting(String id) => setState(() {
        _selecting = true;
        _selectedIds
          ..clear()
          ..add(id);
      });

  void _toggleSelected(String id) => setState(() {
        if (!_selectedIds.remove(id)) _selectedIds.add(id);
        if (_selectedIds.isEmpty) _selecting = false;
      });

  void _exitSelecting() => setState(() {
        _selecting = false;
        _selectedIds.clear();
      });

  Future<void> _checkoutOne(ListItem item) => showCheckoutSheet(context: context, items: [item]);

  Future<void> _checkoutSelected(List<ListItem> all) async {
    final items = all.where((i) => _selectedIds.contains(i.id)).toList();
    if (items.isEmpty) return;
    await showCheckoutSheet(context: context, items: items);
    if (mounted) _exitSelecting();
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(listItemsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '已選 ${_selectedIds.length} 項' : '清單'),
        leading: _selecting ? IconButton(icon: const Icon(Icons.close), onPressed: _exitSelecting) : null,
        actions: [
          if (_selecting)
            TextButton(
              onPressed: _selectedIds.isEmpty ? null : () => _checkoutSelected(items),
              child: const Text('完成'),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ShoppingTab(
            selecting: _selecting,
            selectedIds: _selectedIds,
            onLongPressItem: _enterSelecting,
            onToggleSelected: _toggleSelected,
            onCheckoutOne: _checkoutOne,
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: tutorialKey('lists-fab'),
        heroTag: 'fab-lists',
        tooltip: '新增購物項目', // 也是語意標籤（e2e 與無障礙都靠它）

        onPressed: () => showAddShoppingItemSheet(context: context),
        child: const Icon(Icons.add),
      ),
    );
  }
}
