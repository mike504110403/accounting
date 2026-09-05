import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LedgerNotifier.update 覆寫 ledger 狀態（v1.5 只有名稱改得動）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final before = container.read(ledgerProvider);
    await container.read(ledgerStateProvider.notifier).update(
          Ledger(id: before.id, name: '改名', inviteCode: before.inviteCode),
        );
    expect(container.read(ledgerProvider).name, '改名');
    expect(container.read(ledgerProvider).inviteCode, before.inviteCode);
  });

  test('MembersNotifier.update 只替換對應 id', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final me = container.read(membersProvider).firstWhere((m) => m.id == kMeId);
    await container
        .read(membersStateProvider.notifier)
        .update(me.copyWith(displayName: '麥克'));
    final after = container.read(membersProvider);
    expect(after.firstWhere((m) => m.id == kMeId).displayName, '麥克');
    expect(after.firstWhere((m) => m.id == kWifeId).displayName, '老婆'); // 別人的值不變
  });

  group('TopupsNotifier（v1.5 個人補入）', () {
    // flutter_riverpod 3.4.2：同一個 tree 連續兩次 pumpWidget 會重用 container，
    // 所以每個案例各自 new 一個 ProviderContainer（這裡是 container 級測試）。
    ProviderContainer makeContainer() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    PersonalTopup draft({String memberId = kMeId, int amount = 3000, DateTime? on}) {
      final now = DateTime.now();
      return PersonalTopup(
        id: '',
        ledgerId: kLedgerId,
        memberId: memberId,
        amount: amount,
        occurredOn: on ?? DateTime(now.year, now.month, now.day),
        createdBy: memberId,
        note: '加班補入',
      );
    }

    test('build() 從快照取初值：種子的四筆補入都在', () {
      final c = makeContainer();
      expect(c.read(topupsProvider), hasLength(4));
    });

    test('add 成功後 state 立刻多一筆（不等 Realtime 事件），回傳帶 DB id', () async {
      final c = makeContainer();
      final before = c.read(topupsProvider).length;

      final saved = await c.read(topupsProvider.notifier).add(draft());

      expect(saved.id, isNotEmpty);
      expect(c.read(topupsProvider).length, before + 1);
      expect(c.read(topupsProvider).any((t) => t.id == saved.id), isTrue);
    });

    test('remove 成功後 state 立刻少一筆', () async {
      final c = makeContainer();
      final saved = await c.read(topupsProvider.notifier).add(draft());
      final before = c.read(topupsProvider).length;

      await c.read(topupsProvider.notifier).remove(saved.id);

      expect(c.read(topupsProvider).length, before - 1);
      expect(c.read(topupsProvider).any((t) => t.id == saved.id), isFalse);
    });

    test('add 失敗（補別人的）→ state 完全沒動', () async {
      final c = makeContainer();
      final before = c.read(topupsProvider);

      await expectLater(
        c.read(topupsProvider.notifier).add(draft(memberId: kWifeId)),
        throwsA(isA<LedgerException>()),
      );
      expect(c.read(topupsProvider), before, reason: '寫入失敗不做樂觀更新');
    });

    test('refresh 重抓整表（另一台裝置寫進來的補入會出現）', () async {
      final repo = InMemoryLedgerRepository();
      final c = ProviderContainer(
        overrides: [ledgerRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(c.dispose);
      final before = c.read(topupsProvider).length;

      await repo.addTopup(draft(amount: 777));
      expect(c.read(topupsProvider).length, before, reason: '還沒 refresh，本機不該自己知道');

      await c.read(topupsProvider.notifier).refresh();
      expect(c.read(topupsProvider).length, before + 1);
      expect(c.read(topupsProvider).any((t) => t.amount == 777), isTrue);
    });
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

  test('AllocationsNotifier.add（只有 add，設定後不可改不可刪）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(allocationsProvider.notifier);
    final before = container.read(allocationsProvider).length;

    // 假資料的本月預算已經佔掉 c-food／c-dining…，挑一個還沒設定的分類。
    await notifier.add(BudgetAllocation(
      id: 'al-test',
      ledgerId: kLedgerId,
      categoryId: 'c-fun',
      amount: 500,
      occurredOn: DateTime(DateTime.now().year, DateTime.now().month, 20),
      createdBy: kMeId,
      note: '本月娛樂',
    ));
    expect(container.read(allocationsProvider).length, before + 1);
    final added = container.read(allocationsProvider).last;
    expect(added.amount, 500);
    expect(added.note, '本月娛樂');
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
