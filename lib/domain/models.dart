/// 領域模型（對應 docs/specs/ledger.md「領域模型」與 ADR-0009）。
/// 純資料類，不含 UI；欄位名與 Supabase 表一致（snake_case 只出現在 JSON 層）。
library;

enum EntryKind { expense, income }

/// 趨勢圖顆粒度。
enum Granularity { day, week, month, year }

// ── JSON 基礎工具 ───────────────────────────────────────────────────────
//
// 手寫序列化（不引 freezed／json_serializable）。三條規則：
// 1. 欄位名一律 DB 的 snake_case；2. enum 用 DB 字面值；
// 3. `date` 欄位解析後不帶時間分量（DB 是 date，前端一律 date-only 比較）。

/// `date` 欄位（`occurred_on`／`due_on`／`month`）→ 不帶時間的 [DateTime]。
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
/// 留在 UTC 的話台北凌晨（＝UTC 前一天）的紀錄會提早一天生效。
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

/// enum 值 → DB 字面值。v1.5 的兩個 enum（[EntryKind]、[Granularity]）名稱與 DB 一致；
/// 之前為了 `void_`（結算狀態）留的去尾底線分支隨結算一起移除。
String _enumName(Enum v) => v.name;

/// 月初（date-only）。`balance_math.monthOf` 的同義工具，這裡保持私有避免匯入迴圈。
DateTime _monthOf(DateTime d) => DateTime(d.year, d.month, 1);

// ── 模型 ────────────────────────────────────────────────────────────────

/// 帳本。v1.5（ADR-0009）drop 掉 `default_ratio` 與 `opening_balance_shared`：
/// 沒有逐筆分攤、也沒有期初餘額，共同餘額只由收入與共同錢包支出推動。
class Ledger {
  const Ledger({
    required this.id,
    required this.name,
    required this.inviteCode,
  });

  /// DB 若還帶著尚未 drop 的舊欄（逐支套 migration 期間），多餘的鍵直接忽略。
  factory Ledger.fromJson(Map<String, dynamic> j) => Ledger(
        id: j['id'] as String,
        name: j['name'] as String,
        inviteCode: j['invite_code'] as String,
      );

  final String id;
  final String name;
  final String inviteCode;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'invite_code': inviteCode,
      };
}

/// 帳本成員。v1.5 drop 掉 `monthly_topup`／`opening_balance_personal`：
/// 補入改成手動記的 [PersonalTopup]，沒有期初。
class Member {
  const Member({
    required this.id,
    required this.ledgerId,
    required this.userId,
    required this.displayName,
    required this.joinedAt,
  });

  factory Member.fromJson(Map<String, dynamic> j) => Member(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        userId: j['user_id'] as String,
        displayName: j['display_name'] as String,
        // `members.joined_at` 是 not null，缺鍵只會是「舊 build／替身沒帶」。
        // fallback 取 epoch 而不是 now()：加入月落在遠古只會讓可清月份往前多找，
        // 不會讓歷史月份憑空從清帳序列裡消失。
        joinedAt: _tsOrNull(j['joined_at']) ?? DateTime(1970),
      );

  final String id;
  final String ledgerId;
  final String userId;
  final String displayName;

  /// `members.joined_at`；首次清帳的「最早可清月」會看它（呼叫端以本地時區取月初）。
  final DateTime joinedAt;

