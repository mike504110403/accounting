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

TutorialStep stepTitled(String title) =>
    tutorialSteps.firstWhere((s) => s.title == title, orElse: () => fail('找不到步驟「$title」'));

void main() {
  // ── 文案（純函式層：直接讀 tutorialSteps，不起 app）────────────────────
  //
  // 抽成純 test 的理由：導覽文案是 v1.5 的規格面（ADR-0009 廢掉視角／結算／分攤），
  // 驗它不需要把四個分頁都建出來——跨頁互動另有下面那條 widget test 顧。

  group('導覽文案（v1.5／ADR-0009）', () {
    test('沒有任何一步再提視角、結算、簽核、分攤、代墊或期初', () {
      const gone = ['視角', '家庭視角', '個人視角', '結算', '簽核', '分攤', '代墊', '期初', '私人', '份額'];
      for (final step in tutorialSteps) {
        for (final word in gone) {
          expect(step.title.contains(word), isFalse, reason: '步驟標題「${step.title}」不得提「$word」');
          expect(step.body.contains(word), isFalse, reason: '步驟「${step.title}」的內文不得提「$word」');
        }
      }
    });

    test('沒有指向已移除的視角切換錨點', () {
      expect(tutorialSteps.map((s) => s.target), isNot(contains('view-toggle')),
          reason: 'ViewModeToggle 已刪；target 找不到 rect 會讓 overlay 每幀重排重試');
      expect(tutorialSteps.length, 11, reason: 'v1.4 的 12 步拿掉視角那一步');
    });

    test('記帳入口那步改講「誰先付」，並點名預設是自己', () {
      final step = stepTitled('記帳入口');
      expect(step.body, contains('誰先付'));
      expect(step.body, contains('共同錢包'));
      expect(step.body, contains('補入剩餘'));
      expect(step.body, contains('共同餘額'));
      expect(
        step.body,
        '之後點「＋新增」記收入或支出：選分類、填金額，再選誰先付（預設你自己，也可以改成共同錢包）。先付的錢從你的補入剩餘扣，共同錢包付的從共同餘額扣。先看看其他頁面。',
      );
    });

    test('預算步文案：v1.5 只有一種支出，全部都扣預算', () {
      final step = stepTitled('本月預算');
      expect(step.body, '設定各分類的本月預算；所有支出都會扣，超支一眼看得到。');
      expect(step.body.contains('共同支出'), isFalse,
          reason: 'v1.5 只有一種支出＝家庭支出，沒有「共同支出」這個對照組');
      expect(step.body.contains('信封'), isFalse);
    });

    test('分類管理步文案：去分攤比例與餘額設定，改指我的名稱／成員／清帳與補入', () {
      final step = stepTitled('分類管理');
      expect(
        step.body,
        '這裡可以新增分類、拖曳排序；左滑任一列＝編輯／刪除。我的名稱、成員與清帳都在設定裡；每月到預算頁補入。',
      );
      expect(step.body, contains('補入'));
      expect(step.body.contains('餘額設定'), isFalse);
    });
  });

  // ── 跨頁互動（整個 app）──────────────────────────────────────────────

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

    // 0 記帳入口（說明）
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

    // 6 互動：回「帳目」（v1.5 拿掉視角那一步後，下一步直接是齒輪）
    await expectStep(6);
    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();

    // 7 互動：點齒輪進設定
    await expectStep(7);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    // 8 互動：點「分類管理」進子頁
    await expectStep(8);
    await tester.tap(find.text('分類管理'));
    await tester.pumpAndSettle();

    // 9 分類頁說明
    await expectStep(9);
    await tester.tap(find.byKey(const Key('tutorial-next')));
    await tester.pumpAndSettle();

    // 10 完成：收掉 overlay、帶回帳目頁
    await expectStep(10);
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

  testWidgets('maybeStart 在 widget test binding 下不自動開（既有測試不被劫持）', (tester) async {
    final c = await pumpApp(tester);
    c.read(tutorialProvider.notifier).maybeStart();
    await tester.pumpAndSettle();
    expect(c.read(tutorialProvider), isNull);
    expect(find.byKey(const Key('tutorial-card')), findsNothing);
  });
}
