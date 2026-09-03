import 'package:flutter/material.dart';

import 'category_section.dart';

/// 分類管理子頁：從設定頁「分類管理 ›」進入，內容沿用 category_section.dart。
class CategoryPage extends StatelessWidget {
  const CategoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分類管理')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: const SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: CategoryManagementSection(),
          ),
        ),
      ),
    );
  }
}
