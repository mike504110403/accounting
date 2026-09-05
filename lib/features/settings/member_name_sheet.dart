/// 成員顯示名稱：驗證規則、寫入 helper、設定頁的「我的名稱」sheet。
///
/// 背景（Mike 手測 2026-09-05）：Apple 登入只要 email scope，`create_ledger`／`join_ledger`
/// 拿不到 full_name 就退到 email 前綴——隱藏信箱的前綴是 `4yrcfzrc99` 這種代號，
/// 全 app 的人名都變成代號。所以首登／加入帳本一律要使用者自己填名稱，之後也隨時可改。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mock_data.dart';
import '../../domain/models.dart';

/// 顯示名稱上限（DB 無長度約束，純 UI 守：人名列、清帳明細、圓餅 legend 都要放得下）。
const kMemberNameMaxLength = 20;

/// 回傳錯誤訊息；null＝合法。呼叫端自己 trim 過再存。
String? validateMemberName(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '請輸入你的名稱';
  if (name.length > kMemberNameMaxLength) return '名稱最多 $kMemberNameMaxLength 個字';
  return null;
}

/// 把「目前帳本裡的我」改名。只送 display_name（v1.5 起 `members` 只有這一欄可改）。
///
/// 呼叫前提：快照已載好（`currentLedgerIdProvider.select` 之後）。找不到自己＝快照壞了，
/// 丟 [LedgerException] 讓呼叫端照一般錯誤顯示。
Future<void> saveMyDisplayName(WidgetRef ref, String name) async {
  final meId = ref.read(currentMemberIdProvider);
  final members = ref.read(membersStateProvider);
  Member? me;
  for (final m in members) {
    if (m.id == meId) me = m;
  }
  if (me == null) throw const LedgerException('找不到你的成員資料，請重新載入');
  await ref.read(membersStateProvider.notifier).update(me.copyWith(displayName: name.trim()));
}

/// 設定頁「我的名稱」bottom sheet：一欄一鈕，錯誤顯示在 sheet 內（與其他設定 sheet 同款）。
class MemberNameSheet extends ConsumerStatefulWidget {
  const MemberNameSheet({super.key});

  @override
  ConsumerState<MemberNameSheet> createState() => _MemberNameSheetState();
}

class _MemberNameSheetState extends ConsumerState<MemberNameSheet> {
  late final TextEditingController _controller;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final meId = ref.read(currentMemberIdProvider);
    String current = '';
    for (final m in ref.read(membersProvider)) {
      if (m.id == meId) current = m.displayName;
    }
    _controller = TextEditingController(text: current);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final err = validateMemberName(_controller.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await saveMyDisplayName(ref, _controller.text);
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('已儲存')));
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
    final t = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('我的名稱', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('對方在帳目與清帳明細裡看到的就是這個名字。',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('member-name-field'),
            controller: _controller,
            autofocus: true,
            maxLength: kMemberNameMaxLength,
            decoration: const InputDecoration(counterText: ''),
            onSubmitted: (_) => _save(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!, style: TextStyle(color: t.colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('save-member-name-button'),
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '儲存中…' : '儲存'),
            ),
          ),
        ],
      ),
    );
  }
}