  Member copyWith({String? displayName, DateTime? joinedAt}) => Member(
        id: id,
        ledgerId: ledgerId,
        userId: userId,
        displayName: displayName ?? this.displayName,
        joinedAt: joinedAt ?? this.joinedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'user_id': userId,
        'display_name': displayName,
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

/// 一筆家庭支出或共同收入（v1.5／ADR-0009）。
///
/// 只有一種支出＝家庭支出，只區分「分類」與「誰先付」：
/// [payerId] 非 null ＝該成員先付（扣他當月的補入剩餘）；null ＝共同錢包付（扣共同餘額）。
/// 收入只有共同收入，[payerId] 恆 null。**沒有** scope／split_method／settled_state／分攤列。
class Entry {
  const Entry({
    required this.id,
    required this.ledgerId,
    required this.kind,
    required this.amount,
    required this.categoryId,
    required this.occurredOn,
    required this.createdBy,
    this.note = '',
    this.payerId,
    this.isAdjustment = false,
    this.createdAt,
    this.lineItems = const [],
  });

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        kind: _enumOf(EntryKind.values, j['kind'], 'kind'),
        amount: (j['amount'] as num).toInt(),
        categoryId: j['category_id'] as String,
        occurredOn: _date(j['occurred_on']),
        createdBy: j['created_by'] as String,
        note: (j['note'] as String?) ?? '',
        // 可缺／可 null：共同錢包付的支出與所有收入都沒有付款人。
        payerId: j['payer_id'] as String?,
        isAdjustment: (j['is_adjustment'] as bool?) ?? false,
        createdAt: j['created_at'] == null ? null : DateTime.tryParse(j['created_at'] as String),
        // Supabase select 的巢狀寫法：`entries(*, line_items(*))`；沒帶子表時是空清單。
        lineItems: [
          for (final x in (j['line_items'] as List?) ?? const [])
            LineItem.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
      );

  final String id;
  final String ledgerId;
  final EntryKind kind;

  /// 整數元；沖銷筆為負。
  final int amount;
  final String categoryId;
  final DateTime occurredOn;
  final String createdBy;
  final String note;

  /// null ＝ 共同錢包（收入恆 null）。
  final String? payerId;
  final bool isAdjustment;

  /// DB 的 created_at（列表預設排序鍵：建立時間倒序）；記憶體 mock／未回傳時為 null。
  final DateTime? createdAt;
  final List<LineItem> lineItems;

  bool get isExpense => kind == EntryKind.expense;

  /// 共同錢包付＝沒有付款人。
  bool get fromCommonWallet => payerId == null;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'kind': _enumName(kind),
        'amount': amount,
        'category_id': categoryId,
        'occurred_on': _dateStr(occurredOn),
        'created_by': createdBy,
        'note': note,
        'payer_id': payerId,
        'is_adjustment': isAdjustment,
        'line_items': [for (final x in lineItems) x.toJson()],
      };

  /// `upsert_entry` RPC 的 `p_entry`：只吐可寫欄。
  ///
  /// `created_by`／`created_at` **不可送**——欄位級授權會 permission denied。
  /// [id] 為空字串代表新筆（尚未有 DB id），不帶 `id` 欄讓 DB 自己生。
  Map<String, dynamic> toUpsertJson() => {
        if (id.isNotEmpty) 'id': id,
        'ledger_id': ledgerId,
        'kind': _enumName(kind),
        'amount': amount,
        'category_id': categoryId,
        'occurred_on': _dateStr(occurredOn),
        'note': note,
        'payer_id': payerId,
        'is_adjustment': isAdjustment,
      };

  Entry copyWith({
    int? amount,
    String? categoryId,
    DateTime? occurredOn,
    String? note,
    String? payerId,
    bool clearPayer = false,
    List<LineItem>? lineItems,
  }) {
    return Entry(
      id: id,
      ledgerId: ledgerId,
      kind: kind,
      amount: amount ?? this.amount,
      categoryId: categoryId ?? this.categoryId,
      occurredOn: occurredOn ?? this.occurredOn,
      createdBy: createdBy,
      note: note ?? this.note,
      payerId: clearPayer ? null : (payerId ?? this.payerId),
      isAdjustment: isAdjustment,
      createdAt: createdAt,
      lineItems: lineItems ?? this.lineItems,
    );
  }
}

/// 個人補入（v1.5 新表 `personal_topups`）。
///
/// 每人每月自己按「補入」記金額，可多筆、可備註；只能寫自己那列
/// （`member_id = created_by = 本人`），未清月可刪、已清月鎖定，**沒有 UPDATE**。
class PersonalTopup {
  PersonalTopup({
    required this.id,
    required this.ledgerId,
    required this.memberId,
    required this.amount,
    required this.occurredOn,
    required this.createdBy,
    this.note = '',
    this.createdAt,
    DateTime? month,
  }) : month = month ?? _monthOf(occurredOn);

  factory PersonalTopup.fromJson(Map<String, dynamic> j) => PersonalTopup(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        memberId: j['member_id'] as String,
        amount: (j['amount'] as num).toInt(),
        occurredOn: _date(j['occurred_on']),
        month: _dateOrNull(j['month']),
        note: (j['note'] as String?) ?? '',
        createdBy: j['created_by'] as String,
        createdAt: _tsOrNull(j['created_at']),
      );

  final String id;
  final String ledgerId;

  /// 補入是誰的（只能是本人）。
  final String memberId;

  /// 整數元，DB check `personal_topups_amount_positive` 保證 > 0。
  final int amount;
  final DateTime occurredOn;

  /// DB 的 generated 欄（月初）：**只讀不送**。缺鍵時由 [occurredOn] 推出來——
  /// 兩者在 DB 定義上永遠一致（generated always as 月初），不是「缺鍵當 0」。
  final DateTime month;
  final String note;
  final String createdBy;
  final DateTime? createdAt;

