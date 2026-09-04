import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app/router.dart';
import 'app/theme.dart';
import 'app/theme_mode.dart';
import 'data/auth.dart';
import 'data/current_ledger.dart';
import 'data/ledger_repository.dart';
import 'app/tutorial.dart';
import 'data/polling.dart';
import 'data/realtime.dart';
import 'data/supabase_client.dart';
import 'data/supabase_repository.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 連線與快照載入期間先給一個 spinner，不要停在白畫面。
  runApp(const _BootSplash());

  final prefs = await SharedPreferences.getInstance();

  SupabaseClient? client;
  SupabaseLedgerRepository? repo;
  String? origin;
  String? bootError;

  if (!kUseMock) {
    await initSupabase();
    client = Supabase.instance.client;
    repo = SupabaseLedgerRepository(client);

    bootError = await restoreSelectedLedger(
      prefs: prefs,
      repo: repo,
      hasSession: client.auth.currentSession != null,
    );
    if (bootError != null) debugPrint('開機載入帳本快照失敗: $bootError');

    try {
      origin = Uri.base.origin; // Web 才有意義；其他平台會丟例外。
    } catch (_) {
      origin = null;
    }
  }

  runApp(ProviderScope(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      if (client != null && repo != null) ...[
        supabaseClientProvider.overrideWithValue(client),
        ledgerRepositoryProvider.overrideWithValue(repo),
        authServiceProvider.overrideWithValue(SupabaseAuthService(client, redirectTo: origin)),
        realtimeSourceProvider.overrideWithValue(SupabaseRealtimeSource(client)),
      ],
      if (bootError != null) bootErrorProvider.overrideWith(() => _PresetBootError(bootError!)),
    ],
    child: const AccountingApp(),
  ));
}

/// 把 `main()` 算出來的開機錯誤帶進 provider 圖。
class _PresetBootError extends BootErrorNotifier {
  _PresetBootError(this._message);
  final String _message;

  @override
  String? build() => _message;
}

/// 開機期間的 loading 畫面。
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) => MaterialApp(
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
}

class AccountingApp extends ConsumerWidget {
  const AccountingApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    // watch 而不是 read：Realtime 訂閱的生命週期掛在這個 provider 上，
    // 沒人 watch 它就不會被建立（也就永遠收不到事件）。
    ref.watch(ledgerRealtimeProvider);
    // 5 秒輪詢保底（Mike 裁示 2026-09-03）：Realtime 漏事件也追得回來。
    ref.watch(ledgerPollingProvider);
    final bootError = ref.watch(bootErrorProvider);

    // 開機載快照失敗時擋在路由前面：帳本 id 還留著（redirect 會放行到帳目頁），
    // 但快照是空的，直接進去只會看到一個空殼子。
    if (bootError != null) {
      return MaterialApp(
        title: '共同記帳',
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: mode,
        debugShowCheckedModeBanner: false,
        home: const BootErrorScreen(),
      );
    }

    return MaterialApp.router(
      // 新手導覽圖層蓋在整個 router 之上（tutorial.dart）。
      builder: (context, child) => Stack(
        children: [?child, const TutorialLayer()],
      ),
      title: '共同記帳',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      routerConfig: ref.watch(routerProvider),
      debugShowCheckedModeBanner: false,
    );
  }
}

/// 開機載不到帳本時的錯誤畫面：只提供「重試」，不清掉已選的帳本。
class BootErrorScreen extends ConsumerStatefulWidget {
  const BootErrorScreen({super.key});

  @override
  ConsumerState<BootErrorScreen> createState() => _BootErrorScreenState();
}

class _BootErrorScreenState extends ConsumerState<BootErrorScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    await ref.read(bootErrorProvider.notifier).retry();
    if (mounted) setState(() => _retrying = false);
  }

  @override
  Widget build(BuildContext context) {
    final message = ref.watch(bootErrorProvider) ?? '';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off, size: 40, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(height: 16),
                Text(
                  message,
                  key: const Key('boot-error-message'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('boot-retry-button'),
                  onPressed: _retrying ? null : _retry,
                  child: Text(_retrying ? '重試中…' : '重試'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
