import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../app/month_app_bar.dart';
import '../../domain/balance_math.dart';
import '../../data/month_summary_provider.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'pie_card.dart';
import 'stats_card.dart';
import 'trend_card.dart';
import 'trend_math.dart';
import 'view_math.dart';

/// 統計頁：月摘要、支出圓餅、趨勢線；家庭三條（花費／共同餘額／超支）、個人兩條
/// （花費／個人餘額）（ADR-0003、ADR-0008）。
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  late DateTime _month = monthOf(DateTime.now());
  ViewMode _mode = ViewMode.family;
  PieBy _pieBy = PieBy.category;
  bool _weekly = false;
  DateTime? _week;
  Granularity _granularity = Granularity.month;

  void _setMonth(DateTime m) => setState(() {
        _month = DateTime(m.year, m.month, 1);
        _week = null; // 換月後週選擇重算，不沿用上個月的那一週
      });

  void _setMode(ViewMode m) => setState(() {
        _mode = m;
        // 個人視角沒有「依成員」：state 一併拉回，免得切回家庭時
        // 冒出一個使用者在個人視角根本看不到、也沒選過的選擇。
        if (m == ViewMode.personal) _pieBy = PieBy.category;
      });

  /// 目前選到的那一週；沒選過就用含今天的那一週（本月不含今天時退回該月第一週）。
  WeekRange _resolveWeek(List<WeekRange> weeks) {
    final picked = _week;
    if (picked != null) {
      for (final w in weeks) {
        if (w.start == picked) return w;
      }
    }
    final today = dateOnly(DateTime.now());
    for (final w in weeks) {
      if (inRange(today, w.start, w.end)) return w;
    }
    return weeks.first;
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final me = ref.watch(currentMemberIdProvider);
    final members = ref.watch(membersProvider);
    final categories = ref.watch(categoriesProvider);
    final entries = ref.watch(entriesProvider);
    final allocations = ref.watch(allocationsProvider);
    final closes = ref.watch(monthClosesProvider);

    Member? found;
    for (final m in members) {
      if (m.id == me) found = m;
    }
    // final 才能在下面的 closure 裡吃到型別提升（非 final 的區域變數在 closure 內不提升）。
    final meMember = found;

    final personal = _mode == ViewMode.personal;
    final items = viewEntries(entries, _mode, me, ledger.defaultRatio);

    // 餘額（ADR-0008，v1.4）：家庭＝共同餘額、個人＝個人餘額（額度制）。
    //
    // 個人餘額有一個 DB 模型必然的月份語意（spec v1.4「個人餘額」「清帳」）：清帳把
    // 該月從公式移除，所以問「已清帳月份」不管是即時公式還是 server `month_summary`
    // 恆得到 0——這不是 bug，是清帳的定義；該月唯一還留著的事實是清帳當下寫進
    // `MonthClose.details` 的快照（`ending`）。**只有這個月真的有一列清帳紀錄時**才
    // 改讀快照，蓋過即時公式與 server 值；快照裡找不到本人（有列，但那一列沒有本人
    // 這一行——資料異常）不假裝有一個算得出來的數字。
    //
    // 「≤ 最後清帳月但這個月本身沒有列」（帳本開始前的前史月份）刻意不算「有清帳」：
    // 落回即時公式，公式自己會因為 `isMonthClosed` 的級聯定義把這種月份的 N 與淨變動
    // 都算成 0——「這個月你根本還沒存在」跟「這個月清過帳、找不到你」是兩回事，
    // 前者該顯示 0，後者才顯示「—」。
    int familyBalanceAt(DateTime until) =>
        sharedBalance(ledger: ledger, entries: entries, until: until);
    int personalFormulaAt(DateTime until) => meMember == null
        ? 0
        : personalBalance(
            member: meMember,
            entries: entries,
            closes: closes,
            until: until,
            joinedMonth: monthOf(meMember.joinedAt),
          );
    bool hasCloseRow(DateTime until) => closes.any((c) => sameMonth(c.month, until));

    // 月摘要卡永遠是「月」層級。
    final cardUntil = lastDayOfMonth(_month);
    final cardClosed = personal && meMember != null && hasCloseRow(cardUntil);

    // 月摘要卡的餘額改吃 DB month_summary（Mike 裁示 2026-09-03）；趨勢線的
    // 逐桶餘額仍是前端依 server 列現算（逐桶打 RPC 成本過高，已記驗證債）。
    final server = ref.watch(monthSummaryProvider(cardUntil)).value;
    // null＝已清帳但快照裡找不到本人，_SummaryCard 直接讀 summary.balance == null
    // 顯示「—」，不另外傳一個獨立的 dash 旗標。
    final int? cardBalance = !personal
        ? (server?.sharedBalance ?? familyBalanceAt(cardUntil))
        : cardClosed
            ? closedEndingFor(closes, meMember.id, cardUntil)
            : (server?.personalBalance ?? personalFormulaAt(cardUntil));
    final summary = monthSummary(items: items, month: _month, balance: cardBalance);
    // 看未來月：個人餘額（即時公式與 server 皆同）以「今天所在月」為上界，等於
    // 「不含未來補入額」的保守投影（spec v1.4「個人餘額」N 的定義）；卡片加一行小字
    // 提醒，不是另一套算法。家庭視角未來月無小字（共同餘額沒有「未來補入額」這回事）。
    final showProjectionNote = personal && _month.isAfter(monthOf(DateTime.now()));

    // 趨勢線的餘額：家庭恆用即時公式；個人「這個月有清帳列」時只有「月」顆粒度用
    // 快照——日／週／年顆粒度落在那個月的桶不畫點（`null`＝線斷開，見
    // Bucket.balance），快照是整月一筆事實，硬塞進更細的顆粒度會變成同一個數字
    // 連續畫好幾點，誤導使用者。前史月份（沒有清帳列）一律落回即時公式（見上）。
    final int? Function(DateTime until) trendBalanceAt = personal
        ? (until) {
            if (meMember != null && hasCloseRow(until)) {
              if (_granularity != Granularity.month) return null;
              return closedEndingFor(closes, meMember.id, until);
            }
            return personalFormulaAt(until);
          }
        : familyBalanceAt;

    final weeks = weekRangesOfMonth(_month);
    final week = _resolveWeek(weeks);
    final pieStart = _weekly ? week.start : _month;
    final pieEnd = _weekly ? week.end : lastDayOfMonth(_month);
    // 個人視角只能依分類（依成員的 payer 歸戶與份額金額混用會誤讀）。
    final pieBy = personal ? PieBy.category : _pieBy;
    final slices = pieSlices(
      items.where((i) => inRange(i.entry.occurredOn, pieStart, pieEnd)),
      pieBy,
    );

    // 順序即配色索引：圓餅與趨勢用同一套，同分類同色且不隨金額排序而變。
    final expenseCats = [
      for (final c in categories)
        if (c.kind == EntryKind.expense) c,
    ];

    // 超支線的視角差異（ADR-0008，v1.4）：家庭＝當月超支合計；個人沒有預算，恆 0。
    final trendInput = TrendInput(
      items: items,
      categories: categories,
      balanceAt: trendBalanceAt,
      overspendAt: personal
          ? (_) => 0
          : (until) => totalOverspend(
                entries: entries,
                allocations: allocations,
                until: until,
              ),
      categoryOverspendAt: personal
          ? (_, _) => 0
          : (categoryId, until) => overspend(
                allocations: allocations,
                entries: entries,
                categoryId: categoryId,
                until: until,
              ),
    );
    final buckets = bucketize(trendInput, _granularity, _month);
    final byCategory = bucketizeByCategory(trendInput, _granularity, _month);

    return Scaffold(
      // 與帳目頁共用同一個頂部列：月份標題與視角切換的高度、間距、位置完全一致。
      appBar: MonthAppBar(
        month: _month,
        onMonthChanged: _setMonth,
        view: _mode,
        onViewChanged: _setMode,
      ),
      body: _Centered(
        child: ListView(
          // 左右留白由 theme 的 cardTheme.margin（h16）提供，這裡只給上下。
          padding: const EdgeInsets.fromLTRB(0, 10, 0, 32),
          children: [
            _SummaryCard(
              summary: summary,
              mode: _mode,
              showProjectionNote: showProjectionNote,
            ),
            PieCard(
              // 月模式不給副標：期間就是 AppBar 那個月，而「整月」已寫在切換鍵上。
              periodLabel: _weekly ? weekRangeLabel(week) : null,
              slices: slices,
              by: pieBy,
              onByChanged: (v) => setState(() => _pieBy = v),
              showByToggle: !personal,
              weekly: _weekly,
              onWeeklyChanged: (v) => setState(() => _weekly = v),
              weeks: weeks,
              week: week,
              onWeekChanged: (w) => setState(() => _week = w.start),
              labelFor: (key) => _labelFor(key, pieBy, categories, members),
              colorIndexFor: (key) => _colorIndexFor(key, pieBy, expenseCats, members),
            ),
            TrendCard(
              buckets: buckets,
              byCategory: byCategory,
              expenseCategories: expenseCats,
              granularity: _granularity,
              onGranularityChanged: (v) => setState(() => _granularity = v),
              viewMode: _mode,
            ),
          ],
        ),
      ),
    );
  }

  String _labelFor(String key, PieBy by, List<Category> categories, List<Member> members) {
    if (by == PieBy.category) {
      for (final c in categories) {
        if (c.id == key) return c.name;
      }
      return '未分類';
    }
    if (key == kCommonWalletKey) return '共同錢包';
    for (final m in members) {
      if (m.id == key) return m.displayName;
    }
    return '未知成員';
  }

  /// 配色索引：分類用支出分類的固定順序、成員用成員順序（共同錢包排 0）。
  /// 不用「圓餅切片名次」當索引——那會讓同一個分類換個月就換色。
  /// 查不到回 -1，由 [sliceColorAt] 給中性灰（不退回 0，免得和第一個分類撞色）。
  int _colorIndexFor(String key, PieBy by, List<Category> expenseCats, List<Member> members) {
    if (by == PieBy.category) {
      return expenseCats.indexWhere((c) => c.id == key);
    }
    if (key == kCommonWalletKey) return 0;
    final i = members.indexWhere((m) => m.id == key);
    return i < 0 ? -1 : i + 1;
  }
}

