/// 領域模型（對應 docs/specs/ledger.md「領域模型」與 ADR-0007）。
/// 純資料類，不含 UI；欄位名與 Supabase 表一致（snake_case 只出現在 JSON 層）。
library;

enum EntryKind { expense, income }

enum EntryScope { private, shared }

enum SplitMethod { equal, ratio, amount, common }

enum SettledState { open, settling, settled }

enum SettlementStatus { pending, settled, void_ }

/// 統計視角：家庭（僅 shared）／個人（private ＋ 我在 shared 的份額）。
enum ViewMode { family, personal }

/// 趨勢圖顆粒度。
enum Granularity { day, week, month, year }

// ── JSON 基礎工具 ───────────────────────────────────────────────────────
//
// 手寫序列化（不引 freezed／json_serializable）。三條規則：
// 1. 欄位名一律 DB 的 snake_case；2. enum 用 DB 字面值（`void_` ↔ 'void'）；
// 3. `date` 欄位解析後不帶時間分量（DB 是 date，前端一律 date-only 比較）。

/// jsonb map（`default_ratio`／`nets`）→ `Map<String, int>`。
/// JSON 數字回來可能是 `num`（雲端 REST 是 double），一律 `.toInt()`。
Map<String, int> _intMap(Object? v) {
  if (v == null) return const {};
  return {
    for (final e in (v as Map).entries) e.key as String: (e.value as num).toInt(),
  };
}

/// `date` 欄位（`occurred_on`／`due_on`）→ 不帶時間的 [DateTime]。
DateTime _date(Object? v) {
  if (v is DateTime) return DateTime(v.year, v.month, v.day);
  final s = v as String;
  final head = s.length >= 10 ? s.substring(0, 10) : s;
  final p = head.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

DateTime? _dateOrNull(Object? v) => v == null ? null : _date(v);

String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String? _dateStrOrNull(DateTime? d) => d == null ? null : _dateStr(d);

/// `timestamptz` 欄位 → 本地時區的 [DateTime]（保留時間分量）。
///
/// 一定要 `toLocal()`：`balance_math` 的「計到 until 當日含」會把時間截成日曆日，
/// 留在 UTC 的話台北凌晨（＝UTC 前一天）結算會提早一天生效。
DateTime _ts(Object? v) => (v is DateTime ? v : DateTime.parse(v as String)).toLocal();

DateTime? _tsOrNull(Object? v) => v == null ? null : _ts(v);

String? _tsStrOrNull(DateTime? d) => d?.toIso8601String();

/// enum 字面值 → 值；找不到就丟 [ArgumentError]（DB 加了新值而前端沒跟上要立刻炸，不要靜靜吞掉）。
T _enumOf<T extends Enum>(List<T> values, Object? raw, String field) {
  final s = raw as String;
  for (final v in values) {
    if (_enumName(v) == s) return v;
  }
  throw ArgumentError.value(raw, field, '未知的 $field 值');
}

/// Dart 的 `void` 是保留字，enum 值只能叫 `void_`；對外一律吐 DB 字面值。
String _enumName(Enum v) => v.name.endsWith('_') ? v.name.substring(0, v.name.length - 1) : v.name;

// ── 模型 ────────────────────────────────────────────────────────────────

class Ledger {
  const Ledger({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.defaultRatio,
    this.openingBalanceShared = 0,
  });

  factory Ledger.fromJson(Map<String, dynamic> j) => Ledger(
        id: j['id'] as String,
        name: j['name'] as String,
        inviteCode: j['invite_code'] as String,
        defaultRatio: _intMap(j['default_ratio']),
        openingBalanceShared: (j['opening_balance_shared'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String name;
  final String inviteCode;

  /// memberId → 百分比（合計 100）。
  final Map<String, int> defaultRatio;
  final int openingBalanceShared;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'invite_code': inviteCode,
        'default_ratio': defaultRatio,
        'opening_balance_shared': openingBalanceShared,
      };
}

class Member {
  const Member({
    required this.id,
    required this.ledgerId,
    required this.userId,
    required this.displayName,
    required this.joinedAt,
    this.monthlyTopup = 0,
    this.openingBalancePersonal = 0,
  });

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        userId: j['user_id'] as String,
        displayName: j['display_name'] as String,
        // 缺鍵當 0：DB 有 default 0，但舊版 build／記憶體替身可能不帶這個鍵。
        monthlyTopup: (j['monthly_topup'] as num?)?.toInt() ?? 0,
        openingBalancePersonal: (j['opening_balance_personal'] as num?)?.toInt() ?? 0,
        // `members.joined_at` 是 not null，缺鍵只會是「舊 build／替身沒帶」。
        // fallback 取 epoch 而不是 now()：加入月落在遠古 ＝ 每個月都有補入額，
        // 寧可多算也不要因為「今天」而讓歷史月份的補入額整批消失（少算才是對不平的那一邊）。
        joinedAt: _tsOrNull(j['joined_at']) ?? DateTime(1970),
      );

  final String id;
  final String ledgerId;
  final String userId;
  final String displayName;

  /// 每月補入額（v1.4／ADR-0008）：從加入帳本那個月起，每個未清帳月份加一次。
  final int monthlyTopup;

  /// **v1.4 起廢用**：欄位仍在 DB（跨版本並存），但不進任何公式、也不再送 update。
  final int openingBalancePersonal;

  /// `members.joined_at`；補入額從這個月開始算（呼叫端以本地時區取月初）。
  final DateTime joinedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'user_id': userId,
        'display_name': displayName,
        'monthly_topup': monthlyTopup,
        'opening_balance_personal': openingBalancePersonal,
        'joined_at': joinedAt.toIso8601String(),
      };
}

class Category {
  const Category({
    required this.id,
    required this.ledgerId,
    required this.kind,
    required this.name,
    required this.icon,
    required this.sort,
  });

  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        kind: _enumOf(EntryKind.values, j['kind'], 'kind'),
        name: j['name'] as String,
        icon: j['icon'] as String,
        sort: (j['sort'] as num).toInt(),
      );

  final String id;
  final String ledgerId;
  final EntryKind kind;
  final String name;

  /// Material icon 名稱或 emoji，UI 自行對應。
  final String icon;
  final int sort;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'kind': _enumName(kind),
        'name': name,
        'icon': icon,
        'sort': sort,
      };
}

