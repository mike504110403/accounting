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

import 'package:accounting/data/in_memory_repository.dart';
import 'package:accounting/data/ledger_repository.dart';
import 'package:accounting/data/supabase_client.dart';
import 'package:accounting/data/supabase_repository.dart';
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

// ── 記憶體版 ──────────────────────────────────────────────────────────

class InMemoryEnv implements ContractEnv {
  InMemoryEnv(this._repo);

  static Future<InMemoryEnv> create() async {
    // 清掉波 1 那筆 pending settlement 與帳目：契約測試要從乾淨狀態起跑。
    final base = InMemoryLedgerRepository().snapshot;
    return InMemoryEnv(
      InMemoryLedgerRepository(seed: base.copyWith(entries: const [], settlements: const [])),
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
  /// 這組測試會建帳本、寫帳目、發起結算——指錯 URL 就是拿正式資料當測試場，
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
  final createdEntryIds = <String>[];
  final createdAllocationIds = <String>[];

  setUp(() async {
    env = await makeEnv();
    final snap = await env.asA.loadSnapshot(env.ledgerId);
    expenseCategoryId = snap.categories.firstWhere((c) => c.kind == EntryKind.expense).id;
    createdEntryIds.clear();
    createdAllocationIds.clear();
  });

  // 每條測試自己建的資料自己清（結算後鎖住的除外，那是測試本身要驗的狀態）。
  tearDown(() async {
    for (final id in createdEntryIds) {
      try {
        await env.asA.removeEntry(id);
      } catch (_) {}
    }
    for (final id in createdAllocationIds) {
      try {
        await env.asA.removeAllocation(id);
      } catch (_) {}
    }
    await env.dispose();
  });

  DateTime today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Entry newSharedExpense({
    required int amount,
    String note = '契約測試',
    String? payerId,
    SplitMethod splitMethod = SplitMethod.common,
    List<EntrySplit> splits = const [],
    List<LineItem> lineItems = const [],
    Funding funding = Funding.balance,
  }) =>
      Entry(
        id: '',
        ledgerId: env.ledgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: amount,
        categoryId: expenseCategoryId,
        occurredOn: today(),
        createdBy: env.memberA,
        note: note,
        payerId: payerId,
        splitMethod: splitMethod,
        funding: funding,
        splits: splits,
        lineItems: lineItems,
      );

  Future<Entry> save(Entry e) async {
    final saved = await env.asA.upsertEntry(e);
    createdEntryIds.add(saved.id);
    return saved;
  }

  test('快照欄位齊全：帳本、成員、分類、目前成員 id 都有值', () async {
    final snap = await env.asA.loadSnapshot(env.ledgerId);
    expect(snap.ledger.id, env.ledgerId);
    expect(snap.ledger.name, isNotEmpty);
    expect(snap.ledger.inviteCode.length, kInviteCodeLength);
    expect(snap.members.length, greaterThanOrEqualTo(2));
    expect(snap.categories, isNotEmpty);
    expect(snap.currentMemberId, isNotEmpty);
    expect(snap.currentMemberId, env.memberA);
    for (final e in snap.entries) {
      expect(e.ledgerId, env.ledgerId);
    }
  });

  test('新增帳目：id 由資料層產生，子表一起寫入', () async {
    final saved = await save(newSharedExpense(
      amount: 1000,
      payerId: env.memberA,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: '', memberId: env.memberA, share: 500),
        EntrySplit(entryId: '', memberId: env.memberB, share: 500),
      ],
      lineItems: const [
        LineItem(id: '', entryId: '', name: '雞蛋', amount: 600, sort: 0),
        LineItem(id: '', entryId: '', name: '牛奶', amount: 400, sort: 1),
      ],
    ));

    expect(saved.id, isNotEmpty);
    expect(saved.amount, 1000);
    expect(saved.settledState, SettledState.open);
    expect(saved.splits.length, 2);
    expect(saved.lineItems.length, 2);
    expect(saved.lineItems.map((l) => l.name).toSet(), {'雞蛋', '牛奶'});

    final all = await env.asA.fetchEntries(env.ledgerId);
    expect(all.where((e) => e.id == saved.id), hasLength(1));
  });

  test('更新帳目：子表傳 null＝完全不動', () async {
    final saved = await save(newSharedExpense(
      amount: 1000,
      payerId: env.memberA,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: '', memberId: env.memberA, share: 500),
        EntrySplit(entryId: '', memberId: env.memberB, share: 500),
      ],
      lineItems: const [LineItem(id: '', entryId: '', name: '雞蛋', amount: 1000, sort: 0)],
    ));

