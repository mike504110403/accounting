import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/format.dart';
import '../../app/theme_mode.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';

/// 設定：帳本、外觀、成員、期初餘額、分類管理入口（波 1 工人實作，替換本檔內容）。
/// 緊湊單頁：每個項目一行，點進去才開 bottom sheet 編輯（spec v1.1 UI 互動原則：表單一律 bottom sheet）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              key: const Key('settings-content-column'),
              children: const [
                _LedgerCard(),
                _AppearanceCard(),
                _MembersCard(),
                _OtherCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Ledger _copyLedger(Ledger l, {String? name, Map<String, int>? defaultRatio, int? openingBalanceShared}) => Ledger(
      id: l.id,
      name: name ?? l.name,
      inviteCode: l.inviteCode,
      defaultRatio: defaultRatio ?? l.defaultRatio,
      openingBalanceShared: openingBalanceShared ?? l.openingBalanceShared,
    );

Member? _findMember(List<Member> members, String id) {
  for (final m in members) {
    if (m.id == id) return m;
  }
  return null;
}

void _openSheet(BuildContext context, WidgetBuilder builder) {
  showModalBottomSheet<void>(context: context, isScrollControlled: true, useSafeArea: true, builder: builder);
}

/// 一行摘要列：標籤在左、值在右，單行（資訊密度：Mike 裁示，不疊兩行）。點擊開 bottom sheet 編輯（或直接動作）。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, this.value, this.trailing, this.onTap});
  final String label;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13), // 連文字行高湊到 ≥44px 點擊目標
        child: Row(
          children: [
            Text(label),
            // 只留一個會撐開的 widget：value 有值時它自己吃掉剩餘寬度並靠右對齊；
            // 沒 value 時才用 Spacer 把 trailing 推到最右。兩個一起用會各分一半寬度，值被攔腰截斷（MAJOR-1）。
            if (value != null)
              Expanded(
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              const Spacer(),
            if (trailing != null) ...[const SizedBox(width: 4), trailing!] else if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: theme.colorScheme.outline),
            ],
          ],
        ),
      ),
    );
  }
}

class _LedgerCard extends ConsumerWidget {
  const _LedgerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    return Card(
      child: Column(
        children: [
          _SettingsRow(
            label: '帳本名稱',
            value: ledger.name,
            onTap: () => _openSheet(context, (_) => const _LedgerNameSheet()),
          ),
          _SettingsRow(
            label: '邀請碼',
            value: ledger.inviteCode,
            trailing: IconButton(
              icon: const Icon(Icons.copy_outlined),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                try {
                  await Clipboard.setData(ClipboardData(text: ledger.inviteCode));
                  messenger.showSnackBar(const SnackBar(content: Text('已複製邀請碼')));
                } catch (_) {
                  messenger.showSnackBar(const SnackBar(content: Text('複製失敗，請重試')));
                }
              },
            ),
          ),
          _SettingsRow(
            label: '帳本切換',
            value: ledger.name,
            onTap: () => _openSheet(context, (_) => _LedgerSwitchSheet(ledgerName: ledger.name)),
          ),
        ],
      ),
    );
  }
}

class _LedgerNameSheet extends ConsumerStatefulWidget {
  const _LedgerNameSheet();

  @override
  ConsumerState<_LedgerNameSheet> createState() => _LedgerNameSheetState();
}

class _LedgerNameSheetState extends ConsumerState<_LedgerNameSheet> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: ref.read(ledgerProvider).name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save(Ledger ledger) {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '請輸入名稱');
      return;
    }
    // sheet 蓋在上面時 ScaffoldMessenger 的 SnackBar 會被 sheet 擋住看不到（MAJOR-2）：
    // 錯誤改顯示在 sheet 內；成功則先 pop 讓出畫面、再用 pop 前存好的 messenger 補 SnackBar。
    final messenger = ScaffoldMessenger.of(context);
    try {
      ref.read(ledgerStateProvider.notifier).update(_copyLedger(ledger, name: name));
      Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('已儲存')));
    } catch (_) {
      setState(() => _error = '儲存失敗，請重試');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('帳本名稱', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(key: const ValueKey('ledger-name-field'), controller: _controller, autofocus: true),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(key: const ValueKey('save-ledger-name-button'), onPressed: () => _save(ledger), child: const Text('儲存')),
          ),
        ],
      ),
    );
  }
}

class _LedgerSwitchSheet extends StatefulWidget {
  const _LedgerSwitchSheet({required this.ledgerName});
  final String ledgerName;

  @override
  State<_LedgerSwitchSheet> createState() => _LedgerSwitchSheetState();
}

class _LedgerSwitchSheetState extends State<_LedgerSwitchSheet> {
  final _joinController = TextEditingController();
  String? _error; // 驗證錯誤（紅字）
  String? _info; // 波 2 待接後端的提示（一般字）

