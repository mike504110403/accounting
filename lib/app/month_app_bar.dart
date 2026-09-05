import 'package:flutter/material.dart';

import 'month_picker.dart';

/// 帳目與統計共用的頂部列：月份標題（箭頭＋彈窗）置中。
/// v1.5（ADR-0009）起沒有家庭／個人切換。leading／actions 只影響左右角，不影響標題位置。
class MonthAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MonthAppBar({
    super.key,
    required this.month,
    required this.onMonthChanged,
    this.leading,
    this.actions,
  });

  final DateTime month;
  final ValueChanged<DateTime> onMonthChanged;
  final Widget? leading;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leadingWidth: 56,
      automaticallyImplyLeading: false,
      leading: SizedBox(width: 56, child: Center(child: leading)),
      actions: [SizedBox(width: 56, child: Center(child: (actions == null || actions!.isEmpty) ? null : actions!.first))],
      title: MonthTitle(month: month, onChanged: onMonthChanged),
    );
  }
}
