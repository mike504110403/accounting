/// 領域模型（對應 docs/specs/ledger.md「領域模型」與 ADR-0007）。
/// 純資料類，不含 UI；欄位名與 Supabase 表一致（snake_case 只出現在 JSON 層）。
library;

enum EntryKind { expense, income }

enum EntryScope { private, shared }

enum SplitMethod { equal, ratio, amount, common }

enum SettledState { open, settling, settled }

enum SettlementStatus { pending, settled, void_ }

/// 資金來源（v1.3／ADR-0007）：共同錢包的共同支出可從信封（budget）出，其餘一律走餘額。
enum Funding { balance, budget }

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
    this.openingBalancePersonal = 0,
  });

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        userId: j['user_id'] as String,
        displayName: j['display_name'] as String,
        openingBalancePersonal: (j['opening_balance_personal'] as num?)?.toInt() ?? 0,
      );

  final String id;
  final String ledgerId;
  final String userId;
  final String displayName;
  final int openingBalancePersonal;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'user_id': userId,
        'display_name': displayName,
        'opening_balance_personal': openingBalancePersonal,
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
  /// 不變式（ADR-0007，DB 也有 check）：`funding == budget` 只允許共同錢包
  /// （`payerId == null`）的共同支出（`scope == shared && kind == expense`）。
  /// 前端先擋，違反直接丟 [ArgumentError]——讓錯誤停在建構點，不要流到 DB 才炸。
  Entry({
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
    this.funding = Funding.balance,
    this.createdAt,
    this.lineItems = const [],
    this.splits = const [],
  }) {
    if (funding == Funding.budget &&
        !(payerId == null && scope == EntryScope.shared && kind == EntryKind.expense)) {
      throw ArgumentError.value(
        funding,
        'funding',
        'funding=budget 只允許共同錢包（payer 為空）的共同支出',
      );
    }
  }

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
        funding: _enumOf(Funding.values, j['funding'] ?? 'balance', 'funding'),
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

  /// 資金來源：從信封出還是從共同可用餘額出（ADR-0007）。
  final Funding funding;

  /// DB 的 created_at（列表預設排序鍵：建立時間倒序）；記憶體 mock／未回傳時為 null。
  final DateTime? createdAt;
  final List<LineItem> lineItems;
  final List<EntrySplit> splits;

  bool get isExpense => kind == EntryKind.expense;
  bool get fromCommonWallet => payerId == null || splitMethod == SplitMethod.common;

  /// 從信封（預算）出的共同支出；不變式保證它必然是共同錢包的共同支出。
  bool get fromBudget => funding == Funding.budget;

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
        'funding': _enumName(funding),
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
        'funding': _enumName(funding),
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
    Funding? funding,
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
      funding: funding ?? this.funding,
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

/// 一次手動撥款／退回（ADR-0007，取代 `Budget`）。[amount] 可負（＝退回）。
/// 信封只看當月：同分類同月的所有列相加＝該月撥款，不跨月。
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

  /// 整數元，可負（退回），DB check 保證 ≠ 0。
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