    final updated = await env.asA.upsertEntry(
      saved.copyWith(note: '只改備註'),
      writeSplits: false,
      writeLineItems: false,
    );

    expect(updated.note, '只改備註');
    expect(updated.splits.length, 2, reason: 'null＝不動那張子表');
    expect(updated.lineItems.length, 1);
  });

  test('更新帳目：子表傳空清單＝清空', () async {
    final saved = await save(newSharedExpense(
      amount: 800,
      lineItems: const [
        LineItem(id: '', entryId: '', name: '衛生紙', amount: 500, sort: 0),
        LineItem(id: '', entryId: '', name: '洗衣精', amount: 300, sort: 1),
      ],
    ));
    expect(saved.lineItems.length, 2);

    final cleared = await env.asA.upsertEntry(
      saved.copyWith(lineItems: const []),
      writeSplits: false,
    );
    expect(cleared.lineItems, isEmpty);
  });

  test('更新帳目：子表有內容＝全刪重建（改金額與分攤在同一次呼叫裡完成）', () async {
    final saved = await save(newSharedExpense(
      amount: 1000,
      payerId: env.memberA,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: '', memberId: env.memberA, share: 500),
        EntrySplit(entryId: '', memberId: env.memberB, share: 500),
      ],
    ));

    final updated = await env.asA.upsertEntry(
      saved.copyWith(
        amount: 1200,
        splits: [
          EntrySplit(entryId: saved.id, memberId: env.memberA, share: 600),
          EntrySplit(entryId: saved.id, memberId: env.memberB, share: 600),
        ],
      ),
      writeLineItems: false,
    );

    expect(updated.amount, 1200);
    expect(updated.splits.map((s) => s.share).toList()..sort(), [600.0, 600.0]);
  });

  test('刪除帳目：之後查不到', () async {
    final saved = await save(newSharedExpense(amount: 300));
    await env.asA.removeEntry(saved.id);
    createdEntryIds.remove(saved.id);

    final all = await env.asA.fetchEntries(env.ledgerId);
    expect(all.where((e) => e.id == saved.id), isEmpty);
  });

  test('代墊筆不可能帶 funding=budget：模型不變式在建構點就擋下來', () {
    expect(
      () => Entry(
        id: '',
        ledgerId: env.ledgerId,
        kind: EntryKind.expense,
        scope: EntryScope.shared,
        amount: 500,
        categoryId: expenseCategoryId,
        occurredOn: today(),
        createdBy: env.memberA,
        payerId: env.memberA, // 代墊
        splitMethod: SplitMethod.equal,
        funding: Funding.budget,
      ),
      throwsArgumentError,
    );
  });

  test('撥款：新增與刪除', () async {
    final now = DateTime.now();
    final saved = await env.asA.addAllocation(BudgetAllocation(
      id: '',
      ledgerId: env.ledgerId,
      categoryId: expenseCategoryId,
      amount: 5000,
      occurredOn: DateTime(now.year, now.month, 1),
      createdBy: env.memberA,
      note: '契約測試撥款',
    ));
    createdAllocationIds.add(saved.id);

    expect(saved.id, isNotEmpty);
    expect(saved.amount, 5000);
    expect(saved.createdBy, env.memberA, reason: '不能以別人的名義撥款');

    var all = await env.asA.fetchAllocations(env.ledgerId);
    expect(all.where((a) => a.id == saved.id), hasLength(1));

    await env.asA.removeAllocation(saved.id);
    createdAllocationIds.remove(saved.id);
    all = await env.asA.fetchAllocations(env.ledgerId);
    expect(all.where((a) => a.id == saved.id), isEmpty);
  });

  test('改帳本設定：只送有 UPDATE 授權的三欄', () async {
    final before = await env.asA.fetchLedger(env.ledgerId);
    final renamed = Ledger(
      id: before.id,
      name: '改過的帳本名',
      inviteCode: before.inviteCode,
      defaultRatio: {env.memberA: 70, env.memberB: 30},
      openingBalanceShared: 88000,
    );

    await env.asA.updateLedger(renamed);

    final after = await env.asA.fetchLedger(env.ledgerId);
    expect(after.name, '改過的帳本名');
    expect(after.defaultRatio, {env.memberA: 70, env.memberB: 30});
    expect(after.openingBalanceShared, 88000);
    expect(after.inviteCode, before.inviteCode, reason: 'invite_code 不可直接寫，輪替只走 rotate_invite_code');
  });

  test('改自己那列成員：只送 display_name／opening_balance_personal', () async {
    final members = await env.asA.fetchMembers(env.ledgerId);
    final me = members.firstWhere((m) => m.id == env.memberA);

    await env.asA.updateMember(Member(
      id: me.id,
      ledgerId: me.ledgerId,
      userId: me.userId,
      displayName: '改過的暱稱',
      openingBalancePersonal: 12345,
    ));

    final after = (await env.asA.fetchMembers(env.ledgerId)).firstWhere((m) => m.id == env.memberA);
    expect(after.displayName, '改過的暱稱');
    expect(after.openingBalancePersonal, 12345);
    expect(after.ledgerId, me.ledgerId, reason: 'ledger_id 不可變');
    expect(after.userId, me.userId, reason: 'user_id 不可變');
  });

  test('結算：發起 → 對方簽核 → settled，涵蓋帳目鎖住', () async {
    final entry = await save(newSharedExpense(
      amount: 1000,
      note: '結算契約',
      payerId: env.memberA,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: '', memberId: env.memberA, share: 500),
        EntrySplit(entryId: '', memberId: env.memberB, share: 500),
      ],
    ));

    final pending = await env.asA.initiateSettlement(env.ledgerId);
    expect(pending.status, SettlementStatus.pending);
    expect(pending.nets[env.memberA], 500);
    expect(pending.nets[env.memberB], -500);
    expect(pending.entryIds, contains(entry.id));
    expect(pending.requiredSigners, {env.memberB}, reason: '發起人自動視為已簽');

    var entries = await env.asA.fetchEntries(env.ledgerId);
    expect(entries.firstWhere((e) => e.id == entry.id).settledState, SettledState.settling);

    final settled = await env.asB.approveSettlement(pending.id);
    expect(settled.status, SettlementStatus.settled);
    expect(settled.settledAt, isNotNull);

    entries = await env.asA.fetchEntries(env.ledgerId);
    final locked = entries.firstWhere((e) => e.id == entry.id);
    expect(locked.settledState, SettledState.settled);

    // 已結帳＝金額鎖住、刪不掉、子表不接受重寫。
    await expectLater(
      env.asA.upsertEntry(locked.copyWith(amount: 2000), writeSplits: false, writeLineItems: false),
      throwsA(isA<LedgerException>()),
    );
    await expectLater(env.asA.removeEntry(locked.id), throwsA(isA<LedgerException>()));
    await expectLater(
      env.asA.upsertEntry(locked.copyWith(note: '改備註'), writeLineItems: true),
      throwsA(isA<LedgerException>()),
    );

    createdEntryIds.remove(entry.id); // 已結帳，清不掉也不該清
  });

  test('已結帳的帳目仍可改細項（ADR-0002：直寫 line_items，不走 upsert_entry）', () async {
    final entry = await save(newSharedExpense(
      amount: 1000,
      note: '結帳後還要改細項',
      payerId: env.memberA,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: '', memberId: env.memberA, share: 500),
        EntrySplit(entryId: '', memberId: env.memberB, share: 500),
      ],
      lineItems: const [LineItem(id: '', entryId: '', name: '打錯的細項', amount: 1000, sort: 0)],
    ));

    final pending = await env.asA.initiateSettlement(env.ledgerId);
    await env.asB.approveSettlement(pending.id);
    createdEntryIds.remove(entry.id); // 已結帳，清不掉

    final settled = (await env.asA.fetchEntries(env.ledgerId)).firstWhere((e) => e.id == entry.id);
    expect(settled.settledState, SettledState.settled);

    // upsert_entry 帶子表會被擋（守衛還在）……
    await expectLater(
      env.asA.upsertEntry(settled.copyWith(note: '順便改細項'), writeLineItems: true),
      throwsA(isA<LedgerException>()),
    );

    // ……但直寫 line_items 表是允許的，這是 spec 給的路。
    final rebuilt = await env.asA.replaceLineItems(entry.id, const [
      LineItem(id: '', entryId: '', name: '改對的細項', amount: 700, sort: 0),
      LineItem(id: '', entryId: '', name: '補一列', amount: 300, sort: 1),
    ]);
    expect(rebuilt.map((l) => l.name).toList(), ['改對的細項', '補一列']);

    final after = (await env.asA.fetchEntries(env.ledgerId)).firstWhere((e) => e.id == entry.id);
    final names = [...after.lineItems]..sort((a, b) => a.sort.compareTo(b.sort));
    expect(names.map((l) => l.name).toList(), ['改對的細項', '補一列']);
    expect(after.amount, 1000, reason: '金額仍鎖住，改細項不動主筆');
    expect(after.settledState, SettledState.settled);
  });

  test('replaceLineItems 傳空清單＝清空細項', () async {
    final entry = await save(newSharedExpense(
      amount: 300,
      lineItems: const [LineItem(id: '', entryId: '', name: '要被清掉的', amount: 300, sort: 0)],
    ));
    expect(entry.lineItems, hasLength(1));

    final cleared = await env.asA.replaceLineItems(entry.id, const []);
    expect(cleared, isEmpty);
    final after = (await env.asA.fetchEntries(env.ledgerId)).firstWhere((e) => e.id == entry.id);
    expect(after.lineItems, isEmpty);
  });

  test('結算：取消 pending 會把涵蓋帳目打回 open', () async {
    final entry = await save(newSharedExpense(
      amount: 600,
      note: '取消結算契約',
      payerId: env.memberA,
      splitMethod: SplitMethod.equal,
      splits: [
        EntrySplit(entryId: '', memberId: env.memberA, share: 300),
        EntrySplit(entryId: '', memberId: env.memberB, share: 300),
      ],
    ));

    final pending = await env.asA.initiateSettlement(env.ledgerId);
    final cancelled = await env.asA.cancelSettlement(pending.id);
    expect(cancelled.status, SettlementStatus.void_);

    final entries = await env.asA.fetchEntries(env.ledgerId);
    expect(entries.firstWhere((e) => e.id == entry.id).settledState, SettledState.open);
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

/// Supabase 專屬：現場註冊一個誰都不是的帳號，驗 RLS 對「完全非成員」也關得起來。
///
/// seed 的兩個帳號都是「我們的家」的成員，用它們驗不到這條；地端 autoconfirm 是開的，
/// 註冊即登入。大腦每次跑整合測試前會 `db reset`，所以留下來的測試帳號不必自己清。
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

/// Supabase 專屬：DB 的 check constraint 打回來時要變成看得懂的中文。
///
/// 模型的不變式讓「代墊＋budget」根本組不出 [Entry]，所以這裡直接對 RPC 送壞 payload，
/// 驗的是**錯誤轉譯**這一段（第二道防線真的被踩到時使用者看到什麼）。
void supabaseOnlyTests() {
  test('代墊＋funding=budget 被 DB 打回，轉成可讀的中文錯誤', () async {
    final env = await SupabaseEnv.create();
    addTearDown(env.dispose);
    final snap = await env.asA.loadSnapshot(env.ledgerId);
    final categoryId = snap.categories.firstWhere((c) => c.kind == EntryKind.expense).id;
    final now = DateTime.now();
    final occurredOn =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    Object? caught;
    try {
      await env.clientA.rpc<dynamic>('upsert_entry', params: {
        'p_entry': {
          'ledger_id': env.ledgerId,
          'kind': 'expense',
          'scope': 'shared',
          'amount': 500,
          'category_id': categoryId,
          'occurred_on': occurredOn,
          'note': '代墊卻想吃信封',
          'payer_id': env.memberA,
          'split_method': 'equal',
          'funding': 'budget',
        },
      });
    } on PostgrestException catch (e) {
      caught = e;
    }
    expect(caught, isNotNull, reason: 'DB 必須擋下代墊筆走信封');
    expect((caught! as PostgrestException).message,
        contains('entries_funding_common_wallet_only'));

    // 對照組：共同錢包的共同支出走信封是合法的，不該被同一條 check 擋住。
    final legal = await env.asA.upsertEntry(Entry(
      id: '',
      ledgerId: env.ledgerId,
      kind: EntryKind.expense,
      scope: EntryScope.shared,
      amount: 500,
      categoryId: categoryId,
      occurredOn: DateTime(now.year, now.month, now.day),
      createdBy: env.memberA,
      note: '共同錢包吃信封（合法）',
      funding: Funding.budget,
    ));
    expect(legal.funding, Funding.budget);
    await env.asA.removeEntry(legal.id);
  });
}

void main() {
  group('InMemoryLedgerRepository', () => contractTests(InMemoryEnv.create));

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
