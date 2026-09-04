import 'package:intl/intl.dart';

final _n = NumberFormat('#,###');

/// 整數元格式：1234 → "1,234"；負數保留符號。
String fmtAmount(int v) => _n.format(v);

/// 帶正負號：正數補「+」，負數沿用 [fmtAmount] 自帶的負號（0 → "0"）。
/// 對帳與清帳明細用：一欄數字要讓人一眼看出方向。
String fmtSignedAmount(int v) => v > 0 ? '+${fmtAmount(v)}' : fmtAmount(v);

/// 帶單位：1234 → "1,234 元"。
String fmtMoney(int v) => '${_n.format(v)} 元';

/// 兩位小數分攤額：283.5 → "283.5"。
String fmtShare(double v) => v == v.roundToDouble() ? _n.format(v.round()) : v.toStringAsFixed(1);

String fmtMonth(DateTime m) => '${m.year}年${m.month}月';

/// 年月：2026／08（兩位數月、全形斜線）。與 `errors.dart` 的「請先清 2026／08」同格式——
/// 清帳的按鈕、列表、sheet 標題與 RPC 錯誤訊息裡的月份，使用者看到的必須是同一種寫法。
String fmtYearMonth(DateTime m) => '${m.year}／${m.month.toString().padLeft(2, '0')}';
const _wd = ['', '一', '二', '三', '四', '五', '六', '日'];

/// 不依賴 locale 初始化（widget test 直接可用）：9/2 (三)。
String fmtDate(DateTime d) => '${d.month}/${d.day} (${_wd[d.weekday]})';

/// 完整日期：2026/09/03（補零、半形斜線、**帶年份**）。
///
/// 給「事件發生在哪一天」這種要能跨年對照的地方用——清帳列表的清帳時間就是：
/// 2026／01 清掉 2025／12 是常態，只寫月/日看不出是哪一年清的。
String fmtDateFull(DateTime d) =>
    '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
