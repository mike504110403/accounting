/// `LedgerRepository` 的契約測試：**同一組測試跑兩個實作**。
///
/// - `InMemoryLedgerRepository`：永遠跑。
/// - `SupabaseLedgerRepository`：只有帶 `--dart-define=INTEGRATION=true` 才跑，
///   連地端棧、用 seed 帳號登入。
///
/// ```
/// flutter test --dart-define=INTEGRATION=true \
///   --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
///   --dart-define=SUPABASE_ANON_KEY=<地端 anon key> test/data
/// ```
///
/// 兩個實作跑同一組斷言，是「頁面只對著介面寫」這件事的唯一保證——
/// 記憶體版跟真 DB 行為分岔的地方，就是正式環境會炸而測試全綠的地方。
library;

import 'package:accounting/data/errors.dart' show requireId;
import 'package:accounting/data/in_memory_repository.dart';
import 'package:accounting/data/ledger_repository.dart';
import 'package:accounting/data/supabase_client.dart';
import 'package:accounting/data/supabase_repository.dart';
import 'package:accounting/domain/balance_math.dart';
import 'package:accounting/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 一本有兩個成員的帳本，以及兩位成員各自的 repository 視角。
abstract class ContractEnv {
  String get ledgerId;
  String get memberA;
  String get memberB;
  String get inviteCode;

  /// 成員 A 的視角（Supabase 版＝以 A 的 session 登入的 client）。
  LedgerRepository get asA;

  /// 成員 B 的視角。
  LedgerRepository get asB;

  /// 只有 Supabase 版能驗「非成員完全讀不到」（記憶體版沒有 RLS 概念）。
  bool get enforcesMembership => false;

  /// 建一本 [asA] 是成員、[asB] 不是成員的帳本，回傳其 id。
  Future<String> createLedgerOnlyA();

  Future<void> dispose() async {}
}

DateTime thisMonth() {
  final n = DateTime.now();
  return DateTime(n.year, n.month, 1);
}

/// 某個月的最後一天（清帳的「一鍵記共同收入」記在這一天）。
DateTime lastDayOf(DateTime month) => DateTime(month.year, month.month + 1, 0);

// ── 記憶體版 ──────────────────────────────────────────────────────────

class InMemoryEnv implements ContractEnv {
  InMemoryEnv(this._repo);

  static Future<InMemoryEnv> create() async {
    // 契約測試要從乾淨狀態起跑：清掉種子的帳目、補入、預算與清帳紀錄
    // （v1.5 的預算是「每分類每月一筆」，留著種子那幾筆會讓「第一次設定」直接撞 unique）。
    // 成員加入月一律壓成上個月：可清月的第一條是「最早有帳目、補入或成員加入的月份」，
    // 加入月更早的話每條清帳測試都要先清完中間那幾個月。
    final base = InMemoryLedgerRepository().snapshot;
    final joined = DateTime(thisMonth().year, thisMonth().month - 1, 1);
    return InMemoryEnv(
      InMemoryLedgerRepository(
        seed: base.copyWith(
          members: [for (final m in base.members) m.copyWith(joinedAt: joined)],
          entries: const [],
          topups: const [],
          allocations: const [],
          closes: const [],
        ),
      ),
    );
  }

  final InMemoryLedgerRepository _repo;

  @override
  String get ledgerId => _repo.snapshot.ledger.id;
  @override
  String get memberA => kMeId;
  @override
  String get memberB => kWifeId;
  @override
  String get inviteCode => _repo.snapshot.ledger.inviteCode;
  @override
  bool get enforcesMembership => false;

  // 同一份資料、換一個「目前登入者」——記憶體版的「換帳號」就是這樣。
  @override
  LedgerRepository get asA => _repo..currentMemberId = kMeId;
  @override
  LedgerRepository get asB => _repo..currentMemberId = kWifeId;

  @override
  Future<String> createLedgerOnlyA() async => throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

// ── Supabase 版 ───────────────────────────────────────────────────────

class SupabaseEnv implements ContractEnv {
  SupabaseEnv._(this._clientA, this._clientB, this.asA, this.asB, this.ledgerId, this.inviteCode,
      this.memberA, this.memberB);

  /// A＝`mike@test.local`、B＝`wife@test.local`（seed 帳號）。
  ///
  /// 兩人都在一本**當場建出來的**帳本裡工作，不動 seed 的「我們的家」——
  /// 那本要留給 Mike 手測，測試把它寫花了就沒得測了。
  /// 測試用 client：走 implicit flow。PKCE 需要 asyncStorage（`supabase_flutter` 才有），
  /// 在 `flutter test` 裡建純 `SupabaseClient` 時 `signUp` 會斷言失敗。
  static SupabaseClient testClient() => SupabaseClient(
        kSupabaseUrl,
        kSupabaseAnonKey,
        authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
      );

