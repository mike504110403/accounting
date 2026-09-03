/// 購物清單「勾選結帳」底部 sheet：單勾或多選都走這裡。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
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

  bool get _canSubmit => _categoryId != null && _total != null;

  @override
  void dispose() {
    for (final c in _actualCtrls.values) {
      c.removeListener(_onActualChanged);
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
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _confirm() async {
    final total = _total;
    if (_categoryId == null || total == null) return;
    setState(() => _submitting = true);

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
      );

      // 先 add entry；項目更新中途失敗就補償刪掉 entry、復原已更新的項目，不留孤兒 entry、
      // 也不留「已標完成但 entryId 指向不存在 entry」的死路（那種狀態使用者無法自救）。
      ref.read(entriesProvider.notifier).add(entry);
      final now = DateTime.now();
      final updatedItems = markItemsDone(widget.items, entry.id, now);
      var appliedCount = 0;
      try {
        for (final item in updatedItems) {
          ref.read(listItemsProvider.notifier).update(item);
          appliedCount++;
        }
      } catch (_) {
        ref.read(entriesProvider.notifier).remove(entry.id); // 補償：先撤掉孤兒 entry
        try {
          for (var i = 0; i < appliedCount; i++) {
            ref.read(listItemsProvider.notifier).update(widget.items[i]); // 復原成結帳前的原值
          }
        } catch (_) {
          // 復原本身失敗也不吞掉原因，外層照樣用原始例外走失敗路徑。
        }
        rethrow;
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('結帳失敗，請稍後再試')));
        setState(() => _submitting = false);
      }
    }
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
            _fieldRow(
              '分類',
              DropdownButtonFormField<String>(
                initialValue: _categoryId,
                isDense: true,
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
                items: [for (final c in categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            ),
            _dateFieldRow('日期', fmtDate(_date), _pickDate, key: const Key('checkout-date-row')),
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

/// 資訊密度：欄位標籤在左、輸入在右，單行。
Widget _fieldRow(String label, Widget input) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(width: 56, child: Text(label)),
        Expanded(child: input),
      ],
    ),
  );
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