class LineItem {
  const LineItem({
    required this.id,
    required this.entryId,
    required this.name,
    this.amount,
    this.sort = 0,
  });

  factory LineItem.fromJson(Map<String, dynamic> j) => LineItem(
        id: j['id'] as String,
        entryId: j['entry_id'] as String,
        name: j['name'] as String,
        amount: (j['amount'] as num?)?.toInt(),
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String entryId;
  final String name;

  /// 可空；加總可不等於主筆金額（ADR-0001）。
  final int? amount;
  final int sort;

  Map<String, dynamic> toJson() => {
        'id': id,
        'entry_id': entryId,
        'name': name,
        'amount': amount,
        'sort': sort,
      };
}

class EntrySplit {
  const EntrySplit({required this.entryId, required this.memberId, required this.share});

  factory EntrySplit.fromJson(Map<String, dynamic> j) => EntrySplit(
        entryId: j['entry_id'] as String,
        memberId: j['member_id'] as String,
        // numeric(12,2) 從 REST 回來可能是 num 也可能是字串。
        share: j['share'] is String ? double.parse(j['share'] as String) : (j['share'] as num).toDouble(),
      );

  final String entryId;
  final String memberId;

  /// 兩位小數（ADR-0005）。
  final double share;

  Map<String, dynamic> toJson() => {
        'entry_id': entryId,
        'member_id': memberId,
        'share': share,
      };
}

class Entry {
  /// v1.4（ADR-0008）起沒有「資金來源」：所有支出都是餘額支出，預算只是影子紀錄。
  const Entry({
    required this.id,
    required this.ledgerId,
    required this.kind,
    required this.scope,
    required this.amount,
    required this.categoryId,
    required this.occurredOn,
    required this.createdBy,
    this.note = '',
    this.payerId,
    this.splitMethod = SplitMethod.common,
    this.settledState = SettledState.open,
    this.isAdjustment = false,
    this.createdAt,
    this.lineItems = const [],
    this.splits = const [],
  });

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        kind: _enumOf(EntryKind.values, j['kind'], 'kind'),
        scope: _enumOf(EntryScope.values, j['scope'], 'scope'),
        amount: (j['amount'] as num).toInt(),
        categoryId: j['category_id'] as String,
        occurredOn: _date(j['occurred_on']),
        createdBy: j['created_by'] as String,
        note: (j['note'] as String?) ?? '',
        payerId: j['payer_id'] as String?,
        splitMethod: _enumOf(SplitMethod.values, j['split_method'], 'split_method'),
        settledState: _enumOf(SettledState.values, j['settled_state'], 'settled_state'),
        isAdjustment: (j['is_adjustment'] as bool?) ?? false,
        createdAt: j['created_at'] == null ? null : DateTime.tryParse(j['created_at'] as String),
        // Supabase select 的巢狀寫法：`entries(*, line_items(*), entry_splits(*))`。
        lineItems: [
          for (final x in (j['line_items'] as List?) ?? const [])
            LineItem.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
        splits: [
          for (final x in (j['entry_splits'] as List?) ?? const [])
            EntrySplit.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
      );

  final String id;
  final String ledgerId;
  final EntryKind kind;
  final EntryScope scope;

  /// 整數元；修正筆可負。
  final int amount;
  final String categoryId;
  final DateTime occurredOn;
  final String createdBy;
  final String note;

  /// null ＝ 共同錢包。
  final String? payerId;
  final SplitMethod splitMethod;
  final SettledState settledState;
  final bool isAdjustment;

  /// DB 的 created_at（列表預設排序鍵：建立時間倒序）；記憶體 mock／未回傳時為 null。
  final DateTime? createdAt;
  final List<LineItem> lineItems;
  final List<EntrySplit> splits;

  bool get isExpense => kind == EntryKind.expense;
  bool get fromCommonWallet => payerId == null || splitMethod == SplitMethod.common;

  /// settled 後金額／payer／split 鎖住（ADR-0002）。
  bool get amountLocked => settledState == SettledState.settled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'kind': _enumName(kind),
        'scope': _enumName(scope),
        'amount': amount,
        'category_id': categoryId,
        'occurred_on': _dateStr(occurredOn),
        'created_by': createdBy,
        'note': note,
        'payer_id': payerId,
        'split_method': _enumName(splitMethod),
        'settled_state': _enumName(settledState),
        'is_adjustment': isAdjustment,
        'line_items': [for (final x in lineItems) x.toJson()],
        'entry_splits': [for (final x in splits) x.toJson()],
      };

