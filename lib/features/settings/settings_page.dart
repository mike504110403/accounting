import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/build_info.dart';
import '../../app/tutorial.dart';

import '../../app/format.dart';
import '../../app/theme_mode.dart';
import '../../data/auth.dart';
import '../../data/current_ledger.dart';
import '../../data/ledger_repository.dart';
import '../../domain/mock_data.dart';
import '../../domain/models.dart';
import 'closes_page.dart' show lastClosedMonth;
import 'member_name_sheet.dart' show MemberNameSheet, saveMyDisplayName;

/// 設定：帳本、外觀、成員、清帳與分類管理入口（波 1 工人實作，替換本檔內容）。
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

Ledger _copyLedger(Ledger l, {String? name}) => Ledger(
      id: l.id,
      name: name ?? l.name,
      inviteCode: l.inviteCode,
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
  const _SettingsRow({super.key, required this.label, this.value, this.trailing, this.onTap});
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const Key('copy-invite-code'),
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: '複製邀請碼',
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
                IconButton(
                  key: const Key('rotate-invite-code'),
                  icon: const Icon(Icons.refresh),
                  tooltip: '重新產生邀請碼（舊碼立刻失效）',
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    try {
                      await ref.read(ledgerStateProvider.notifier).rotateInviteCode();
                      messenger.showSnackBar(const SnackBar(content: Text('已產生新的邀請碼')));
                    } catch (e) {
                      messenger.showSnackBar(
                        SnackBar(content: Text(e is LedgerException ? e.message : '產生失敗，請重試')),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          _SettingsRow(
            label: '帳本切換',
            value: ledger.name,
            onTap: () => _openSheet(context, (_) => const _LedgerSwitchSheet()),
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
  bool _saving = false;

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

  Future<void> _save(Ledger ledger) async {
    if (_saving) return;
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '請輸入名稱');
      return;
    }
    // sheet 蓋在上面時 ScaffoldMessenger 的 SnackBar 會被 sheet 擋住看不到（MAJOR-2）：
    // 錯誤改顯示在 sheet 內；成功則先 pop 讓出畫面、再用 pop 前存好的 messenger 補 SnackBar。
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(ledgerStateProvider.notifier).update(_copyLedger(ledger, name: name));
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
            child: FilledButton(
              key: const ValueKey('save-ledger-name-button'),
              onPressed: _saving ? null : () => _save(ledger),
              child: Text(_saving ? '儲存中…' : '儲存'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 帳本切換／加入／新增。三件事都是真的寫入：
/// 切換＝重載快照、加入＝`join_ledger`（10 碼邀請碼）、新增＝`create_ledger`。
class _LedgerSwitchSheet extends ConsumerStatefulWidget {
  const _LedgerSwitchSheet();

  @override
  ConsumerState<_LedgerSwitchSheet> createState() => _LedgerSwitchSheetState();
}

class _LedgerSwitchSheetState extends ConsumerState<_LedgerSwitchSheet> {
  final _joinController = TextEditingController();
  final _newNameController = TextEditingController(text: '我們的家');
  String? _error;
  bool _busy = false;
  bool _creating = false;
  List<Ledger>? _ledgers;

  @override
  void initState() {
    super.initState();
    _loadLedgers();
  }

  @override
  void dispose() {
    _joinController.dispose();
    _newNameController.dispose();
    super.dispose();
  }

  Future<void> _loadLedgers() async {
    try {
      final list = await ref.read(ledgerRepositoryProvider).myLedgers();
      if (mounted) setState(() => _ledgers = list);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ledgers = const [];
        _error = e is LedgerException ? e.message : '讀取帳本清單失敗，請重試';
      });
    }
  }

  /// 三條路共用的收尾：選定帳本 → 重載快照 → 關掉 sheet。
  ///
  /// `carryName`（加入／新增）：新帳本裡的成員列是 RPC 用 email 前綴建的（Apple 隱藏信箱＝代號），
  /// 把目前帳本裡自己的名稱帶過去，不必再填一次；之後隨時可在「我的名稱」改。
  ///
  /// 只帶到**本來不是成員**的帳本：貼到自己已在的那本邀請碼時 `join_ledger` 直接回（不新建成員列），
  /// 這時帶名會蓋掉在那本設好的名字。「已是成員」以 sheet 開啟時抓的 `_ledgers` 判定。
  /// 帶名失敗不擋切換（帳本已切好、名稱可事後改），pop 後補一句 SnackBar 提示。
  Future<void> _run(Future<String> Function() action, {bool carryName = false}) async {
    if (_busy) return;
    final myName = _findMember(ref.read(membersProvider), ref.read(currentMemberIdProvider))?.displayName;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ledgerId = await action();
      final alreadyMember = _ledgers?.any((l) => l.id == ledgerId) ?? false;
      await ref.read(currentLedgerIdProvider.notifier).select(ledgerId);
      var nameFailed = false;
      if (carryName && !alreadyMember && myName != null && myName.isNotEmpty) {
        try {
          await saveMyDisplayName(ref, myName);
        } catch (_) {
          nameFailed = true;
        }
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      if (nameFailed) {
        messenger.showSnackBar(const SnackBar(content: Text('名稱沒帶過去，可到「我的名稱」再改')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is LedgerException ? e.message : '操作失敗，請重試';
      });
    }
  }

  Future<void> _join() async {
    final code = _joinController.text.trim().toUpperCase();
    if (code.length != kInviteCodeLength) {
      setState(() => _error = '請輸入 $kInviteCodeLength 碼邀請碼');
      return;
    }
    await _run(() async => (await ref.read(ledgerRepositoryProvider).joinLedger(code)).id, carryName: true);
  }

  Future<void> _create() async {
    final name = _newNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '請輸入帳本名稱');
      return;
    }
    await _run(() async => (await ref.read(ledgerRepositoryProvider).createLedger(name)).id, carryName: true);
  }

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(ledgerProvider).id;
    final ledgers = _ledgers;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('帳本切換', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (ledgers == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('載入中…'),
              )
            else
              for (final l in ledgers)
                ListTile(
                  key: ValueKey('ledger-option-${l.id}'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(l.id == currentId ? Icons.check_circle : Icons.circle_outlined, size: 18),
                  title: Text(l.name),
                  enabled: !_busy && l.id != currentId,
                  onTap: () => _run(() async => l.id),
                ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('join-code-field'),
                    controller: _joinController,
                    maxLength: kInviteCodeLength,
                    // 同首登：先濾非英數再截長度，貼上夾空白不吃名額。
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]'))],
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: '輸入 $kInviteCodeLength 碼邀請碼',
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('join-ledger-button'),
                  onPressed: _busy ? null : _join,
                  child: const Text('加入'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_creating) ...[
              TextField(
                key: const ValueKey('new-ledger-name-field'),
                controller: _newNameController,
                decoration: const InputDecoration(labelText: '新帳本名稱'),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('create-ledger-button'),
                  onPressed: _busy ? null : _create,
                  child: const Text('建立'),
                ),
              ),
            ] else
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  key: const ValueKey('new-ledger-button'),
                  onPressed: _busy ? null : () => setState(() => _creating = true),
                  icon: const Icon(Icons.add),
                  label: const Text('新增帳本'),
                ),
              ),
            // sheet 蓋在最上層，SnackBar 會被擋住看不到（MAJOR-2）：狀態改顯示在 sheet 內。
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
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
    final members = ref.watch(membersProvider);
    final meId = ref.watch(currentMemberIdProvider);
    final me = _findMember(members, meId);

    final namesSummary = members.map((m) => m.displayName).join('、');

    return Card(
      child: Column(
        children: [
          _SettingsRow(
            key: const Key('my-name-row'),
            label: '我的名稱',
            value: me?.displayName ?? '—',
            onTap: () => _openSheet(context, (_) => const MemberNameSheet()),
          ),
          _SettingsRow(
            label: '成員',
            value: namesSummary.isEmpty ? '尚無成員' : namesSummary,
            onTap: () => _openSheet(context, (_) => _MembersListSheet(members: members)),
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

class _OtherCard extends ConsumerWidget {
  const _OtherCard();

  /// 登出。帳本選擇與快照的清理統一由 `AuthNotifier` 的登入狀態監聽做
  /// （登出、token 過期、別的分頁換帳號都會走到同一條路）。
  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(authProvider.notifier).signOut();
      if (context.mounted) context.go('/login');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is LedgerException ? e.message : '登出失敗，請重試')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final last = lastClosedMonth(ref.watch(monthClosesProvider));
    return Card(
      child: Column(
        children: [
          _SettingsRow(
            key: const Key('closes-row'),
            label: '清帳',
            value: last == null ? '尚未清帳' : '上次清帳 ${fmtYearMonth(last)}',
            onTap: () => context.push('/settings/closes'),
          ),
          KeyedSubtree(
            key: tutorialKey('settings-categories'),
            child: _SettingsRow(
              label: '分類管理',
              onTap: () => context.push('/settings/categories'),
            ),
          ),
          _SettingsRow(
            key: const Key('sign-out-row'),
            label: '登出',
            onTap: () => _signOut(context, ref),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'build $kBuildStamp',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
