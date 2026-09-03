/// 領域模型（對應 docs/specs/ledger.md「領域模型」）。
/// 純資料類，不含 UI；DB 接上後型別維持不變。
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

class Ledger {
  const Ledger({
    required this.id,
    required this.name,
    required this.inviteCode,
    required this.defaultRatio,
    this.openingBalanceShared = 0,
  });
  final String id;
  final String name;
  final String inviteCode;

  /// memberId → 百分比（合計 100）。
  final Map<String, int> defaultRatio;
  final int openingBalanceShared;
}

class Member {
  const Member({
    required this.id,
    required this.ledgerId,
    required this.userId,
    required this.displayName,
    this.openingBalancePersonal = 0,
  });
  final String id;
  final String ledgerId;
  final String userId;
  final String displayName;
  final int openingBalancePersonal;
}

class Category {
  const Category({
    required this.id,
    required this.ledgerId,
    required this.kind,
    required this.name,
    required this.icon,
    required this.sort,
    this.rollover = false,
  });
  final String id;
  final String ledgerId;
  final EntryKind kind;
  final String name;

  /// Material icon 名稱或 emoji，UI 自行對應。
  final String icon;
  final int sort;
  final bool rollover;
}

class LineItem {
  const LineItem({
    required this.id,
    required this.entryId,
    required this.name,
    this.amount,
    this.sort = 0,
  });
  final String id;
  final String entryId;
  final String name;

  /// 可空；加總可不等於主筆金額（ADR-0001）。
  final int? amount;
  final int sort;
}

class EntrySplit {
  const EntrySplit({required this.entryId, required this.memberId, required this.share});
  final String entryId;
  final String memberId;

  /// 兩位小數（ADR-0005）。
  final double share;
}

class Entry {
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
    this.lineItems = const [],
    this.splits = const [],
  });
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
  final List<LineItem> lineItems;
  final List<EntrySplit> splits;

  bool get isExpense => kind == EntryKind.expense;
  bool get fromCommonWallet => payerId == null || splitMethod == SplitMethod.common;

  /// settled 後金額／payer／split 鎖住（ADR-0002）。
  bool get amountLocked => settledState == SettledState.settled;

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
}

class Budget {
  const Budget({
    required this.id,
    required this.ledgerId,
    required this.categoryId,
    required this.month,
    required this.limit,
  });
  final String id;
  final String ledgerId;
  final String categoryId;

  /// 該月 1 號。
  final DateTime month;
  final int limit;
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
}