  /// 整合測試只准打地端棧。
  ///
  /// 這組測試會建帳本、寫帳目、清帳——指錯 URL 就是拿正式資料當測試場，
  /// 而且 seed 帳號的密碼是明文 `password`，雲端上不該有這種帳號可用。
  static void requireLocalStack() {
    final isLocal = kSupabaseUrl.contains('127.0.0.1') || kSupabaseUrl.contains('localhost');
    if (!isLocal) {
      fail('整合測試只能對地端棧跑，目前 SUPABASE_URL=$kSupabaseUrl。'
          '請帶 --dart-define=SUPABASE_URL=http://127.0.0.1:54321');
    }
  }

  static Future<SupabaseEnv> create() async {
    requireLocalStack();
    final clientA = testClient();
    final clientB = testClient();
    await clientA.auth.signInWithPassword(email: 'mike@test.local', password: 'password');
    await clientB.auth.signInWithPassword(email: 'wife@test.local', password: 'password');

    final repoA = SupabaseLedgerRepository(clientA);
    final repoB = SupabaseLedgerRepository(clientB);

    final ledger = await repoA.createLedger('contract-${DateTime.now().microsecondsSinceEpoch}');
    await repoB.joinLedger(ledger.inviteCode);

    final snapA = await repoA.loadSnapshot(ledger.id);
    final snapB = await repoB.loadSnapshot(ledger.id);

    return SupabaseEnv._(clientA, clientB, repoA, repoB, ledger.id, ledger.inviteCode,
        snapA.currentMemberId, snapB.currentMemberId);
  }

  final SupabaseClient _clientA;
  final SupabaseClient _clientB;

  @override
  final LedgerRepository asA;
  @override
  final LedgerRepository asB;
  @override
  final String ledgerId;
  @override
  final String inviteCode;
  @override
  final String memberA;
  @override
  final String memberB;
  @override
  bool get enforcesMembership => true;

  SupabaseClient get clientA => _clientA;

  @override
  Future<String> createLedgerOnlyA() async {
    final l = await asA.createLedger('solo-${DateTime.now().microsecondsSinceEpoch}');
    return l.id;
  }

