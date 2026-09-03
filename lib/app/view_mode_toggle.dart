import 'package:flutter/material.dart';

import '../domain/models.dart';

/// 家庭／個人視角切換：滿版等寬兩格、單行不換行，帳目與統計共用。
class ViewModeToggle extends StatelessWidget {
  const ViewModeToggle({super.key, required this.value, required this.onChanged});
  final ViewMode value;
  final ValueChanged<ViewMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<ViewMode>(
        key: const Key('view-mode-toggle'),
        segments: const [
          ButtonSegment(value: ViewMode.family, label: Text('家庭', maxLines: 1, softWrap: false), icon: Icon(Icons.home_outlined)),
          ButtonSegment(value: ViewMode.personal, label: Text('個人', maxLines: 1, softWrap: false), icon: Icon(Icons.person_outline)),
        ],
        selected: {value},
        onSelectionChanged: (s) => onChanged(s.first),
        showSelectedIcon: false,
        expandedInsets: EdgeInsets.zero,
        style: const ButtonStyle(
          visualDensity: VisualDensity.standard,
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
        ),
      ),
    );
  }
}
