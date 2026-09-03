import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/category_icon.dart';
import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'split_math.dart';

/// 新增／編輯帳目的全螢幕表單。entryId 為 null ＝ 新增。
///
/// 版面依 spec v1.1「資訊密度」：單一平面列表、細標題分段、說明只在錯誤時出現、
/// 折疊區收起只留一行摘要、儲存鈕固定在底部。
class EntryFormPage extends ConsumerStatefulWidget {
  const EntryFormPage({super.key, this.entryId});
  final String? entryId;

  @override
  ConsumerState<EntryFormPage> createState() => _EntryFormPageState();
}

/// 金額輸入：只收數字，開頭至多一個負號，且只有修正筆允許負號（spec：金額整數元，修正筆可負）。
class _AmountFormatter extends TextInputFormatter {
  const _AmountFormatter({required this.allowNegative});
  final bool allowNegative;

  static final _positive = RegExp(r'^\d*$');
  static final _signed = RegExp(r'^-?\d*$');

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.isEmpty) return newValue;
    return (allowNegative ? _signed : _positive).hasMatch(newValue.text) ? newValue : oldValue;
  }
}

class _LineRow {
  _LineRow({String name = '', String amount = ''})
      : name = TextEditingController(text: name),
        amount = TextEditingController(text: amount);
  final TextEditingController name;
  final TextEditingController amount;

  void dispose() {
    name.dispose();
    amount.dispose();
  }
}

