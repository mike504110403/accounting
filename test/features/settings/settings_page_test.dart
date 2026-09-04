import 'package:accounting/app/theme.dart';
import 'package:accounting/app/theme_mode.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/settings/category_page.dart';
import 'package:accounting/data/current_ledger.dart';
import 'package:accounting/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/fixtures.dart';

class _ThrowingLedgerNotifier extends LedgerNotifier {
  @override
  Future<void> update(Ledger l) => throw Exception('boom');
}

class _ThrowingCategoriesNotifier extends CategoriesNotifier {
  @override
  Future<Category> add(Category c) => throw Exception('boom');
}

class _ThrowingMembersNotifier extends MembersNotifier {
  @override
  Future<void> update(Member m) => throw Exception('boom');
}

/// 分類列改左滑顯示編輯／刪除（2026-09-03）：先把該列往左拖開 action pane，再點對應圖示。
Future<void> _swipeRowAction(WidgetTester tester, String rowText, IconData icon) async {
  final tile = find.ancestor(of: find.text(rowText), matching: find.byType(ListTile));
  await tester.ensureVisible(tile);
  await tester.drag(tile, const Offset(-220, 0));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(icon));
  await tester.pumpAndSettle();
}

/// 帶最小 go_router（/settings、/settings/categories）的測試殼，比照真實 router.dart 的接法，
/// 讓「分類管理」列的 context.push 能實際導頁。每次呼叫都建新的 GoRouter，測試之間不共用導頁狀態。
Future<ProviderContainer> _pump(WidgetTester tester, [ProviderContainer? withContainer]) async {
  final container = withContainer ?? ProviderContainer();
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/settings',
    routes: [
      GoRoute(
        path: '/settings',
        builder: (_, _) => const SettingsPage(),
        routes: [GoRoute(path: 'categories', builder: (_, _) => const CategoryPage())],
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      // 套真主題（不是 MaterialApp 預設主題）：buildTheme 對按鈕、卡片等的樣式覆寫（例如 FilledButton
      // minimumSize）才會真的在測試裡生效，之前測試殼沒套真主題，主題地雷（見 8349213）測不出來。
      child: MaterialApp.router(theme: buildTheme(Brightness.light), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// 點設定頁裡「分攤比例」一行，開 bottom sheet。
Future<void> _openRatioSheet(WidgetTester tester) async {
  await tester.tap(find.text('分攤比例'));
  await tester.pumpAndSettle();
}

/// 點設定頁裡「期初餘額」一行，開 bottom sheet。
Future<void> _openOpeningBalanceSheet(WidgetTester tester) async {
  await tester.tap(find.text('期初餘額'));
  await tester.pumpAndSettle();
}

/// 點設定頁裡「分類管理」一行，進子頁。
Future<void> _openCategoryPage(WidgetTester tester) async {
  await tester.tap(find.text('分類管理'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // widget test 沒有真正的平台剪貼簿實作，手動 mock 讓 Clipboard.setData 成功回傳。
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async => null,
    );
  });

  testWidgets('比例合計≠100 擋存，ledger 不變', (tester) async {
    final container = await _pump(tester);
    final before = container.read(ledgerProvider).defaultRatio;

    await _openRatioSheet(tester);
    await tester.enterText(find.byKey(ValueKey('ratio-field-$kMeId')), '70');
    await tester.enterText(find.byKey(ValueKey('ratio-field-$kWifeId')), '40');
    await tester.tap(find.byKey(const ValueKey('save-ratio-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('比例合計需為 100'), findsOneWidget);
    expect(container.read(ledgerProvider).defaultRatio, before);
  });

  testWidgets('比例合計＝100 儲存成功，ledger 更新', (tester) async {
    final container = await _pump(tester);

    await _openRatioSheet(tester);
    await tester.enterText(find.byKey(ValueKey('ratio-field-$kMeId')), '60');
    await tester.enterText(find.byKey(ValueKey('ratio-field-$kWifeId')), '40');
    await tester.tap(find.byKey(const ValueKey('save-ratio-button')));
    await tester.pumpAndSettle();

    expect(find.text('已儲存'), findsOneWidget);
    expect(container.read(ledgerProvider).defaultRatio, {kMeId: 60, kWifeId: 40});
    // 成功後 sheet 應已關閉（MAJOR-2：先 pop 再 snack），欄位不該還在畫面上。
    expect(find.byKey(ValueKey('ratio-field-$kMeId')), findsNothing);
  });

  testWidgets('刪除使用中分類被擋，分類仍存在', (tester) async {
    final container = await _pump(tester);

    await _openCategoryPage(tester);
    await _swipeRowAction(tester, '食品', Icons.delete_outline);

    expect(find.text('此分類已有帳目使用，無法刪除'), findsOneWidget);
    expect(container.read(categoriesProvider).any((c) => c.id == 'c-food'), isTrue);
  });

  testWidgets('新增分類成功後可刪除（未使用中）', (tester) async {
    final container = await _pump(tester);
    final before = container.read(categoriesProvider).length;

    await _openCategoryPage(tester);
    await tester.tap(find.byKey(const ValueKey('add-category-expense')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('category-name-field')), '寵物');
    // 步驟精靈：名稱 → 下一步 → 圖示 → 儲存（同一顆鈕）。
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();

    expect(find.text('寵物'), findsOneWidget);
    expect(container.read(categoriesProvider).length, before + 1);

    await _swipeRowAction(tester, '寵物', Icons.delete_outline);

    expect(find.text('寵物'), findsNothing);
    expect(container.read(categoriesProvider).length, before);
  });

  testWidgets('編輯分類名稱成功', (tester) async {
    final container = await _pump(tester);

    await _openCategoryPage(tester);
    await _swipeRowAction(tester, '交通', Icons.edit_outlined);
    await tester.enterText(find.byKey(const ValueKey('category-name-field')), '交通費');
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();

    expect(find.text('交通費'), findsOneWidget);
    expect(container.read(categoriesProvider).firstWhere((c) => c.id == 'c-transport').name, '交通費');
  });

  testWidgets('期初餘額（共同／個人）一次儲存成功', (tester) async {
    final container = await _pump(tester);

    // 一顆「儲存」同時存共同與個人兩欄（不再各存各的、各自 pop 一次）。
    await _openOpeningBalanceSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('opening-shared-field')), '99999');
    await tester.enterText(find.byKey(const ValueKey('opening-personal-field')), '12345');
    await tester.tap(find.byKey(const ValueKey('save-opening-button')));
    await tester.pumpAndSettle();

    expect(container.read(ledgerProvider).openingBalanceShared, 99999);
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).openingBalancePersonal, 12345);
    expect(find.byKey(const ValueKey('opening-shared-field')), findsNothing); // sheet 已關
  });

  testWidgets('帳本名稱編輯成功', (tester) async {
    final container = await _pump(tester);

    await tester.tap(find.text('帳本名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ledger-name-field')), '新家名稱');
    await tester.tap(find.byKey(const ValueKey('save-ledger-name-button')));
    await tester.pumpAndSettle();

    expect(container.read(ledgerProvider).name, '新家名稱');
    expect(find.byKey(const ValueKey('ledger-name-field')), findsNothing); // sheet 已關
  });

  testWidgets('邀請碼複製', (tester) async {
    // 獨立成一條測試：帳本名稱儲存後也會彈 SnackBar，跟複製的 SnackBar 排隊會互相干擾判斷時機。
    await _pump(tester);

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pumpAndSettle();
    expect(find.text('已複製邀請碼'), findsOneWidget);
  });

  testWidgets('帳本切換 sheet：列出所屬帳本，目前那本打勾且不可再點', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();

    final option = find.byKey(const ValueKey('ledger-option-$kLedgerId'));
    expect(option, findsOneWidget);
    expect(find.descendant(of: option, matching: find.byIcon(Icons.check_circle)), findsOneWidget);
    expect(tester.widget<ListTile>(option).enabled, isFalse, reason: '已經在這本了，不該還能點');
    expect(find.text('加入其他帳本'), findsNothing); // 說明文字拿掉，欄位靠自己的 labelText 表意
  });

  testWidgets('帳本切換 sheet：加入帳本用正確的 10 碼邀請碼可切過去', (tester) async {
    final other = Ledger(
      id: 'ledger-2',
      name: '第二本',
      inviteCode: 'BBBBBBBBBB',
      defaultRatio: const {kMeId: 100},
    );
    final container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(repoWith(ledger: other, entries: const [], settlements: const [])),
    ]);
    await _pump(tester, container);
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('join-code-field')), 'bbbbbbbbbb');
    await tester.tap(find.byKey(const ValueKey('join-ledger-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('join-code-field')), findsNothing, reason: '成功後 sheet 收掉');
    expect(container.read(currentLedgerIdProvider), 'ledger-2');
  });

  testWidgets('帳本切換 sheet：新增帳本走 create_ledger，切到新帳本', (tester) async {
    final container = ProviderContainer();
    await _pump(tester, container);
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('new-ledger-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('new-ledger-name-field')), '小家庭');
    await tester.tap(find.byKey(const ValueKey('create-ledger-button')));
    await tester.pumpAndSettle();

    expect(container.read(ledgerProvider).name, '小家庭');
    expect(container.read(entriesProvider), isEmpty, reason: '換帳本＝整份快照換掉，不得殘留上一本的帳目');
  });

  testWidgets('期初餘額列的值文字不被攔腰截斷（MAJOR-1：Spacer+Flexible 平分寬度的舊 bug，取最緊的樣本列）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(tester);

    final rowFinder = find.ancestor(of: find.text('期初餘額'), matching: find.byType(Row)).first;
    final valueFinder = find.descendant(of: rowFinder, matching: find.textContaining('／'));
    final paragraph = tester.renderObject<RenderParagraph>(valueFinder);
    expect(paragraph.didExceedMaxLines, isFalse);
  });

  testWidgets('外觀列：標籤與 SegmentedButton 同一行（單行、標籤在左）', (tester) async {
    await _pump(tester);

    final appearanceRow = find.ancestor(of: find.text('外觀'), matching: find.byType(Row));
    expect(find.descendant(of: appearanceRow, matching: find.byKey(const Key('theme-mode-toggle'))), findsOneWidget);
  });

  testWidgets('比例儲存失敗：sheet 內顯示錯誤且維持開啟（MAJOR-2：不再用被 sheet 蓋住看不到的 SnackBar）', (tester) async {
    await _pump(tester, ProviderContainer(overrides: [ledgerStateProvider.overrideWith(() => _ThrowingLedgerNotifier())]));

    await _openRatioSheet(tester);
    await tester.enterText(find.byKey(ValueKey('ratio-field-$kMeId')), '60');
    await tester.enterText(find.byKey(ValueKey('ratio-field-$kWifeId')), '40');
    await tester.tap(find.byKey(const ValueKey('save-ratio-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    // sheet 沒關（欄位還在），錯誤是 sheet 內的一行，不是可能被蓋住的 SnackBar。
    expect(find.byKey(ValueKey('ratio-field-$kMeId')), findsOneWidget);
  });

  testWidgets('期初餘額儲存失敗（共同欄寫入炸掉）：sheet 內顯示錯誤且維持開啟、ledger 不變', (tester) async {
    final container = await _pump(tester, ProviderContainer(overrides: [ledgerStateProvider.overrideWith(() => _ThrowingLedgerNotifier())]));
    final before = container.read(ledgerProvider).openingBalanceShared;

    await _openOpeningBalanceSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('opening-shared-field')), '99999');
    await tester.tap(find.byKey(const ValueKey('save-opening-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    expect(find.byKey(const ValueKey('opening-shared-field')), findsOneWidget); // sheet 沒關
    expect(container.read(ledgerProvider).openingBalanceShared, before);
  });

  testWidgets('新增分類儲存失敗：sheet 內顯示錯誤且維持開啟、分類清單不變', (tester) async {
    final container = await _pump(tester, ProviderContainer(overrides: [categoriesStateProvider.overrideWith(() => _ThrowingCategoriesNotifier())]));
    final before = container.read(categoriesProvider).length;

    await _openCategoryPage(tester);
    await tester.tap(find.byKey(const ValueKey('add-category-expense')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('category-name-field')), '寵物');
    // 步驟精靈：名稱 → 下一步 → 圖示 → 儲存（同一顆鈕）。
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    // sheet 沒關（步驟精靈停在圖示步，名稱欄不在畫面上，改驗儲存鈕仍在）。
    expect(find.byKey(const ValueKey('save-category-button')), findsOneWidget);
    expect(container.read(categoriesProvider).length, before);
  });

  testWidgets('期初餘額儲存失敗（個人欄寫入炸掉）：sheet 內顯示錯誤且維持開啟、member 不變、已寫入的共同欄退回原值', (tester) async {
    final container = await _pump(tester, ProviderContainer(overrides: [membersStateProvider.overrideWith(() => _ThrowingMembersNotifier())]));
    final before = container.read(membersProvider).firstWhere((m) => m.id == kMeId).openingBalancePersonal;
    final sharedBefore = container.read(ledgerProvider).openingBalanceShared;

    await _openOpeningBalanceSheet(tester);
    // 共同欄也改成新值：共同先寫成功、個人再炸，斷言共同被退回（不是沒動過就剛好等於原值）。
    await tester.enterText(find.byKey(const ValueKey('opening-shared-field')), '${sharedBefore + 1}');
    await tester.enterText(find.byKey(const ValueKey('opening-personal-field')), '99999');
    await tester.tap(find.byKey(const ValueKey('save-opening-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    expect(find.byKey(const ValueKey('opening-personal-field')), findsOneWidget); // sheet 沒關
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).openingBalancePersonal, before);
    expect(container.read(ledgerProvider).openingBalanceShared, sharedBefore);
  });

  testWidgets('帳本切換 sheet：碼長不對與錯碼都用 error 色顯示在 sheet 內，不切帳本', (tester) async {
    final container = ProviderContainer();
    await _pump(tester, container);
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    // 「帳本切換」同時是設定列與 sheet 標題，拿 sheet 內獨有的元素取主題
    final errorColor = Theme.of(tester.element(find.text('加入'))).colorScheme.error;

    await tester.tap(find.text('加入')); // 空碼
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('請輸入 10 碼邀請碼')).style?.color, errorColor);

    await tester.enterText(find.byKey(const ValueKey('join-code-field')), 'ZZZZZZZZZZ');
    await tester.tap(find.byKey(const ValueKey('join-ledger-button')));
    await tester.pumpAndSettle();
    expect(find.text('請輸入 10 碼邀請碼'), findsNothing);
    expect(tester.widget<Text>(find.text('邀請碼不正確')).style?.color, errorColor);
    expect(find.byKey(const ValueKey('join-code-field')), findsOneWidget, reason: '失敗不關 sheet');
    expect(container.read(ledgerProvider).id, kLedgerId, reason: '錯碼不該切走');
  });

  testWidgets('邀請碼列：顯示 10 碼，「重新產生」換一組新碼', (tester) async {
    final container = ProviderContainer();
    await _pump(tester, container);
    final before = container.read(ledgerProvider).inviteCode;
    expect(before.length, 10);
    expect(find.text(before), findsOneWidget);

    await tester.tap(find.byKey(const Key('rotate-invite-code')));
    await tester.pumpAndSettle();

    final after = container.read(ledgerProvider).inviteCode;
    expect(after.length, 10);
    expect(after, isNot(before));
    expect(find.text(after), findsOneWidget);
  });

  testWidgets('切夜晚後 themeModeProvider 為 dark', (tester) async {
    // sharedPrefsProvider 預設就是 null（見 theme_mode.dart），不用另外 override。
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(home: SettingsPage())));
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), ThemeMode.system);

    await tester.tap(find.text('夜晚'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), ThemeMode.dark);
  });

  testWidgets('390×844 緊湊：整頁內容高度 ≤ 螢幕高（不必捲動）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: SettingsPage())));
    await tester.pumpAndSettle();

    final contentHeight = tester.getSize(find.byKey(const Key('settings-content-column'))).height;
    expect(contentHeight, lessThanOrEqualTo(844));
  });

  testWidgets('390px 不爆版（無 overflow）', (tester) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: SettingsPage())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色主題渲染不炸', (tester) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6F6D), brightness: Brightness.dark)),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('390×667＋鍵盤 336：開分類 sheet 無 overflow 且「儲存」鈕可點（MAJOR-A）', (tester) async {
    tester.view.physicalSize = const Size(390, 667);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await _pump(tester);
    await _openCategoryPage(tester);
    await tester.tap(find.byKey(const ValueKey('add-category-expense')));
    await tester.pumpAndSettle();
    // 鍵盤在 sheet 開了、名稱欄 autofocus 之後才彈起：inset 這時才設（先設會把設定頁也壓住、點不到「分類管理」）。
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull); // 鍵盤彈起後 sheet 沒有 overflow

    await tester.ensureVisible(find.byKey(const ValueKey('save-category-button')));
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // 鈕真的點得到、點下去也沒炸（名稱空白顯示 sheet 內錯誤）
    expect(find.text('請輸入名稱'), findsOneWidget);
  });

  testWidgets('真主題（buildTheme）下開四個 sheet 都不炸', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('帳本名稱'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('save-ledger-name-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('加入')); // 裸 FilledButton 在 Row 裡，主題地雷（8349213）測這裡
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(20, 20)); // 點外面關掉 sheet
    await tester.pumpAndSettle();

    await _openRatioSheet(tester);
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await _openOpeningBalanceSheet(tester);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('save-opening-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