/// [until] 所在月的清帳快照裡，[memberId] 的月末餘額（spec v1.4「個人餘額」
/// 「清帳」，ADR-0008）。
///
/// **只能在確定 [until] 所在月真的有一列清帳紀錄時呼叫**（呼叫端自己先判斷，
/// 例如 `closes.any((c) => sameMonth(c.month, until))`）——這裡不重新判斷「有沒有
/// 清帳」，只管「那一列裡有沒有這個人」。首次可清月之前的前史月份沒有列，那是
/// 呼叫端該用即時公式（自然算出 0）的情況，不歸這個函式管，見呼叫端註解。
///
/// 找不到本人（有列，但那一列沒有這個人這一行——資料異常，理論上不會發生）回傳
/// null，呼叫端顯示「—」，不假裝有一個算得出來的數字。
int? closedEndingFor(List<MonthClose> closes, String memberId, DateTime until) {
  for (final c in closes) {
    if (!sameMonth(c.month, until)) continue;
    for (final line in c.details.members) {
      if (line.memberId == memberId) return line.ending;
    }
    return null; // 找到列，但那一列沒有本人
  }
  return null; // 防禦性寫法：呼叫端理論上已保證這裡一定找得到列
}

/// 桌面寬度不爆版：內容置中並限寬 560。
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: child),
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.mode,
    required this.showProjectionNote,
  });

  final MonthSummary summary;

  /// balance 格的字面依視角借用趨勢 legend 的同一個 label（v1.4）：家庭「共同餘額」、
  /// 個人「個人餘額」——兩處同一個量、同一個 source，不會各自漂移。
  final ViewMode mode;

  /// 看未來月時加一行小字提醒：這個數字不含未來月的補入額（見 [_StatsPageState.build]）。
  final bool showProjectionNote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return StatsCard(
      title: '月摘要',
      // 兩行各兩格（Mike 裁示 2026-09-03）：上行收入／支出、下行損益／餘額。
      child: Column(
        key: const Key('month-summary'),
        children: [
          Row(
            children: [
              _Figure(label: '收入', value: summary.income, color: cs.primary),
              _Figure(label: '支出', value: summary.expense, color: cs.error),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _Figure(
                label: '損益',
                value: summary.net,
                color: summary.net >= 0 ? cs.primary : cs.error,
              ),
              _Figure(
                label: TrendLine.balance.labelFor(mode),
                value: summary.balance,
                color: cs.onSurface,
              ),
            ],
          ),
          if (showProjectionNote) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '投影（不含未來補入額）',
                key: const Key('personal-balance-projection-note'),
                style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.color});

  final String label;

  /// `null`＝顯示「—」代替一個數字（已清帳月快照裡找不到本人，資料異常）。
  final int? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value == null ? '—' : fmtAmount(value!),
              style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700, color: color, fontFeatures: kTabularFigures),
            ),
          ),
        ],
      ),
    );
  }
}
