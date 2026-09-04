import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/auth.dart';
import '../data/current_ledger.dart';
import '../features/auth/login_page.dart';
import '../features/auth/onboarding_page.dart';
import '../features/budget/budget_page.dart';
import '../domain/models.dart';
import '../features/entries/entries_page.dart';
import '../features/entries/entry_form_page.dart';
import '../features/lists/lists_page.dart';
import '../features/settings/category_page.dart';
import '../features/settings/settings_page.dart';
import '../features/stats/stats_page.dart';
import 'shell.dart';
import 'tutorial.dart' show tutorialNavObserver;

const kLoginRoute = '/login';
const kOnboardingRoute = '/onboarding';
const kHomeRoute = '/entries';

/// 三態分流：沒登入 → 登入頁；登入了但還沒有帳本 → 首登頁；其餘放行。
///
/// 抽成純函式的理由：`redirect` 是這一層唯一的安全邊界（沒有它，重新整理就能
/// 直接開到 `/entries` 看見上一個帳號的畫面），純函式才測得動全部三態。
String? authRedirect({
  required bool signedIn,
  required bool hasLedger,
  required String location,
}) {
  if (!signedIn) return location == kLoginRoute ? null : kLoginRoute;
  if (!hasLedger) return location == kOnboardingRoute ? null : kOnboardingRoute;
  // 已經登入且有帳本就不該停在登入頁；但 /onboarding 允許停留——
  // 建立帳本成功的當下 hasLedger 已翻真，還要停在「分享邀請碼」關（2026-09-03）。
  // 老使用者誤入 /onboarding 由頁面 initState 的 _resolveExisting 自己送去 /entries。
  if (location == kLoginRoute) return kHomeRoute;
  return null;
}

/// 登入狀態或帳本變動時要求 GoRouter 重跑一次 `redirect`。
class _RouterRefresh extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// 路由表。四個 Tab 的路由是波 1 定案的，不隨資料層變動。
///
/// 做成 provider（不是 top-level 單例）是因為 `redirect` 必須讀到**這個
/// ProviderContainer** 的登入／帳本狀態；單例只能讀全域可變狀態，測試之間會互相污染。
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen(signedInProvider, (_, _) => refresh.bump());
  ref.listen(hasLedgerProvider, (_, _) => refresh.bump());

  final router = GoRouter(
    initialLocation: kHomeRoute,
    refreshListenable: refresh,
    observers: [tutorialNavObserver],
    redirect: (context, state) => authRedirect(
      signedIn: ref.read(signedInProvider),
      hasLedger: ref.read(hasLedgerProvider),
      location: state.matchedLocation,
    ),
    routes: [
      GoRoute(path: kLoginRoute, builder: (_, _) => const LoginPage()),
      GoRoute(path: kOnboardingRoute, builder: (_, _) => const OnboardingPage()),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(navigationShell: shell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/entries',
              builder: (_, _) => const EntriesPage(),
              routes: [
                GoRoute(path: 'new', builder: (_, state) => EntryFormPage(template: state.extra as Entry?)),
                GoRoute(path: ':id', builder: (_, s) => EntryFormPage(entryId: s.pathParameters['id'])),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [GoRoute(path: '/stats', builder: (_, _) => const StatsPage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/budget', builder: (_, _) => const BudgetPage())]),
          StatefulShellBranch(routes: [GoRoute(path: '/lists', builder: (_, _) => const ListsPage())]),
        ],
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const SettingsPage(),
        routes: [GoRoute(path: 'categories', builder: (_, _) => const CategoryPage())],
      ),
    ],
  );

  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
