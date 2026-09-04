import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LedgerNotifier.update 覆寫 ledger 狀態', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(ledgerProvider);
    await container.read(ledgerStateProvider.notifier).update(
          Ledger(id: before.id, name: '改名', inviteCode: before.inviteCode, defaultRatio: before.defaultRatio, openingBalanceShared: 1),
        );
    expect(container.read(ledgerProvider).name, '改名');
    expect(container.read(ledgerProvider).openingBalanceShared, 1);
  });

  test('MembersNotifier.update 只替換對應 id', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final me = container.read(membersProvider).firstWhere((m) => m.id == kMeId);
    await container.read(membersStateProvider.notifier).update(
          Member(id: me.id, ledgerId: me.ledgerId, userId: me.userId, displayName: me.displayName, openingBalancePersonal: 777),
        );
    final after = container.read(membersProvider);
    expect(after.firstWhere((m) => m.id == kMeId).openingBalancePersonal, 777);
    expect(after.firstWhere((m) => m.id == kWifeId).openingBalancePersonal, 30000); // 別人的值不變
  });

  test('CategoriesNotifier.add/update/remove', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(categoriesStateProvider.notifier);
    final before = container.read(categoriesProvider).length;

    await notifier.add(const Category(id: 'c-test', ledgerId: kLedgerId, kind: EntryKind.expense, name: '測試', icon: 'more_horiz', sort: 99));
    expect(container.read(categoriesProvider).length, before + 1);

    await notifier.update(const Category(id: 'c-test', ledgerId: kLedgerId, kind: EntryKind.expense, name: '測試改名', icon: 'inventory_2', sort: 99));
    final updated = container.read(categoriesProvider).firstWhere((c) => c.id == 'c-test');
    expect(updated.name, '測試改名');
    expect(updated.icon, 'inventory_2');

    await notifier.remove('c-test');
    expect(container.read(categoriesProvider).any((c) => c.id == 'c-test'), isFalse);
    expect(container.read(categoriesProvider).length, before);
  });

  test('CategoriesNotifier.reorder 只影響同 kind、依 sort 重排', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(categoriesStateProvider.notifier);

    // 支出分類原序：食品(0) 餐飲(1) 日常用品(2) 住房(3) 水電(4) 交通(5) 娛樂(6)
    // 把 index0（食品）移到 index2（onReorderItem 語意：newIndex 已是移除後的目標位置）。
    await notifier.reorder(EntryKind.expense, 0, 2);

    final expense = container.read(categoriesProvider).where((c) => c.kind == EntryKind.expense).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    expect(expense.map((c) => c.name).toList(), ['餐飲', '日常用品', '食品', '住房', '水電', '交通', '娛樂']);

    // 收入分類不受影響。
    final income = container.read(categoriesProvider).where((c) => c.kind == EntryKind.income).toList()..sort((a, b) => a.sort.compareTo(b.sort));
    expect(income.map((c) => c.name).toList(), ['薪水', '獎金']);
  });

  test('CategoriesNotifier.reorder 寫回前已依 kind、sort 統一排序（不靠消費端再 sort）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await container.read(categoriesStateProvider.notifier).reorder(EntryKind.expense, 0, 2);

    final raw = container.read(categoriesProvider);
    for (var i = 1; i < raw.length; i++) {
      final prev = raw[i - 1];
      final cur = raw[i];
      final kindOrdered = prev.kind.index < cur.kind.index || (prev.kind == cur.kind && prev.sort <= cur.sort);
      expect(kindOrdered, isTrue, reason: '${prev.kind}/${prev.sort} 應排在 ${cur.kind}/${cur.sort} 之前或同組遞增');
    }
  });

  test('AllocationsNotifier.add/remove', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(allocationsProvider.notifier);
    final before = container.read(allocationsProvider).length;

    await notifier.add(BudgetAllocation(
      id: 'al-test',
      ledgerId: kLedgerId,
      categoryId: 'c-food',
      amount: -500,
      occurredOn: DateTime(2026, 5, 20),
      createdBy: kMeId,
      note: '退回',
    ));
    expect(container.read(allocationsProvider).length, before + 1);
    final added = container.read(allocationsProvider).last;
    expect(added.amount, -500, reason: '撥款可負');
    expect(added.note, '退回');

    await notifier.remove('al-test');
    expect(container.read(allocationsProvider).any((a) => a.id == 'al-test'), isFalse);
    expect(container.read(allocationsProvider).length, before);

    // 不存在的 id：當沒事發生，不動 state
    await notifier.remove('does-not-exist');
    expect(container.read(allocationsProvider).length, before);
  });

  test('CategoriesNotifier.reorder 索引越界時不動 state', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(categoriesProvider);

    await container.read(categoriesStateProvider.notifier).reorder(EntryKind.expense, -1, 2);
    expect(container.read(categoriesProvider), before);

    await container.read(categoriesStateProvider.notifier).reorder(EntryKind.expense, 0, 999);
    expect(container.read(categoriesProvider), before);

    await container.read(categoriesStateProvider.notifier).reorder(EntryKind.income, 5, 0); // 收入只有 2 筆
    expect(container.read(categoriesProvider), before);
  });
}
