import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../app/month_app_bar.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import '../../app/circle_slide_action.dart';
import '../../app/tutorial.dart';
import 'entry_colors.dart';
import 'search_page.dart';

/// 帳目頁（v1.5／ADR-0009）：月份切換、月摘要、依日分組列表。
/// 沒有家庭／個人視角，也沒有結算卡片與簽核——每筆只記「誰先付」。
class EntriesPage extends ConsumerStatefulWidget {
  const EntriesPage({super.key});

  @override
  ConsumerState<EntriesPage> createState() => _EntriesPageState();
}

/// 列表排序（Mike 裁示 2026-09-03）：預設建立時間倒序，可切金額高→低／低→高。
enum _EntrySort { created, amountDesc, amountAsc }

class _EntriesPageState extends ConsumerState<EntriesPage> {
  DateTime _month = monthOf(DateTime.now());

  @override
  void initState() {
    super.initState();
    // 首次進 app 的新手導覽（tutorial.dart；看過就不再開）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(tutorialProvider.notifier).maybeStart();
    });
  }

  // 篩選與分頁（Mike 裁示 2026-09-03）：分類、日期區間；一次 20 筆、滑到底再放 20 筆。
  static const _pageSize = 20;
  String? _filterCategoryId;
  DateTimeRange? _range;
  _EntrySort _sort = _EntrySort.created;
  int _visibleCount = _pageSize;

  void _resetPaging() => _visibleCount = _pageSize;

  DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

  bool _inPeriod(Entry e) {
    final r = _range;
    if (r == null) return sameMonth(e.occurredOn, _month);
    final d = _dayOf(e.occurredOn);
    return !d.isBefore(_dayOf(r.start)) && !d.isAfter(_dayOf(r.end));
  }

  /// 建立時間倒序；mock／舊資料沒有 createdAt 就退回記帳日再退 id，穩定可重現。
  int _cmpCreatedDesc(Entry a, Entry b) {
    final ca = a.createdAt, cb = b.createdAt;
    if (ca != null && cb != null) return cb.compareTo(ca);
    final byDate = b.occurredOn.compareTo(a.occurredOn);
    if (byDate != 0) return byDate;
    return b.id.compareTo(a.id);
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDateRange: _range ??
          DateTimeRange(start: _month, end: DateTime(_month.year, _month.month + 1, 0)),
      currentDate: now,
    );
    if (picked != null && mounted) {
      setState(() {
        _range = picked;
        _resetPaging();
      });
    }
  }

  Future<void> _pickFilterCategory(List<Category> categories) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                key: const Key('filter-cat-all'),
                label: const Text('全部分類'),
                selected: _filterCategoryId == null,
                onSelected: (_) {
                  setState(() {
                    _filterCategoryId = null;
                    _resetPaging();
                  });
                  Navigator.of(ctx).pop();
                },
              ),
              for (final c in categories)
                ChoiceChip(
                  key: Key('filter-cat-${c.id}'),
                  label: Text(c.name),
                  selected: _filterCategoryId == c.id,
                  onSelected: (_) {
                    setState(() {
                      _filterCategoryId = c.id;
                      _resetPaging();
                    });
                    Navigator.of(ctx).pop();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _setMonth(DateTime m) => setState(() => _month = monthOf(m));

  /// 月摘要的 family key：一律該月最後一天（`monthSummaryProvider` 的約定）。
  DateTime get _until => DateTime(_month.year, _month.month + 1, 0);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 左滑刪除：確認框＋repository 守衛（鎖月的筆 DB trigger 會擋，訊息 toast 出來）。
  Future<void> _deleteEntry(Entry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除這筆帳目？'),
        content: const Text('刪除後無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('刪除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await ref.read(entriesProvider.notifier).remove(e.id);
    } on LedgerException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('刪除失敗，請稍後再試');
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);
    final categories = ref.watch(categoriesProvider);
    final all = ref.watch(entriesProvider);
    final closes = ref.watch(monthClosesProvider);

    // v1.5 沒有視角：同帳本的帳目全部可見，只依月份／區間、分類篩。
    final filtered = [
      for (final e in all)
        if (_inPeriod(e) && (_filterCategoryId == null || e.categoryId == _filterCategoryId)) e,
    ]..sort(switch (_sort) {
        _EntrySort.created => _cmpCreatedDesc,
        _EntrySort.amountDesc => (a, b) {
            final c = b.amount.compareTo(a.amount);
            return c != 0 ? c : _cmpCreatedDesc(a, b);
          },
        _EntrySort.amountAsc => (a, b) {
            final c = a.amount.compareTo(b.amount);
            return c != 0 ? c : _cmpCreatedDesc(a, b);
          },
      });

    // 摘要吃整個篩選結果（不受分頁影響）；v1.5 起一律全額，沒有份額換算。
    var income = 0, expense = 0;
    for (final e in filtered) {
      if (e.isExpense) {
        expense += e.amount;
      } else {
        income += e.amount;
      }
    }

    // 共同餘額＝Σ共同收入 − Σ共同錢包支出，桶末水位（spec v1.5「三個數」）。
    // 正式值由 DB 的 `month_summary` 算（monthSummaryProvider）；server 還沒回應時
    // 先吃前端同一條公式的 fallback，避免摘要列閃一格空白。
    final sharedBalanceValue = ref.watch(monthSummaryProvider(_until)).value?.sharedBalance ??
        sharedBalance(entries: all, until: _until);

    final paged = filtered.take(_visibleCount).toList();
    final hasMore = filtered.length > _visibleCount;

    // 依日分組只在預設排序有意義；金額排序時攤平不分組。
    final grouped = _sort == _EntrySort.created;
    final groups = <DateTime, List<Entry>>{};
    for (final e in paged) {
      final k = _dayOf(e.occurredOn);
      (groups[k] ??= []).add(e);
    }
    final days = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    // 被沖銷的原筆：沖銷筆備註帶「#原id前8碼」，比對出配對集合。
    final reversedTags = <String>{
      for (final e in all)
        if (e.isAdjustment)
          ...RegExp(r'#([0-9A-Za-z-]{8})').allMatches(e.note).map((m) => m.group(1)!),
    };
    bool isReversed(Entry e) =>
        !e.isAdjustment && e.id.length >= 8 && reversedTags.contains(e.id.substring(0, 8));

    // 沖銷與被沖銷是不可變軌跡：不可編輯也不可刪（Mike 裁示 2026-09-04），整排滑動動作拿掉。
    // 已清帳月份（含更早月份）的帳目同款處理（v1.4 鎖月）：滑開只會撞上 DB trigger。
    Widget entryRow(Entry e) {
      final immutable = e.isAdjustment || isReversed(e) || isMonthClosed(closes, e.occurredOn);
      final tile = _EntryTile(
        entry: e,
        categories: categories,
        members: members,
        reversed: isReversed(e),
        onTap: () => context.push('/entries/${e.id}'),
      );
      if (immutable) return tile;
      return Slidable(
          key: ValueKey('slide-${e.id}'),
          endActionPane: ActionPane(
            motion: const DrawerMotion(),
            extentRatio: 0.34,
            children: [
              // 圓形 icon、無文字（Mike 裁示 2026-09-03）。
              CircleSlideAction(
                icon: Icons.edit_outlined,
                background: Theme.of(context).colorScheme.secondaryContainer,
                foreground: Theme.of(context).colorScheme.onSecondaryContainer,
                tooltip: '編輯',
                onPressed: () => context.push('/entries/${e.id}?edit=1'),
              ),
              CircleSlideAction(
                icon: Icons.delete_outline,
                background: Theme.of(context).colorScheme.errorContainer,
                foreground: Theme.of(context).colorScheme.onErrorContainer,
                tooltip: '刪除',
                onPressed: () => _deleteEntry(e),
              ),
            ],
          ),
          child: tile,
        );
    }

    return Scaffold(
      appBar: MonthAppBar(
        month: _month,
        onMonthChanged: _setMonth,
        leading: IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜尋',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const EntrySearchPage()),
          ),
        ),
        actions: [
          IconButton(
            key: tutorialKey('settings-gear'),
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: tutorialKey('fab-add'),
        heroTag: 'fab-entries', // 兩個 tab 各有 FAB，預設 hero tag 會相撞

        onPressed: () => context.push('/entries/new'),
        icon: const Icon(Icons.add),
        label: const Text('新增'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              children: [
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      // 滑近底部就再放 20 筆（資料已在快照裡，放行渲染即可）。
                      if (hasMore && n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
                        setState(() => _visibleCount += _pageSize);
                      }
                      return false;
                    },
                    child: ListView(
                    key: tutorialKey('entry-list'),
                    padding: const EdgeInsets.only(bottom: 96),
                    children: [
                      _MonthSummary(
                          income: income, expense: expense, sharedBalance: sharedBalanceValue),
                      // 篩選與排序列（Mike 裁示 2026-09-03）。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                        child: Row(
                          children: [
                            // chips 水平可捲、標籤不截斷（Mike 裁示 2026-09-03：時間要完整顯示）。
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    _FilterPill(
                                      key: const Key('filter-category-chip'),
                                      label: _filterCategoryName(categories),
                                      active: _filterCategoryId != null,
                                      onTap: () => _pickFilterCategory([...categories]..sort((a, b) => a.sort.compareTo(b.sort))),
                                      onClear: _filterCategoryId == null
                                          ? null
                                          : () => setState(() {
                                                _filterCategoryId = null;
                                                _resetPaging();
                                              }),
                                    ),
                                    const SizedBox(width: 8),
                                    _FilterPill(
                                      key: const Key('filter-range-chip'),
                                      label: _rangeLabel(),
                                      active: _range != null,
                                      onTap: _pickRange,
                                      onClear: _range == null
                                          ? null
                                          : () => setState(() {
                                                _range = null;
                                                _resetPaging();
                                              }),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            PopupMenuButton<_EntrySort>(
                              key: const Key('sort-chip'),
                              initialValue: _sort,
                              tooltip: '排序',
                              onSelected: (v) => setState(() {
                                _sort = v;
                                _resetPaging();
                              }),
                              itemBuilder: (_) => const [
                                PopupMenuItem(key: Key('sort-created'), value: _EntrySort.created, child: Text('建立時間（新→舊）')),
                                PopupMenuItem(key: Key('sort-amount-desc'), value: _EntrySort.amountDesc, child: Text('金額（高→低）')),
                                PopupMenuItem(key: Key('sort-amount-asc'), value: _EntrySort.amountAsc, child: Text('金額（低→高）')),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.swap_vert, size: 18),
                                    const SizedBox(width: 2),
                                    Text(_sortLabel(), style: Theme.of(context).textTheme.labelSmall),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (paged.isEmpty) const _EmptyState(),
                      if (grouped)
                        for (final d in days) ...[
                          _DayHeader(
                            day: d,
                            subtotal: groups[d]!.fold<int>(
                              0,
                              // 損益慣例：收入正、支出負，與列上金額的 +/− 一致。
                              (a, e) => a + (e.isExpense ? -e.amount : e.amount),
                            ),
                          ),
                          Card(
                            clipBehavior: Clip.antiAlias, // 左滑動作背景不露出圓角外
                            child: Column(children: [for (final e in groups[d]!) entryRow(e)]),
                          ),
                        ]
                      else if (paged.isNotEmpty)
                        // 金額排序：跨日攤平、不分組（分組會打斷排序）。
                        Card(
                          clipBehavior: Clip.antiAlias,
                          child: Column(children: [for (final e in paged) entryRow(e)]),
                        ),
                      if (hasMore)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Center(
                            child: Text('往下滑載入更多（${paged.length}/${filtered.length}）',
                                key: const Key('load-more-hint'),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                          ),
                        ),
                    ],
                  ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _filterCategoryName(List<Category> categories) {
    if (_filterCategoryId == null) return '全部分類';
    for (final c in categories) {
      if (c.id == _filterCategoryId) return c.name;
    }
    return '分類';
  }

  String _rangeLabel() {
    final r = _range;
    if (r == null) return '本月';
    return '${r.start.month}/${r.start.day}–${r.end.month}/${r.end.day}';
  }

  String _sortLabel() => switch (_sort) {
        _EntrySort.created => '最新',
        _EntrySort.amountDesc => '金額高→低',
        _EntrySort.amountAsc => '金額低→高',
      };
}

/// 月摘要：收入／支出吃當前篩選結果，共同餘額是桶末水位（`month_summary` RPC）。
class _MonthSummary extends StatelessWidget {
  const _MonthSummary({
    required this.income,
    required this.expense,
    required this.sharedBalance,
  });
  final int income;
  final int expense;

  /// Σ共同收入 − Σ共同錢包支出（spec v1.5「三個數」）。
  final int sharedBalance;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget cell(String label, int value, Color color) => Expanded(
          child: Column(
            children: [
              Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 4),
              Text(fmtAmount(value),
                  style: t.textTheme.titleMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  )),
            ],
          ),
        );
    return Card(
      key: const Key('month-summary'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          children: [
            cell('收入', income, incomeColor(context)),
            cell('支出', expense, t.colorScheme.onSurface),
            cell('共同餘額', sharedBalance,
                sharedBalance < 0 ? t.colorScheme.error : t.colorScheme.onSurface),
          ],
        ),
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.day, required this.subtotal});
  final DateTime day;
  final int subtotal;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant, letterSpacing: 0.8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(fmtDate(day), style: style),
          Text('小計 ${fmtAmount(subtotal)}',
              style: style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.categories,
    required this.members,
    required this.onTap,
    this.reversed = false,
  });
  final Entry entry;
  final List<Category> categories;
  final List<Member> members;
  final VoidCallback onTap;

  /// 這筆已被沖銷（有對應反向紀錄）：與沖銷筆同組弱化配色＋刪除線。
  final bool reversed;

  String _categoryName() {
    for (final c in categories) {
      if (c.id == entry.categoryId) return c.name;
    }
    return '未分類';
  }

  String _iconName() {
    for (final c in categories) {
      if (c.id == entry.categoryId) return c.icon;
    }
    return 'more_horiz';
  }

  /// 付款人 chip 的文字：成員 `displayName`，`payerId == null` ＝共同錢包（spec v1.5「帳目」）。
  String _payerLabel() {
    final id = entry.payerId;
    if (id == null) return '共同';
    for (final m in members) {
      if (m.id == id) return m.displayName;
    }
    return '成員';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // 沖銷配對（Mike 裁示 2026-09-04）：被沖銷＝偏紅、沖銷筆＝偏藍，正常筆不變。
    final Color? inkColor = reversed
        ? t.colorScheme.error
        : entry.isAdjustment
            ? (t.brightness == Brightness.dark ? Colors.lightBlue.shade300 : Colors.blue.shade700)
            : null;
    final tags = <String>[
      if (reversed) '已沖銷',
      if (entry.isAdjustment) '沖銷',
      if (entry.lineItems.isNotEmpty) '細項 ${entry.lineItems.length}',
    ];
    final title = entry.note.isEmpty ? _categoryName() : entry.note;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: t.colorScheme.surfaceContainerHighest,
              child: Icon(categoryIcon(_iconName()), size: 18, color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.bodyLarge?.copyWith(
                              color: inkColor,
                              decoration: reversed ? TextDecoration.lineThrough : null,
                              decorationColor: inkColor,
                            )),
                      ),
                    ],
                  ),
                  // 收入且無標籤時整塊不畫：不留一條空 Wrap 撐出多餘的 4px。
                  if (entry.isExpense || tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          // 誰先付（spec v1.5）：支出才有，收入一律共同收入、不顯示。
                          if (entry.isExpense)
                            _Tag(
                              key: Key('payer-chip-${entry.id}'),
                              text: _payerLabel(),
                              tone: t.colorScheme.primary,
                            ),
                          for (final x in tags)
                            _Tag(
                              text: x,
                              tone: x == '已沖銷'
                                  ? t.colorScheme.error
                                  : x == '沖銷'
                                      ? (t.brightness == Brightness.dark
                                          ? Colors.lightBlue.shade300
                                          : Colors.blue.shade700)
                                      : t.colorScheme.onSurfaceVariant,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              entry.isExpense ? fmtAmount(entry.amount) : '+${fmtAmount(entry.amount)}',
              style: t.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: inkColor ?? (entry.isExpense ? t.colorScheme.onSurface : incomeColor(context)),
                decoration: reversed ? TextDecoration.lineThrough : null,
                decorationColor: inkColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({super.key, required this.text, required this.tone});
  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined, size: 40, color: t.colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text('這個月還沒有紀錄', style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text('點右下角「新增」記第一筆', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 篩選 pill：自組（Container＋padding＋Text），不用 Chip——
/// Mike 裝置上 Chip 的內建標籤量寬會把 CJK 量窄導致硬截字（2026-09-04 實錄，
/// 同頁自組的「細項 N」徽章正常），改用與徽章相同的機制就地免疫。
class _FilterPill extends StatelessWidget {
  const _FilterPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    this.onClear,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: active ? t.colorScheme.secondaryContainer : t.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: active ? Colors.transparent : t.colorScheme.outlineVariant),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  softWrap: false,
                  style: t.textTheme.labelLarge?.copyWith(
                      color: active ? t.colorScheme.onSecondaryContainer : t.colorScheme.onSurface)),
              if (onClear != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onClear,
                  child: Icon(Icons.close, size: 15,
                      color: active ? t.colorScheme.onSecondaryContainer : t.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
