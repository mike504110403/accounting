import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'month_picker.dart';
import 'view_mode_toggle.dart';

/// 帳目與統計共用的頂部列：月份標題（箭頭＋彈窗）置中，下方家庭／個人切換。
/// 兩頁高度、間距、位置完全一致；leading／actions 只影響左右角，不影響標題與切換的位置。
class MonthAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MonthAppBar({
    super.key,
    required this.month,
    required this.onMonthChanged,
    required this.view,
    required this.onViewChanged,
    this.leading,
    this.actions,
  });

  final DateTime month;
  final ValueChanged<DateTime> onMonthChanged;
  final ViewMode view;
  final ValueChanged<ViewMode> onViewChanged;
  final Widget? leading;
  final List<Widget>? actions;

  static const double toggleHeight = 56;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + toggleHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      // 左右角各固定 56 寬，內容置中，讓標題在兩頁都精確置中。
      leadingWidth: 56,
      automaticallyImplyLeading: false,
      leading: SizedBox(width: 56, child: Center(child: leading)),
      actions: [SizedBox(width: 56, child: Center(child: (actions == null || actions!.isEmpty) ? null : actions!.first))],
      title: MonthTitle(month: month, onChanged: onMonthChanged),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(toggleHeight),
        child: SizedBox(
          height: toggleHeight,
          child: ViewModeToggle(value: view, onChanged: onViewChanged),
        ),
      ),
    );
  }
}