  /// `upsert_entry` RPC 的 `p_entry`：只吐可寫欄。
  ///
  /// `settled_state`／`created_by`／`created_at` **不可送**——欄位級授權會 permission denied。
  /// [id] 為空字串代表新筆（尚未有 DB id），不帶 `id` 欄讓 DB 自己生。
  Map<String, dynamic> toUpsertJson() => {
        if (id.isNotEmpty) 'id': id,
        'ledger_id': ledgerId,
        'kind': _enumName(kind),
        'scope': _enumName(scope),
        'amount': amount,
        'category_id': categoryId,
        'occurred_on': _dateStr(occurredOn),
        'note': note,
        'payer_id': payerId,
        'split_method': _enumName(splitMethod),
        'is_adjustment': isAdjustment,
      };

  Entry copyWith({
    int? amount,
    String? categoryId,
    DateTime? occurredOn,
    String? note,
    String? payerId,
    bool clearPayer = false,
    SplitMethod? splitMethod,
    SettledState? settledState,
    EntryScope? scope,
    List<LineItem>? lineItems,
    List<EntrySplit>? splits,
  }) {
    return Entry(
      id: id,
      ledgerId: ledgerId,
      kind: kind,
      scope: scope ?? this.scope,
      amount: amount ?? this.amount,
      categoryId: categoryId ?? this.categoryId,
      occurredOn: occurredOn ?? this.occurredOn,
      createdBy: createdBy,
      note: note ?? this.note,
      payerId: clearPayer ? null : (payerId ?? this.payerId),
      splitMethod: splitMethod ?? this.splitMethod,
      settledState: settledState ?? this.settledState,
      isAdjustment: isAdjustment,
      lineItems: lineItems ?? this.lineItems,
      splits: splits ?? this.splits,
    );
  }
}

class Settlement {
  const Settlement({
    required this.id,
    required this.ledgerId,
    required this.status,
    required this.initiatedBy,
    required this.createdAt,
    required this.nets,
    required this.entryIds,
    required this.approvedBy,
    this.settledAt,
  });

