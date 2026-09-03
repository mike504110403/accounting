import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/app/month_app_bar.dart';
import 'package:accounting/features/entries/entries_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// update 一律丟例外，用來驗失敗路徑。
class ThrowingSettlements extends SettlementsNotifier {
  @override
  void update(Settlement s) => throw Exception('boom');
}

/// 沒有任何 pending settlement。
class EmptySettlements extends SettlementsNotifier {
  @override
  List<Settlement> build() => [];
}

/// 沒有 pending 且 add 一律丟例外，用來驗發起結算的失敗路徑。
class ThrowingAddSettlements extends EmptySettlements {
  @override
  void add(Settlement s) => throw Exception('boom');
}

/// 三人帳本、還有兩個人要簽的 pending settlement（我只是其中一個簽核人）。
class TwoSignerSettlements extends SettlementsNotifier {
  @override
  List<Settlement> build() => [
        Settlement(
          id: 's-multi',
          ledgerId: kLedgerId,
          status: SettlementStatus.pending,
          initiatedBy: kWifeId,
          createdAt: DateTime.now(),
          nets: const {kMeId: -300, kWifeId: 500, 'm-kid': -200},
          entryIds: const ['e-6'],
          approvedBy: const {},
        ),
      ];
}

/// entries 的 update 一律丟例外，用來驗簽核第一步就失敗的路徑。
class ThrowingUpdateEntries extends EntriesNotifier {
  @override
  void update(Entry e) => throw Exception('boom');
}

/// 兩筆互相抵銷的代墊：淨額全為 0。
class BalancedEntries extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-a',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 1000,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: 'Mike 代墊',
          payerId: kMeId,
          splitMethod: SplitMethod.equal,
          splits: const [
            EntrySplit(entryId: 'e-a', memberId: kMeId, share: 500),
            EntrySplit(entryId: 'e-a', memberId: kWifeId, share: 500),
          ],
        ),
        Entry(
          id: 'e-b',
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
            EntrySplit(entryId: 'e-b', memberId: kMeId, share: 500),
            EntrySplit(entryId: 'e-b', memberId: kWifeId, share: 500),
          ],
        ),
      ];
}

/// 只有發起人淨額非零（分攤沒攤到別人）→ 沒有人需要簽。
class SoloNetEntries extends EntriesNotifier {
  @override
  List<Entry> build() => [
        Entry(
          id: 'e-solo',
          ledgerId: kLedgerId,
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 1000,
          categoryId: 'c-food',
          occurredOn: DateTime.now(),
          createdBy: kMeId,
          note: '只有我有淨額',
          payerId: kMeId,
          splitMethod: SplitMethod.amount,
          splits: const [EntrySplit(entryId: 'e-solo', memberId: kMeId, share: 500)],
        ),
      ];
}

/// 帳目頁的共用視角切換（避開統計頁同名元件）。
Finder viewMode(String label) => find.descendant(
      of: find.descendant(of: find.byType(EntriesPage), matching: find.byKey(const Key('view-mode-toggle'))),
      matching: find.text(label),
    );

