import 'package:accounting/domain/models.dart';
import 'package:accounting/domain/month_summary.dart';
import 'package:flutter_test/flutter_test.dart';

/// 序列化的 round-trip 一律比 `toJson → fromJson → toJson` 的兩張 map：
/// 模型沒有 value equality（加 `==` 會動到 Riverpod 的重繪判斷，不在本任務範圍），
/// 比 map 一樣抓得到「toJson 有吐但 fromJson 沒吃」的漏欄。
void main() {
  Map<String, dynamic> roundTrip(
      Map<String, dynamic> json, Object Function(Map<String, dynamic>) parse) {
    final obj = parse(json);
    return (obj as dynamic).toJson() as Map<String, dynamic>;
  }

  group('round-trip', () {
    test('Ledger（v1.5：只剩 id／name／invite_code）', () {
      const x = Ledger(id: 'l-1', name: '我們的家', inviteCode: 'A7K3QZ');
      final j = x.toJson();
      expect(j.keys.toSet(), {'id', 'name', 'invite_code'});
      expect(roundTrip(j, Ledger.fromJson), j);
    });

    test('Ledger.fromJson：舊 build／尚未 drop 的 default_ratio 直接忽略', () {
      final l = Ledger.fromJson({
        'id': 'l-1',
        'name': '我們的家',
        'invite_code': 'A7K3QZ',
        'default_ratio': {'m-a': 50, 'm-b': 50},
        'opening_balance_shared': 120000,
      });
      expect(l.name, '我們的家');
      expect(l.toJson().containsKey('default_ratio'), isFalse);
      expect(l.toJson().containsKey('opening_balance_shared'), isFalse);
    });

    test('Member（v1.5：只剩 display_name／joined_at）', () {
      final x = Member(
        id: 'm-a',
        ledgerId: 'l-1',
        userId: 'u-1',
        displayName: 'Mike',
        joinedAt: DateTime(2026, 4, 1, 9),
      );
      final j = x.toJson();
      expect(j.keys.toSet(), {'id', 'ledger_id', 'user_id', 'display_name', 'joined_at'});
      expect(roundTrip(j, Member.fromJson), j);
    });

    test('Member.fromJson：帶著舊鍵 monthly_topup 的列仍解析得動（忽略）', () {
      final m = Member.fromJson({
        'id': 'm-a',
        'ledger_id': 'l-1',
        'user_id': 'u-1',
        'display_name': 'Mike',
        'monthly_topup': 10000,
        'opening_balance_personal': 500,
        'joined_at': '2026-04-01T09:00:00.000',
      });
      expect(m.displayName, 'Mike');
      expect(m.joinedAt, DateTime(2026, 4, 1, 9));
      expect(m.toJson().containsKey('monthly_topup'), isFalse);
    });

    test('Member.fromJson：缺 joined_at 時 fallback epoch', () {
      final m = Member.fromJson({
        'id': 'm-a',
        'ledger_id': 'l-1',
        'user_id': 'u-1',
        'display_name': 'Mike',
      });
      expect(m.joinedAt, DateTime(1970));
    });

    test('Member.copyWith 只換名字，其餘照抄', () {
      final m = Member(
        id: 'm-a',
        ledgerId: 'l-1',
        userId: 'u-1',
        displayName: 'Mike',
        joinedAt: DateTime(2026, 4, 1),
      );
      final renamed = m.copyWith(displayName: '麥克');
      expect(renamed.displayName, '麥克');
      expect(renamed.id, m.id);
      expect(renamed.userId, m.userId);
      expect(renamed.joinedAt, m.joinedAt);
    });

    test('Category', () {
      const x = Category(
          id: 'c-1', ledgerId: 'l-1', kind: EntryKind.expense, name: '食品', icon: 'restaurant', sort: 3);
      final j = x.toJson();
      expect(j['kind'], 'expense');
      expect(roundTrip(j, Category.fromJson), j);
    });

    test('LineItem（amount 可空）', () {
      const x = LineItem(id: 'li-1', entryId: 'e-1', name: '雞蛋', sort: 2);
      final j = x.toJson();
      expect(j['amount'], isNull);
      expect(roundTrip(j, LineItem.fromJson), j);
    });

    test('Entry（含巢狀 line_items，v1.5 沒有分攤子表）', () {
      final x = Entry(
        id: 'e-1',
        ledgerId: 'l-1',
        kind: EntryKind.expense,
        amount: 567,
        categoryId: 'c-food',
        occurredOn: DateTime(2026, 5, 8),
        createdBy: 'm-a',
        note: '全聯買菜',
        payerId: 'm-a',
        lineItems: const [
          LineItem(id: 'li-1', entryId: 'e-1', name: '雞蛋', amount: 89, sort: 0),
          LineItem(id: 'li-2', entryId: 'e-1', name: '牛奶', amount: 95, sort: 1),
        ],
      );
      final j = x.toJson();
      expect(j.keys.toSet(), {
        'id',
        'ledger_id',
        'kind',
        'amount',
        'category_id',
        'occurred_on',
        'created_by',
        'note',
        'payer_id',
        'is_adjustment',
        'line_items',
      });
      expect(roundTrip(j, Entry.fromJson), j);
      expect(Entry.fromJson(j).lineItems, hasLength(2));
    });

    test('Entry.fromJson：缺 payer_id、缺 line_items 的列照樣解析（共同錢包付的支出）', () {
      final e = Entry.fromJson({
        'id': 'e-1',
        'ledger_id': 'l-1',
        'kind': 'expense',
        'amount': 3000,
        'category_id': 'c-util',
        'occurred_on': '2026-05-03',
        'created_by': 'm-a',
      });
      expect(e.payerId, isNull);
      expect(e.fromCommonWallet, isTrue);
      expect(e.lineItems, isEmpty);
      expect(e.note, '');
      expect(e.isAdjustment, isFalse);
    });

    test('Entry.fromJson：DB 多回一個前端不認得的鍵時直接忽略（v1.5 drop 掉的欄位就是這個形狀）',
        () {
      final e = Entry.fromJson({
        'id': 'e-1',
        'ledger_id': 'l-1',
        'kind': 'expense',
        'scope': 'shared',
        'split_method': 'equal',
        'settled_state': 'settled',
        'amount': 100,
        'category_id': 'c-food',
        'occurred_on': '2026-05-08',
        'created_by': 'm-a',
      });
      expect(e.amount, 100);
      expect(e.toJson().containsKey('scope'), isFalse);
      expect(e.toJson().containsKey('split_method'), isFalse);
      expect(e.toJson().containsKey('settled_state'), isFalse);
    });

    test('Entry：沖銷筆金額為負', () {
      final e = Entry.fromJson({
        'id': 'e-2',
        'ledger_id': 'l-1',
        'kind': 'expense',
        'amount': -567,
        'category_id': 'c-food',
        'occurred_on': '2026-05-09',
        'created_by': 'm-a',
        'payer_id': 'm-a',
        'is_adjustment': true,
      });
      expect(e.amount, -567);
      expect(e.isAdjustment, isTrue);
    });

    test('PersonalTopup（v1.5 新表；month 只讀不送）', () {
      final x = PersonalTopup(
        id: 'pt-1',
        ledgerId: 'l-1',
        memberId: 'm-a',
        amount: 10000,
        occurredOn: DateTime(2026, 5, 1),
        createdBy: 'm-a',
        note: '本月補入',
      );
      final j = x.toJson();
      expect(j.keys.toSet(), {
        'id',
        'ledger_id',
        'member_id',
        'amount',
        'occurred_on',
        'note',
        'created_by',
      }, reason: 'month 是 generated 欄，送了會被 DB 拒絕');
      expect(roundTrip(j, PersonalTopup.fromJson), j);
    });

    test('PersonalTopup.fromJson：DB 回來的 month 照收；缺鍵時由 occurred_on 推出月初', () {
      final withMonth = PersonalTopup.fromJson({
        'id': 'pt-1',
        'ledger_id': 'l-1',
        'member_id': 'm-a',
        'amount': 10000,
        'occurred_on': '2026-05-18',
        'month': '2026-05-01',
        'created_by': 'm-a',
        'created_at': '2026-05-18T09:00:00.000',
      });
      expect(withMonth.month, DateTime(2026, 5, 1));
      expect(withMonth.createdAt, DateTime(2026, 5, 18, 9));

      final without = PersonalTopup.fromJson({
        'id': 'pt-2',
        'ledger_id': 'l-1',
        'member_id': 'm-a',
        'amount': 5000,
        'occurred_on': '2026-05-18',
        'created_by': 'm-a',
      });
      expect(without.month, DateTime(2026, 5, 1));
      expect(without.note, '');
    });

    test('PersonalTopup：bigint 回 num 時照樣是 int', () {
      final t = PersonalTopup.fromJson({
        'id': 'pt-1',
        'ledger_id': 'l-1',
        'member_id': 'm-a',
        'amount': 10000.0,
        'occurred_on': '2026-05-18',
        'created_by': 'm-a',
      });
      expect(t.amount, 10000);
      expect(t.amount, isA<int>());
    });

    test('BudgetAllocation', () {
      final x = BudgetAllocation(
        id: 'a-1',
        ledgerId: 'l-1',
        categoryId: 'c-food',
        amount: 6000,
        occurredOn: DateTime(2026, 5, 1),
        createdBy: 'm-a',
        note: '本月食品',
      );
      final j = x.toJson();
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
        doneAt: DateTime(2026, 5, 20, 10),
        entryId: 'e-9',
        sort: 3,
      );
      final j = x.toJson();
      expect(roundTrip(j, ListItem.fromJson), j);

      const todo = ListItem(id: 'l-2', ledgerId: 'led-1', title: '繳管理費');
      expect(todo.isTodo, isTrue);
      expect(roundTrip(todo.toJson(), ListItem.fromJson), todo.toJson());
    });
  });

  group('日期解析', () {
    test('date-only 字串解析後不帶時間分量', () {
      final e = Entry.fromJson({
        'id': 'e-1',
        'ledger_id': 'l-1',
        'kind': 'expense',
        'amount': 100,
        'category_id': 'c-food',
        'occurred_on': '2026-05-08',
        'created_by': 'm-a',
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
      // balance_math 的「計到 until 當日含」會把時間截成日曆日；
      // 留在 UTC 的話台北凌晨（＝UTC 前一天 16:00）的紀錄會提早一天生效。
      final c = MonthClose.fromJson({
        'id': 'mc-1',
        'ledger_id': 'l-1',
        'month': '2026-07-01',
        'closed_by': 'm-a',
        'closed_at': '2026-08-01T16:00:00+00:00',
        'details': const {'month': '2026-07-01', 'members': [], 'shared_paid': 0},
      });
      final expected = DateTime.utc(2026, 8, 1, 16).toLocal();
      // DateTime 的 == 也比 isUtc，留在 UTC 這條就會紅。
      expect(c.closedAt, expected);
      expect(c.closedAt.isUtc, isFalse);
    });

    test('timestamptz 保留時間分量', () {
      final t = PersonalTopup.fromJson({
        'id': 'pt-1',
        'ledger_id': 'l-1',
        'member_id': 'm-a',
        'amount': 100,
        'occurred_on': '2026-05-18',
        'created_by': 'm-a',
        'created_at': '2026-05-18T09:30:00.000',
      });
      expect(t.createdAt, DateTime(2026, 5, 18, 9, 30));
    });
  });

  group('Entry.toUpsertJson', () {
    Entry base({String id = 'e-1', String? payerId}) => Entry(
          id: id,
          ledgerId: 'l-1',
          kind: EntryKind.expense,
          amount: 300,
          categoryId: 'c-food',
          occurredOn: DateTime(2026, 5, 8),
          createdBy: 'm-a',
          note: '午餐',
          payerId: payerId,
          lineItems: const [LineItem(id: 'li-1', entryId: 'e-1', name: '飯', amount: 300)],
        );

    test('只吐 upsert_entry 可寫欄，不含 created_by／created_at／子表', () {
      final j = base(payerId: 'm-a').toUpsertJson();
      expect(j.keys.toSet(), {
        'id',
        'ledger_id',
        'kind',
        'amount',
        'category_id',
        'occurred_on',
        'note',
        'payer_id',
        'is_adjustment',
      });
      expect(j['occurred_on'], '2026-05-08');
      expect(j['payer_id'], 'm-a');
      expect(j.containsKey('created_by'), isFalse);
      expect(j.containsKey('line_items'), isFalse, reason: '細項走 p_line_items，不塞在 p_entry 裡');
    });

    test('v1.5 drop 掉的欄位一個都不出現', () {
      final j = base().toUpsertJson();
      for (final gone in ['scope', 'split_method', 'settled_state', 'entry_splits']) {
        expect(j.containsKey(gone), isFalse, reason: '$gone 在 v1.5 已 drop');
      }
      expect(j['payer_id'], isNull, reason: '共同錢包付＝payer_id 明確送 null');
    });

    test('id 為空（新筆）時不帶 id 欄，讓 DB 自己生', () {
      final j = base(id: '').toUpsertJson();
      expect(j.containsKey('id'), isFalse);
    });
  });

  group('月清帳（v1.5）', () {
    final details = MonthCloseDetails(
      month: _july,
      members: const [
        MonthCloseMemberLine(
            memberId: 'm-a', displayName: 'Mike', topup: 10000, paid: 6000, ending: 4000),
        MonthCloseMemberLine(
            memberId: 'm-b', displayName: '老婆', topup: 10000, paid: 2000, ending: 8000),
      ],
      sharedPaid: 3000,
    );

    test('MonthClose round-trip（details 落地不帶 income_amount）', () {
      final x = MonthClose(
        id: 'mc-1',
        ledgerId: 'l-1',
        month: _july,
        closedBy: 'm-a',
        closedAt: DateTime(2026, 8, 1, 10, 30),
        incomeEntryId: 'e-close-1',
        details: details,
      );
      final j = x.toJson();
      expect(j['month'], '2026-07-01');
      expect(j['income_entry_id'], 'e-close-1');
      expect((j['details']! as Map).containsKey('income_amount'), isFalse,
          reason: 'close_month 落地的 details 是事實快照，不帶預覽用的提示');
      expect(roundTrip(j, MonthClose.fromJson), j);

      final back = MonthClose.fromJson(j);
      expect(back.month, _july);
      expect(back.closedAt, DateTime(2026, 8, 1, 10, 30));
      expect(back.details.members.first.ending, 4000);
      expect(back.details.sharedPaid, 3000);
      expect(back.details.incomeAmount, isNull);
    });

    test('MonthClose.fromJson：沒勾「記共同收入」時 income_entry_id 是 null', () {
      final c = MonthClose.fromJson({
        'id': 'mc-1',
        'ledger_id': 'l-1',
        'month': '2026-07-01',
        'closed_by': 'm-a',
        'closed_at': '2026-08-01T10:30:00.000',
        'income_entry_id': null,
        'details': const {'month': '2026-07-01', 'members': [], 'shared_paid': 0},
      });
      expect(c.incomeEntryId, isNull);
    });

    test('MonthCloseDetails.fromJson：預覽帶 income_amount，落地的沒有；bigint 收成 int', () {
      final preview = MonthCloseDetails.fromJson({
        'month': '2026-07-01',
        'members': const [
          {
            'member_id': 'm-a',
            'display_name': 'Mike',
            'topup': 10000.0,
            'paid': 6000.0,
            'ending': 4000.0,
          },
        ],
        'shared_paid': 3000.0,
        'income_amount': 12000.0,
      });
      expect(preview.incomeAmount, 12000);
      expect(preview.members.single.topup, isA<int>());
      expect(preview.members.single.ending, 4000);
      expect(preview.sharedPaid, 3000);

      final landed = MonthCloseDetails.fromJson({
        'month': '2026-07-01',
        'members': const [],
        'shared_paid': 0,
      });
      expect(landed.incomeAmount, isNull);
      expect(landed.sharedPaid, 0);
    });
  });

  group('MonthSummary.fromJson（v1.5 契約）', () {
    Map<String, dynamic> payload() => {
          'shared_balance': 17000,
          'budget_total': 6000,
          'spent_total': 11000,
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
          'members': const [
            {
              'member_id': 'm-a',
              'display_name': 'Mike',
              'topup': 10000,
              'paid': 6000,
              'remaining': 4000,
            },
            {
              'member_id': 'm-b',
              'display_name': '老婆',
              'topup': 10000,
              'paid': 2000,
              'remaining': 8000,
            },
          ],
          'shared_paid': 3000,
        };

    test('四個合計＋categories＋members＋shared_paid 都吃得到', () {
      final s = MonthSummary.fromJson(payload());
      expect(s.sharedBalance, 17000);
      expect(s.budgetTotal, 6000);
      expect(s.spentTotal, 11000);
      expect(s.overspendTotal, 1500);
      expect(s.sharedPaid, 3000);
      expect(s.members.map((m) => m.memberId).toList(), ['m-a', 'm-b'],
          reason: 'DB 依 joined_at, id 排好，前端不重排');
      expect(s.memberLineOf('m-b').remaining, 8000);
      expect(s.envelopeOf('c-food').allocated, 5000);
      // 沒有那一列的分類全 0（該月既無預算也無支出）。
      expect(s.envelopeOf('c-util').allocated, 0);
      expect(s.envelopeOf('c-util').over, 0);
    });

    test('不在 members 裡的成員（還沒加入）→ 全 0', () {
      final s = MonthSummary.fromJson(payload());
      final none = s.memberLineOf('m-zzz');
      expect(none.topup, 0);
      expect(none.paid, 0);
      expect(none.remaining, 0);
    });

    test('缺 members 鍵 → 丟錯，不靜靜當成空清單（外部輸入不受信）', () {
      final json = payload()..remove('members');
      expect(() => MonthSummary.fromJson(json), throwsA(isA<TypeError>()),
          reason: '缺鍵當空清單的話，畫面會顯示「兩個人這個月都沒補入」這種假事實');
      // 缺 categories／shared_paid 同理（只有文件明寫可缺的鍵才准有預設值）。
      expect(() => MonthSummary.fromJson(payload()..remove('categories')),
          throwsA(isA<TypeError>()));
      expect(() => MonthSummary.fromJson(payload()..remove('shared_paid')),
          throwsA(isA<TypeError>()));
    });

    test('bigint 回 num 時照樣收成 int', () {
      final json = payload()
        ..['shared_balance'] = 17000.0
        ..['shared_paid'] = 3000.0;
      final s = MonthSummary.fromJson(json);
      expect(s.sharedBalance, 17000);
      expect(s.sharedBalance, isA<int>());
      expect(s.sharedPaid, 3000);
    });
  });
}

final _july = DateTime(2026, 7, 1);