  factory Settlement.fromJson(Map<String, dynamic> j) => Settlement(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        status: _enumOf(SettlementStatus.values, j['status'], 'status'),
        initiatedBy: j['initiated_by'] as String,
        createdAt: _ts(j['created_at']),
        settledAt: _tsOrNull(j['settled_at']),
        nets: _intMap(j['nets']),
        // 巢狀 select：`settlements(*, settlement_entries(entry_id), settlement_approvals(member_id))`。
        entryIds: [
          for (final x in (j['settlement_entries'] as List?) ?? const [])
            (x as Map)['entry_id'] as String,
        ],
        approvedBy: {
          for (final x in (j['settlement_approvals'] as List?) ?? const [])
            (x as Map)['member_id'] as String,
        },
      );

  final String id;
  final String ledgerId;
  final SettlementStatus status;
  final String initiatedBy;
  final DateTime createdAt;
  final DateTime? settledAt;

  /// memberId → 淨額（正＝應收、負＝應付），整數。
  final Map<String, int> nets;
  final List<String> entryIds;
  final Set<String> approvedBy;

  /// 需簽者＝淨額非零成員 − 發起人（ADR-0002）。
  Set<String> get requiredSigners =>
      nets.entries.where((e) => e.value != 0 && e.key != initiatedBy).map((e) => e.key).toSet();
  bool get fullyApproved => requiredSigners.difference(approvedBy).isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'status': _enumName(status),
        'initiated_by': initiatedBy,
        'created_at': createdAt.toIso8601String(),
        'settled_at': _tsStrOrNull(settledAt),
        'nets': nets,
        'settlement_entries': [for (final x in entryIds) {'entry_id': x}],
        'settlement_approvals': [for (final x in approvedBy) {'member_id': x}],
      };
}

/// 一個分類某個月的預算（v1.4／ADR-0008：影子紀錄，不是錢）。
/// **每分類每月至多一列**、[amount] 必須 > 0，設定後不可改、不可刪、不可退回；不跨月。
class BudgetAllocation {
  const BudgetAllocation({
    required this.id,
    required this.ledgerId,
    required this.categoryId,
    required this.amount,
    required this.occurredOn,
    required this.createdBy,
    this.note = '',
  });

  factory BudgetAllocation.fromJson(Map<String, dynamic> j) => BudgetAllocation(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        categoryId: j['category_id'] as String,
        amount: (j['amount'] as num).toInt(),
        occurredOn: _date(j['occurred_on']),
        note: (j['note'] as String?) ?? '',
        createdBy: j['created_by'] as String,
      );

  final String id;
  final String ledgerId;
  final String categoryId;

  /// 整數元，DB check 保證 > 0。
  final int amount;
  final DateTime occurredOn;
  final String note;
  final String createdBy;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'category_id': categoryId,
        'amount': amount,
        'occurred_on': _dateStr(occurredOn),
        'note': note,
        'created_by': createdBy,
      };
}

/// 購物清單與待辦同表：categoryId 為 null ＝ 待辦。
class ListItem {
  const ListItem({
    required this.id,
    required this.ledgerId,
    required this.title,
    this.store,
    this.estimated,
    this.categoryId,
    this.assigneeId,
    this.dueOn,
    this.doneAt,
    this.entryId,
    this.sort = 0,
  });