class _EntryFormPageState extends ConsumerState<EntryFormPage> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _lines = <_LineRow>[];
  final _manual = <String, TextEditingController>{};
  final _ratio = <String, TextEditingController>{};

  EntryKind _kind = EntryKind.expense;
  EntryScope _scope = EntryScope.shared;
  String? _categoryId;
  DateTime _date = DateTime.now();
  String? _payerId; // null ＝ 共同錢包
  SplitMethod _method = SplitMethod.common;
  bool _isAdjustment = false;
  Entry? _original;
  bool _missing = false;

  /// 分攤欄位的 controller 延後到用得到時才建立：成員清單變動（加入新成員、切帳本）
  /// 也不會出現沒有 controller 的成員。
  TextEditingController _manualOf(String memberId) =>
      _manual.putIfAbsent(memberId, () => TextEditingController());
  TextEditingController _ratioOf(String memberId) => _ratio.putIfAbsent(
        memberId,
        () => TextEditingController(text: '${ref.read(ledgerProvider).defaultRatio[memberId] ?? 0}'),
      );

  @override
  void initState() {
    super.initState();
    final id = widget.entryId;
    if (id == null) return;

    Entry? found;
    for (final e in ref.read(entriesProvider)) {
      if (e.id == id) found = e;
    }
    if (found == null) {
      _missing = true;
      return;
    }
    _original = found;
    _kind = found.kind;
    _scope = found.scope;
    _amount.text = found.amount.toString();
    _note.text = found.note;
    _categoryId = found.categoryId;
    _date = found.occurredOn;
    _payerId = found.payerId;
    _method = found.splitMethod;
    _isAdjustment = found.isAdjustment;
    for (final li in found.lineItems) {
      _lines.add(_LineRow(name: li.name, amount: li.amount?.toString() ?? ''));
    }
    for (final s in found.splits) {
      _manualOf(s.memberId).text = s.share.round().toString();
      // 既有 ratio 筆：從 splits 反推百分比帶回表單。
      if (found.splitMethod == SplitMethod.ratio && found.amount != 0) {
        _ratioOf(s.memberId).text = '${(s.share / found.amount * 100).round()}';
      }
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    for (final c in _manual.values) {
      c.dispose();
    }
    for (final c in _ratio.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 已結帳或結算中都鎖金額／付款來源／分攤／範圍（結算中改動會讓 settlement 作廢，ADR-0002）。
  bool get _locked => _settled || _settling;
  bool get _settled => _original?.amountLocked ?? false;
  bool get _settling => _original?.settledState == SettledState.settling;
  String get _lockReason => _settled ? '已結帳，金額鎖定；改用修正筆' : '結算中，簽核完成或作廢後才能改金額';
  int get _amountValue => int.tryParse(_amount.text.trim()) ?? 0;
  int get _lineTotal {
    var sum = 0;
    for (final l in _lines) {
      sum += int.tryParse(l.amount.text.trim()) ?? 0;
    }
    return sum;
  }

  Map<String, int> get _manualValues =>
      {for (final e in _manual.entries) e.key: int.tryParse(e.value.text.trim()) ?? 0};
  Map<String, int> get _ratioValues =>
      {for (final e in _ratio.entries) e.key: int.tryParse(e.value.text.trim()) ?? 0};
  int get _ratioTotal => _ratioValues.values.fold(0, (a, b) => a + b);

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 支出＋共同時才有付款來源與分攤。
  bool get _splittable => _kind == EntryKind.expense && _scope == EntryScope.shared;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _save() {
    final me = ref.read(currentMemberIdProvider);
    final members = ref.read(membersProvider);
    final ledger = ref.read(ledgerProvider);
    final orig = _original;
    final locked = _locked;

    // 鎖定時金額／付款來源／分攤／範圍一律沿用原值（UI 已 disable，這是防禦層）。
    final int amount;
    if (locked) {
      amount = orig!.amount;
    } else {
      final raw = _amount.text.trim();
      if (raw.isEmpty) {
        _toast('請輸入金額');
        return;
      }
      final parsed = int.tryParse(raw);
      if (parsed == null) {
        _toast('金額格式不正確');
        return;
      }
      if (parsed == 0) {
        _toast('請輸入金額');
        return;
      }
      if (parsed < 0 && !_isAdjustment) {
        _toast('負數金額請開啟「修正筆」');
        return;
      }
      amount = parsed;
    }
    if (_categoryId == null) {
      _toast('請選擇分類');
      return;
    }

    final scope = locked ? orig!.scope : _scope;
    final payerId = locked
        ? orig!.payerId
        : (_kind == EntryKind.income ? null : (scope == EntryScope.private ? me : _payerId));
    final method = locked
        ? orig!.splitMethod
        : (_kind == EntryKind.income || scope == EntryScope.private || payerId == null
            ? SplitMethod.common
            : _method);

    if (!locked && method == SplitMethod.amount) {
      final total = manualTotal(_manualValues);
      if (total != amount) {
        _toast('分攤金額合計需等於主筆金額（目前 ${fmtAmount(total)}／${fmtAmount(amount)}）');
        return;
      }
    }
    if (!locked && method == SplitMethod.ratio && _ratioTotal != 100) {
      _toast('比例合計需為 100%（目前 $_ratioTotal%）');
      return;
    }

    final id = orig?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    final splits = locked
        ? orig!.splits
        : toEntrySplits(
            id,
            buildSplits(
              amount: amount,
              method: method,
              members: members,
              ratio: _ratioValues,
              manual: _manualValues,
            ),
          );
    final lineItems = <LineItem>[];
    for (var i = 0; i < _lines.length; i++) {
      final name = _lines[i].name.text.trim();
      if (name.isEmpty) continue;
      lineItems.add(LineItem(
        id: 'li-$id-$i',
        entryId: id,
        name: name,
        amount: int.tryParse(_lines[i].amount.text.trim()),
        sort: i,
      ));
    }

    final entry = Entry(
      id: id,
      ledgerId: ledger.id,
      kind: _kind,
      scope: scope,
      amount: amount,
      categoryId: _categoryId!,
      occurredOn: _date,
      createdBy: orig?.createdBy ?? me,
      note: _note.text.trim(),
      payerId: payerId,
      splitMethod: method,
      settledState: orig?.settledState ?? SettledState.open,
      isAdjustment: locked ? orig!.isAdjustment : _isAdjustment,
      lineItems: lineItems,
      splits: splits,
    );

    try {
      if (orig == null) {
        ref.read(entriesProvider.notifier).add(entry);
      } else {
        ref.read(entriesProvider.notifier).update(entry);
      }
    } catch (e, st) {
      debugPrint('帳目儲存失敗: $e\n$st');
      _toast('儲存失敗，請稍後再試');
      return;
    }
    if (mounted) context.pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除這筆帳目？'),
        content: const Text('刪除後無法復原。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      ref.read(entriesProvider.notifier).remove(_original!.id);
    } catch (e, st) {
      debugPrint('帳目刪除失敗: $e\n$st');
      _toast('刪除失敗，請稍後再試');
      return;
    }
    if (mounted) context.pop();
  }

  String _nameOf(List<Member> members, String id) {
    for (final m in members) {
      if (m.id == id) return m.displayName;
    }
    return '成員';
  }

  /// 折疊區收起時的一行摘要：共同・老婆付・比例 50/50。
  String _advancedSummary(List<Member> members) {
    final scope = _scope == EntryScope.private ? '私人' : '共同';
    if (_kind == EntryKind.income || _scope == EntryScope.private) return scope;
    if (_payerId == null) return '$scope・共同錢包';
    final payer = '${_nameOf(members, _payerId!)}付';
    final method = switch (_method) {
      SplitMethod.equal => '均分',
      SplitMethod.ratio => '比例 ${[for (final m in members) _ratioValues[m.id] ?? 0].join('/')}',
      SplitMethod.amount => '金額',
      SplitMethod.common => '不分攤',
    };
    return '$scope・$payer・$method';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final members = ref.watch(membersProvider);
    final categories = [
      for (final c in ref.watch(categoriesProvider))
        if (c.kind == _kind) c,
    ]..sort((a, b) => a.sort.compareTo(b.sort));
    for (final m in members) {
      _manualOf(m.id);
      _ratioOf(m.id);
    }

    if (_missing) {
      return Scaffold(
        appBar: AppBar(title: const Text('帳目')),
        body: const Center(child: Text('找不到這筆帳目')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_original == null ? '新增' : '編輯'),
        leading: IconButton(icon: const Icon(Icons.close), tooltip: '關閉', onPressed: () => context.pop()),
        actions: [
          if (_original != null && !_locked)
            PopupMenuButton<String>(
              key: const Key('entry-menu'),
              onSelected: (v) {
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(key: Key('delete-entry'), value: 'delete', child: Text('刪除')),
              ],
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: FilledButton(key: const Key('save-button'), onPressed: _save, child: const Text('儲存')),
      ),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<EntryKind>(
                    segments: const [
                      ButtonSegment(value: EntryKind.expense, label: Text('支出')),
                      ButtonSegment(value: EntryKind.income, label: Text('收入')),
                    ],
                    selected: {_kind},
                    showSelectedIcon: false,
                    onSelectionChanged: _original != null
                        ? null
                        : (s) => setState(() {
                              _kind = s.first;
                              _categoryId = null;
                            }),
                  ),
                  if (_locked)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          Icon(Icons.lock_outline, size: 16, color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_lockReason,
                                style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                    ),
                  TextField(
                    key: const Key('amount-field'),
                    controller: _amount,
                    enabled: !_locked,
                    keyboardType: const TextInputType.numberWithOptions(signed: true),
                    inputFormatters: [_AmountFormatter(allowNegative: _isAdjustment)],
                    textAlign: TextAlign.center,
                    style: t.textTheme.headlineMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    decoration: const InputDecoration(hintText: '0', filled: false, border: InputBorder.none),
                    onChanged: (_) => setState(() {}),
                  ),
                  _SectionLabel('分類'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final c in categories)
                        _CategoryCell(
                          key: Key('category-${c.id}'),
                          category: c,
                          selected: _categoryId == c.id,
                          onTap: () => setState(() => _categoryId = c.id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      ActionChip(
                        key: const Key('date-button'),
                        avatar: const Icon(Icons.calendar_today_outlined, size: 16),
                        label: Text(fmtDate(_date)),
                        onPressed: _pickDate,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const Key('note-field'),
                          controller: _note,
                          decoration: const InputDecoration(hintText: '備註'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _LineItemsSection(
                    lines: _lines,
                    amount: _amountValue,
                    lineTotal: _lineTotal,
                    onAdd: () => setState(() => _lines.add(_LineRow())),
                    onRemove: (i) => setState(() => _lines.removeAt(i).dispose()),
                    onChanged: () => setState(() {}),
                  ),
                  ExpansionTile(
                    key: const Key('advanced-tile'),
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Row(
                      children: [
                        Text('進階', style: t.textTheme.labelLarge),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _advancedSummary(members),
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                    children: [
                      _OptionRow(
                        label: '範圍',
                        children: [
                          for (final e in const {EntryScope.shared: '共同', EntryScope.private: '私人'}.entries)
                            _MiniChip(
                              chipKey: Key('scope-${e.key.name}'),
                              label: e.value,
                              selected: _scope == e.key,
                              onTap: _locked
                                  ? null
                                  : () => setState(() {
                                        _scope = e.key;
                                        if (_scope == EntryScope.private) {
                                          _payerId = ref.read(currentMemberIdProvider);
                                          _method = SplitMethod.common;
                                        }
                                      }),
                            ),
                        ],
                      ),
                      if (_splittable) ...[
                        _OptionRow(
                          label: '付款',
                          children: [
                            _MiniChip(
                              chipKey: const Key('payer-common'),
                              label: '共同錢包',
                              selected: _payerId == null,
                              onTap: _locked
                                  ? null
                                  : () => setState(() {
                                        _payerId = null;
                                        _method = SplitMethod.common;
                                      }),
                            ),
                            for (final m in members)
                              _MiniChip(
                                chipKey: Key('payer-${m.id}'),
                                label: m.displayName,
                                selected: _payerId == m.id,
                                onTap: _locked ? null : () => setState(() => _payerId = m.id),
                              ),
                          ],
                        ),
                        _OptionRow(
                          label: '分攤',
                          children: [
                            for (final e in const {
                              SplitMethod.equal: ('split-equal', '均分'),
                              SplitMethod.ratio: ('split-ratio', '比例'),
                              SplitMethod.amount: ('split-amount', '金額'),
                              SplitMethod.common: ('split-common', '共同'),
                            }.entries)
                              _MiniChip(
                                chipKey: Key(e.value.$1),
                                label: e.value.$2,
                                selected: _method == e.key,
                                onTap: _locked || (_payerId == null && e.key != SplitMethod.common)
                                    ? null
                                    : () => setState(() => _method = e.key),
                              ),
                          ],
                        ),
                        if (_payerId != null && _method == SplitMethod.ratio)
                          _PercentRow(
                            members: members,
                            controllers: _ratio,
                            enabled: !_locked,
                            total: _ratioTotal,
                            onChanged: () => setState(() {}),
                          ),
                        if (_payerId != null && _method == SplitMethod.amount)
                          _ManualRow(
                            members: members,
                            controllers: _manual,
                            enabled: !_locked,
                            total: manualTotal(_manualValues),
                            amount: _amountValue,
                            onChanged: () => setState(() {}),
                          ),
                        if (_payerId != null && (_method == SplitMethod.equal || _method == SplitMethod.ratio))
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              [
                                for (final e in buildSplits(
                                  amount: _amountValue,
                                  method: _method,
                                  members: members,
                                  ratio: _ratioValues,
                                ).entries)
                                  '${_nameOf(members, e.key)} ${fmtShare(e.value)}',
                              ].join('　'),
                              textAlign: TextAlign.right,
                              style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                      SwitchListTile(
                        key: const Key('adjustment-switch'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        visualDensity: VisualDensity.compact,
                        title: Tooltip(
                          message: '沖銷已結帳金額用，可填負數',
                          child: Text('修正筆', style: t.textTheme.labelMedium),
                        ),
                        value: _isAdjustment,
                        onChanged: _locked ? null : (v) => setState(() => _isAdjustment = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 細標題：分段用，不做卡片。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 6, 0, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

/// 選項列：標籤在左、chip 在右，單行。
class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 4,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 緊湊選項 chip：未選只有框線，選中才實色。
class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.chipKey, required this.label, required this.selected, required this.onTap});
  final Key chipKey;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ChoiceChip(
      key: chipKey,
      label: Text(label, style: t.textTheme.labelMedium),
      selected: selected,
      onSelected: onTap == null ? null : (_) => onTap!(),
      // 視覺維持小（padding 控制），命中區交給 padded tap target，守 spec 的 ≥44px。
      materialTapTargetSize: MaterialTapTargetSize.padded,
      labelPadding: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      showCheckmark: false,
    );
  }
}

/// 比例分攤：每成員百分比可改，合計不是 100 才提示。
class _PercentRow extends StatelessWidget {
  const _PercentRow({
    required this.members,
    required this.controllers,
    required this.enabled,
    required this.total,
    required this.onChanged,
  });
  final List<Member> members;
  final Map<String, TextEditingController> controllers;
  final bool enabled;
  final int total;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              for (final m in members) ...[
                Expanded(
                  child: TextField(
                    key: Key('ratio-${m.id}'),
                    controller: controllers[m.id],
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.end,
                    style: t.textTheme.labelLarge,
                    decoration: InputDecoration(labelText: m.displayName, suffixText: '%'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                if (m != members.last) const SizedBox(width: 8),
              ],
            ],
          ),
          if (total != 100)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('合計 $total%，需為 100%',
                  style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}

/// 金額分攤：每成員金額可填，合計不等於主筆才提示。
class _ManualRow extends StatelessWidget {
  const _ManualRow({
    required this.members,
    required this.controllers,
    required this.enabled,
    required this.total,
    required this.amount,
    required this.onChanged,
  });
  final List<Member> members;
  final Map<String, TextEditingController> controllers;
  final bool enabled;
  final int total;
  final int amount;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              for (final m in members) ...[
                Expanded(
                  child: TextField(
                    key: Key('manual-${m.id}'),
                    controller: controllers[m.id],
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.end,
                    style: t.textTheme.labelLarge,
                    decoration: InputDecoration(labelText: m.displayName),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                if (m != members.last) const SizedBox(width: 8),
              ],
            ],
          ),
          if (total != amount)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('合計 ${fmtAmount(total)}／${fmtAmount(amount)}',
                  style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.error)),
            ),
        ],
      ),
    );
  }
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({super.key, required this.category, required this.selected, required this.onTap});
  final Category category;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final short = category.name.length <= 2 ? category.name : category.name.substring(0, 2);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 62,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: selected ? t.colorScheme.primaryContainer : Colors.transparent,
          border: Border.all(color: selected ? Colors.transparent : t.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Icon(categoryIcon(category.icon),
                size: 20, color: selected ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(
              short,
              maxLines: 1,
              style: t.textTheme.labelSmall?.copyWith(
                  color: selected ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}

/// 細項：名稱＋金額可空，差額只在有細項且不等於主筆時以右對齊小字提示。
class _LineItemsSection extends StatelessWidget {
  const _LineItemsSection({
    required this.lines,
    required this.amount,
    required this.lineTotal,
    required this.onAdd,
    required this.onRemove,
    required this.onChanged,
  });
  final List<_LineRow> lines;
  final int amount;
  final int lineTotal;
  final VoidCallback onAdd;
  final void Function(int index) onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('細項', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const Spacer(),
            IconButton(
              key: const Key('lineitem-add'),
              icon: const Icon(Icons.add, size: 20),
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              tooltip: '加一列細項',
              onPressed: onAdd,
            ),
          ],
        ),
        for (var i = 0; i < lines.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: Key('li-name-$i'),
                    controller: lines[i].name,
                    decoration: const InputDecoration(hintText: '名稱'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: Key('li-amount-$i'),
                    controller: lines[i].amount,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(hintText: '金額'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                IconButton(
                  key: Key('li-del-$i'),
                  icon: const Icon(Icons.close, size: 18),
                  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                  tooltip: '刪除這列',
                  onPressed: () => onRemove(i),
                ),
              ],
            ),
          ),
        if (lines.isNotEmpty && lineTotal != amount)
          Align(
            alignment: Alignment.centerRight,
            child: Text('合計 ${fmtAmount(lineTotal)}／${fmtAmount(amount)}',
                style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }
}
