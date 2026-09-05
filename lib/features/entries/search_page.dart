import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:syncfusion_flutter_charts/charts.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';

/// 一筆搜尋結果（以細項為單位；備註命中的主筆、清單項目也各自成列）。
class SearchHit {
  const SearchHit({
    required this.label,
    required this.subtitle,
    required this.icon,
    this.amount,
    this.date,
    this.entryId,
    this.fromList = false,
  });
  final String label;
  final String subtitle;
  final String icon;
  final int? amount;
  final DateTime? date;
  final String? entryId;
  final bool fromList;
}

/// 純函式：依關鍵字比對細項名、備註、清單標題（大小寫不分、包含即命中）。
///
/// v1.5（ADR-0009）沒有私人範圍：同帳本的帳目全部可見，兩個人記的都搜得到。
List<SearchHit> searchHits({
  required String query,
  required List<Entry> entries,
  required List<ListItem> listItems,
  required List<Category> categories,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  String catName(String id) {
    for (final c in categories) {
      if (c.id == id) return c.name;
    }
    return '未分類';
  }

  String catIcon(String? id) {
    for (final c in categories) {
      if (c.id == id) return c.icon;
    }
    return 'more_horiz';
  }

  final hits = <SearchHit>[];
  for (final e in entries) {
    final tail = e.note.isEmpty ? catName(e.categoryId) : '${catName(e.categoryId)}・${e.note}';
    for (final li in e.lineItems) {
      if (!li.name.toLowerCase().contains(q)) continue;
      hits.add(SearchHit(
        label: li.name,
        subtitle: tail,
        icon: catIcon(e.categoryId),
        amount: li.amount,
        date: e.occurredOn,
        entryId: e.id,
      ));
    }
    if (e.note.isNotEmpty && e.note.toLowerCase().contains(q)) {
      hits.add(SearchHit(
        label: e.note,
        subtitle: catName(e.categoryId),
        icon: catIcon(e.categoryId),
        amount: e.amount,
        date: e.occurredOn,
        entryId: e.id,
      ));
    }
  }
  for (final i in listItems) {
    if (!i.title.toLowerCase().contains(q)) continue;
    hits.add(SearchHit(
      label: i.title,
      subtitle: i.isTodo ? '待辦' : (i.store ?? catName(i.categoryId!)),
      icon: catIcon(i.categoryId),
      amount: i.estimated,
      date: i.doneAt ?? i.dueOn,
      entryId: i.entryId,
      fromList: true,
    ));
  }
  hits.sort((a, b) {
    final da = a.date, db = b.date;
    if (da == null && db == null) return 0;
    if (da == null) return 1;
    if (db == null) return -1;
    return db.compareTo(da);
  });
  return hits;
}

/// 同名品項（帳目細項、有金額）≥2 筆的價格序列，用來畫折線。
Map<String, List<SearchHit>> priceSeries(List<SearchHit> hits) {
  final byName = <String, List<SearchHit>>{};
  for (final h in hits) {
    if (h.fromList || h.amount == null || h.date == null) continue;
    (byName[h.label] ??= []).add(h);
  }
  byName.removeWhere((_, v) => v.length < 2);
  for (final v in byName.values) {
    v.sort((a, b) => a.date!.compareTo(b.date!));
  }
  return byName;
}

/// 品項模糊搜尋頁：即時過濾細項／備註／清單。
class EntrySearchPage extends ConsumerStatefulWidget {
  const EntrySearchPage({super.key});

  @override
  ConsumerState<EntrySearchPage> createState() => _EntrySearchPageState();
}

class _EntrySearchPageState extends ConsumerState<EntrySearchPage> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final hits = searchHits(
      query: _query.text,
      entries: ref.watch(entriesProvider),
      listItems: ref.watch(listItemsProvider),
      categories: ref.watch(categoriesProvider),
    );
    final series = priceSeries(hits);
    final empty = _query.text.trim().isEmpty;

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          key: const Key('search-field'),
          controller: _query,
          autofocus: true,
          decoration: const InputDecoration(hintText: '搜尋品項、備註、清單', isDense: true),
          onChanged: (_) => setState(() {}),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: empty
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text('輸入品項名稱、備註或清單項目開始搜尋',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  )
                : hits.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('找不到符合的品項',
                            style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                        children: [
                          for (final e in series.entries) _PriceCard(name: e.key, points: e.value),
                          Card(
                            key: const Key('search-results'),
                            margin: EdgeInsets.zero,
                            child: Column(
                              children: [
                                for (final h in hits)
                                  _HitTile(
                                    hit: h,
                                    onTap: h.entryId == null ? null : () => context.push('/entries/${h.entryId}'),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
          ),
        ),
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({required this.hit, required this.onTap});
  final SearchHit hit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: t.colorScheme.surfaceContainerHighest,
              child: Icon(categoryIcon(hit.icon), size: 16, color: t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(hit.label,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge),
                      ),
                      if (hit.fromList) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: t.colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('清單',
                              style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    hit.date == null ? hit.subtitle : '${fmtDate(hit.date!)}・${hit.subtitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(hit.amount == null ? '—' : fmtAmount(hit.amount!),
                style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.name, required this.points});
  final String name;
  final List<SearchHit> points;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$name 價格變化', style: t.textTheme.titleSmall),
            Text('${points.length} 筆紀錄・${fmtDate(points.first.date!)} 起',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            SizedBox(
              height: 160,
              child: SfCartesianChart(
                margin: EdgeInsets.zero,
                plotAreaBorderWidth: 0,
                primaryXAxis: DateTimeAxis(
                  dateFormat: DateFormat('M/d'),
                  majorGridLines: const MajorGridLines(width: 0),
                  labelStyle: t.textTheme.labelSmall ?? const TextStyle(),
                  edgeLabelPlacement: EdgeLabelPlacement.shift,
                ),
                primaryYAxis: NumericAxis(
                  numberFormat: NumberFormat('#,###'),
                  majorGridLines: MajorGridLines(width: 0.5, color: t.colorScheme.outlineVariant),
                  labelStyle: t.textTheme.labelSmall ?? const TextStyle(),
                ),
                trackballBehavior: TrackballBehavior(
                  enable: true,
                  activationMode: ActivationMode.singleTap,
                  tooltipDisplayMode: TrackballDisplayMode.floatAllPoints,
                ),
                series: <CartesianSeries<SearchHit, DateTime>>[
                  LineSeries<SearchHit, DateTime>(
                    name: name,
                    dataSource: points,
                    xValueMapper: (h, _) => h.date!,
                    yValueMapper: (h, _) => h.amount,
                    color: t.colorScheme.primary,
                    width: 2,
                    markerSettings: const MarkerSettings(isVisible: true),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