  /// 寫入 payload。不帶 `month`（generated 欄，送了會被 DB 拒絕）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'member_id': memberId,
        'amount': amount,
        'occurred_on': _dateStr(occurredOn),
        'note': note,
        'created_by': createdBy,
      };
}

/// 一個分類某個月的預算（ADR-0008 起：影子紀錄，不是錢）。
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

// ── 月清帳（v1.5／ADR-0009）─────────────────────────────────────────────

/// 清帳明細裡的一位成員（`month_closes.details.members[]`）。
///
/// 三個數在 DB 是 bigint（一個月的加總越得過 int 上界），Dart 的 int 是 64-bit，照收。
class MonthCloseMemberLine {
  const MonthCloseMemberLine({
    required this.memberId,
    required this.displayName,
    required this.topup,
    required this.paid,
    required this.ending,
  });

  factory MonthCloseMemberLine.fromJson(Map<String, dynamic> j) => MonthCloseMemberLine(
        memberId: j['member_id'] as String,
        displayName: j['display_name'] as String,
        topup: (j['topup'] as num).toInt(),
        paid: (j['paid'] as num).toInt(),
        ending: (j['ending'] as num).toInt(),
      );

  final String memberId;
  final String displayName;

  /// 該月補入合計。
  final int topup;

  /// 該月本人先付的支出合計。
  final int paid;

  /// 月末＝[topup] − [paid]。> 0 → 該成員轉錢給共同帳戶；< 0 → 共同帳戶補他。
  final int ending;

  Map<String, dynamic> toJson() => {
        'member_id': memberId,
        'display_name': displayName,
        'topup': topup,
        'paid': paid,
        'ending': ending,
      };
}

/// 一份清帳明細：`month_close_preview` 的回傳，也是 `month_closes.details` 的形狀。
///
/// [incomeAmount] 只出現在預覽（＝Σ應轉入 − Σ應補出，落地的 `details` 不帶）。
class MonthCloseDetails {
  const MonthCloseDetails({
    required this.month,
    required this.members,
    required this.sharedPaid,
    this.incomeAmount,
  });

  factory MonthCloseDetails.fromJson(Map<String, dynamic> j) => MonthCloseDetails(
        month: _date(j['month']),
        members: [
          for (final x in (j['members'] as List?) ?? const [])
            MonthCloseMemberLine.fromJson(Map<String, dynamic>.from(x as Map)),
        ],
        sharedPaid: (j['shared_paid'] as num?)?.toInt() ?? 0,
        incomeAmount: (j['income_amount'] as num?)?.toInt(),
      );

  /// 被清的那個月（月初）。
  final DateTime month;
  final List<MonthCloseMemberLine> members;

  /// 該月共同錢包支出合計（僅供對照，清帳不動共同餘額）。
  final int sharedPaid;

  /// 「一鍵記共同收入」的金額（只在預覽有值；≤ 0 就不會記那筆收入）。
  final int? incomeAmount;

  Map<String, dynamic> toJson() => {
        'month': _dateStr(month),
        'members': [for (final m in members) m.toJson()],
        'shared_paid': sharedPaid,
        if (incomeAmount != null) 'income_amount': incomeAmount,
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
    this.incomeEntryId,
  });

  factory MonthClose.fromJson(Map<String, dynamic> j) => MonthClose(
        id: j['id'] as String,
        ledgerId: j['ledger_id'] as String,
        month: _date(j['month']),
        closedBy: j['closed_by'] as String,
        closedAt: _ts(j['closed_at']),
        incomeEntryId: j['income_entry_id'] as String?,
        details: MonthCloseDetails.fromJson(Map<String, dynamic>.from(j['details'] as Map)),
      );

  final String id;
  final String ledgerId;

  /// 被清的那個月（月初）。
  final DateTime month;
  final String closedBy;
  final DateTime closedAt;

  /// 「一鍵記共同收入」記下的那筆 entry；沒勾或金額 ≤ 0 時為 null。
  final String? incomeEntryId;

  /// 清帳當下的事實快照（之後再補記也不動它）。
  final MonthCloseDetails details;

  Map<String, dynamic> toJson() => {
        'id': id,
        'ledger_id': ledgerId,
        'month': _dateStr(month),
        'closed_by': closedBy,
        'closed_at': closedAt.toIso8601String(),
        'income_entry_id': incomeEntryId,
        'details': details.toJson(),
      };
}