  factory ListItem.fromJson(Map<String, dynamic> j) => ListItem(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        title: j['title'] as String,
        store: j['store'] as String?,
        estimated: (j['estimated'] as num?)?.toInt(),
        categoryId: j['category_id'] as String?,
        assigneeId: j['assignee_id'] as String?,
        dueOn: _dateOrNull(j['due_on']),
        doneAt: _tsOrNull(j['done_at']),
        entryId: j['entry_id'] as String?,
        sort: (j['sort'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String ledgerId;
  final String title;
  final String? store;
  final int? estimated;
  final String? categoryId;
  final String? assigneeId;
  final DateTime? dueOn;
  final DateTime? doneAt;

  /// 勾選後產生的支出。
  final String? entryId;
  final int sort;

  bool get isTodo => categoryId == null;
  bool get isDone => doneAt != null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'title': title,
        'store': store,
        'estimated': estimated,
        'category_id': categoryId,
        'assignee_id': assigneeId,
        'due_on': _dateStrOrNull(dueOn),
        'done_at': _tsStrOrNull(doneAt),
        'entry_id': entryId,
        'sort': sort,
      };
}

// ── 月清帳（v1.4／ADR-0008）─────────────────────────────────────────────

/// 清帳預覽的結構化提醒（`month_close_preview` 的 `warnings`，DB 不回中文句子）。
class CloseWarning {
  const CloseWarning({required this.code, required this.count});

  factory CloseWarning.fromJson(Map<String, dynamic> j) => CloseWarning(
        code: j['code'] as String,
        count: (j['count'] as num).toInt(),
      );

  /// 目前只有 `unsplit_advances`（該月有幾筆沒有分攤列的代墊）。
  final String code;
  final int count;

  Map<String, dynamic> toJson() => {'code': code, 'count': count};
}

/// 清帳明細裡的一位成員（`month_closes.details.members[]`）。
///
/// [net]／[ending] 在 DB 是 bigint（一個月的加總越得過 int 上界），Dart 的 int 是 64-bit，照收。
class MonthCloseMemberLine {
  const MonthCloseMemberLine({
    required this.memberId,
    required this.displayName,
    required this.topup,
    required this.net,
    required this.ending,
  });

  factory MonthCloseMemberLine.fromJson(Map<String, dynamic> j) => MonthCloseMemberLine(
        memberId: j['member_id'] as String,
        displayName: j['display_name'] as String,
        topup: (j['topup'] as num).toInt(),
        net: (j['net'] as num).toInt(),
        ending: (j['ending'] as num).toInt(),
      );

  final String memberId;
  final String displayName;

  /// 該月補入額（加入月之前為 0）。
  final int topup;

  /// 該月淨變動。
  final int net;

  /// 月末餘額＝[topup] ＋ [net]。> 0 → 該成員轉錢給共同帳戶；< 0 → 共同帳戶補他。
  final int ending;

  Map<String, dynamic> toJson() => {
        'member_id': memberId,
        'display_name': displayName,
        'topup': topup,
        'net': net,
        'ending': ending,
      };
}

/// 一份清帳明細：`month_close_preview` 的回傳，也是 `month_closes.details` 的形狀。
///
/// [warnings] 只出現在預覽（落地的 `details` 不帶）；缺鍵時是空清單。
class MonthCloseDetails {
  const MonthCloseDetails({
    required this.month,
    required this.members,
    required this.sharedDelta,
    this.warnings = const [],
  });

  factory MonthCloseDetails.fromJson(Map<String, dynamic> j) => MonthCloseDetails(
        month: _date(j['month']),
        members: [
          for (final x in (j['members'] as List?) ?? const [])
            MonthCloseMemberLine.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
        sharedDelta: (j['shared_delta'] as num?)?.toInt() ?? 0,
        warnings: [
          for (final x in (j['warnings'] as List?) ?? const [])
            CloseWarning.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
      );

  /// 被清的那個月（月初）。
  final DateTime month;
  final List<MonthCloseMemberLine> members;

  /// 該月共同餘額變動（僅供對照，清帳不動共同餘額）。
  final int sharedDelta;
  final List<CloseWarning> warnings;

  Map<String, dynamic> toJson() => {
        'month': _dateStr(month),
        'members': [for (final m in members) m.toJson()],
        'shared_delta': sharedDelta,
        'warnings': [for (final w in warnings) w.toJson()],
      };
}

/// 一次清帳（`month_closes` 一列）。前端只讀，只能經 `close_month` RPC 寫入、不可撤銷。
class MonthClose {
  const MonthClose({
    required this.id,
    required this.ledgerId,
    required this.month,
    required this.closedBy,
    required this.closedAt,
    required this.details,
  });

  factory MonthClose.fromJson(Map<String, dynamic> j) => MonthClose(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        month: _date(j['month']),
        closedBy: j['closed_by'] as String,
        closedAt: _ts(j['closed_at']),
        details: MonthCloseDetails.fromJson(Map<String, dynamic>.from(j['details'] as Map)),
      );

  final String id;
  final String ledgerId;

  /// 被清的那個月（月初）。
  final DateTime month;
  final String closedBy;
  final DateTime closedAt;

  /// 清帳當下的事實快照（之後改補入額也不動它）。
  final MonthCloseDetails details;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'month': _dateStr(month),
        'closed_by': closedBy,
        'closed_at': closedAt.toIso8601String(),
        'details': details.toJson()..remove('warnings'),
      };
}
