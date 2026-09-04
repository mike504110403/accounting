import 'package:accounting/domain/models.dart';
import 'package:accounting/domain/month_summary.dart';
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

    test('Member（v1.4：monthly_topup／joined_at）', () {
      final x = Member(
        id: 'm-a',
        ledgerId: 'l-1',
        userId: 'u-1',
        displayName: 'Mike',
        monthlyTopup: 10000,
        openingBalancePersonal: 50000,
        joinedAt: DateTime(2026, 3, 1, 9, 30),
      );
      final j = x.toJson();
      expect(j.containsKey('display_name'), isTrue);
      expect(j['monthly_topup'], 10000);
      expect(roundTrip(j, Member.fromJson), j);

      final back = Member.fromJson(j);
      expect(back.monthlyTopup, 10000);
      expect(back.joinedAt, DateTime(2026, 3, 1, 9, 30));
      expect(back.openingBalancePersonal, 50000, reason: 'v1.4 廢用但欄位仍解析');
    });

    test('Member.fromJson：缺 monthly_topup 預設 0、缺 joined_at fallback epoch', () {
      final back = Member.fromJson(const {
        'id': 'm-a',
        'ledger_id': 'l-1',
        'user_id': 'u-1',
        'display_name': 'Mike',
      });
      expect(back.monthlyTopup, 0);
      // `members.joined_at` 是 not null，缺鍵只會是舊 build／替身沒帶。
      // fallback 取 epoch（＝很久以前就加入、每個月都有補入額），不是 now()——
      // 少算補入額會讓餘額憑空變少，寧可多算。
      expect(back.joinedAt, DateTime(1970));
      expect(back.openingBalancePersonal, 0);
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
      // 欄位清單寫死：v1.4 drop 掉的資金來源欄若被誰加回來，這裡會立刻紅。
      expect(j.keys.toSet(), {
        'id',
        'ledger_id',
        'kind',
        'scope',
        'amount',
        'category_id',
        'occurred_on',
        'created_by',
        'note',
        'payer_id',
        'split_method',
        'settled_state',
        'is_adjustment',
        'line_items',
        'entry_splits',
      });
      expect(roundTrip(j, Entry.fromJson), j);

      final back = Entry.fromJson(j);
      expect(back.lineItems.single.name, '雞蛋');
      expect(back.splits.single.share, 283.5);
      expect(back.settledState, SettledState.settling);
      expect(back.isAdjustment, isTrue);
    });

    test('Entry.fromJson：DB 多回一個前端不認得的鍵時直接忽略（v1.4 drop 掉的欄位就是這個形狀）', () {
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
        'obsolete_column': 'budget',
      };
      final back = Entry.fromJson(j);
      expect(back.amount, 100);
      expect(back.note, '');
      expect(back.lineItems, isEmpty);
      expect(back.toJson().containsKey('obsolete_column'), isFalse);
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
    Entry base({String id = 'e-1', String? payerId}) => Entry(
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
      }, reason: '欄位清單寫死：v1.4 drop 掉的資金來源欄被加回來就會紅');
    });

    test('id 為空（新筆）時不帶 id 欄，讓 DB 自己生', () {
      expect(base(id: '').toUpsertJson().containsKey('id'), isFalse);
      expect(base().toUpsertJson()['id'], 'e-1');
    });

  });

  group('月清帳（v1.4）', () {
    final details = MonthCloseDetails(
      month: DateTime(2026, 7, 1),
      members: const [
        MonthCloseMemberLine(
          memberId: 'm-a',
          displayName: 'Mike',
          topup: 10000,
          net: -10200,
          ending: -200,
        ),
        MonthCloseMemberLine(
          memberId: 'm-b',
          displayName: '老婆',
          topup: 8000,
          net: -500,
          ending: 7500,
        ),
      ],
      sharedDelta: 1000,
    );

    test('MonthClose round-trip（details 落地不帶 warnings）', () {
      final x = MonthClose(
        id: 'mc-1',
        ledgerId: 'l-1',
        month: DateTime(2026, 7, 1),
        closedBy: 'm-a',
        closedAt: DateTime(2026, 8, 1, 10, 30),
        details: details,
      );
      final j = x.toJson();
      expect(j['month'], '2026-07-01');
      expect((j['details']! as Map).containsKey('warnings'), isFalse,
          reason: 'close_month 落地的 details 是事實快照，不帶提醒');
      expect(roundTrip(j, MonthClose.fromJson), j);

      final back = MonthClose.fromJson(j);
      expect(back.month, DateTime(2026, 7, 1));
      expect(back.closedAt, DateTime(2026, 8, 1, 10, 30));
      expect(back.details.members.first.ending, -200);
      expect(back.details.sharedDelta, 1000);
      expect(back.details.warnings, isEmpty);
    });

    test('MonthCloseDetails.fromJson：warnings 是 [{code, count}]，缺鍵時空清單', () {
      final withWarning = MonthCloseDetails.fromJson({
        'month': '2026-07-01',
        'members': const [],
        'shared_delta': 0,
        'warnings': const [
          {'code': 'unsplit_advances', 'count': 3},
        ],
      });
      expect(withWarning.warnings.single.code, 'unsplit_advances');
      expect(withWarning.warnings.single.count, 3);

      final none = MonthCloseDetails.fromJson({
        'month': '2026-07-01',
        'members': const [],
        'shared_delta': 0,
      });
      expect(none.warnings, isEmpty);
      expect(none.sharedDelta, 0);
    });
  });

  group('MonthSummary.fromJson（v1.4 新鍵）', () {
    Map<String, dynamic> payload({Map<String, dynamic>? me}) => {
          'shared_balance': 7500,
          'budget_total': 6000,
          'spent_total': 5500,
          'overspend_total': 1500,
          'categories': const [
            {
              'category_id': 'c-food',
              'allocated': 5000,
              'spent': 3000,
              'remaining': 2000,
              'over': 0,
            },
          ],
          'me': me,
        };

    test('四個合計＋categories＋me 都吃得到', () {
      final s = MonthSummary.fromJson(payload(me: const {
        'member_id': 'm-a',
        'personal_balance': 8700,
        'monthly_topup': 10000,
        'month_net': -1300,
      }));
      expect(s.sharedBalance, 7500);
      expect(s.budgetTotal, 6000);
      expect(s.spentTotal, 5500);
      expect(s.overspendTotal, 1500);
      expect(s.memberId, 'm-a');
      expect(s.personalBalance, 8700);
      expect(s.monthlyTopup, 10000);
      expect(s.monthNet, -1300);
      expect(s.envelopeOf('c-food').allocated, 5000);
      expect(s.envelopeOf('c-food').spent, 3000);
      // 沒有那一列的分類全 0（該月既無預算也無共同支出）。
      expect(s.envelopeOf('c-util').allocated, 0);
      expect(s.envelopeOf('c-util').over, 0);
    });

    test('me 為 null（非成員）時個人那組全部 null', () {
      final s = MonthSummary.fromJson(payload());
      expect(s.memberId, isNull);
      expect(s.personalBalance, isNull);
      expect(s.monthlyTopup, isNull);
      expect(s.monthNet, isNull);
      expect(s.sharedBalance, 7500);
    });
  });
}
