import 'package:accounting/app/theme.dart';
import 'package:accounting/app/theme_mode.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/settings/category_page.dart';
import 'package:accounting/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

class _ThrowingLedgerNotifier extends LedgerNotifier {
  @override
  void update(Ledger l) => throw Exception('boom');
}

class _ThrowingCategoriesNotifier extends CategoriesNotifier {
  @override
  void add(Category c) => throw Exception('boom');
}

class _ThrowingMembersNotifier extends MembersNotifier {
  @override
  void update(Member m) => throw Exception('boom');
}

Finder _rowIcon(String rowText, IconData icon) => find.descendant(
      of: find.ancestor(of: find.text(rowText), matching: find.byType(ListTile)),
      matching: find.byIcon(icon),
    );

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
    await tester.tap(_rowIcon('食品', Icons.delete_outline));
    await tester.pumpAndSettle();

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
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();

    expect(find.text('寵物'), findsOneWidget);
    expect(container.read(categoriesProvider).length, before + 1);

    await tester.ensureVisible(_rowIcon('寵物', Icons.delete_outline)); // 真主題列高較大，新列在 800×600 落到畫面外
    await tester.tap(_rowIcon('寵物', Icons.delete_outline));
    await tester.pumpAndSettle();

    expect(find.text('寵物'), findsNothing);
    expect(container.read(categoriesProvider).length, before);
  });

  testWidgets('編輯分類名稱成功', (tester) async {
    final container = await _pump(tester);

    await _openCategoryPage(tester);
    await tester.tap(_rowIcon('交通', Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('category-name-field')), '交通費');
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

  testWidgets('帳本切換 sheet：說明文字拿掉，目前帳本改單行標籤在左值在右', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();

    expect(find.text('目前帳本'), findsOneWidget);
    // 主頁「帳本名稱」列＋「帳本切換」列的摘要值，加上 sheet 內「目前帳本」的值，都是同一個 ledger.name。
    expect(find.text('我們的家'), findsNWidgets(3));
    expect(find.text('加入其他帳本'), findsNothing); // 舊的說明文字已拿掉，欄位靠自己的 labelText 表意
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
    await tester.tap(find.byKey(const ValueKey('save-category-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    expect(find.byKey(const ValueKey('category-name-field')), findsOneWidget); // sheet 沒關
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

  testWidgets('帳本切換 sheet：驗證錯誤用 error 色、波 2 提示用一般色，兩者互斥', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    final errorColor = Theme.of(tester.element(find.text('加入'))).colorScheme.error; // 「帳本切換」同時是設定列與 sheet 標題，拿 sheet 內獨有的元素取主題

    await tester.tap(find.text('加入')); // 空碼
    await tester.pumpAndSettle();
    final errorText = tester.widget<Text>(find.text('請輸入 6 碼邀請碼'));
    expect(errorText.style?.color, errorColor);

    await tester.tap(find.text('新增帳本'));
    await tester.pumpAndSettle();
    expect(find.text('請輸入 6 碼邀請碼'), findsNothing);
    final infoText = tester.widget<Text>(find.text('波 2 接後端'));
    expect(infoText.style?.color, isNot(errorColor));
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
