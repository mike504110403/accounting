/// 清帳的「對帳」呈現詞彙（spec v1.5「清帳」節／ADR-0009）。
///
/// 這一份同時被預覽 sheet 與清帳列表的展開明細吃：兩處看到的欄位、方向文案、
/// 金額寫法必須是同一份——清帳不可撤銷，預覽跟事後明細長得不一樣的話，
/// 使用者按下去之前看到的東西就不算數。
///
/// 月份文字一律走 `app/format.dart` 的 [fmtYearMonth]（與 errors.dart 的「請先清 2026／08」同格式）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/format.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';

/// 一位成員該月的處理方向。月末（補入 − 先付）> 0 ＝ 他手上還有補入要繳回共同帳戶；
/// < 0 ＝ 他先付超過補入，共同帳戶要補他；＝ 0 ＝ 剛好，不用動錢。
String closeDirectionText(MonthCloseMemberLine line) {
  if (line.ending > 0) return '${line.displayName} 轉 ${fmtAmount(line.ending)} 給共同帳戶';
  if (line.ending < 0) return '共同帳戶補 ${line.displayName} ${fmtAmount(-line.ending)}';
  return '免處理';
}

/// 對帳明細（唯讀）：每位成員一列三個數字（補入、先付、月末）＋一行方向文案，
/// 末尾對照該月共同錢包支出合計（清帳不動共同餘額，這裡只供對照）。
class CloseDetailsView extends StatelessWidget {
  const CloseDetailsView({super.key, required this.details});

  final MonthCloseDetails details;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(flex: 3, child: SizedBox.shrink()),
            Expanded(flex: 2, child: Text('補入', textAlign: TextAlign.right, style: muted)),
            Expanded(flex: 2, child: Text('先付', textAlign: TextAlign.right, style: muted)),
            Expanded(flex: 2, child: Text('月末', textAlign: TextAlign.right, style: muted)),
          ],
        ),
        for (final line in details.members) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(flex: 3, child: Text(line.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
              Expanded(flex: 2, child: Text(fmtAmount(line.topup), textAlign: TextAlign.right)),
              Expanded(flex: 2, child: Text(fmtAmount(line.paid), textAlign: TextAlign.right)),
              Expanded(
                flex: 2,
                child: Text(
                  fmtSignedAmount(line.ending),
                  textAlign: TextAlign.right,
                  // 負數＝共同帳戶要補他，紅字（spec：負數紅字）。
                  style: line.ending < 0 ? TextStyle(color: t.colorScheme.error) : null,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(closeDirectionText(line), style: muted),
          ),
        ],
        const SizedBox(height: 8),
        Text('共同錢包支出 ${fmtAmount(details.sharedPaid)}', style: muted),
      ],
    );
  }
}

/// 清帳預覽 sheet：確認前的最後一眼。確定 → 二次確認 dialog → `close_month`。
///
/// 成功時 `pop(true)`（由清帳頁補 SnackBar：sheet 蓋在上面時 SnackBar 會被擋住看不到）；
/// 失敗一律留在 sheet 內顯示錯誤行、解除 loading、不 pop。
class ClosePreviewSheet extends ConsumerStatefulWidget {
  const ClosePreviewSheet({super.key, required this.month, required this.details});

  /// 要清的月份（月初；`SupabaseLedgerRepository` 不代為正規化）。
  final DateTime month;

  /// `month_close_preview` 剛回來的明細（含 `income_amount`）。
  final MonthCloseDetails details;

  @override
  ConsumerState<ClosePreviewSheet> createState() => _ClosePreviewSheetState();
}

class _ClosePreviewSheetState extends ConsumerState<ClosePreviewSheet> {
  bool _closing = false;
  String? _error;

  /// 「一鍵記共同收入」勾選狀態。已知本月不需要轉入（[_incomeKnownNonPositive]）
  /// 時強制不勾且停用；其餘情況（含 RPC 沒給 `incomeAmount` 的極端狀況）預設勾
  /// （spec v1.5：確認頁提供、預設勾——金額未知就交給 DB 判斷，勾了也不會多記一筆）。
  late bool _recordIncome;