Future<ProviderContainer> pumpApp(WidgetTester tester, [ProviderContainer? container]) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = container ?? ProviderContainer();
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AccountingApp()));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('根啟動＋切 Tab 回帳目：看得到列表與假資料', (tester) async {
    await pumpApp(tester);
    expect(find.text('菜市場'), findsOneWidget);

    await tester.tap(find.text('統計'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('帳目'));
    await tester.pumpAndSettle();

    // 往下捲到月初的資料
    await tester.dragUntilVisible(find.text('全聯買菜'), find.byType(ListView).first, const Offset(0, -120));
    expect(find.text('全聯買菜'), findsOneWidget);
    await tester.dragUntilVisible(find.text('房租'), find.byType(ListView).first, const Offset(0, -120));
    expect(find.text('房租'), findsOneWidget);
  });

  testWidgets('視角切換：家庭看不到私人、個人看得到自己的私人', (tester) async {
    await pumpApp(tester);
    expect(find.text('Steam'), findsNothing);

    await tester.tap(viewMode('個人'));
    await tester.pumpAndSettle();
    expect(find.text('Steam'), findsOneWidget);
  });

  testWidgets('個人視角：全聯買菜顯示我的份額 284', (tester) async {
    await pumpApp(tester);
    await tester.tap(viewMode('個人'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.text('全聯買菜'), find.byType(ListView).first, const Offset(0, -120));

    final row = find.ancestor(of: find.text('全聯買菜'), matching: find.byType(InkWell)).first;
    expect(find.descendant(of: row, matching: find.text('284')), findsOneWidget);
  });

  testWidgets('待簽核卡片：同意 → settlement settled、涵蓋 entries settled', (tester) async {
    final container = await pumpApp(tester);
    expect(find.textContaining('待你簽核'), findsOneWidget);
    expect(find.textContaining('應付 430'), findsOneWidget);

    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();

    final s = container.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.settled);
    expect(s.approvedBy, contains(kMeId));
    expect(s.settledAt, isNotNull);
    final entries = container.read(entriesProvider);
    for (final id in const ['e-6', 'e-7', 'e-9', 'e-10']) {
      expect(entries.firstWhere((e) => e.id == id).settledState, SettledState.settled);
    }
  });

  testWidgets('多簽：還有人沒簽時只累加 approvedBy，不落 settled', (tester) async {
    const kid = Member(id: 'm-kid', ledgerId: kLedgerId, userId: 'u3', displayName: '小孩');
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [
        membersProvider.overrideWithValue(const [
          Member(id: kMeId, ledgerId: kLedgerId, userId: 'u1', displayName: 'Mike'),
          Member(id: kWifeId, ledgerId: kLedgerId, userId: 'u2', displayName: '老婆'),
          kid,
        ]),
        settlementsProvider.overrideWith(TwoSignerSettlements.new),
      ]),
    );

    await tester.tap(find.text('同意'));
    await tester.pumpAndSettle();

    final s = c.read(settlementsProvider).single;
    expect(s.requiredSigners, {kMeId, 'm-kid'});
    expect(s.approvedBy, {kMeId});
    expect(s.status, SettlementStatus.pending, reason: '小孩還沒簽');
    expect(s.settledAt, isNull);
    expect(c.read(entriesProvider).firstWhere((e) => e.id == 'e-6').settledState, SettledState.settling);
    expect(find.textContaining('簽核 1/2'), findsOneWidget);
  });

  testWidgets('簽核第二步失敗：補償回原狀、無半套狀態並顯示 SnackBar', (tester) async {
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [settlementsProvider.overrideWith(ThrowingSettlements.new)]),
    );
    await tester.tap(find.text('同意'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('失敗'), findsOneWidget);

    final s = c.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.pending);
    expect(s.approvedBy, isEmpty);
    final entries = c.read(entriesProvider);
    for (final id in const ['e-6', 'e-7', 'e-9', 'e-10']) {
      expect(entries.firstWhere((e) => e.id == id).settledState, SettledState.settling);
    }
  });

  testWidgets('簽核第一步失敗：entries 與 settlement 都不動並顯示 SnackBar', (tester) async {
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [entriesProvider.overrideWith(ThrowingUpdateEntries.new)]),
    );
    final before = {for (final e in c.read(entriesProvider)) e.id: e.settledState};

    await tester.tap(find.text('同意'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('簽核失敗'), findsOneWidget);
    final s = c.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.pending);
    expect(s.approvedBy, isEmpty);
    expect(s.settledAt, isNull);
    for (final e in c.read(entriesProvider)) {
      expect(e.settledState, before[e.id], reason: e.id);
    }
  });

  testWidgets('沒有 pending 時顯示發起結算，發起後涵蓋 entries 轉 settling', (tester) async {
    final container = await pumpApp(tester, ProviderContainer(overrides: [settlementsProvider.overrideWith(EmptySettlements.new)]));
    expect(find.textContaining('代墊淨額 +284'), findsOneWidget);

    await tester.tap(find.text('發起'));
    await tester.pumpAndSettle();

    final s = container.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.pending);
    expect(s.initiatedBy, kMeId);
    expect(s.nets[kMeId], 284);
    expect(s.nets[kWifeId], -284);
    expect(s.entryIds, const ['e-5']);
    final entries = container.read(entriesProvider);
    for (final id in s.entryIds) {
      expect(entries.firstWhere((e) => e.id == id).settledState, SettledState.settling);
    }
  });

  testWidgets('發起結算失敗顯示 SnackBar', (tester) async {
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [settlementsProvider.overrideWith(ThrowingAddSettlements.new)]),
    );
    await tester.tap(find.text('發起'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('發起結算失敗'), findsOneWidget);
    // 第二步（add settlement）失敗 → entries 補償回 open，無半套狀態
    expect(c.read(settlementsProvider), isEmpty);
    expect(c.read(entriesProvider).firstWhere((e) => e.id == 'e-5').settledState, SettledState.open);
  });

  testWidgets('淨額全為零：顯示已平衡且沒有發起結算按鈕', (tester) async {
    await pumpApp(
      tester,
      ProviderContainer(overrides: [
        entriesProvider.overrideWith(BalancedEntries.new),
        settlementsProvider.overrideWith(EmptySettlements.new),
      ]),
    );
    expect(find.text('目前已平衡'), findsOneWidget);
    expect(find.text('發起'), findsNothing);
  });

  testWidgets('沒有人需要簽時發起即成立：settlement 與 entries 直接 settled', (tester) async {
    final c = await pumpApp(
      tester,
      ProviderContainer(overrides: [
        entriesProvider.overrideWith(SoloNetEntries.new),
        settlementsProvider.overrideWith(EmptySettlements.new),
      ]),
    );
    await tester.tap(find.text('發起'));
    await tester.pumpAndSettle();

    final s = c.read(settlementsProvider).single;
    expect(s.status, SettlementStatus.settled);
    expect(s.settledAt, isNotNull);
    expect(s.requiredSigners, isEmpty);
    expect(c.read(entriesProvider).single.settledState, SettledState.settled);
  });

  testWidgets('結算卡片維持單行小卡：高度 ≤ 72', (tester) async {
    await pumpApp(tester);
    expect(tester.getSize(find.byKey(const Key('settlement-card'))).height, lessThanOrEqualTo(72));

    // 沒有 pending 的「代墊淨額」卡同樣要小
    await pumpApp(tester, ProviderContainer(overrides: [settlementsProvider.overrideWith(EmptySettlements.new)]));
    expect(tester.getSize(find.byKey(const Key('settlement-card'))).height, lessThanOrEqualTo(72));
  });

  testWidgets('頂部列用共用 MonthAppBar：搜尋在左、齒輪在右、月份與視角切換都在裡面', (tester) async {
    await pumpApp(tester);
    final bar = find.descendant(of: find.byType(EntriesPage), matching: find.byType(MonthAppBar));
    expect(bar, findsOneWidget);
    for (final f in [
      find.byTooltip('搜尋'),
      find.byTooltip('設定'),
      find.byKey(const Key('month-title')),
      find.byKey(const Key('view-mode-toggle')),
    ]) {
      expect(find.descendant(of: bar, matching: f), findsOneWidget);
    }
    // 搜尋在左角、齒輪在右角
    expect(
      tester.getCenter(find.descendant(of: bar, matching: find.byTooltip('搜尋'))).dx,
      lessThan(tester.getCenter(find.descendant(of: bar, matching: find.byTooltip('設定'))).dx),
    );
    expect(viewMode('家庭'), findsOneWidget);
    expect(viewMode('個人'), findsOneWidget);
  });

  testWidgets('深色模式：帳目頁正常渲染', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester);
    expect(find.text('菜市場'), findsOneWidget);
    expect(find.textContaining('待你簽核'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('月份標題右滑：切到上個月', (tester) async {
    await pumpApp(tester);
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('全聯買菜'), findsNothing);
    expect(find.text('整月買菜'), findsOneWidget);
  });

  testWidgets('點月份標題開底部滾輪，選「本月」回到本月', (tester) async {
    await pumpApp(tester);
    await tester.fling(find.byKey(const Key('month-title')), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('整月買菜'), findsOneWidget);

    await tester.tap(find.byKey(const Key('month-title')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('month-picker-month')), findsOneWidget);
    await tester.tap(find.text('本月'));
    await tester.pumpAndSettle();
    expect(find.text('菜市場'), findsOneWidget);
  });
}
