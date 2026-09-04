/// 分類選擇器（Mike 裁示 2026-09-04 第二版）：橫向小 icon 無限循環滑動。
/// 預設可視 5 個、置中者為選中、依分類排序左右接續（循環）；永遠有選中值（滾輪語義）。
/// 表單、編輯彈窗、購物／結帳 sheet 共用這一顆。
library;

import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'category_icon.dart';

class CategoryWheel extends StatefulWidget {
  const CategoryWheel({
    super.key,
    required this.categories,
    required this.selectedId,
    required this.onSelected,
    this.enabled = true,
    this.height = 72,
  });

  final List<Category> categories;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  final bool enabled;
  final double height;

  /// 一屏可視數（置中選中＋左右各兩個）。測試用它換算單格寬。
  static const visibleCount = 5;

  @override
  State<CategoryWheel> createState() => _CategoryWheelState();
}

class _CategoryWheelState extends State<CategoryWheel> {
  /// 無限循環：從一個很大的中點頁開始，往兩邊都滑得動；index 取模映射回分類。
  static const _loops = 1000;

  int get _n => widget.categories.length;
  int get _base => _n * _loops;

  int _indexOf(String? id) {
    final i = widget.categories.indexWhere((c) => c.id == id);
    return i < 0 ? 0 : i;
  }

  late final PageController _controller = PageController(
    viewportFraction: 1 / CategoryWheel.visibleCount,
    initialPage: _base + _indexOf(widget.selectedId),
  );

  @override
  void didUpdateWidget(CategoryWheel old) {
    super.didUpdateWidget(old);
    if (_n == 0 || !_controller.hasClients) return;
    final page = _controller.page?.round() ?? _controller.initialPage;
    // 外部換選取（如支出/收入切換重設）或分類清單長度變了：跳回中點對應頁。
    final target = _indexOf(widget.selectedId);
    final changed = old.categories.length != _n || old.selectedId != widget.selectedId;
    if (changed && page % _n != target) {
      _controller.jumpToPage(_base + target);
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
        child: PageView.builder(
          controller: _controller,
          onPageChanged: (i) => widget.onSelected(widget.categories[i % _n].id),
          itemBuilder: (_, i) {
            final c = widget.categories[i % _n];
            final selected = c.id == widget.selectedId;
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: selected ? 40 : 32,
                    height: selected ? 40 : 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHigh,
                    ),
                    child: Icon(
                      categoryIcon(c.icon),
                      size: selected ? 20 : 16,
                      color: selected ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelSmall?.copyWith(
                      color: selected ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
                      fontWeight: selected ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