  @override
  void initState() {
    super.initState();
    _recordIncome = !_incomeKnownNonPositive;
  }

  /// `month_close_preview` 回來的應轉入金額；只有預覽帶這欄，落地快照不帶（見 model 註解）。
  int? get _incomeAmount => widget.details.incomeAmount;

  /// 「已經確定知道」這個月不需要轉入：`incomeAmount` 有值且 ≤ 0。
  /// `incomeAmount == null`（RPC 沒給）不算「知道是 0 以下」，只是「不知道」——
  /// 這時勾選框照樣可勾、預設勾，只是金額顯示「—」。
  bool get _incomeKnownNonPositive => _incomeAmount != null && _incomeAmount! <= 0;

  Future<bool> _askConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清帳 ${fmtYearMonth(widget.month)}？'),
        content: const Text('清帳後不可撤銷，該月及更早月份的帳目將鎖定。'),
        actions: [
          TextButton(
            key: const Key('close-confirm-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('close-confirm-ok'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('確定清帳'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _close() async {
    if (_closing) return;
    if (!await _askConfirm()) return;
    if (!mounted) return;
    setState(() {
      _closing = true;
      _error = null;
    });
    try {
      // ledgerId 一律取當下的 `ledgerProvider`，不從頁面參數帶進來：
      // sheet 開著時切帳本的話，參數會是上一本的 id，清到別人的帳本上。
      final ledgerId = ref.read(ledgerProvider).id;
      await ref
          .read(ledgerRepositoryProvider)
          .closeMonth(ledgerId, widget.month, recordIncome: _recordIncome);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _closing = false;
        _error = e is LedgerException ? e.message : '清帳失敗，請稍後再試';
      });
      return;
    }
    // 清完只要重抓 closes 與 entries：`monthSummaryProvider` 自己 watch 了
    // `monthClosesProvider` 會跟著重打 RPC；「一鍵記共同收入」勾選時 `close_month`
    // 同一交易多記一筆收入，entriesProvider 也要重抓才看得到那一筆。
    // 重抓失敗不改變「已經清帳成功」這件事：吞掉並照常收尾（輪詢／Realtime 會補上）。
    try {
      await ref.read(monthClosesProvider.notifier).refresh();
    } catch (e, st) {
      debugPrint('清帳後重抓 closes 失敗: $e\n$st');
    }
    try {
      await ref.read(entriesProvider.notifier).refresh();
    } catch (e, st) {
      debugPrint('清帳後重抓 entries 失敗: $e\n$st');
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final incomeAmount = _incomeAmount;
    // 清帳寫入中一律關不掉（下拉、點外面、系統返回都走 maybePop → 吃這裡的 canPop）：
    // sheet 在 await 中途被關掉的話，成功與否只剩 SnackBar 沒得顯示，人不知道清了沒。
    return PopScope(
      canPop: !_closing,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${fmtYearMonth(widget.month)} 對帳', style: t.textTheme.titleLarge),
              const SizedBox(height: 12),
              CloseDetailsView(details: widget.details),
              const SizedBox(height: 8),
              // 整列可點（不是只有小方塊）：CheckboxListTile 本身就處理了列點擊 toggle。
              CheckboxListTile(
                key: const Key('record-income-checkbox'),
                value: _recordIncome,
                onChanged: _incomeKnownNonPositive
                    ? null
                    : (v) => setState(() => _recordIncome = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  _incomeKnownNonPositive
                      ? '本月無需轉入'
                      : '一鍵記共同收入 ${incomeAmount != null ? fmtAmount(incomeAmount) : '—'}',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    key: const Key('close-sheet-error'),
                    style: t.textTheme.bodySmall?.copyWith(fontSize: 12, color: t.colorScheme.error),
                  ),
                ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('confirm-close-button'),
                  onPressed: _closing ? null : _close,
                  child: Text(_closing ? '清帳中…' : '確認清帳'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
