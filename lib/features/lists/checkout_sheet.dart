/// 購物清單「勾選結帳」底部 sheet：單勾或多選都走這裡。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/category_wheel.dart';
import '../../app/format.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import '../entries/split_math.dart';
import 'checkout.dart';

Future<void> showCheckoutSheet({required BuildContext context, required List<ListItem> items}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => CheckoutSheet(items: items),
  );
}

/// 結帳表單：
/// - 單項：只有一個「金額」欄（預填 estimated），entry.amount 就是該欄。
/// - 多項：每項一個「金額」欄（預填 estimated），下方「總計」是唯讀、自動加總、即時更新（Mike 手測裁示，不可手改）。
/// - 任一金額欄為空／非數字／≤0 時確認鈕 disabled，並在該欄顯示錯誤提示。
/// 分類預設第一項的分類可改；日期預設今天（date-only）。
class CheckoutSheet extends ConsumerStatefulWidget {
  const CheckoutSheet({super.key, required this.items});
  final List<ListItem> items;

  @override
  ConsumerState<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends ConsumerState<CheckoutSheet> {
  final _actualCtrls = <String, TextEditingController>{};
  late String? _categoryId;
  late DateTime _date;
  bool _submitting = false;
  String? _error;

  // 結帳方式（Mike 裁示 2026-09-04：與支出表單同一組選項與規則）。
  String? _payerId; // null＝共同錢包
  SplitMethod _method = SplitMethod.common;
  Funding _funding = Funding.balance;
  bool _fundingTouched = false;
  final _ratioCtrls = <String, TextEditingController>{};
  final _manualCtrls = <String, TextEditingController>{};

  TextEditingController _ratioOf(String memberId) => _ratioCtrls.putIfAbsent(
        memberId,
        () => TextEditingController(text: '${ref.read(ledgerProvider).defaultRatio[memberId] ?? 0}'),
      );
  TextEditingController _manualOf(String memberId) =>
      _manualCtrls.putIfAbsent(memberId, () => TextEditingController());

  Map<String, int> get _ratioValues =>
      {for (final e in _ratioCtrls.entries) e.key: int.tryParse(e.value.text.trim()) ?? 0};
  Map<String, int> get _manualValues =>
      {for (final e in _manualCtrls.entries) e.key: int.tryParse(e.value.text.trim()) ?? 0};
  int get _ratioTotal => _ratioValues.values.fold(0, (a, b) => a + b);

  /// 同支出表單 `_syncFunding` 的精簡版：代墊一律 balance；共同錢包未手動選過就吃預設。
  void _syncFunding() {
    if (_payerId != null || _categoryId == null) {
      _funding = Funding.balance;
      _fundingTouched = false;
      return;
    }
    if (_fundingTouched) return;
    _funding = defaultFunding(
      allocations: ref.read(allocationsProvider),
      categoryId: _categoryId!,
      month: _date,
    );
  }

  /// 分攤驗證（擋確認鈕）：比例合計 100、金額分攤合計＝總計。
  String? get _splitError {
    if (_payerId == null) return null;
    if (_method == SplitMethod.ratio && _ratioTotal != 100) return '比例合計需為 100（目前 $_ratioTotal）';
    final t = _total;
    if (_method == SplitMethod.amount && t != null && manualTotal(_manualValues) != t) {
      return '分攤合計 ${fmtAmount(manualTotal(_manualValues))} ≠ 總計 ${fmtAmount(t)}';
    }
    return null;
  }

  bool get _isMulti => widget.items.length > 1;

  @override
  void initState() {
    super.initState();
    for (final item in widget.items) {
      // estimated 缺的項目預填空字串而非 "0"：填 "0" 會因為 ≤0 規則立刻顯示紅字，體驗上更奇怪。
      final text = item.estimated == null ? '' : item.estimated.toString();
      _actualCtrls[item.id] = TextEditingController(text: text)..addListener(_onActualChanged);
    }
    _categoryId = widget.items.first.categoryId;
    final now = DateTime.now();
    _date = DateTime(now.year, now.month, now.day); // date-only：occurred_on 是 date-only 欄位
    _syncFunding();
  }

  /// 多項結帳的「總計」是唯讀自動加總，跟著任一項金額變動即時更新；也連動確認鈕的可按狀態。
  void _onActualChanged() => setState(() {});

  /// 單一金額來源：欄位空白／非數字／≤0 一律回 null（不再偷偷回退成 estimated）。
  /// `_total` 與送出時的 `actuals` 都只透過這裡取值，避免兩處各自 fallback 不一致。
  int? _amountOf(ListItem item) {
    final raw = _actualCtrls[item.id]!.text.trim();
    if (raw.isEmpty) return null;
    final v = int.tryParse(raw);
    if (v == null || v <= 0) return null;
    return v;
  }

  /// 任一項金額無效就是 null——多項的「總計」與確認鈕的 disabled 判斷共用這個。
  int? get _total {
    var sum = 0;
    for (final item in widget.items) {
      final v = _amountOf(item);
      if (v == null) return null;
      sum += v;
    }
    return sum;
  }

  bool get _canSubmit => _categoryId != null && _total != null && _splitError == null;

  @override
  void dispose() {
    for (final c in _actualCtrls.values) {
      c.removeListener(_onActualChanged);
      c.dispose();
    }
    for (final c in _ratioCtrls.values) {
      c.dispose();
    }
    for (final c in _manualCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _date = picked;
        _syncFunding();
      });
    }
  }

  Future<void> _confirm() async {
    final total = _total;
    if (_categoryId == null || total == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      final actuals = <String, int>{for (final item in widget.items) item.id: _amountOf(item)!};
      final entry = buildEntryFromItems(
        items: widget.items,
        actuals: actuals,
        total: total,
        categoryId: _categoryId!,
        date: DateTime(_date.year, _date.month, _date.day),
        ledgerId: ref.read(ledgerProvider).id,
        me: ref.read(currentMemberIdProvider),
        allocations: ref.read(allocationsProvider),
        payerId: _payerId,
        splitMethod: _payerId == null ? SplitMethod.common : _method,
        funding: _payerId == null ? _funding : null,
        members: ref.read(membersProvider),
        ratio: _ratioValues,
        manual: _manualValues,
      );

      // 先建 entry（拿 DB 給的 id）再更新項目；第二步失敗就補償刪掉剛建的 entry、
      // 復原已更新的項目——不留孤兒 entry，也不留「已標完成但 entryId 指向不存在 entry」
      // 的死路（那種狀態使用者無法自救）。兩步之間沒有交易，補償是唯一的保險。
      final saved = await ref.read(entriesProvider.notifier).add(entry);
      final now = DateTime.now();
      final updatedItems = markItemsDone(widget.items, saved.id, now);
      var appliedCount = 0;
      try {
        for (final item in updatedItems) {
          await ref.read(listItemsProvider.notifier).update(item);
          appliedCount++;
        }
      } catch (_) {
        try {
          await ref.read(entriesProvider.notifier).remove(saved.id); // 補償：先撤掉孤兒 entry
          for (var i = 0; i < appliedCount; i++) {
            await ref.read(listItemsProvider.notifier).update(widget.items[i]); // 復原成結帳前的原值
          }
        } catch (_) {
          // 補償本身失敗也不吞掉原因，外層照樣用原始例外走失敗路徑。
        }
        rethrow;
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      // sheet 蓋在最上層，SnackBar 會被擋住看不到：錯誤顯示在 sheet 內。
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e is LedgerException ? e.message : '結帳失敗，請稍後再試';
        });
      }
    }
  }

  /// 結帳方式區（與支出表單同規則）：付款（共同錢包／成員代墊）、分攤、資金來源。
  List<Widget> _paymentSection(BuildContext context) {
    final t = Theme.of(context);
    final members = ref.watch(membersProvider);
    final splitError = _splitError;
    Widget chip(String label, bool selected, VoidCallback onTap, {Key? key}) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ChoiceChip(
            key: key,
            label: Text(label),
            selected: selected,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: _submitting ? null : (_) => onTap(),
          ),
        );
    Widget row(String label, List<Widget> chips) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              SizedBox(width: 56, child: Text(label, style: t.textTheme.bodyMedium)),
              Expanded(child: Wrap(runSpacing: 4, children: chips)),
            ],
          ),
        );

    return [
      row('付款', [
        chip('共同錢包', _payerId == null, key: const Key('checkout-payer-common'), () => setState(() {
              _payerId = null;
              _method = SplitMethod.common;
              _syncFunding();
            })),
        for (final m in members)
          chip(m.displayName, _payerId == m.id, key: Key('checkout-payer-${m.id}'), () => setState(() {
                _payerId = m.id;
                if (_method == SplitMethod.common) _method = SplitMethod.equal;
                _syncFunding();
              })),
      ]),
      if (_payerId == null && _categoryId != null)
        row('資金', [
          chip('預算', _funding == Funding.budget, key: const Key('checkout-funding-budget'), () => setState(() {
                _funding = Funding.budget;
                _fundingTouched = true;
              })),
          chip('餘額', _funding == Funding.balance, key: const Key('checkout-funding-balance'), () => setState(() {
                _funding = Funding.balance;
                _fundingTouched = true;
              })),
        ]),
      if (_payerId != null) ...[
        row('分攤', [
          for (final e in const {
            SplitMethod.equal: ('checkout-split-equal', '均分'),
            SplitMethod.ratio: ('checkout-split-ratio', '比例'),
            SplitMethod.amount: ('checkout-split-amount', '金額'),
          }.entries)
            chip(e.value.$2, _method == e.key, key: Key(e.value.$1), () => setState(() => _method = e.key)),
        ]),
        if (_method == SplitMethod.ratio)
          Padding(
            padding: const EdgeInsets.only(left: 56, top: 2),
            child: Row(
              children: [
                for (final m in members) ...[
                  Expanded(
                    child: TextField(
                      key: Key('checkout-ratio-${m.id}'),
                      controller: _ratioOf(m.id),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(isDense: true, labelText: '${m.displayName} %'),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        if (_method == SplitMethod.amount)
          Padding(
            padding: const EdgeInsets.only(left: 56, top: 2),
            child: Row(
              children: [
                for (final m in members) ...[
                  Expanded(
                    child: TextField(
                      key: Key('checkout-manual-${m.id}'),
                      controller: _manualOf(m.id),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(isDense: true, labelText: m.displayName),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        if (splitError != null)
          Padding(
            padding: const EdgeInsets.only(left: 56, top: 4),
            child: Text(splitError,
                key: const Key('checkout-split-error'),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
          ),
      ],
    ];
  }

  Widget _amountRow(ListItem item) {
    final invalid = _amountOf(item) == null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 16), child: Text(item.title))),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _actualCtrls[item.id],
              keyboardType: TextInputType.number,
              textAlign: TextAlign.end,
              decoration: InputDecoration(isDense: true, errorText: invalid ? '請輸入金額' : null),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).where((c) => c.kind == EntryKind.expense).toList();
    final total = _total;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('確認結帳', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            for (final item in widget.items) _amountRow(item),
            if (_isMulti) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('總計', style: Theme.of(context).textTheme.titleSmall),
                  Text(
                    total == null ? '—' : fmtMoney(total),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('分類', style: Theme.of(context).textTheme.bodyMedium),
            ),
            CategoryWheel(
              key: const Key('checkout-category-wheel'),
              categories: categories..sort((a, b) => a.sort.compareTo(b.sort)),
              selectedId: _categoryId,
              onSelected: (id) => setState(() {
                _categoryId = id;
                _syncFunding();
              }),
            ),
            _dateFieldRow('日期', fmtDate(_date), _pickDate, key: const Key('checkout-date-row')),
            const SizedBox(height: 4),
            ..._paymentSection(context),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _submitting || !_canSubmit ? null : _confirm,
              child: const Text('確認'),
            ),
          ],
        ),
      ),
    );
  }
}


/// 可點的欄位列（如日期／到期日）：整列（含標籤）都能點開選擇器，且點擊高度至少 44px（點擊目標最小尺寸）。
Widget _dateFieldRow(String label, String value, VoidCallback onTap, {Key? key}) {
  return InkWell(
    key: key,
    onTap: onTap,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          SizedBox(width: 56, child: Text(label)),
          Expanded(child: Text(value)),
        ],
      ),
    ),
  );
}
