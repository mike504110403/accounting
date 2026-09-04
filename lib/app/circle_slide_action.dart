/// 左滑動作的共用圓形 icon 鈕（Mike 裁示 2026-09-03：不要文字）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

class CircleSlideAction extends StatelessWidget {
  const CircleSlideAction({
    super.key,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return CustomSlidableAction(
      onPressed: (_) => onPressed(),
      backgroundColor: Colors.transparent,
      padding: EdgeInsets.zero,
      child: Tooltip(
        message: tooltip ?? '',
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(shape: BoxShape.circle, color: background),
          child: Icon(icon, size: 20, color: foreground),
        ),
      ),
    );
  }
}