  @override
  void dispose() {
    _joinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('帳本切換', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.check_circle, size: 18),
              const SizedBox(width: 8),
              const Text('目前帳本'),
              const Spacer(),
              Text(widget.ledgerName, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _joinController,
                  maxLength: 6,
                  decoration: const InputDecoration(labelText: '輸入 6 碼邀請碼', counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  if (_joinController.text.trim().length != 6) {
                    setState(() {
                      _error = '請輸入 6 碼邀請碼';
                      _info = null;
                    });
                    return;
                  }
                  setState(() {
                    _error = null;
                    _info = '波 2 接後端';
                  });
                },
                child: const Text('加入'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => setState(() {
                _error = null;
                _info = '波 2 接後端';
              }),
              icon: const Icon(Icons.add),
              label: const Text('新增帳本'),
            ),
          ),
          // sheet 蓋在最上層，ScaffoldMessenger 的 SnackBar 會被擋住看不到（MAJOR-2）：狀態改顯示在 sheet 內；
          // 錯誤與一般提示分開上色，錯誤才套 colorScheme.error。
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.error)),
            ),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_info!, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _AppearanceCard extends ConsumerWidget {
  const _AppearanceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Text('外觀'),
            const SizedBox(width: 12),
            Expanded(
              child: SegmentedButton<ThemeMode>(
                key: const Key('theme-mode-toggle'),
                segments: [
                  ButtonSegment(value: ThemeMode.light, label: Text(themeModeLabel(ThemeMode.light), maxLines: 1, softWrap: false)),
                  ButtonSegment(value: ThemeMode.dark, label: Text(themeModeLabel(ThemeMode.dark), maxLines: 1, softWrap: false)),
                  ButtonSegment(value: ThemeMode.system, label: Text(themeModeLabel(ThemeMode.system), maxLines: 1, softWrap: false)),
                ],
                selected: {mode},
                showSelectedIcon: false,
                expandedInsets: EdgeInsets.zero,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersCard extends ConsumerWidget {
  const _MembersCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledger = ref.watch(ledgerProvider);
    final members = ref.watch(membersProvider);
    final meId = ref.watch(currentMemberIdProvider);
    final me = _findMember(members, meId);

    final namesSummary = members.map((m) => m.displayName).join('、');
    final ratioSummary = members.map((m) => '${m.displayName} ${ledger.defaultRatio[m.id] ?? 0}%').join('・');
    // 不留空格：390px 下這行是最緊的樣本，「共同 120,000／我 50,000」帶空格量過會被截斷，拿掉空格才塞得下。
    final balanceSummary = '共同${fmtAmount(ledger.openingBalanceShared)}／我${fmtAmount(me?.openingBalancePersonal ?? 0)}';

    return Card(
      child: Column(
        children: [
          _SettingsRow(
            label: '成員',
            value: namesSummary.isEmpty ? '尚無成員' : namesSummary,
            onTap: () => _openSheet(context, (_) => _MembersListSheet(members: members)),
          ),
          _SettingsRow(
            label: '分攤比例',
            value: ratioSummary.isEmpty ? '尚無成員' : ratioSummary,
            onTap: () => _openSheet(context, (_) => const _RatioSheet()),
          ),
          _SettingsRow(
            label: '期初餘額',
            value: balanceSummary,
            onTap: () => _openSheet(context, (_) => const _OpeningBalanceSheet()),
          ),
        ],
      ),
    );
  }
}

class _MembersListSheet extends StatelessWidget {
  const _MembersListSheet({required this.members});
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('成員', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final m in members)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(child: Text(m.displayName.isNotEmpty ? m.displayName.substring(0, 1) : '?')),
              title: Text(m.displayName),
            ),
        ],
      ),
    );
  }
}

class _RatioSheet extends ConsumerStatefulWidget {
  const _RatioSheet();

  @override
  ConsumerState<_RatioSheet> createState() => _RatioSheetState();
}

class _RatioSheetState extends ConsumerState<_RatioSheet> {
  final Map<String, TextEditingController> _controllers = {};
  String? _error;

  TextEditingController _controllerFor(Member m, Map<String, int> ratio) =>
      _controllers.putIfAbsent(m.id, () => TextEditingController(text: (ratio[m.id] ?? 0).toString()));

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _save(Ledger ledger, List<Member> members) {
    final newRatio = <String, int>{};
    var sum = 0;
    for (final m in members) {
      final v = int.tryParse(_controllers[m.id]?.text.trim() ?? '') ?? 0;
      newRatio[m.id] = v;
      sum += v;
    }
    if (sum != 100) {
      setState(() => _error = '比例合計需為 100（目前 $sum）');
      return;
    }
    // sheet 蓋在上面時 SnackBar 會被擋住看不到（MAJOR-2）：錯誤改 sheet 內一行；成功先 pop 再補 SnackBar。
    final messenger = ScaffoldMessenger.of(context);
    try {
      ref.read(ledgerStateProvider.notifier).update(_copyLedger(ledger, defaultRatio: newRatio));
      Navigator.of(context).pop();
      messenger.showSnackBar(const SnackBar(content: Text('已儲存')));
    } catch (_) {
      setState(() => _error = '儲存失敗，請重試');
    }
  }

