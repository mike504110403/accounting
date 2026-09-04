import 'package:accounting/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 序列化的 round-trip 一律比 `toJson → fromJson → toJson` 的兩張 map：
/// 模型沒有 value equality（加 `==` 會動到 Riverpod 的重繪判斷，不在本任務範圍），
/// 比 map 一樣抓得到「toJson 有吐但 fromJson 沒吃」的漏欄。
void main() {
  Map<String, dynamic> roundTrip(Map<String, dynamic> json, Object Function(Map<String, dynamic>) parse) {
    final obj = parse(json);
    return (obj as dynamic).toJson() as Map<String, dynamic>;
  }

  group('round-trip', () {
    test('Ledger', () {
      const x = Ledger(
        id: 'l-1',
        name: '我們的家',
        inviteCode: 'A7K3QZ',
        defaultRatio: {'m-a': 50, 'm-b': 50},
        openingBalanceShared: 120000,
      );
      final j = x.toJson();
      expect(roundTrip(j, Ledger.fromJson), j);
      expect(Ledger.fromJson(j).defaultRatio, {'m-a': 50, 'm-b': 50});
    });

    test('Member', () {
      const x = Member(id: 'm-a', ledgerId: 'l-1', userId: 'u-1', displayName: 'Mike', openingBalancePersonal: 50000);
      final j = x.toJson();
      expect(j.containsKey('display_name'), isTrue);
      expect(roundTrip(j, Member.fromJson), j);
    });

    test('Category', () {
      const x = Category(id: 'c-food', ledgerId: 'l-1', kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 3);
      final j = x.toJson();
      expect(j['kind'], 'expense');
      expect(j.containsKey('rollover'), isFalse, reason: 'v1.3 拿掉 rollover');
      expect(roundTrip(j, Category.fromJson), j);
    });

    test('LineItem（amount 可空）', () {
      const x = LineItem(id: 'li-1', entryId: 'e-1', name: '雞蛋', amount: 89, sort: 2);
      expect(roundTrip(x.toJson(), LineItem.fromJson), x.toJson());
      const y = LineItem(id: 'li-2', entryId: 'e-1', name: '不知道多少');
      expect(roundTrip(y.toJson(), LineItem.fromJson), y.toJson());
      expect(LineItem.fromJson(y.toJson()).amount, isNull);
    });

    test('EntrySplit（numeric 兩位小數）', () {
      const x = EntrySplit(entryId: 'e-1', memberId: 'm-a', share: 283.5);
      expect(roundTrip(x.toJson(), EntrySplit.fromJson), x.toJson());
      // REST 回 numeric 有時是字串
      expect(EntrySplit.fromJson(const {'entry_id': 'e-1', 'member_id': 'm-a', 'share': '283.50'}).share, 283.5);
    });

    test('Entry（含巢狀 line_items／entry_splits）', () {
      final x = Entry(
        id: 'e-1',
        ledgerId: 'l-1',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 567,
        categoryId: 'c-food',
        occurredOn: DateTime(2026, 5, 8),
        createdBy: 'm-a',
        note: '全聯買菜',
        payerId: 'm-a',
        splitMethod: SplitMethod.equal,
        settledState: SettledState.settling,
        isAdjustment: true,
        lineItems: const [LineItem(id: 'li-1', entryId: 'e-1', name: '雞蛋', amount: 89)],
        splits: const [EntrySplit(entryId: 'e-1', memberId: 'm-a', share: 283.5)],
      );
      final j = x.toJson();
      expect(j['occurred_on'], '2026-05-08');
      expect(j['funding'], 'balance');
      expect(roundTrip(j, Entry.fromJson), j);

      final back = Entry.fromJson(j);
      expect(back.lineItems.single.name, '雞蛋');
      expect(back.splits.single.share, 283.5);
      expect(back.settledState, SettledState.settling);
      expect(back.isAdjustment, isTrue);
    });

    test('Entry：funding=budget 的共同錢包支出', () {
      final x = Entry(
        id: 'e-2',
        ledgerId: 'l-1',
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 6200,
        categoryId: 'c-food',
        occurredOn: DateTime(2026, 5, 10),
        createdBy: 'm-a',
        funding: Funding.budget,
      );
      final j = x.toJson();
      expect(j['funding'], 'budget');
      expect(j['payer_id'], isNull);
      expect(roundTrip(j, Entry.fromJson), j);
    });

    test('Entry.fromJson：沒有 funding 欄時當 balance（DB default）', () {
      final j = {
        'id': 'e-3',
        'ledger_id': 'l-1',
        'kind': 'expense',
        'scope': 'shared',
        'amount': 100,
        'category_id': 'c-food',
        'occurred_on': '2026-05-01',
        'created_by': 'm-a',
        'split_method': 'common',
        'settled_state': 'open',
      };
      expect(Entry.fromJson(j).funding, Funding.balance);
      expect(Entry.fromJson(j).note, '');
      expect(Entry.fromJson(j).lineItems, isEmpty);
    });

    test('Settlement（含巢狀 settlement_entries／settlement_approvals，void_ ↔ void）', () {
      final x = Settlement(
        id: 's-1',
        ledgerId: 'l-1',
        status: SettlementStatus.void_,
        initiatedBy: 'm-b',
        createdAt: DateTime(2026, 5, 18, 9, 30),
        settledAt: DateTime(2026, 5, 20, 10),
        nets: const {'m-a': 500, 'm-b': -500},
        entryIds: const ['e-1', 'e-2'],
        approvedBy: const {'m-a'},
      );
      final j = x.toJson();
      expect(j['status'], 'void', reason: 'Dart 的 void_ 對到 DB 字面值 void');
      expect(j['settlement_entries'], [
        {'entry_id': 'e-1'},
        {'entry_id': 'e-2'},
      ]);
      expect(j['settlement_approvals'], [
        {'member_id': 'm-a'},
      ]);
      expect(roundTrip(j, Settlement.fromJson), j);
      expect(Settlement.fromJson(j).status, SettlementStatus.void_);
    });

    test('Settlement：settled_at 為 null 也能來回', () {
      final x = Settlement(
        id: 's-2',
        ledgerId: 'l-1',
        status: SettlementStatus.pending,
        initiatedBy: 'm-b',
        createdAt: DateTime(2026, 5, 18, 9, 30),
        nets: const {'m-a': 0},
        entryIds: const [],
        approvedBy: const {},
      );
      final j = x.toJson();
      expect(j['settled_at'], isNull);
      expect(roundTrip(j, Settlement.fromJson), j);
    });

    test('BudgetAllocation（金額可負）', () {
      final x = BudgetAllocation(
        id: 'al-1',
        ledgerId: 'l-1',
        categoryId: 'c-food',
        amount: -1200,
        occurredOn: DateTime(2026, 5, 20),
        note: '退回',
        createdBy: 'm-a',
      );
      final j = x.toJson();
      expect(j['amount'], -1200);
      expect(j['occurred_on'], '2026-05-20');
      expect(roundTrip(j, BudgetAllocation.fromJson), j);
    });

    test('ListItem（購物項目與待辦）', () {
      final x = ListItem(
        id: 'l-1',
        ledgerId: 'led-1',
        title: '衛生紙',
        store: '藥局',
        estimated: 199,
        categoryId: 'c-daily',
        assigneeId: 'm-a',
        dueOn: DateTime(2026, 5, 30),
        doneAt: DateTime(2026, 5, 21, 8, 5),
        entryId: 'e-9',
        sort: 3,
      );
      final j = x.toJson();
      expect(j['due_on'], '2026-05-30');
      expect(roundTrip(j, ListItem.fromJson), j);

      const todo = ListItem(id: 'l-2', ledgerId: 'led-1', title: '繳管理費');
      expect(roundTrip(todo.toJson(), ListItem.fromJson), todo.toJson());
      expect(ListItem.fromJson(todo.toJson()).isTodo, isTrue);
    });
  });

  group('日期解析', () {
    test('date-only 字串解析後不帶時間分量', () {
      final e = Entry.fromJson({
        'id': 'e-1',
        'ledger_id': 'l-1',
        'kind': 'expense',
        'scope': 'shared',
        'amount': 100,
        'category_id': 'c-food',
        'occurred_on': '2026-05-08',
        'created_by': 'm-a',
        'split_method': 'common',
        'settled_state': 'open',
      });
      expect(e.occurredOn, DateTime(2026, 5, 8));
      expect(e.occurredOn.hour, 0);
      expect(e.occurredOn.minute, 0);
    });

    test('帶時間分量的 date 字串也截成 date-only', () {
      final i = ListItem.fromJson({
        'id': 'l-1',
        'ledger_id': 'led-1',
        'title': 'x',
        'due_on': '2026-05-30T00:00:00+08:00',
      });
      expect(i.dueOn, DateTime(2026, 5, 30));
    });

    test('帶 offset 的 timestamptz 換算成本地時間（不留在 UTC）', () {
      // balance_math 的「計到 until 當日含」會把 settledAt 截成日曆日；
      // 留在 UTC 的話台北凌晨（＝UTC 前一天 16:00）結算會提早一天生效。
      final s = Settlement.fromJson({
        'id': 's-1',
        'ledger_id': 'l-1',
        'status': 'settled',
        'initiated_by': 'm-b',
        'created_at': '2026-05-18T01:30:00+00:00',
        'settled_at': '2026-05-20T16:00:00+00:00',
        'nets': <String, dynamic>{},
      });
      final expected = DateTime.utc(2026, 5, 20, 16).toLocal();
      // DateTime 的 == 也比 isUtc，留在 UTC 這條就會紅。
      expect(s.settledAt, expected);
      expect(s.settledAt!.isUtc, isFalse);
      expect(s.createdAt.isUtc, isFalse);
      // 日曆日必須是本地的那一天（台北：2026-05-21；UTC：2026-05-20）
      expect(
        DateTime(s.settledAt!.year, s.settledAt!.month, s.settledAt!.day),
        DateTime(expected.year, expected.month, expected.day),
      );
    });

    test('timestamptz 保留時間分量', () {
      final s = Settlement.fromJson({
        'id': 's-1',
        'ledger_id': 'l-1',
        'status': 'settled',
        'initiated_by': 'm-b',
        'created_at': '2026-05-18T09:30:00.000',
        'settled_at': '2026-05-20T10:00:00.000',
        'nets': <String, dynamic>{},
      });
      expect(s.createdAt, DateTime(2026, 5, 18, 9, 30));
      expect(s.settledAt, DateTime(2026, 5, 20, 10));
    });
  });

  group('jsonb map', () {
    test('nets／default_ratio 的值是 num 時也能解析成 int', () {
      final s = Settlement.fromJson({
        'id': 's-1',
        'ledger_id': 'l-1',
        'status': 'pending',
        'initiated_by': 'm-b',
        'created_at': '2026-05-18T09:30:00.000',
        'nets': {'m-a': 500.0, 'm-b': -500.0},
      });
      expect(s.nets, {'m-a': 500, 'm-b': -500});
      expect(s.nets['m-a'], isA<int>());

      final l = Ledger.fromJson({
        'id': 'l-1',
        'name': 'x',
        'invite_code': 'A7K3QZ',
        'default_ratio': {'m-a': 50.0, 'm-b': 50.0},
        'opening_balance_shared': 100.0,
      });
      expect(l.defaultRatio, {'m-a': 50, 'm-b': 50});
      expect(l.openingBalanceShared, 100);
    });
  });

  group('Entry.toUpsertJson', () {
    Entry base({String id = 'e-1', Funding funding = Funding.balance, String? payerId}) => Entry(
          id: id,
          ledgerId: 'l-1',
          kind: EntryKind.expense,
          scope: EntryScope.shared,
          amount: 300,
          categoryId: 'c-food',
          occurredOn: DateTime(2026, 5, 8),
          createdBy: 'm-a',
          note: '午餐',
          payerId: payerId,
          settledState: SettledState.settling,
          funding: funding,
        );

    test('只吐 upsert_entry 可寫欄，不含 settled_state／created_by／created_at', () {
      final j = base().toUpsertJson();
      expect(j.containsKey('settled_state'), isFalse, reason: '欄位級授權會 permission denied');
      expect(j.containsKey('created_by'), isFalse);
      expect(j.containsKey('created_at'), isFalse);
      expect(j.containsKey('line_items'), isFalse);
      expect(j.containsKey('entry_splits'), isFalse);
      expect(j.keys.toSet(), {
        'id',
        'ledger_id',
        'kind',
        'scope',
        'amount',
        'category_id',
        'occurred_on',
        'note',
        'payer_id',
        'split_method',
        'is_adjustment',
        'funding',
      });
    });

    test('id 為空（新筆）時不帶 id 欄，讓 DB 自己生', () {
      expect(base(id: '').toUpsertJson().containsKey('id'), isFalse);
      expect(base().toUpsertJson()['id'], 'e-1');
    });

    test('funding 送 DB 字面值', () {
      expect(base(funding: Funding.budget).toUpsertJson()['funding'], 'budget');
      expect(base().toUpsertJson()['funding'], 'balance');
    });
  });

  group('funding 不變式', () {
    Entry build({
      EntryKind kind = EntryKind.expense,
      EntryScope scope = EntryScope.shared,
      String? payerId,
    }) =>
        Entry(
          id: 'e-1',
          ledgerId: 'l-1',
          kind: kind,
          scope: scope,
          amount: 300,
          categoryId: 'c-food',
          occurredOn: DateTime(2026, 5, 8),
          createdBy: 'm-a',
          payerId: payerId,
          funding: Funding.budget,
        );

    test('代墊（payer 非空）不得用預算', () {
      expect(() => build(payerId: 'm-a'), throwsArgumentError);
    });

    test('私人支出不得用預算', () {
      expect(() => build(scope: EntryScope.private, payerId: 'm-a'), throwsArgumentError);
    });

    test('收入不得用預算', () {
      expect(() => build(kind: EntryKind.income), throwsArgumentError);
    });

    test('共同錢包的共同支出可以用預算', () {
      expect(build().funding, Funding.budget);
    });

    test('copyWith 把合法的預算筆改成代墊也會被擋', () {
      final ok = build();
      expect(() => ok.copyWith(payerId: 'm-a'), throwsArgumentError);
    });

    test('fromJson 也吃同一條不變式', () {
      expect(
        () => Entry.fromJson({
          'id': 'e-1',
          'ledger_id': 'l-1',
          'kind': 'expense',
          'scope': 'shared',
          'amount': 100,
          'category_id': 'c-food',
          'occurred_on': '2026-05-08',
          'created_by': 'm-a',
          'payer_id': 'm-a',
          'split_method': 'equal',
          'settled_state': 'open',
          'funding': 'budget',
        }),
        throwsArgumentError,
      );
    });
  });
}
