/// Realtime：事件到達就重抓該表。
///
/// 用假的事件來源手動觸發——真的 websocket 進不了單元測試，但「收到事件之後做什麼」
/// 才是會寫錯的那一半（漏掉重抓＝老婆按了發起，我這邊永遠看不到待簽卡）。
library;

import 'package:accounting/data/current_ledger.dart';
import 'package:accounting/data/realtime.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';

void main() {
  late FakeRealtimeSource fake;
  late InMemoryLedgerRepository repo;
  late ProviderContainer container;

  setUp(() {
    fake = FakeRealtimeSource();
    repo = repoWith(settlements: const []);
    container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(repo),
      realtimeSourceProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);
    // 訂閱的生命週期掛在這個 provider 上（正式環境由 AccountingApp watch）。
    final sub = container.listen(ledgerRealtimeProvider, (_, _) {});
    addTearDown(sub.close);
  });

  test('訂閱用目前帳本 id', () {
    expect(fake.subscribedLedgerId, kLedgerId);
  });

  test('entries 事件 → 重抓帳目', () async {
    final before = container.read(entriesProvider).length;
    // 模擬「另一台裝置寫進 DB」：直接動 repository，不經過 notifier。
    await repo.upsertEntry(Entry(
      id: '',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: 999,
      categoryId: 'c-food',
      occurredOn: DateTime.now(),
      createdBy: kWifeId,
      note: '老婆那台新增的',
    ));
    expect(container.read(entriesProvider).length, before, reason: '事件還沒到，本機不該自己知道');

    fake.emit(LedgerTable.entries);
    await pumpEventQueue();

    expect(container.read(entriesProvider).length, before + 1);
    expect(container.read(entriesProvider).any((e) => e.note == '老婆那台新增的'), isTrue);
  });

  test('settlements 事件 → 連帳目一起重抓（settled_state 是 trigger 改的）', () async {
    expect(container.read(settlementsProvider), isEmpty);
    await repo.upsertEntry(Entry(
      id: 'e-remote',
      ledgerId: kLedgerId,
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: 1000,
      categoryId: 'c-food',
      occurredOn: DateTime.now(),
      createdBy: kWifeId,
      note: '老婆代墊',
      payerId: kWifeId,
      splitMethod: SplitMethod.equal,
      splits: const [
        EntrySplit(entryId: 'e-remote', memberId: kMeId, share: 500),
        EntrySplit(entryId: 'e-remote', memberId: kWifeId, share: 500),
      ],
    ));
    // 老婆那台發起結算。
    repo.currentMemberId = kWifeId;
    await repo.initiateSettlement(kLedgerId);
    repo.currentMemberId = kMeId;

    fake.emit(LedgerTable.settlements);
    await pumpEventQueue();

    expect(container.read(settlementsProvider).single.status, SettlementStatus.pending);
    expect(
      container.read(entriesProvider).firstWhere((e) => e.id == 'e-remote').settledState,
      SettledState.settling,
      reason: '只重抓 settlements 的話，對方那邊的金額不會變成鎖住',
    );
  });

  test('DELETE 事件（payload 沒有 ledger_id，靠不帶 filter 的訂閱收到）→ 重抓', () async {
    // 預設 replica identity 下，DELETE 的 payload 只有主鍵：帶 ledger_id filter 的訂閱
    // 收不到，所以 SupabaseRealtimeSource 另外掛了一個不帶 filter 的 DELETE 訂閱。
    // 這裡驗的是收到之後那一半：整表重抓，被刪的那筆要從 state 消失。
    final victim = container.read(entriesProvider).first;
    await repo.removeEntry(victim.id);
    expect(container.read(entriesProvider).any((e) => e.id == victim.id), isTrue,
        reason: '事件還沒到，本機不該自己知道');

    fake.emit(LedgerTable.entries);
    await pumpEventQueue();

    expect(container.read(entriesProvider).any((e) => e.id == victim.id), isFalse);
  });

  test('list_items 事件 → 重抓清單', () async {
    final before = container.read(listItemsProvider).length;
    await repo.addListItem(const ListItem(id: '', ledgerId: kLedgerId, title: '遠端加的牛奶', categoryId: 'c-food'));

    fake.emit(LedgerTable.listItems);
    await pumpEventQueue();

    expect(container.read(listItemsProvider).length, before + 1);
    expect(container.read(listItemsProvider).any((i) => i.title == '遠端加的牛奶'), isTrue);
  });

  test('budget_allocation 事件 → 重抓撥款', () async {
    final before = container.read(allocationsProvider).length;
    final now = DateTime.now();
    await repo.addAllocation(BudgetAllocation(
      id: '',
      ledgerId: kLedgerId,
      categoryId: 'c-food',
      amount: 1234,
      occurredOn: DateTime(now.year, now.month, 1),
      createdBy: kMeId,
      note: '遠端撥款',
    ));

    fake.emit(LedgerTable.budgetAllocation);
    await pumpEventQueue();

    expect(container.read(allocationsProvider).length, before + 1);
    expect(container.read(allocationsProvider).any((a) => a.note == '遠端撥款'), isTrue);
  });

  test('重抓失敗不會變成 uncaught（背景刷新不該打斷使用者）', () async {
    final failing = FailingRepository(seed: repo.snapshot);
    final c = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(_FetchFailsRepository(failing)),
      realtimeSourceProvider.overrideWithValue(fake),
    ]);
    addTearDown(c.dispose);
    final sub = c.listen(ledgerRealtimeProvider, (_, _) {});
    addTearDown(sub.close);

    fake.emit(LedgerTable.entries);
    await pumpEventQueue();
    // 走到這裡就代表例外沒有逃出去；state 維持原樣。
    expect(c.read(entriesProvider), isNotEmpty);
  });

  test('登出（清掉帳本）→ 退訂', () async {
    await container.read(currentLedgerIdProvider.notifier).clear();
    await pumpEventQueue();
    expect(fake.unsubscribeCount, greaterThanOrEqualTo(1));
  });
}

/// `fetchEntries` 一律失敗的 repository。
class _FetchFailsRepository extends InMemoryLedgerRepository {
  _FetchFailsRepository(InMemoryLedgerRepository inner) : super(seed: inner.snapshot);

  @override
  Future<List<Entry>> fetchEntries(String ledgerId) async =>
      throw const LedgerException('連線失敗，請檢查網路後再試');
}
