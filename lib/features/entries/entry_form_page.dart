import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:flutter_slidable/flutter_slidable.dart';

import '../../app/category_wheel.dart';
import '../../app/circle_slide_action.dart';
import '../../app/format.dart';
import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'reversal.dart';
import 'split_math.dart';

/// 新增／編輯帳目的全螢幕表單。entryId 為 null ＝ 新增。
///
/// 版面依 spec v1.1「資訊密度」：單一平面列表、細標題分段、說明只在錯誤時出現、
/// 折疊區收起只留一行摘要、儲存鈕固定在底部。
class EntryFormPage extends ConsumerStatefulWidget {
  const EntryFormPage({super.key, this.entryId, this.template});
  final String? entryId;

  /// 新增時的預填範本（沖銷後「重新記一筆」帶原資訊進來；不是編輯）。
  final Entry? template;

  @override
  ConsumerState<EntryFormPage> createState() => _EntryFormPageState();
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

  /// 步驟精靈（Mike 裁示 2026-09-03，四關版）：類型・分類・金額 → 日期・備註・細項 → 進階 → 確認。
  static const _stepTitles = ['類型・分類・金額', '日期・備註・細項', '進階', '確認'];
  static const _confirmStep = 3;
  int _step = 0;

  void _nextStep() => setState(() => _step = (_step + 1).clamp(0, _confirmStep));
  void _prevStep() => setState(() => _step = (_step - 1).clamp(0, _confirmStep));

