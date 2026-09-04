/// 資料層對外的唯一例外型別，以及「DB／Auth 原始錯誤 → 使用者看得懂的中文」轉譯。
///
/// 頁面一律 catch [LedgerException] 並顯示 `e.message`；PostgREST 的英文訊息
/// （`entry settled: amount locked, use an adjustment entry`）不會外流到 UI。
library;

import 'package:supabase_flutter/supabase_flutter.dart';

class LedgerException implements Exception {
  const LedgerException(this.message, {this.code, this.cause});

  /// 已經是中文、可以直接顯示給使用者的訊息。
  final String message;

  /// 原始錯誤碼（PostgREST 的 SQLSTATE 或 gotrue 的 code），供除錯與測試斷言用。
  final String? code;
  final Object? cause;

  @override
  String toString() => 'LedgerException($message, code: $code)';
}

/// 外部輸入不受信：Supabase 回來的 JSON 交給 `fromJson` 前後包這層，
/// 缺欄／型別不符一律變成可讀錯誤，不得靜默成 0（紀律：外部輸入不受信）。
T parseRow<T>(String table, Map<String, dynamic> row, T Function(Map<String, dynamic>) fromJson) {
  try {
    return fromJson(row);
  } catch (e) {
    throw LedgerException('伺服器回傳的「$table」資料格式不正確，請稍後再試', cause: e);
  }
}

List<T> parseRows<T>(String table, List<dynamic> rows, T Function(Map<String, dynamic>) fromJson) => [
      for (final r in rows) parseRow(table, Map<String, dynamic>.from(r as Map), fromJson),
    ];

/// RPC 回傳的單列（PostgREST 可能給 Map，也可能給只有一個元素的 List）。
Map<String, dynamic> asRowMap(Object? row) {
  if (row is Map) return Map<String, dynamic>.from(row);
  if (row is List && row.isNotEmpty && row.first is Map) {
    return Map<String, dynamic>.from(row.first as Map);
  }
  throw const LedgerException('伺服器回應格式錯誤，請稍後再試');
}

/// RPC 回傳列的 `id`。
///
/// 型別不符要說「伺服器回應格式錯誤」，不能讓 `as String` 的 TypeError 掉進
/// [guard] 的最外層而被誤報成「連線失敗，請檢查網路」——那會讓人一直重試一個
/// 跟網路完全無關的問題。
String requireId(Object? row) {
  final id = asRowMap(row)['id'];
  if (id is! String || id.isEmpty) {
    throw const LedgerException('伺服器回應格式錯誤，請稍後再試');
  }
  return id;
}

/// 把任何一段 Supabase 呼叫包成「只會丟 [LedgerException]」。
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on LedgerException {
    rethrow;
  } on PostgrestException catch (e) {
    throw LedgerException(_postgrestMessage(e), code: e.code, cause: e);
  } on AuthException catch (e) {
    throw LedgerException(_authMessage(e), code: e.code, cause: e);
  } catch (e) {
    throw LedgerException('連線失敗，請檢查網路後再試', cause: e);
  }
}

String _postgrestMessage(PostgrestException e) => dbMessage(e.message, code: e.code);

