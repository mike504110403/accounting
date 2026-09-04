/// 分類垂直滾輪（Mike 裁示 2026-09-03：分類選擇不秀 icon、改滾輪）。
/// 與 month_picker.dart 同款 CupertinoPicker；選中即回呼，永遠有選中值（滾輪語義）。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';

class CategoryWheel extends StatefulWidget {
  const CategoryWheel({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
    this.height = 108,
  });

  final List<Category> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final double height;

  static const itemExtent = 36.0;

  @override
  State<CategoryWheel> createState() => _CategoryWheelState();
}

class _CategoryWheelState extends State<CategoryWheel> {
  late final FixedExtentScrollController _controller =
      FixedExtentScrollController(initialItem: _indexOf(widget.selectedId));

  int _indexOf(String? id) {
    final i = widget.categories.indexWhere((c) => c.id == id);
    return i < 0 ? 0 : i;
  }

  @override
  void didUpdateWidget(CategoryWheel old) {
    super.didUpdateWidget(old);
    // 外部把選取換掉（如切支出／收入重設）時把滾輪帶到位；自己滾動觸發的回呼不會進這裡的 jump。
    final target = _indexOf(widget.selectedId);
    if (_controller.hasClients && old.selectedId != widget.selectedId && _controller.selectedItem != target) {
      _controller.jumpToItem(target);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (widget.categories.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(child: Text('尚無分類', style: t.textTheme.bodySmall)),
      );
    }
    return IgnorePointer(
      ignoring: !widget.enabled,
      child: SizedBox(
        height: widget.height,
        child: CupertinoTheme(
          data: CupertinoThemeData(brightness: t.brightness),
          child: CupertinoPicker(
            itemExtent: CategoryWheel.itemExtent,
            scrollController: _controller,
            onSelectedItemChanged: (i) => widget.onSelected(widget.categories[i].id),
            children: [
              for (final c in widget.categories)
                Center(
                  key: Key('category-${c.id}'),
                  child: Text(c.name, style: t.textTheme.bodyLarge),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