  @override
  Widget build(BuildContext context) {
    final members = ref.watch(membersProvider);
    final ledger = ref.watch(ledgerProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('預設分攤比例', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final m in members) ...[
                Expanded(
                  child: TextField(
                    key: ValueKey('ratio-field-${m.id}'),
                    controller: _controllerFor(m, ledger.defaultRatio),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: m.displayName, suffixText: '%'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(key: const ValueKey('save-ratio-button'), onPressed: () => _save(ledger, members), child: const Text('儲存比例')),
          ),
        ],
      ),
    );
  }
}

class _OpeningBalanceSheet extends ConsumerStatefulWidget {
  const _OpeningBalanceSheet();

  @override
  ConsumerState<_OpeningBalanceSheet> createState() => _OpeningBalanceSheetState();
}

class _OpeningBalanceSheetState extends ConsumerState<_OpeningBalanceSheet> {
  late final TextEditingController _sharedController;
  late final TextEditingController _personalController;
  String? _error;

  @override
  void initState() {
    super.initState();
    final ledger = ref.read(ledgerProvider);
    final meId = ref.read(currentMemberIdProvider);
    final me = _findMember(ref.read(membersProvider), meId);
    _sharedController = TextEditingController(text: ledger.openingBalanceShared.toString());
    _personalController = TextEditingController(text: (me?.openingBalancePersonal ?? 0).toString());
  }

  @override
  void dispose() {
    _sharedController.dispose();
    _personalController.dispose();
    super.dispose();
  }

  // 一顆「儲存」同時存共同與個人兩欄（任一失敗都停在 sheet 內顯示錯誤，不半途 pop）。
  // sheet 蓋在上面時 SnackBar 會被擋住看不到（MAJOR-2）：錯誤改 sheet 內一行；成功先 pop 再補 SnackBar。
  void _save(Ledger ledger, Member? me) {
    final sharedV = int.tryParse(_sharedController.text.trim());
    if (sharedV == null) {
      setState(() => _error = '請輸入有效金額');
      return;
    }
    final personalV = me == null ? null : int.tryParse(_personalController.text.trim());
    if (me != null && personalV == null) {
      setState(() => _error = '請輸入有效金額');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final ledgerNotifier = ref.read(ledgerStateProvider.notifier);
    try {
      ledgerNotifier.update(_copyLedger(ledger, openingBalanceShared: sharedV));
    } catch (_) {
      setState(() => _error = '儲存失敗，請重試');
      return;
    }
    if (me != null) {
      try {
        ref.read(membersStateProvider.notifier).update(Member(id: me.id, ledgerId: me.ledgerId, userId: me.userId, displayName: me.displayName, openingBalancePersonal: personalV!));
      } catch (_) {
        // 個人欄寫入失敗時把已寫進去的共同欄退回原值，讓「儲存失敗」文案與事實一致（兩欄都沒存）。
        // 退回本身若也炸，吞掉：本來就已在失敗路徑、sheet 仍留在畫面讓使用者重試。
        try {
          ledgerNotifier.update(ledger);
        } catch (_) {}
        setState(() => _error = '儲存失敗，請重試');
        return;
      }
    }
    Navigator.of(context).pop();
    messenger.showSnackBar(const SnackBar(content: Text('已儲存')));
  }

  @override
  Widget build(BuildContext context) {
    final ledger = ref.watch(ledgerProvider);
    final members = ref.watch(membersProvider);
    final meId = ref.watch(currentMemberIdProvider);
    final me = _findMember(members, meId);

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('期初餘額', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('opening-shared-field'),
            controller: _sharedController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '共同'),
          ),
          if (me != null) ...[
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('opening-personal-field'),
              controller: _personalController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '我的個人'),
            ),
          ] else
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('尚無成員資料')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(key: const ValueKey('save-opening-button'), onPressed: () => _save(ledger, me), child: const Text('儲存')),
          ),
        ],
      ),
    );
  }
}

class _OtherCard extends StatelessWidget {
  const _OtherCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          _SettingsRow(
            label: '分類管理',
            onTap: () => context.push('/settings/categories'),
          ),
          _SettingsRow(
            label: '登出',
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('登出：波 2 接後端'))),
          ),
        ],
      ),
    );
  }
}
