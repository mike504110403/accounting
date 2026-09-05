/// 補入 sheet（v1.5／ADR-0009）：記一筆自己的個人補入。
///
/// 只能補自己（`memberId = createdBy = currentMemberIdProvider`），金額必填 > 0，
/// 備註選填；日期預設今天並夾在 [month] 內（同月直接用今天，否則退到該月 1 號——
/// 呼叫端已經用「已清月／未來月鈕停用」擋掉不該開 sheet 的月份，這裡只處理
/// 「檢視的是過去某個未清月」那個正常情境）。錯誤一律顯示在 sheet 內
/// （sheet 蓋著時 SnackBar 看不到，沿用其他寫入 sheet 的慣例）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/balance_math.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';

class TopupSheet extends ConsumerStatefulWidget {
  const TopupSheet({super.key, required this.month});

  /// 正在看的月份（月 1 號）。
  final DateTime month;

  @override
  ConsumerState<TopupSheet> createState() => _TopupSheetState();
}

class _TopupSheetState extends ConsumerState<TopupSheet> {
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  DateTime _occurredOn() {
    final now = DateTime.now();
    if (sameMonth(now, widget.month)) return DateTime(now.year, now.month, now.day);
    return DateTime(widget.month.year, widget.month.month, 1);
  }

  Future<void> _submit() async {
    final raw = int.tryParse(_amountController.text.trim());
    if (raw == null || raw <= 0) {
      setState(() => _error = '補入金額必須大於 0');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final memberId = ref.read(currentMemberIdProvider);
      await ref.read(topupsProvider.notifier).add(PersonalTopup(
            // id 留空＝新筆，由 repository（Supabase 由 DB）產生。
            id: '',
            ledgerId: ref.read(ledgerProvider).id,
            memberId: memberId,
            amount: raw,
            occurredOn: _occurredOn(),
            note: _noteController.text.trim(),
            createdBy: memberId,
          ));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e is LedgerException ? e.message : '儲存失敗，請重試';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('補入', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              key: const Key('topup-amount-field'),
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(signed: false),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '金額'),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('topup-note-field'),
              controller: _noteController,
              decoration: const InputDecoration(labelText: '備註'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('topup-submit-btn'),
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? '處理中…' : '補入'),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