  @override
  Future<void> dispose() async {
    await _clientA.auth.signOut();
    await _clientB.auth.signOut();
    await _clientA.dispose();
    await _clientB.dispose();
  }
}

// ── 契約 ─────────────────────────────────────────────────────────────

void contractTests(Future<ContractEnv> Function() makeEnv) {
  late ContractEnv env;
  late String expenseCategoryId;
  late String incomeCategoryId;
  final createdEntryIds = <String>[];

  setUp(() async {
    env = await makeEnv();
    final snap = await env.asA.loadSnapshot(env.ledgerId);
    expenseCategoryId = snap.categories.firstWhere((c) => c.kind == EntryKind.expense).id;
    incomeCategoryId = snap.categories.firstWhere((c) => c.kind == EntryKind.income).id;
    createdEntryIds.clear();
  });

  // 每條測試自己建的資料自己清（清帳後鎖住的除外，那是測試本身要驗的狀態）。
  tearDown(() async {
    for (final id in createdEntryIds) {
      try {
        await env.asA.removeEntry(id);
      } catch (_) {}
    }
    // 預算沒得清：budget_allocation 連 DELETE 授權都收回了（設定即定案）。
    // 每條測試各自 makeEnv() 一本新帳本，所以不需要清。
    await env.dispose();
  });

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// 上個月的某一天（帳目用）。
  DateTime lastMonthDay(int day) {
    final m = prevMonth(thisMonth());
    return DateTime(m.year, m.month, day);
  }

  Entry newExpense({
    required int amount,
    String note = '契約測試',
    String? payerId,
    List<LineItem> lineItems = const [],
    DateTime? occurredOn,
    bool isAdjustment = false,
  }) =>
      Entry(
        id: '',
        ledgerId: env.ledgerId,
        kind: EntryKind.expense,
        amount: amount,
        categoryId: expenseCategoryId,
        occurredOn: occurredOn ?? today(),
        createdBy: env.memberA,
        note: note,
        payerId: payerId,
        isAdjustment: isAdjustment,
        lineItems: lineItems,
      );

  PersonalTopup newTopup({
    required int amount,
    String? memberId,
    DateTime? occurredOn,
    String note = '本月補入',
  }) =>
      PersonalTopup(
        id: '',
        ledgerId: env.ledgerId,
        memberId: memberId ?? env.memberA,
        amount: amount,
        occurredOn: occurredOn ?? today(),
        note: note,
        createdBy: memberId ?? env.memberA,
      );

  Future<Entry> save(Entry e) async {
    final saved = await env.asA.upsertEntry(e);
    createdEntryIds.add(saved.id);
    return saved;
  }

  test('快照欄位齊全：帳本、成員、分類、補入、目前成員 id 都有值', () async {
    final snap = await env.asA.loadSnapshot(env.ledgerId);
    expect(snap.ledger.id, env.ledgerId);
    expect(snap.ledger.name, isNotEmpty);
    expect(snap.ledger.inviteCode.length, kInviteCodeLength);
    expect(snap.members.length, greaterThanOrEqualTo(2));
    expect(snap.categories, isNotEmpty);
    expect(snap.currentMemberId, isNotEmpty);
    expect(snap.currentMemberId, env.memberA);
    expect(snap.topups, isEmpty, reason: '乾淨帳本沒有補入');
    for (final e in snap.entries) {
      expect(e.ledgerId, env.ledgerId);
    }
  });

  test('新增帳目：id 由資料層產生，細項一起寫入', () async {
    final saved = await save(newExpense(
      amount: 1000,
      payerId: env.memberA,
      lineItems: const [
        LineItem(id: '', entryId: '', name: '雞蛋', amount: 600, sort: 0),
        LineItem(id: '', entryId: '', name: '牛奶', amount: 400, sort: 1),
      ],
    ));

    expect(saved.id, isNotEmpty);
    expect(saved.amount, 1000);
    expect(saved.payerId, env.memberA);
    expect(saved.lineItems.length, 2);
    expect(saved.lineItems.map((l) => l.name).toSet(), {'雞蛋', '牛奶'});

    final all = await env.asA.fetchEntries(env.ledgerId);
    expect(all.where((e) => e.id == saved.id), hasLength(1));
  });

  test('更新帳目：細項傳 null＝完全不動', () async {
    final saved = await save(newExpense(
      amount: 1000,
      payerId: env.memberA,
      lineItems: const [LineItem(id: '', entryId: '', name: '雞蛋', amount: 1000, sort: 0)],
    ));

    final updated = await env.asA.upsertEntry(
      saved.copyWith(note: '只改備註'),
      writeLineItems: false,
    );

    expect(updated.note, '只改備註');
    expect(updated.lineItems.length, 1, reason: 'null＝不動那張子表');
  });

  test('更新帳目：細項傳空清單＝清空', () async {
    final saved = await save(newExpense(
      amount: 800,
      lineItems: const [
        LineItem(id: '', entryId: '', name: '衛生紙', amount: 500, sort: 0),
        LineItem(id: '', entryId: '', name: '洗衣精', amount: 300, sort: 1),
      ],
    ));
    expect(saved.lineItems.length, 2);

    final cleared = await env.asA.upsertEntry(saved.copyWith(lineItems: const []));
    expect(cleared.lineItems, isEmpty);
  });

  test('更新帳目：細項有內容＝全刪重建（改金額與細項在同一次呼叫裡完成）', () async {
    final saved = await save(newExpense(
      amount: 1000,
      payerId: env.memberA,
      lineItems: const [LineItem(id: '', entryId: '', name: '舊細項', amount: 1000, sort: 0)],
    ));

    final updated = await env.asA.upsertEntry(saved.copyWith(
      amount: 1200,
      lineItems: const [
        LineItem(id: '', entryId: '', name: '新細項 A', amount: 700, sort: 0),
        LineItem(id: '', entryId: '', name: '新細項 B', amount: 500, sort: 1),
      ],
    ));

    expect(updated.amount, 1200);
    expect(
      ([...updated.lineItems]..sort((a, b) => a.sort.compareTo(b.sort))).map((l) => l.name).toList(),
      ['新細項 A', '新細項 B'],
    );
  });

  test('刪除帳目：之後查不到', () async {
    final saved = await save(newExpense(amount: 300));
    await env.asA.removeEntry(saved.id);
    createdEntryIds.remove(saved.id);

    final all = await env.asA.fetchEntries(env.ledgerId);
    expect(all.where((e) => e.id == saved.id), isEmpty);
  });

  test('v1.5：帳目只記「誰先付」——兩種付款形狀都存得進去，payload 只剩可寫欄', () async {
    final mine = await save(newExpense(amount: 500, note: '我先付', payerId: env.memberA));
    final wallet = await save(newExpense(amount: 700, note: '共同錢包'));

    expect(mine.payerId, env.memberA);
    expect(wallet.payerId, isNull);
    for (final e in [mine, wallet]) {
      expect(e.toUpsertJson().keys.toSet(), {
        'id',
        'ledger_id',
        'kind',
        'amount',
        'category_id',
        'occurred_on',
        'note',
        'payer_id',
        'is_adjustment',
      }, reason: 'v1.5 drop 掉的 scope／split_method／settled_state 不該再出現在寫入 payload 裡');
    }
  });

  test('v1.5：收入帶付款人 → 被擋（收入只有共同收入）', () async {
    final income = Entry(
      id: '',
      ledgerId: env.ledgerId,
      kind: EntryKind.income,
      amount: 20000,
      categoryId: incomeCategoryId,
      occurredOn: today(),
      createdBy: env.memberA,
      note: '薪水',
      payerId: env.memberA,
    );
    await expectLater(
      env.asA.upsertEntry(income),
      throwsA(isA<LedgerException>()
          .having((e) => e.message, 'message', contains('收入不需要付款人'))),
    );
  });

  test('沖銷筆：金額可負，付款人與日期照抄原筆', () async {
    final origin = await save(newExpense(amount: 900, payerId: env.memberA, note: '原筆'));
    final reversal = await save(newExpense(
      amount: -900,
      payerId: env.memberA,
      note: '沖銷',
      occurredOn: origin.occurredOn,
      isAdjustment: true,
    ));
    expect(reversal.amount, -900);
    expect(reversal.isAdjustment, isTrue);
  });

  test('設定本月預算：一分類一月一筆，第二筆被擋、金額必須 > 0', () async {
    final now = DateTime.now();
    final month = DateTime(now.year, now.month, 1);
    BudgetAllocation draft(int amount) => BudgetAllocation(
          id: '',
          ledgerId: env.ledgerId,
          categoryId: expenseCategoryId,
          amount: amount,
          occurredOn: month,
          createdBy: env.memberA,
          note: '契約測試預算',
        );

    final saved = await env.asA.addAllocation(draft(5000));
    expect(saved.id, isNotEmpty);
    expect(saved.amount, 5000);
    expect(saved.createdBy, env.memberA, reason: '不能以別人的名義設定預算');

    final all = await env.asA.fetchAllocations(env.ledgerId);
    expect(all.where((a) => a.id == saved.id), hasLength(1));

    await expectLater(
      env.asA.addAllocation(draft(1000)),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('本月已設定'))),
    );

    await expectLater(
      env.asA.addAllocation(BudgetAllocation(
        id: '',
        ledgerId: env.ledgerId,
        categoryId: expenseCategoryId,
        amount: -1000,
        occurredOn: DateTime(now.year, now.month + 1, 1),
        createdBy: env.memberA,
      )),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('必須大於 0'))),
    );
  });

  test('改帳本設定：只送 name（v1.5 沒有分攤比例與期初餘額）', () async {
    final before = await env.asA.fetchLedger(env.ledgerId);
    await env.asA.updateLedger(
      Ledger(id: before.id, name: '改過的帳本名', inviteCode: before.inviteCode),
    );

    final after = await env.asA.fetchLedger(env.ledgerId);
    expect(after.name, '改過的帳本名');
    expect(after.inviteCode, before.inviteCode,
        reason: 'invite_code 不可直接寫，輪替只走 rotate_invite_code');
  });

  test('改自己那列成員：只送 display_name（v1.5）', () async {
    final members = await env.asA.fetchMembers(env.ledgerId);
    final me = members.firstWhere((m) => m.id == env.memberA);

    await env.asA.updateMember(me.copyWith(displayName: '改過的暱稱'));

    final after = (await env.asA.fetchMembers(env.ledgerId)).firstWhere((m) => m.id == env.memberA);
    expect(after.displayName, '改過的暱稱');
    expect(after.ledgerId, me.ledgerId, reason: 'ledger_id 不可變');
    expect(after.userId, me.userId, reason: 'user_id 不可變');
    expect(after.joinedAt, me.joinedAt, reason: 'joined_at 不可變');
  });

  // ── 個人補入（v1.5 新表 personal_topups）────────────────────────────

  test('補入：新增本人那列 → 讀得到；刪除本人那列 → 讀不到', () async {
    final saved = await env.asA.addTopup(newTopup(amount: 10000));
    expect(saved.id, isNotEmpty);
    expect(saved.memberId, env.memberA);
    expect(saved.amount, 10000);
    expect(saved.month, monthOf(saved.occurredOn), reason: 'month 是 DB 產生的月初');

    final rows = await env.asA.fetchTopups(env.ledgerId);
    expect(rows.where((t) => t.id == saved.id), hasLength(1));

    await env.asA.removeTopup(saved.id);
    expect(await env.asA.fetchTopups(env.ledgerId), isEmpty);
  });

  test('補入：只能補自己的（他人 member_id 被擋）', () async {
    await expectLater(
      env.asA.addTopup(newTopup(amount: 10000, memberId: env.memberB)),
      throwsA(isA<LedgerException>()),
    );
    expect(await env.asA.fetchTopups(env.ledgerId), isEmpty);
  });

  test('補入：刪別人的那列 → 丟例外，列還在', () async {
    // B 記一筆自己的補入，A 想刪掉它：Supabase 是 delete policy 過濾成 0 列，
    // 記憶體版是 42501——訊息不同（一個是「無法刪除」一個是「沒有權限」），
    // 但**兩邊都必須丟例外而且那一列還在**，這才是頁面能依賴的契約。
    final hers = await env.asB.addTopup(newTopup(amount: 5000, memberId: env.memberB));

    await expectLater(env.asA.removeTopup(hers.id), throwsA(isA<LedgerException>()));

    final rows = await env.asA.fetchTopups(env.ledgerId);
    expect(rows.where((t) => t.id == hers.id), hasLength(1), reason: '刪不掉就不能從資料裡消失');
  });

  test('補入：金額必須 > 0（0 與負數都擋，兩實作同一句）', () async {
    for (final bad in [0, -100]) {
      await expectLater(
        env.asA.addTopup(newTopup(amount: bad)),
        throwsA(isA<LedgerException>()
            .having((e) => e.message, 'message', '補入金額必須大於 0')),
        reason: '$bad 應該被擋下來',
      );
    }
    expect(await env.asA.fetchTopups(env.ledgerId), isEmpty);
  });

  test('補入：同一個月可以多筆，兩人的補入彼此都看得到', () async {
    await env.asA.addTopup(newTopup(amount: 6000, note: '第一筆'));
    await env.asA.addTopup(newTopup(amount: 4000, note: '第二筆'));
    await env.asB.addTopup(newTopup(amount: 10000, memberId: env.memberB));

    final rows = await env.asA.fetchTopups(env.ledgerId);
    expect(rows.where((t) => t.memberId == env.memberA), hasLength(2));
    expect(rows.where((t) => t.memberId == env.memberB), hasLength(1));
    expect(
      topupIn(topups: rows, memberId: env.memberA, month: thisMonth()),
      10000,
      reason: '同月多筆相加',
    );
  });

  // ── 月清帳（v1.5／ADR-0009）─────────────────────────────────────────

  /// 上個月的一組資料：A 補入 3,000 先付 1,000、B 補入 2,000 先付 500、共同錢包付 400。
  /// 月末＝A 2,000、B 1,500 → 應記的共同收入 3,500。
  Future<void> seedLastMonth() async {
    await env.asA.addTopup(newTopup(amount: 3000, occurredOn: lastMonthDay(1), note: '上月補入'));
    await env.asB.addTopup(
      newTopup(amount: 2000, memberId: env.memberB, occurredOn: lastMonthDay(1), note: '上月補入'),
    );
    await save(newExpense(
        amount: 1000, note: 'A 上月先付', payerId: env.memberA, occurredOn: lastMonthDay(10)));
    await save(newExpense(
        amount: 500, note: 'B 上月先付', payerId: env.memberB, occurredOn: lastMonthDay(12)));
    await save(newExpense(amount: 400, note: '上月共同錢包', occurredOn: lastMonthDay(14)));
  }

  test('清帳：當月清不了（月份還沒結束）', () async {
    await expectLater(
      env.asA.closeMonth(env.ledgerId, thisMonth()),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('尚未結束'))),
    );
    expect(await env.asA.fetchMonthCloses(env.ledgerId), isEmpty);
  });

  test('清帳：月份不是月初 → 內部錯誤（可清條件第一條，兩個實作同一句）', () async {
    await expectLater(
      env.asA.closeMonth(env.ledgerId, lastMonthDay(15)),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('格式錯誤'))),
    );
    expect(await env.asA.fetchMonthCloses(env.ledgerId), isEmpty);
  });

  test('清帳：跳月被擋——必須先清更早的那個月', () async {
    // 上上月放一筆補入 → 最早可清月變成上上月，直接清上月要被打回。
    final twoMonthsAgo = prevMonth(prevMonth(thisMonth()));
    await env.asA.addTopup(newTopup(amount: 1000, occurredOn: twoMonthsAgo, note: '上上月補入'));

    final expected = '請先清 ${twoMonthsAgo.year}／${twoMonthsAgo.month.toString().padLeft(2, '0')}';
    await expectLater(
      env.asA.closeMonth(env.ledgerId, prevMonth(thisMonth())),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', expected)),
    );
    expect(await env.asA.fetchMonthCloses(env.ledgerId), isEmpty);
  });

  test('清帳：預覽明細＝補入 − 先付，另列共同錢包對照；落地後同月不可再清、該月鎖住', () async {
    await seedLastMonth();
    final month = prevMonth(thisMonth());

    final preview = await env.asA.monthClosePreview(env.ledgerId, month);
    expect(preview.month, month);
    expect(preview.members.map((l) => l.memberId).toSet(), {env.memberA, env.memberB});
    final byId = {for (final l in preview.members) l.memberId: l};
    expect(byId[env.memberA]!.topup, 3000);
    expect(byId[env.memberA]!.paid, 1000);
    expect(byId[env.memberA]!.ending, 2000, reason: '月末＝補入 − 先付');
    expect(byId[env.memberB]!.topup, 2000);
    expect(byId[env.memberB]!.paid, 500);
    expect(byId[env.memberB]!.ending, 1500);
    expect(preview.sharedPaid, 400, reason: '共同錢包支出只是對照，不進任何人的月末');
    expect(preview.incomeAmount, 3500, reason: 'Σ應轉入 − Σ應補出');

    final closed = await env.asA.closeMonth(env.ledgerId, month);
    expect(closed.month, month);
    expect(closed.closedBy, env.memberA);
    expect(
      closed.details.members.map((l) => l.ending).toList(),
      preview.members.map((l) => l.ending).toList(),
      reason: '預覽與落地是同一段算式',
    );
    expect(closed.details.sharedPaid, 400);

    final rows = await env.asA.fetchMonthCloses(env.ledgerId);
    expect(rows, hasLength(1));
    expect(rows.single.month, month);

    // 同月只能清一次。
    await expectLater(
      env.asA.closeMonth(env.ledgerId, month),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('已清帳'))),
    );

    // 該月（與更早月份）鎖住：帳目、細項、補入的寫入全擋。
    createdEntryIds.clear(); // 該月已鎖，清不掉
    await expectLater(
      env.asA.upsertEntry(newExpense(amount: 300, note: '補記到已清月', occurredOn: lastMonthDay(5))),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('該月已清帳'))),
    );
    await expectLater(
      env.asA.addTopup(newTopup(amount: 500, occurredOn: lastMonthDay(5))),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('該月已清帳'))),
    );
    await expectLater(
      env.asA.addAllocation(BudgetAllocation(
        id: '',
        ledgerId: env.ledgerId,
        categoryId: expenseCategoryId,
        amount: 1000,
        occurredOn: month,
        createdBy: env.memberA,
      )),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('該月已清帳'))),
    );

    // 已清月的補入也刪不掉。
    final lastMonthTopup = (await env.asA.fetchTopups(env.ledgerId))
        .firstWhere((t) => sameMonth(t.occurredOn, month) && t.memberId == env.memberA);
    await expectLater(
      env.asA.removeTopup(lastMonthTopup.id),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', contains('該月已清帳'))),
    );
  });

  test('清帳：一鍵記共同收入——該月最後一天、分類「清帳轉入」，income_entry_id 指向它', () async {
    await seedLastMonth();
    final month = prevMonth(thisMonth());

    final closed = await env.asA.closeMonth(env.ledgerId, month);
    expect(closed.incomeEntryId, isNotNull, reason: '預設就記');

    final entries = await env.asA.fetchEntries(env.ledgerId);
    final income = entries.firstWhere((e) => e.id == closed.incomeEntryId);
    expect(income.kind, EntryKind.income);
    expect(income.amount, 3500);
    expect(income.payerId, isNull, reason: '收入沒有付款人');
    expect(income.occurredOn, lastDayOf(month));

    final categories = await env.asA.fetchCategories(env.ledgerId);
    final category = categories.firstWhere((c) => c.id == income.categoryId);
    expect(category.name, '清帳轉入');
    expect(category.kind, EntryKind.income, reason: '帳本沒有這個分類時自動建');

    createdEntryIds.clear(); // 該月已鎖
  });

  test('清帳：recordIncome=false → 不記那筆收入', () async {
    await seedLastMonth();
    final month = prevMonth(thisMonth());

    final before = await env.asA.fetchEntries(env.ledgerId);
    final closed = await env.asA.closeMonth(env.ledgerId, month, recordIncome: false);
    expect(closed.incomeEntryId, isNull);

    final after = await env.asA.fetchEntries(env.ledgerId);
    expect(after.length, before.length, reason: '沒有多出任何帳目');

    createdEntryIds.clear(); // 該月已鎖
  });

  test('清帳：應轉入合計 ≤ 0 時不記收入（先付超過補入）', () async {
    await env.asA.addTopup(newTopup(amount: 1000, occurredOn: lastMonthDay(1)));
    await save(newExpense(
        amount: 4000, note: 'A 先付超過補入', payerId: env.memberA, occurredOn: lastMonthDay(10)));
    final month = prevMonth(thisMonth());

    final preview = await env.asA.monthClosePreview(env.ledgerId, month);
    expect(preview.incomeAmount, lessThanOrEqualTo(0));

    final closed = await env.asA.closeMonth(env.ledgerId, month);
    expect(closed.incomeEntryId, isNull, reason: '≤ 0 不記');

    createdEntryIds.clear(); // 該月已鎖
  });

  test('邀請碼：正確的碼查得到帳本，錯的碼丟可讀錯誤', () async {
    final joined = await env.asB.joinLedger(env.inviteCode);
    expect(joined.id, env.ledgerId, reason: '已是成員 → 直接回該帳本，不重複插');

    await expectLater(
      env.asB.joinLedger('ZZZZZZZZZZ'),
      throwsA(isA<LedgerException>().having((e) => e.message, 'message', '邀請碼不正確')),
    );
  });

  test('非成員讀不到別人的帳本', () async {
    if (!env.enforcesMembership) {
      markTestSkipped('記憶體實作沒有 RLS，這條只在 Supabase 契約下有意義');
      return;
    }
    final soloLedgerId = await env.createLedgerOnlyA();
    await expectLater(env.asB.loadSnapshot(soloLedgerId), throwsA(isA<LedgerException>()));
  });
}

