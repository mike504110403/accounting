import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'add_item_sheets.dart';
import 'checkout_sheet.dart';
import 'shopping_tab.dart';
import 'todo_tab.dart';

/// 清單頁：購物清單／待辦兩個 Tab；購物清單支援長按多選後一次結帳。
class ListsPage extends ConsumerStatefulWidget {
  const ListsPage({super.key});

  @override
  ConsumerState<ListsPage> createState() => _ListsPageState();
}

class _ListsPageState extends ConsumerState<ListsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _selecting = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

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
        bottom: _selecting ? null : TabBar(controller: _tabController, tabs: const [Tab(text: '購物清單'), Tab(text: '待辦')]),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: TabBarView(
            controller: _tabController,
            physics: _selecting ? const NeverScrollableScrollPhysics() : null,
            children: [
              ShoppingTab(
                selecting: _selecting,
                selectedIds: _selectedIds,
                onLongPressItem: _enterSelecting,
                onToggleSelected: _toggleSelected,
                onCheckoutOne: _checkoutOne,
              ),
              const TodoTab(),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _tabController.index == 0
            ? showAddShoppingItemSheet(context: context)
            : showAddTodoItemSheet(context: context),
        child: const Icon(Icons.add),
      ),
    );
  }
}
