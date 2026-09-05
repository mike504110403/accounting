/// 首登頁（Mike 裁示 2026-09-03 關卡制）：
/// 關 0 二選一（建立新帳本／用邀請碼加入）→ 關 1 輸入（**你的名稱**＋帳本名稱／邀請碼）
/// → 建立成功再一關顯示邀請碼＋一鍵複製，才進 app。
///
/// 名稱一律使用者自己填（Mike 2026-09-05）：RPC 的預設名是 email 前綴，Apple 隱藏信箱
/// 給的是 `4yrcfzrc99` 這種代號，不能拿來當人名。
///
/// 錯誤一律顯示在頁內紅字（不用 SnackBar）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/current_ledger.dart';
import '../../data/ledger_repository.dart';
import '../../domain/models.dart';
import '../settings/member_name_sheet.dart' show kMemberNameMaxLength, saveMyDisplayName, validateMemberName;

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({super.key});

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

enum _Step { choose, create, join, share }

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _myName = TextEditingController();
  final _name = TextEditingController(text: '我們的家');
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;
  _Step _step = _Step.choose;

  /// 建立成功的帳本（share 關用：名稱＋邀請碼）。
  Ledger? _created;

  /// 還沒確認「這個帳號到底有沒有帳本」之前不顯示兩條路。
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _resolveExisting();
  }

  /// 「沒有帳本」的唯一可靠判定是 `myLedgers()` 為空，不是「本機沒存過帳本 id」——
  /// 換一台裝置、清過瀏覽器資料、或開機載快照失敗，本機都會是空的，
  /// 但雲端那邊帳本好好的。少了這一步，老使用者會被丟進首登頁，
  /// 而首登頁只給「建帳本／輸邀請碼」兩條路——自己的帳本反而回不去，是條死路。
  Future<void> _resolveExisting() async {
    try {
      final selected = await ref.read(currentLedgerIdProvider.notifier).selectFirstAvailable();
      if (!mounted) return;
      if (selected) {
        context.go('/entries');
        return;
      }
      setState(() => _checking = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = e is LedgerException ? e.message : '讀取帳本失敗，請稍後再試';
      });
    }
  }

  @override
  void dispose() {
    _myName.dispose();
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  /// 建立／加入成功、快照載好之後把自己改名。
  ///
  /// 失敗不擋進 app：帳本已經建好（或已加入），停在本頁重按會再建一本。
  /// 名稱隨時可在設定頁改，這裡只用 SnackBar 提示（MaterialApp 層的 messenger，跨頁還在）。
  Future<void> _applyMyName() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await saveMyDisplayName(ref, _myName.text);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('名稱儲存失敗，可到設定頁再改')));
    }
  }

  Future<void> _create() async {
    final nameError = validateMemberName(_myName.text);
    if (nameError != null) {
      setState(() => _error = nameError);
      return;
    }
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '請輸入帳本名稱');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ledger = await ref.read(ledgerRepositoryProvider).createLedger(name);
      await ref.read(currentLedgerIdProvider.notifier).select(ledger.id);
      if (!mounted) return;
      await _applyMyName();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _created = ledger;
        _step = _Step.share; // 建立完先給分享關，按「開始使用」才進 app
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is LedgerException ? e.message : '操作失敗，請稍後再試';
      });
    }
  }

  Future<void> _join() async {
    final nameError = validateMemberName(_myName.text);
    if (nameError != null) {
      setState(() => _error = nameError);
      return;
    }
    final code = _code.text.trim().toUpperCase();
    if (code.length != kInviteCodeLength) {
      setState(() => _error = '請輸入 $kInviteCodeLength 碼邀請碼');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ledger = await ref.read(ledgerRepositoryProvider).joinLedger(code);
      await ref.read(currentLedgerIdProvider.notifier).select(ledger.id);
      if (!mounted) return;
      await _applyMyName();
      if (mounted) context.go('/entries');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is LedgerException ? e.message : '操作失敗，請稍後再試';
      });
    }
  }

  /// 系統分享棄用（Mike 裁示 2026-09-04）：只做邀請碼複製。
  Future<void> _copyCode() async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: _created!.inviteCode));
    messenger.showSnackBar(const SnackBar(content: Text('已複製邀請碼')));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_step != _Step.share)
                    Row(
                      children: [
                        if (_step != _Step.choose)
                          IconButton(
                            key: const Key('onboarding-back'),
                            icon: const Icon(Icons.arrow_back),
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                      _step = _Step.choose;
                                      _error = null;
                                    }),
                          )
                        else
                          const SizedBox(width: 48),
                        Expanded(
                          child: Text('開始使用', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
                        ),
                        const SizedBox(width: 48),
                      ],
                    ),
                  const SizedBox(height: 24),
                  ..._stepBody(t),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        _error!,
                        key: const Key('onboarding-error'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: t.colorScheme.error),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 建立／加入兩關共用的「你的名稱」欄（放最上面、autofocus）。
  List<Widget> _myNameFields(ThemeData t) => [
        Text('你的名稱', style: t.textTheme.labelLarge),
        const SizedBox(height: 12),
        TextField(
          key: const Key('onboarding-my-name-field'),
          controller: _myName,
          autofocus: true,
          maxLength: kMemberNameMaxLength,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(isDense: true, hintText: '對方會看到的名字', counterText: ''),
        ),
        const SizedBox(height: 20),
      ];

  List<Widget> _stepBody(ThemeData t) {
    switch (_step) {
      case _Step.choose:
        return [
          _ChoiceCard(
            key: const Key('onboarding-choose-create'),
            icon: Icons.add_home_outlined,
            title: '建立新帳本',
            subtitle: '開一本自己的帳，再邀另一半加入',
            onTap: () => setState(() {
              _step = _Step.create;
              _error = null;
            }),
          ),
          const SizedBox(height: 16),
          _ChoiceCard(
            key: const Key('onboarding-choose-join'),
            icon: Icons.group_add_outlined,
            title: '加入既有帳本',
            subtitle: '拿到邀請碼了？輸入就能加入',
            onTap: () => setState(() {
              _step = _Step.join;
              _error = null;
            }),
          ),
        ];
      case _Step.create:
        return [
          ..._myNameFields(t),
          Text('帳本名稱', style: t.textTheme.labelLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('onboarding-name-field'),
            controller: _name,
            decoration: const InputDecoration(isDense: true),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('onboarding-create-button'),
            onPressed: _busy ? null : _create,
            child: Text(_busy ? '處理中…' : '建立帳本'),
          ),
        ];
      case _Step.join:
        return [
          ..._myNameFields(t),
          Text('邀請碼', style: t.textTheme.labelLarge),
          const SizedBox(height: 12),
          TextField(
            key: const Key('onboarding-code-field'),
            controller: _code,
            maxLength: kInviteCodeLength,
            // 先濾掉空白／標點再套長度上限：聊天軟體複製常夾頭尾空白，
            // 不濾的話空白吃掉一個名額，10 碼代碼只剩 9 碼有效（2026-09-04 實測回報）。
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]'))],
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '輸入 $kInviteCodeLength 碼邀請碼',
              counterText: '',
            ),
            onSubmitted: (_) => _join(),
          ),
          const SizedBox(height: 24),
          FilledButton(
            key: const Key('onboarding-join-button'),
            onPressed: _busy ? null : _join,
            child: Text(_busy ? '處理中…' : '加入帳本'),
          ),
        ];
      case _Step.share:
        final l = _created!;
        return [
          Icon(Icons.celebration_outlined, size: 40, color: t.colorScheme.primary),
          const SizedBox(height: 12),
          Text('「${l.name}」建好了！', textAlign: TextAlign.center, style: t.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('把邀請碼分享給另一半，兩個人記同一本帳。',
              textAlign: TextAlign.center,
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: t.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              l.inviteCode,
              key: const Key('onboarding-invite-code'),
              textAlign: TextAlign.center,
              style: t.textTheme.headlineSmall?.copyWith(
                letterSpacing: 4,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('onboarding-share-button'),
            onPressed: _copyCode,
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('複製邀請碼'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('onboarding-start-button'),
            onPressed: () => context.go('/entries'),
            child: const Text('開始使用'),
          ),
        ];
    }
  }
}

/// 關 0 的大卡選項。
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(icon, size: 28, color: t.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: t.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