/// 記憶體種子專屬：spec v1.5「驗收總表／三個數」那組已知資料集。
///
/// Supabase 版沒有這組種子（每條測試都是當場建的空帳本），所以只跑記憶體實作；
/// DB 那側的同一組數字由 `supabase/tests` 的 SQL 測試守。
void seedNumbersTests() {
  late InMemoryLedgerRepository repo;
  late DateTime monthEnd;

  setUp(() {
    repo = InMemoryLedgerRepository();
    monthEnd = lastDayOf(thisMonth());
  });

  test('三個數：共同餘額 17,000／本月支出 11,000／共同錢包 3,000／兩人補入剩餘 4,000 與 8,000',
      () async {
    final s = await repo.monthSummary(kLedgerId, monthEnd);
    expect(s.sharedBalance, 17000, reason: 'Σ共同收入 − Σ共同錢包支出');
    expect(s.spentTotal, 11000, reason: '本月全部支出（不分誰付）');
    expect(s.sharedPaid, 3000);

    final lines = {for (final m in s.members) m.memberId: m};
    expect(lines[kMeId]!.topup, 10000);
    expect(lines[kMeId]!.paid, 6000);
    expect(lines[kMeId]!.remaining, 4000);
    expect(lines[kWifeId]!.topup, 10000);
    expect(lines[kWifeId]!.paid, 2000);
    expect(lines[kWifeId]!.remaining, 8000);
  });

  test('三個數：balance_math 純函式對同一組資料算出同樣的數', () async {
    final snap = repo.snapshot;
    final month = thisMonth();
    expect(sharedBalance(entries: snap.entries, until: monthEnd), 17000);
    expect(totalSpent(entries: snap.entries, until: monthEnd), 11000);
    expect(sharedPaidIn(entries: snap.entries, month: month), 3000);
    for (final e in [
      (kMeId, 10000, 6000, 4000),
      (kWifeId, 10000, 2000, 8000),
    ]) {
      expect(topupIn(topups: snap.topups, memberId: e.$1, month: month), e.$2);
      expect(paidIn(entries: snap.entries, memberId: e.$1, month: month), e.$3);
      expect(
        topupRemaining(
            topups: snap.topups, entries: snap.entries, memberId: e.$1, month: month),
        e.$4,
      );
    }
  });

  test('種子含一筆沖銷：Mike 先付 7,000 ＋ 沖銷 −1,000 ＝ 6,000（spentTotal 同樣淨算）', () async {
    final snap = repo.snapshot;
    final month = thisMonth();
    final mine = snap.entries
        .where((e) => e.isExpense && e.payerId == kMeId && sameMonth(e.occurredOn, month));
    expect(mine.where((e) => e.isAdjustment), hasLength(1), reason: '沖銷筆真的在種子裡');
    expect(mine.where((e) => e.amount > 0).fold<int>(0, (a, e) => a + e.amount), 7000);
    expect(mine.where((e) => e.amount < 0).fold<int>(0, (a, e) => a + e.amount), -1000);
    expect(paidIn(entries: snap.entries, memberId: kMeId, month: month), 6000);

    final s = await repo.monthSummary(kLedgerId, monthEnd);
    expect(s.spentTotal, 11000, reason: '3,000 共同錢包 ＋ 7,000 − 1,000 ＋ 2,000');
    expect(s.memberLineOf(kMeId).paid, 6000);
  });

  test('上月只有成員先付與補入：共同餘額是累計水位，本月底仍是 17,000', () async {
    final snap = repo.snapshot;
    final lastMonth = prevMonth(thisMonth());
    expect(
      snap.entries.where((e) => sameMonth(e.occurredOn, lastMonth) && e.payerId == null),
      isEmpty,
      reason: '上月不放共同收入與共同錢包支出，否則累計水位就不是 17,000',
    );
    expect(sharedPaidIn(entries: snap.entries, month: lastMonth), 0);
    expect(snap.topups.where((t) => sameMonth(t.occurredOn, lastMonth)), hasLength(2));
    expect(sharedBalance(entries: snap.entries, until: lastDayOf(lastMonth)), 0);
    expect(sharedBalance(entries: snap.entries, until: monthEnd), 17000);
  });

  test('clearSnapshot() 之後 monthSummary 不吐「成員還在、數字全 0」的半套', () async {
    // 登出／切帳本會清快照；members 若直接讀欄位而不是讀快照，畫面會閃出上一個帳號的人。
    repo.clearSnapshot();
    final s = await repo.monthSummary(kLedgerId, monthEnd);
    expect(s.members, isEmpty);
    expect(s.categories, isEmpty);
    expect(s.sharedBalance, 0);
    expect(s.spentTotal, 0);
    expect(s.sharedPaid, 0);
  });

  test('members 依 joined_at, id 排序，與 DB month_summary 同一個順序', () async {
    final s = await repo.monthSummary(kLedgerId, monthEnd);
    expect(s.members.map((m) => m.memberId).toList(), [kMeId, kWifeId]);
    expect(s.members.map((m) => m.displayName).toList(), ['Mike', '老婆']);
  });
}

