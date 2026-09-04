import 'package:flutter/material.dart';

import 'tutorial.dart';
import 'package:go_router/go_router.dart';

/// 底部四 Tab 外殼：帳目、統計、預算、清單。
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (i) => navigationShell.goBranch(i, initialLocation: i == navigationShell.currentIndex),
        destinations: [
          NavigationDestination(
              icon: KeyedSubtree(key: tutorialKey('tab-entries'), child: const Icon(Icons.receipt_long_outlined)),
              selectedIcon: const Icon(Icons.receipt_long),
              label: '帳目'),
          const NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: '統計'),
          // 新手導覽的聚焦目標（tutorial.dart）。
          NavigationDestination(
              icon: KeyedSubtree(key: tutorialKey('tab-budget'), child: const Icon(Icons.savings_outlined)),
              selectedIcon: const Icon(Icons.savings),
              label: '預算'),
          NavigationDestination(
              icon: KeyedSubtree(key: tutorialKey('tab-lists'), child: const Icon(Icons.checklist_outlined)),
              selectedIcon: const Icon(Icons.checklist),
              label: '清單'),
        ],
      ),
    );
  }
}
