import 'package:accounting/app/tutorial.dart';
import 'package:accounting/features/entries/entries_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ProviderContainer> pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final c = ProviderContainer();
  addTearDown(c.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: c, child: const AccountingApp()));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('互動導覽整條路：點亮區導頁自動前進，走完回帳目', (tester) async {
    final c = await pumpApp(tester);
    // widget test 不自動開（binding gate），顯式啟動。
    c.read(tutorialProvider.notifier).start();
    await tester.pumpAndSettle();

    Future<void> expectStep(int i) async {
      expect(find.byKey(const Key('tutorial-card')), findsOneWidget, reason: '第 $i 步');
      // 標題限定在卡片內找（步驟標題可能與頁面標題同字，如「分類管理」）。
      expect(
        find.descendant(
            of: find.byKey(const Key('tutorial-card')), matching: find.text(tutorialSteps[i].title)),
        findsOneWidget,
        reason: '第 $i 步標題',
      );
    }

    // 0 記帳入口（說明步）
    await expectStep(0);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    // 1 互動：卡片沒有下一步，點亮起的「預算」tab → 導頁自動前進
    await expectStep(1);
    expect(find.byKey(const Key('tutorial-next')), findsNothing, reason: '互動步沒有下一步鈕');
    // 亮區以外全鎖：點「統計」不會換頁
    await tester.tap(find.byIcon(Icons.pie_chart_outline), warnIfMissed: false);
    await tester.pumpAndSettle();
    await expectStep(1);
    await tester.tap(find.byIcon(Icons.savings_outlined));
    await tester.pumpAndSettle();

    // 2 預算頁說明
    await expectStep(2);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    // 3 互動：點「清單」
    await expectStep(3);
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();

    // 4 互動：點清單「＋」→ 真的開新增購物 sheet，並自動前進
    await expectStep(4);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('新增購物項目'), findsOneWidget, reason: '亮區點擊要放行、sheet 要真的開');

    // 5 說明（sheet 開著）：下一步會順手把 sheet 收掉
    await expectStep(5);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    expect(find.text('新增購物項目'), findsNothing, reason: '下一步要收掉 sheet');

    // 6 互動：回「帳目」
    await expectStep(6);
    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();

    // 7 家庭與個人（說明）
    await expectStep(7);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    // 8 互動：點齒輪進設定
    await expectStep(8);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    // 9 互動：點「分類管理」進子頁
    await expectStep(9);
    await tester.tap(find.text('分類管理'));
    await tester.pumpAndSettle();

    // 10 分類頁說明
    await expectStep(10);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    // 11 完成：收掉 overlay、帶回帳目頁
    await expectStep(11);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tutorial-card')), findsNothing);
    expect(c.read(tutorialProvider), isNull);
    expect(find.byType(EntriesPage), findsOneWidget, reason: '導覽結束帶回帳目頁');
  });

  testWidgets('說明步整個 app 被遮罩擋住；跳過立即收掉', (tester) async {
    final c = await pumpApp(tester);
    c.read(tutorialProvider.notifier).start();
    await tester.pumpAndSettle();

    // 遮罩吸掉點擊：點 FAB 位置不會開新增頁。
    await tester.tap(find.text('新增'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('form-step-0')), findsNothing, reason: '教學中點不到 FAB');

    await tester.tap(find.byKey(const Key('tutorial-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tutorial-card')), findsNothing);
  });

  testWidgets('預算步文案：v1.4 影子預算字串（直接斷言字串，不拿 tutorialSteps 當期望值）', (tester) async {
    final c = await pumpApp(tester);
    c.read(tutorialProvider.notifier).start();
    await tester.pumpAndSettle();

    // 0 記帳入口（說明步）→ 下一步
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    // 1 互動：點亮起的「預算」tab → 導頁自動前進到步驟 2
    await tester.tap(find.byIcon(Icons.savings_outlined));
    await tester.pumpAndSettle();

    // 2 預算頁說明：literal 斷言新文案（限定卡片內找，避免撞到底層 BudgetPage 同字的
    // 「本月預算」stat label——tutorial 高亮需要底層頁面真的建出來，兩處會同框）。
    final card = find.byKey(const Key('tutorial-card'));
    expect(find.descendant(of: card, matching: find.text('本月預算')), findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('設定各分類的本月預算；所有共同支出都會扣，超支一眼看得到。')),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.textContaining('信封')), findsNothing);
  });

  testWidgets('分類管理步文案：v1.4 餘額設定與清帳字串（直接斷言字串，不拿 tutorialSteps 當期望值）', (tester) async {
    final c = await pumpApp(tester);
    c.read(tutorialProvider.notifier).start();
    await tester.pumpAndSettle();

    // 0 記帳入口 → 下一步
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    // 1 互動：點「預算」tab
    await tester.tap(find.byIcon(Icons.savings_outlined));
    await tester.pumpAndSettle();
    // 2 預算頁說明 → 下一步
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    // 3 互動：點「清單」
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
    // 4 互動：點清單「＋」→ 真的開 sheet 並自動前進
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    // 5 說明（sheet 開著）→ 下一步順手收掉 sheet
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    // 6 互動：回「帳目」
    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();
    // 7 家庭與個人（說明）→ 下一步
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();
    // 8 互動：點齒輪進設定
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    // 9 互動：點「分類管理」進子頁
    await tester.tap(find.text('分類管理'));
    await tester.pumpAndSettle();

    // 10 分類頁說明：literal 斷言新文案（限定卡片內找）。
    final card = find.byKey(const Key('tutorial-card'));
    expect(
      find.descendant(
          of: card,
          matching:
              find.text('這裡可以新增分類、拖曳排序；左滑任一列＝編輯／刪除。分攤比例、餘額設定與清帳也都在設定裡。')),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.textContaining('期初餘額')), findsNothing);
  });

  testWidgets('maybeStart 在 widget test binding 下不自動開（既有測試不被劫持）', (tester) async {
    final c = await pumpApp(tester);
    c.read(tutorialProvider.notifier).maybeStart();
    await tester.pumpAndSettle();
    expect(c.read(tutorialProvider), isNull);
    expect(find.byKey(const Key('tutorial-card')), findsNothing);
  });
}