/// Supabase 專屬：現場註冊一個誰都不是的帳號，驗 RLS 對「完全非成員」也關得起來。
void strangerTests() {
  test('全新註冊的帳號讀不到任何既有帳本', () async {
    final env = await SupabaseEnv.create();
    addTearDown(env.dispose);

    final stranger = SupabaseEnv.testClient();
    addTearDown(stranger.dispose);
    final email = 'stranger-${DateTime.now().microsecondsSinceEpoch}@test.local';
    await stranger.auth.signUp(email: email, password: 'password');
    expect(stranger.auth.currentUser, isNotNull, reason: '地端 autoconfirm 開著，註冊即登入');

    final strangerRepo = SupabaseLedgerRepository(stranger);
    expect(await strangerRepo.myLedgers(), isEmpty, reason: '非成員看到的是空集合，不是別人的帳本');
    await expectLater(strangerRepo.loadSnapshot(env.ledgerId), throwsA(isA<LedgerException>()));
  });
}

/// Supabase 專屬：直接對 RPC 送 payload，驗前端模型層看不到的那一段 DB 行為。
void supabaseOnlyTests() {
  test('v1.5：舊 build 送出已經 drop 的鍵時 DB 直接忽略（jsonb 多餘鍵不影響 upsert_entry）',
      () async {
    final env = await SupabaseEnv.create();
    addTearDown(env.dispose);
    final snap = await env.asA.loadSnapshot(env.ledgerId);
    final categoryId = snap.categories.firstWhere((c) => c.kind == EntryKind.expense).id;
    final now = DateTime.now();
    final occurredOn =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // `scope`／`split_method` 在 v1.5 的 migration 已 drop；兩人裝置逐台更新期間，
    // 舊版 build 還是可能送已經不存在的欄位——jsonb 的多餘鍵本來就不影響，這條把它釘住。
    final row = await env.clientA.rpc<dynamic>('upsert_entry', params: {
      'p_entry': {
        'ledger_id': env.ledgerId,
        'kind': 'expense',
        'scope': 'shared',
        'amount': 500,
        'category_id': categoryId,
        'occurred_on': occurredOn,
        'note': '舊 build 還在送已經不存在的欄位',
        'payer_id': env.memberA,
        'split_method': 'common',
      },
    });
    final id = requireId(row);
    final saved = (await env.asA.fetchEntries(env.ledgerId)).firstWhere((e) => e.id == id);
    expect(saved.amount, 500);
    expect(saved.toJson().containsKey('scope'), isFalse);
    await env.asA.removeEntry(id);
  });
}

void main() {
  group('InMemoryLedgerRepository', () => contractTests(InMemoryEnv.create));
  group('InMemoryLedgerRepository 種子（spec v1.5 驗收總表）', seedNumbersTests);

  if (kIntegration) {
    group('SupabaseLedgerRepository', () {
      // 進到任何一條測試之前先擋一次，別等到 setUp 才發現指到雲端。
      setUpAll(SupabaseEnv.requireLocalStack);
      contractTests(SupabaseEnv.create);
      strangerTests();
      supabaseOnlyTests();
    });
  } else {
    test('SupabaseLedgerRepository 契約測試', () {}, skip: '需要 --dart-define=INTEGRATION=true 與地端棧');
  }
}