/// DB 訊息 → 中文。比對 `docs/specs/db-contract.md`「Trigger（前端要預期的錯誤）」與 RPC 的 raise 清單。
///
/// 公開的原因是**記憶體替身也要用它**：`InMemoryLedgerRepository` 的清帳與鎖月守衛
/// 拿 DB 的英文 raise 逐字餵進來，兩個實作看到的中文才保證是同一句
/// （契約測試對兩個實作跑同一組訊息斷言）。
String dbMessage(String m, {String? code}) {
  // check constraint（SQLSTATE 23514）：訊息裡帶 constraint 名稱。
  if (m.contains('entries_amount_sign')) return '負數金額請開啟「修正筆」';
  if (m.contains('entries_private_payer')) return '私人帳目的付款人必須是自己';
  if (m.contains('entries_private_no_split')) return '私人帳目不能分攤';
  if (m.contains('budget_allocation') && m.contains('expense category')) {
    return '預算只能設定在支出分類';
  }
  // v1.4：每分類每月只能設定一次（unique 23505），金額必須 > 0。
  if (m.contains('budget_allocation_one_per_category_month') ||
      (code == '23505' && m.contains('budget_allocation'))) {
    return '這個分類本月已設定預算，設定後不可修改';
  }
  if (m.contains('budget_allocation_amount_positive')) return '預算金額必須大於 0';
  if (m.contains('members_monthly_topup_range')) return '每月補入額必須介於 0 與 1 億之間';

  // 鎖月 trigger（v1.4）：訊息帶的是被擋的那筆所屬的月份。
  if (m.startsWith('month closed:')) return '該月已清帳';

  // 清帳 RPC 的可清條件（`close_month` 與 `month_close_preview` 共用同一組訊息）。
  if (m.contains('close_month:') || m.contains('month_close_preview:')) {
    if (m.contains('month not ended')) return '本月尚未結束';
    if (m.contains('already closed')) return '該月已清帳';
    if (m.contains('nothing to close')) return '沒有可清的月份';
    if (m.contains('unsettled entries in month')) return '有拆帳尚未簽完';
    final mustClose = RegExp(r'must close (\d{4})-(\d{2}) first').firstMatch(m);
    if (mustClose != null) return '請先清 ${mustClose.group(1)}／${mustClose.group(2)}';
    if (m.contains('month must be first day')) return '清帳月份格式錯誤，請重新整理後再試';
    // not a member／not authenticated 落到下面共用的那幾條。
  }

  // settled 鎖定（trigger 一律以 `entry settled: ` 開頭）。
  if (m.startsWith('entry settled:')) {
    if (m.contains('amount locked')) return '這筆已結帳，金額鎖住，請改用修正筆';
    if (m.contains('payer locked')) return '這筆已結帳，付款人鎖住，請改用修正筆';
    if (m.contains('split_method locked')) return '這筆已結帳，分攤方式鎖住，請改用修正筆';
    if (m.contains('scope locked')) return '這筆已結帳，共同／私人鎖住，請改用修正筆';
    if (m.contains('kind locked')) return '這筆已結帳，收入／支出鎖住，請改用修正筆';
    if (m.contains('occurred_on locked')) return '這筆已結帳，日期鎖住，請改用修正筆';
    if (m.contains('split locked')) return '這筆已結帳，分攤鎖住，請改用修正筆';
    if (m.contains('delete blocked')) return '已結帳的帳目不能刪除，請改用修正筆';
    if (m.contains('child tables locked')) return '這筆已結帳，只能改分類與備註';
    return '這筆已結帳，無法修改';
  }

  // 分攤守恆。
  if (m.contains('do not sum to amount') || m.contains('splits (')) {
    return '分攤金額合計與主筆金額不符';
  }
  if (m.contains('nets do not balance')) return '結算淨額不平衡，請重新整理後再試';

  // RPC raise。
  if (m.contains('invalid invite code')) return '邀請碼不正確';
  if (m.contains('a pending settlement already exists')) return '已經有一筆結算正在等待簽核';
  if (m.contains('no settleable entries')) return '目前沒有可結算的帳目';
  if (m.contains('nothing to settle')) return '目前淨額為零，不需要結算';
  if (m.contains('not a required signer')) return '你不是這筆結算的簽核人';
  if (m.contains('settlement is not pending')) return '這筆結算已經處理過了';
  if (m.contains('only the initiator or a required signer may cancel')) {
    return '只有發起人或簽核人可以取消結算';
  }
  if (m.contains('settlement not found')) return '找不到這筆結算，請重新整理';
  if (m.contains('entry not found or not visible')) return '找不到這筆帳目，請重新整理';
  if (m.contains('not a member')) return '你不是這本帳本的成員';
  if (m.contains('is immutable')) return '這個欄位不可修改';

  // 權限層（比 trigger 更早發生）。
  if (code == '42501' || m.contains('permission denied')) {
    return '沒有權限執行這個操作';
  }

  return '操作失敗，請稍後再試';
}

String _authMessage(AuthException e) {
  final m = e.message.toLowerCase();
  if (m.contains('invalid login credentials')) return 'Email 或密碼不正確';
  if (m.contains('user already registered') || e.code == 'user_already_exists') {
    return '這個 Email 已經註冊過了，請直接登入';
  }
  if (m.contains('password should be at least')) return '密碼長度不足';
  if (m.contains('unable to validate email') || m.contains('invalid email')) {
    return 'Email 格式不正確';
  }
  if (m.contains('provider is not enabled') || m.contains('unsupported provider')) {
    return 'Apple 登入尚未啟用';
  }
  if (m.contains('email not confirmed')) return '這個 Email 尚未完成驗證';
  // 不把 gotrue 的英文原文貼到畫面上：使用者看不懂，而且訊息可能帶內部細節。
  // 原文留在 [LedgerException.cause]／`code` 裡供除錯。
  return '登入失敗，請稍後再試';
}
