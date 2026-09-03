import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/budget/budget_page.dart';
import '../features/entries/entries_page.dart';
import '../features/entries/entry_form_page.dart';
import '../features/lists/lists_page.dart';
import '../features/settings/category_page.dart';
import '../features/settings/settings_page.dart';
import '../features/stats/stats_page.dart';
import 'shell.dart';

/// 路由表。各頁只從自己的檔案掛進來，工人不改本檔。
final router = GoRouter(
  initialLocation: '/entries',
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(navigationShell: shell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/entries',
            builder: (_, _) => const EntriesPage(),
            routes: [
              GoRoute(path: 'new', builder: (_, _) => const EntryFormPage()),
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

/// 給沒有 go_router 上下文的地方用（少用）。
NavigatorState? get rootNavigator => router.routerDelegate.navigatorKey.currentState;
