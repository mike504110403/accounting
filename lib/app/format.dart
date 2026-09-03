import 'package:intl/intl.dart';

final _n = NumberFormat('#,###');

/// 整數元格式：1234 → "1,234"；負數保留符號。
String fmtAmount(int v) => _n.format(v);

/// 帶單位：1234 → "1,234 元"。
String fmtMoney(int v) => '${_n.format(v)} 元';

/// 兩位小數分攤額：283.5 → "283.5"。
String fmtShare(double v) => v == v.roundToDouble() ? _n.format(v.round()) : v.toStringAsFixed(1);

String fmtMonth(DateTime m) => '${m.year}年${m.month}月';
const _wd = ['', '一', '二', '三', '四', '五', '六', '日'];

/// 不依賴 locale 初始化（widget test 直接可用）：9/2 (三)。
String fmtDate(DateTime d) => '${d.month}/${d.day} (${_wd[d.weekday]})';
