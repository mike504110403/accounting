/// 登入頁：email／密碼登入與註冊，另加 Apple 登入按鈕。
///
/// 錯誤一律顯示在頁內紅字（不用 SnackBar：登入失敗時使用者的視線在表單上，
/// 而且 SnackBar 會自己消失，看不到就等於沒訊息）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../../data/auth.dart';
import '../../data/current_ledger.dart';
import '../../data/ledger_repository.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 登入成功後：有帳本就選一本並載快照進帳目頁，沒有就去首登。
  Future<void> _afterAuth() async {
    final hasLedger = await ref.read(currentLedgerIdProvider.notifier).selectFirstAvailable();
    if (!mounted) return;
    context.go(hasLedger ? '/entries' : '/onboarding');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _afterAuth();
    } catch (e) {
      // 失敗一定要解除 loading，否則按鈕永遠停用、使用者只能重整。
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is LedgerException ? e.message : '登入失敗，請稍後再試';
      });
    }
  }

  bool get _filled => _email.text.trim().isNotEmpty && _password.text.isNotEmpty;

  Future<void> _signIn() async {
    if (!_filled) {
      setState(() => _error = '請輸入 Email 與密碼');
      return;
    }
    await _run(() => ref
        .read(authProvider.notifier)
        .signIn(email: _email.text.trim(), password: _password.text));
  }

  Future<void> _signUp() async {
    if (!_filled) {
      setState(() => _error = '請輸入 Email 與密碼');
      return;
    }
    await _run(() => ref
        .read(authProvider.notifier)
        .signUp(email: _email.text.trim(), password: _password.text));
  }

  Future<void> _apple() => _run(() => ref.read(authProvider.notifier).signInWithApple());

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              // 簡潔版（Mike 裁示 2026-09-03）：主動線只有 Email／密碼／登入，
              // 註冊降級成文字鈕、Apple 縮成圓形 icon 鈕放「或」分隔線下。
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 藝術字標題（Mike 裁示 2026-09-03）：Pacifico 手寫體；字型載入前退回系統字。
                  Text(
                    'accounting',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.pacifico(
                      textStyle: t.textTheme.headlineLarge?.copyWith(color: t.colorScheme.primary),
                    ),
                  ),
                  const SizedBox(height: 40),
                  TextField(
                    key: const Key('login-email-field'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(labelText: 'Email'),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('login-password-field'),
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密碼'),
                    onSubmitted: (_) => _signIn(),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        key: const Key('login-error'),
                        style: TextStyle(color: t.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('login-button'),
                    onPressed: _busy ? null : _signIn,
                    child: Text(_busy ? '處理中…' : '登入'),
                  ),
                  TextButton(
                    key: const Key('signup-button'),
                    onPressed: _busy ? null : _signUp,
                    child: const Text('註冊新帳號'),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(child: Divider()),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('或',
                            style: t.textTheme.bodySmall
                                ?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                      ),
                      const Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: IconButton.outlined(
                      key: const Key('apple-signin-button'),
                      tooltip: '使用 Apple 登入',
                      onPressed: _busy ? null : _apple,
                      iconSize: 26,
                      padding: const EdgeInsets.all(12),
                      icon: const Icon(Icons.apple),
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
}