  /// 編輯 hub 的單欄彈窗（bottom sheet）活在另一條 route，page 的 setState 不會讓它重建；
  /// 彈窗內容包 [AnimatedBuilder] 聽這個 tick，setState 順手 ping 一下兩邊就同步。
  final _tick = _Tick();

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _tick.ping();
  }

  /// 寫入進行中：儲存鈕停用，避免重複送出。
  bool _saving = false;

  /// 資金來源（v1.3／ADR-0007）：只有共同錢包的共同支出可選，其餘一律 balance。
  Funding _funding = Funding.balance;

  /// 使用者是否手動選過資金來源：true 就不再被 [_syncFunding] 的預設值覆寫，
  /// 直到付款來源切成員／範圍切私人／種類切收入把它強制清掉。
  bool _fundingTouched = false;

  /// 分攤欄位的 controller 延後到用得到時才建立：成員清單變動（加入新成員、切帳本）
  /// 也不會出現沒有 controller 的成員。
  TextEditingController _manualOf(String memberId) =>
      _manual.putIfAbsent(memberId, () => TextEditingController());
  TextEditingController _ratioOf(String memberId) => _ratio.putIfAbsent(
        memberId,
        () => TextEditingController(text: '${ref.read(ledgerProvider).defaultRatio[memberId] ?? 0}'),
      );

  /// 該 kind 排序後的第一個分類（滾輪語義：永遠有選中值；kind 無分類時 null）。
  String? _firstCategoryOf(EntryKind kind) {
    final list = [
      for (final c in ref.read(categoriesProvider))
        if (c.kind == kind) c,
    ]..sort((a, b) => a.sort.compareTo(b.sort));
    return list.isEmpty ? null : list.first.id;
  }

  @override
  void initState() {
    super.initState();
    final id = widget.entryId;
    if (id == null) {
      final tpl = widget.template;
      if (tpl != null) {
        // 沖銷重記：複製原資訊（日期改今天），仍是全新一筆、照走精靈。
        _kind = tpl.kind;
        _scope = tpl.scope;
        _categoryId = tpl.categoryId;
        _amount.text = tpl.amount.abs().toString();
        _note.text = tpl.note;
        _payerId = tpl.scope == EntryScope.private ? tpl.createdBy : tpl.payerId;
        _method = tpl.splitMethod;
        for (final li in tpl.lineItems) {
          _lines.add(_LineRow(name: li.name, amount: li.amount?.toString() ?? ''));
        }
        for (final sp in tpl.splits) {
          _manualOf(sp.memberId).text = sp.share.abs().round().toString();
          if (tpl.splitMethod == SplitMethod.ratio && tpl.amount != 0) {
            _ratioOf(sp.memberId).text = '${(sp.share / tpl.amount * 100).round().abs()}';
          }
        }
      }
      _categoryId ??= _firstCategoryOf(_kind);
      _syncFunding();
      return;
    }

    Entry? found;
    for (final e in ref.read(entriesProvider)) {
      if (e.id == id) found = e;
    }
    if (found == null) {
      _missing = true;
      return;
    }
    _original = found;
    _step = _confirmStep; // 編輯：直接進單頁精簡明細（Mike 裁示 2026-09-03），點欄位開彈窗改
    _kind = found.kind;
    _scope = found.scope;
    _amount.text = found.amount.toString();
    _note.text = found.note;
    _categoryId = found.categoryId;
    _date = found.occurredOn;
    _payerId = found.payerId;
    _method = found.splitMethod;
    _isAdjustment = found.isAdjustment;
    // 編輯既有帳目：只有「共同錢包的共同支出」才是使用者真的選過資金來源，視為已
    // touched、不被之後的分類／日期變動自動覆寫；代墊／私人／收入的 balance 是
    // Entry 不變式逼出來的，不是使用者選的——不能讓它們「假裝已選過」，否則之後切回
    // 共同錢包時 `_syncFunding` 會被 touched 擋住，沒辦法依 defaultFunding 重算。
    _funding = found.funding;
    _fundingTouched = _fundingSelectable;
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
  String get _lockReason => _settled ? '已結帳：金額與分攤鎖定，可整筆沖銷後重新記一筆' : '結算中，簽核完成或作廢後才能改金額';
  int get _amountValue => int.tryParse(_amount.text.trim()) ?? 0;
  /// 名稱非空的細項列（儲存與顯示的口徑：空白列一律不算、儲存時捨棄）。
  int get _validLineCount {
    var n = 0;
    for (final l in _lines) {
      if (l.name.text.trim().isNotEmpty) n++;
    }
    return n;
  }

  bool get _hasBlankLine {
    for (final l in _lines) {
      if (l.name.text.trim().isEmpty) return true;
    }
    return false;
  }

  int get _lineTotal {
    var sum = 0;
    for (final l in _lines) {
      if (l.name.text.trim().isEmpty) continue;
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

  /// 資金來源只在「共同錢包的共同支出、且已選分類」可選（與 [Entry] 的建構不變式一致；
  /// 未選分類時 [defaultFunding] 無主體可算，不渲染這列，維持 balance）。
  bool get _fundingSelectable => _splittable && _payerId == null && _categoryId != null;

  /// 依目前狀態同步 `_funding`：條件不符（付款人是成員／範圍私人／種類收入／尚未選分類）
  /// 就強制收回 balance 並清「已手動選過」旗標；條件符合但使用者還沒手動選過，就依
  /// [defaultFunding] 重算預設；已手動選過的維持原值不覆寫。呼叫端要在每個會影響
  /// 分攤性、付款人、分類、日期的 setState 裡呼叫這個，讓狀態隨時保持一致。
  void _syncFunding() {
    if (!_fundingSelectable) {
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

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _date = picked;
        _syncFunding();
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
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

    // 防禦層：不變式保證 funding=budget 只允許共同錢包的共同支出；_syncFunding 已經
    // 隨狀態同步過，這裡用最終算出的 scope／payerId 再擋一次，確保炸不了。
    final funding = locked
        ? orig!.funding
        : (payerId == null && scope == EntryScope.shared && _kind == EntryKind.expense ? _funding : Funding.balance);

    // 新筆的 id 留空字串＝交給 repository（Supabase 由 DB）產生。
    final id = orig?.id ?? '';
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
        // 細項是「全刪重建」，id 一律留給 repository 產生；空列已捨棄，sort 用有效序。
        id: '',
        entryId: id,
        name: name,
        amount: int.tryParse(_lines[i].amount.text.trim()),
        sort: lineItems.length,
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
      funding: funding,
      lineItems: lineItems,
      splits: splits,
    );

    setState(() => _saving = true);
    try {
      final notifier = ref.read(entriesProvider.notifier);
      if (orig == null) {
        await notifier.add(entry);
      } else if (_settled) {
        // 已結帳（ADR-0002：分類、備註、細項可改）：主筆走 `upsert_entry` 但**不能帶子表**
        // ——那支的子表寫法是全刪重建，settled 下會被 policy 擋成半套。
        // 細項本身是允許改的，改走直寫 `line_items` 表的 replaceLineItems。
        await notifier.update(entry, writeSplits: false, writeLineItems: false);
        await notifier.replaceLineItems(entry.id, lineItems);
      } else {
        await notifier.update(entry);
      }
    } on LedgerException catch (e) {
      if (mounted) setState(() => _saving = false);
      _toast(e.message);
      return;
    } catch (e, st) {
      debugPrint('帳目儲存失敗: $e\n$st');
      if (mounted) setState(() => _saving = false);
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
    setState(() => _saving = true);
    try {
      await ref.read(entriesProvider.notifier).remove(_original!.id);
    } on LedgerException catch (e) {
      if (mounted) setState(() => _saving = false);
      _toast(e.message);
      return;
    } catch (e, st) {
      debugPrint('帳目刪除失敗: $e\n$st');
      if (mounted) setState(() => _saving = false);
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
        child: Row(
          children: [
            if (_step > 0 && _original == null) ...[
              OutlinedButton(
                key: const Key('form-back-button'),
                onPressed: _saving ? null : _prevStep,
                child: const Text('返回'),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: _step == _confirmStep
                  ? FilledButton(
                      key: const Key('save-button'),
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? '儲存中…' : '儲存'),
                    )
                  : FilledButton(
                      key: const Key('form-next-button'),
                      // 金額 0／空白不能進下一關（Mike 裁示 2026-09-03）；其餘格式錯誤仍由儲存端擋。
                      onPressed: _step == 0 && _amountValue == 0 ? null : _nextStep,
                      child: const Text('下一步'),
                    ),
            ),
          ],
        ),
      ),
      // 點內容空白處收鍵盤（Mike 裁示：鍵盤不要擋欄位、要收得掉）。
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
        bottom: false,
        child: Align(
          // 步驟拆開後單步內容不多：整塊垂直置中（Mike 裁示 2026-09-03），
          // 內容比視窗高（鍵盤彈起等）時 SingleChildScrollView 自然轉為可捲。
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 步驟標題與進度置中放大：一眼看懂現在在填什麼、走到哪。
                  // 編輯＝單頁明細 hub，沒有步驟進度。
                  Text(_original != null ? '帳目明細' : _stepTitles[_step],
                      textAlign: TextAlign.center, style: t.textTheme.titleMedium),
                  if (_original == null) ...[
                    const SizedBox(height: 4),
                    Text('${_step + 1}/${_stepTitles.length}',
                        textAlign: TextAlign.center,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                  if (_locked)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline, size: 16, color: t.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(_lockReason,
                                style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  KeyedSubtree(key: ValueKey('form-step-$_step'), child: _stepBody(t, members, categories)),
                ],
              ),
            ),
          ),
        ),
        ),
      ),
    );
  }

  /// 各步驟內容：欄位本體沿用原表單元件，一關一組。
  Widget _stepBody(ThemeData t, List<Member> members, List<Category> categories) {
    switch (_step) {
      case 0:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 窄版置中（Mike 裁示 2026-09-03）：不吃滿版，與下方欄位垂直邊切齊的節奏一致。
            Center(
              child: SegmentedButton<EntryKind>(
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
                        _categoryId = _firstCategoryOf(_kind);
                        _syncFunding();
                      }),
              ),
            ),
            const SizedBox(height: 16),
            // 垂直滾輪：不秀 icon；鎖定只鎖金額／付款來源／分攤／範圍，分類結算中仍可改（spec）。
            CategoryWheel(
              key: const Key('category-wheel'),
              categories: categories,
              selectedId: _categoryId,
              enabled: true,
              onSelected: (id) => setState(() {
                _categoryId = id;
                _syncFunding();
              }),
            ),
            const SizedBox(height: 8),
            _amountField(t),
          ],
        );
      case 1:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: ActionChip(
                key: const Key('date-button'),
                avatar: const Icon(Icons.calendar_today_outlined, size: 16),
                label: Text(fmtDate(_date)),
                onPressed: _pickDate,
              ),
            ),
            const SizedBox(height: 12),
            _noteField(),
            const SizedBox(height: 8),
            // 細項窄版置中（Mike 裁示 2026-09-03）。
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: _linesSection(),
              ),
            ),
          ],
        );
      case 2:
        return _advancedBody(t, members);
      default:
        return _confirmBody(t, members);
    }
  }

  Widget _amountField(ThemeData t) => TextField(
        key: const Key('amount-field'),
        controller: _amount,
        enabled: !_locked,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        style: t.textTheme.headlineMedium?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: const InputDecoration(
          hintText: '0',
          filled: false,
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.symmetric(vertical: 6),
        ),
        onChanged: (_) => setState(() {}),
      );

  Widget _noteField({bool autofocus = false}) => TextField(
        key: const Key('note-field'),
        controller: _note,
        autofocus: autofocus,
        decoration: const InputDecoration(hintText: '備註（可留空）'),
        onChanged: (_) => setState(() {}),
      );

  Widget _linesSection() => _LineItemsSection(
        lines: _lines,
        amount: _amountValue,
        lineTotal: _lineTotal,
        // 有空白列就鎖「＋」（Mike 裁示 2026-09-03：細項沒填不能再往下加）。
        onAdd: _hasBlankLine ? null : () => setState(() => _lines.add(_LineRow())),
        onRemove: (i) => setState(() => _lines.removeAt(i).dispose()),
        onChanged: () => setState(() {}),
      );

  /// 編輯 hub 的單欄彈窗：內容聽 [_tick]，page setState 兩邊同步；「完成」收起。
  Future<void> _editFieldSheet(String title, Widget Function(BuildContext) content) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => AnimatedBuilder(
        animation: _tick,
        builder: (_, _) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 16),
              content(ctx),
              const SizedBox(height: 20),
              FilledButton(
                key: const Key('field-done'),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 確認頁（新增精靈末步）／編輯 hub（單頁精簡明細）。
  /// 新增：點列跳回該步驟。編輯：值以弱色呈現（唯讀感），點列開該欄位的彈窗（Mike 裁示 2026-09-03）。
  Widget _confirmBody(ThemeData t, List<Member> members) {
    final editing = _original != null;
    String categoryName = '—';
    for (final c in ref.read(categoriesProvider)) {
      if (c.id == _categoryId) categoryName = c.name;
    }
    final note = _note.text.trim();
    final linesLabel = _validLineCount == 0 ? '—' : '$_validLineCount 筆・合計 ${fmtAmount(_lineTotal)}';

    VoidCallback? go(int step) => () => setState(() => _step = step);
    final rows = <(String, String, String?, VoidCallback?)>[
      // (標籤, 值, 編輯列 key, onTap)
      ('類型', _kind == EntryKind.income ? '收入' : '支出', null, editing ? null : go(0)),
      (
        '分類',
        categoryName,
        'edit-row-category',
        editing
            ? () => _editFieldSheet('分類', (ctx) {
                  final categories = [
                    for (final c in ref.read(categoriesProvider))
                      if (c.kind == _kind) c,
                  ]..sort((a, b) => a.sort.compareTo(b.sort));
                  return CategoryWheel(
                    key: const Key('category-wheel'),
                    categories: categories,
                    selectedId: _categoryId,
                    enabled: true,
                    onSelected: (id) => setState(() {
                      _categoryId = id;
                      _syncFunding();
                    }),
                  );
                })
            : go(0)
      ),
      (
        '金額',
        fmtAmount(_amountValue),
        'edit-row-amount',
        editing ? () => _editFieldSheet('金額', (_) => _amountField(t)) : go(0)
      ),
      ('日期', fmtDate(_date), 'date-button', editing ? _pickDate : go(1)),
      if (editing || note.isNotEmpty)
        (
          '備註',
          note.isEmpty ? '—' : note,
          'edit-row-note',
          editing ? () => _editFieldSheet('備註', (_) => _noteField(autofocus: true)) : go(1)
        ),
      if (editing || _validLineCount > 0)
        (
          '細項',
          linesLabel,
          'edit-row-lines',
          editing ? () => _editFieldSheet('細項', (_) => _linesSection()) : go(1)
        ),
      (
        '進階',
        _advancedSummary(members),
        'edit-row-advanced',
        editing
            ? () => _editFieldSheet('進階', (ctx) => _advancedBody(Theme.of(ctx), ref.read(membersProvider)))
            : go(2)
      ),

    ];
    final reversed = editing && _settled && hasReversal(ref.watch(entriesProvider), _original!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (editing) const SizedBox.shrink(key: Key('edit-mode')),
        for (final r in rows)
          InkWell(
            key: r.$3 == null ? null : Key(r.$3!),
            onTap: r.$4,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(r.$1, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ),
                  Expanded(
                    child: Text(r.$2,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: (t.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            // 編輯 hub：值弱色＝唯讀感；點了才開彈窗改。
                            color: editing ? t.colorScheme.onSurfaceVariant : null)),
                  ),
                  if (editing && r.$4 != null) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right, size: 16, color: t.colorScheme.onSurfaceVariant),
                  ],
                ],
              ),
            ),
          ),
        if (editing && _settled) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('reverse-entry'),
            icon: const Icon(Icons.undo, size: 18),
            onPressed: reversed || _saving ? null : _reverseAndRedo,
            label: Text(reversed ? '已沖銷' : '沖銷並重新記一筆'),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              reversed
                  ? '這筆已有反向紀錄；如需再記，直接新增即可。'
                  : '會先記一筆一模一樣的反向紀錄（拆帳、預算、餘額沿原路回退），再帶你用原資訊重新記一筆。',
              textAlign: TextAlign.center,
              style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  /// 沖銷（Mike 裁示 2026-09-04）：寫入反向紀錄 → 帶原資訊進「新增」精靈重記。
  Future<void> _reverseAndRedo() async {
    final orig = _original!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('沖銷這筆帳目？'),
        content: const Text('會新增一筆等額反向的紀錄把它整筆抵銷（分攤與預算一併回退），接著用原資訊重新記一筆。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          FilledButton(
            key: const Key('confirm-reverse'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('沖銷'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(entriesProvider.notifier)
          .add(buildReversal(orig, me: ref.read(currentMemberIdProvider)));
    } on LedgerException catch (e) {
      if (mounted) setState(() => _saving = false);
      _toast(e.message);
      return;
    } catch (e, st) {
      debugPrint('沖銷失敗: $e\n$st');
      if (mounted) setState(() => _saving = false);
      _toast('沖銷失敗，請稍後再試');
      return;
    }
    if (mounted) context.pushReplacement('/entries/new', extra: orig);
  }

  Widget _advancedBody(ThemeData t, List<Member> members) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          _syncFunding();
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
                          _syncFunding();
                        }),
              ),
              for (final m in members)
                _MiniChip(
                  chipKey: Key('payer-${m.id}'),
                  label: m.displayName,
                  selected: _payerId == m.id,
                  onTap: _locked
                      ? null
                      : () => setState(() {
                            _payerId = m.id;
                            _syncFunding();
                          }),
                ),
            ],
          ),
          if (_fundingSelectable)
            _OptionRow(
              label: '資金',
              children: [
                _MiniChip(
                  chipKey: const Key('funding-budget'),
                  label: '預算',
                  selected: _funding == Funding.budget,
                  onTap: _locked
                      ? null
                      : () => setState(() {
                            _funding = Funding.budget;
                            _fundingTouched = true;
                          }),
                ),
                _MiniChip(
                  chipKey: const Key('funding-balance'),
                  label: '餘額',
                  selected: _funding == Funding.balance,
                  onTap: _locked
                      ? null
                      : () => setState(() {
                            _funding = Funding.balance;
                            _fundingTouched = true;
                          }),
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
      ],
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


/// 細項：名稱＋金額可空，差額只在有細項且不等於主筆時以右對齊小字提示。
class _LineItemsSection extends StatefulWidget {
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
  final VoidCallback? onAdd;
  final void Function(int index) onRemove;
  final VoidCallback onChanged;

  @override
  State<_LineItemsSection> createState() => _LineItemsSectionState();
}

class _LineItemsSectionState extends State<_LineItemsSection> {
  /// 每列的左滑累計位移：TextField 會在手勢競技場搶走水平拖曳，
  /// 這裡用 raw pointer（不進競技場）觀察，超過門檻直接開 action pane。
  final _dragAcc = <int, double>{};

  List<_LineRow> get lines => widget.lines;
  int get amount => widget.amount;
  int get lineTotal => widget.lineTotal;
  VoidCallback? get onAdd => widget.onAdd;
  void Function(int index) get onRemove => widget.onRemove;
  VoidCallback get onChanged => widget.onChanged;

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
          // 左滑刪除（Mike 裁示 2026-09-04：不放 X 按鈕）。
          Slidable(
            key: ValueKey('li-row-$i'),
            endActionPane: ActionPane(
              motion: const DrawerMotion(),
              extentRatio: 0.22,
              children: [
                CircleSlideAction(
                  key: Key('li-del-$i'),
                  icon: Icons.delete_outline,
                  background: Theme.of(context).colorScheme.errorContainer,
                  foreground: Theme.of(context).colorScheme.onErrorContainer,
                  tooltip: '刪除這列',
                  onPressed: () => onRemove(i),
                ),
              ],
            ),
            child: Builder(
            builder: (sctx) => Listener(
            onPointerDown: (_) => _dragAcc[i] = 0,
            onPointerMove: (e) {
              if (e.delta.dx < 0 && e.delta.dx.abs() > e.delta.dy.abs()) {
                _dragAcc[i] = (_dragAcc[i] ?? 0) + e.delta.dx;
                if ((_dragAcc[i] ?? 0) < -24) {
                  _dragAcc[i] = 0;
                  Slidable.of(sctx)?.openEndActionPane();
                }
              }
            },
            child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: Key('li-name-$i'),
                    controller: lines[i].name,
                    // 讓左滑刪除收得到水平手勢（TextField 的游標拖曳會搶）；小欄位不需要拖選字。
                    enableInteractiveSelection: false,
                    decoration: const InputDecoration(hintText: '名稱'),
                    // 名稱變動要通知外層：加列 gate（空白列鎖「＋」）靠它重算。
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    key: Key('li-amount-$i'),
                    controller: lines[i].amount,
                    enableInteractiveSelection: false,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.end,
                    decoration: const InputDecoration(hintText: '金額'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
              ],
            ),
            ),
            ),
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

class _Tick extends ChangeNotifier {
  void ping() => notifyListeners();
}
