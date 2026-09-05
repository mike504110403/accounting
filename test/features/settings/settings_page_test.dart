import 'package:accounting/app/theme.dart';
import 'package:accounting/app/theme_mode.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/settings/category_page.dart';
import 'package:accounting/features/settings/closes_page.dart';
import 'package:accounting/data/current_ledger.dart';
import 'package:accounting/features/settings/settings_page.dart';
import 'package:flutter/material.dart';
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

/// 模擬 `join_ledger`／`create_ledger` RPC 的預設名：拿不到 full_name 就退到 email 前綴，
/// Apple 隱藏信箱給的是 `4yrcfzrc99` 這種代號。替身本來加入不改名，這裡刻意改成代號。
///
/// 替身只有一本帳本，`myLedgers()` 改回另一本假的，讓「加入／新增」在 sheet 眼裡是本來不在的帳本。
class _RelayNameOnJoinRepository extends InMemoryLedgerRepository {
  _RelayNameOnJoinRepository({super.seed});

  int updateMemberCalls = 0;

  @override
  Future<List<Ledger>> myLedgers() async =>
      [const Ledger(id: 'ledger-other', name: '原本那本', inviteCode: 'CCCCCCCCCC')];

  @override
  Future<void> updateMember(Member member) {
    updateMemberCalls++;
    return super.updateMember(member);
  }

  Future<void> _relayName(Ledger l) async {
    final me = (await fetchMembers(l.id)).firstWhere((m) => m.id == kMeId);
    await super.updateMember(me.copyWith(displayName: '4yrcfzrc99'));
  }

  @override
  Future<Ledger> joinLedger(String code) async {
    final l = await super.joinLedger(code);
    await _relayName(l);
    return l;
  }

  @override
  Future<Ledger> createLedger(String name) async {
    final l = await super.createLedger(name);
    await _relayName(l);
    return l;
  }
}

/// 加入「自己已在的那本」：`join_ledger` 不新建成員列直接回，替身照樣不改名。
class _AlreadyMemberRepository extends InMemoryLedgerRepository {
  int updateMemberCalls = 0;

  @override
  Future<void> updateMember(Member member) {
    updateMemberCalls++;
    return super.updateMember(member);
  }
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
        routes: [
          GoRoute(path: 'categories', builder: (_, _) => const CategoryPage()),
          GoRoute(path: 'closes', builder: (_, _) => const ClosesPage()),
        ],
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

/// 點設定頁裡「分類管理」一行，進子頁。
Future<void> _openCategoryPage(WidgetTester tester) async {
  // 預設 800×600 測試面板下，「我的名稱」列（2026-09-05）把這列推到 y≈631 螢幕外；先捲到可見。
  await tester.ensureVisible(find.text('分類管理'));
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

  testWidgets('設定頁：無「分攤比例」「共同期初餘額」「我的每月補入額」列', (tester) async {
    await _pump(tester);

    expect(find.text('分攤比例'), findsNothing);
    expect(find.text('共同期初餘額'), findsNothing);
    expect(find.text('我的每月補入額'), findsNothing);
  });

  testWidgets('設定頁：有「我的名稱」「成員」「清帳」列', (tester) async {
    await _pump(tester);

    expect(find.text('我的名稱'), findsOneWidget);
    expect(find.text('成員'), findsOneWidget);
    expect(find.text('清帳'), findsOneWidget);
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

  testWidgets('我的名稱列：顯示自己的 display_name，sheet 改名儲存後列與 membersProvider 都更新', (tester) async {
    final container = await _pump(tester);
    final before = container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName;
    final row = find.byKey(const Key('my-name-row'));
    expect(find.descendant(of: row, matching: find.text(before)), findsOneWidget);

    await tester.tap(find.text('我的名稱'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('member-name-field'))).controller?.text, before);

    await tester.enterText(find.byKey(const ValueKey('member-name-field')), '  阿米  ');
    await tester.tap(find.byKey(const ValueKey('save-member-name-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('member-name-field')), findsNothing, reason: '成功後 sheet 收掉');
    final me = container.read(membersProvider).firstWhere((m) => m.id == kMeId);
    expect(me.displayName, '阿米', reason: '前後空白要剪掉');
    expect(find.descendant(of: row, matching: find.text('阿米')), findsOneWidget);
    // 其他成員與自己的其他欄位不動。
    expect(container.read(membersProvider).firstWhere((m) => m.id == kWifeId).displayName, '老婆');
  });

  testWidgets('我的名稱：空白 → sheet 內錯誤行、不 pop、member 不變', (tester) async {
    final container = await _pump(tester);
    final before = container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName;
    await tester.tap(find.text('我的名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('member-name-field')), '   ');
    await tester.tap(find.byKey(const ValueKey('save-member-name-button')));
    await tester.pumpAndSettle();

    expect(find.text('請輸入你的名稱'), findsOneWidget);
    expect(find.byKey(const ValueKey('member-name-field')), findsOneWidget);
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName, before);
  });

  testWidgets('我的名稱：儲存失敗 → sheet 內顯示錯誤且維持開啟、member 不變', (tester) async {
    final container = await _pump(
      tester,
      ProviderContainer(overrides: [membersStateProvider.overrideWith(_ThrowingMembersNotifier.new)]),
    );
    final before = container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName;
    await tester.tap(find.text('我的名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('member-name-field')), '阿米');
    await tester.tap(find.byKey(const ValueKey('save-member-name-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    expect(find.byKey(const ValueKey('member-name-field')), findsOneWidget);
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName, before);
  });

  testWidgets('成員列：點開列出所有成員', (tester) async {
    await _pump(tester);

    await tester.tap(find.text('成員'));
    await tester.pumpAndSettle();

    expect(find.text('Mike'), findsWidgets);
    expect(find.text('老婆'), findsOneWidget);
  });

  testWidgets('帳本切換 sheet：加入帳本會把目前的名稱帶過去，不留 RPC 的 email 前綴代號', (tester) async {
    final container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(_RelayNameOnJoinRepository(
        seed: snapshotWith(
          ledger: const Ledger(id: 'ledger-2', name: '第二本', inviteCode: 'BBBBBBBBBB'),
          entries: const [],
        ),
      )),
    ]);
    await _pump(tester, container);
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName, 'Mike');
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('join-code-field')), 'BBBBBBBBBB');
    await tester.tap(find.byKey(const ValueKey('join-ledger-button')));
    await tester.pumpAndSettle();

    expect(container.read(currentLedgerIdProvider), 'ledger-2');
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName, 'Mike');
  });

  testWidgets('帳本切換 sheet：新增帳本也把目前的名稱帶過去', (tester) async {
    final repo = _RelayNameOnJoinRepository();
    final container = ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);
    await _pump(tester, container);
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('new-ledger-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('new-ledger-name-field')), '小家庭');
    await tester.tap(find.byKey(const ValueKey('create-ledger-button')));
    await tester.pumpAndSettle();

    expect(container.read(ledgerProvider).name, '小家庭');
    expect(container.read(membersProvider).firstWhere((m) => m.id == kMeId).displayName, 'Mike');
    expect(repo.updateMemberCalls, 1, reason: '帶名寫入恰好一次');
  });

  testWidgets('帳本切換 sheet：貼自己已在那本的邀請碼 → 不帶名（不蓋掉那本設好的名字）', (tester) async {
    final repo = _AlreadyMemberRepository();
    final container = ProviderContainer(overrides: [ledgerRepositoryProvider.overrideWithValue(repo)]);
    await _pump(tester, container);
    final code = container.read(ledgerProvider).inviteCode;
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('join-code-field')), code);
    await tester.tap(find.byKey(const ValueKey('join-ledger-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('join-code-field')), findsNothing, reason: 'sheet 照樣收掉');
    expect(repo.updateMemberCalls, 0, reason: '已是成員：不該再寫 display_name');
  });

  testWidgets('帳本切換 sheet：帶名失敗 → 仍切換並關 sheet，SnackBar 提示可到「我的名稱」改', (tester) async {
    final repo = _RelayNameOnJoinRepository(
      seed: snapshotWith(
        ledger: const Ledger(id: 'ledger-2', name: '第二本', inviteCode: 'BBBBBBBBBB'),
        entries: const [],
      ),
    );
    final container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(repo),
      membersStateProvider.overrideWith(_ThrowingMembersNotifier.new),
    ]);
    await _pump(tester, container);
    await tester.tap(find.text('帳本切換'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('join-code-field')), 'BBBBBBBBBB');
    await tester.tap(find.byKey(const ValueKey('join-ledger-button')));
    await tester.pumpAndSettle();

    expect(container.read(currentLedgerIdProvider), 'ledger-2');
    expect(find.byKey(const ValueKey('join-code-field')), findsNothing);
    expect(find.text('名稱沒帶過去，可到「我的名稱」再改'), findsOneWidget);
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
    const other = Ledger(id: 'ledger-2', name: '第二本', inviteCode: 'BBBBBBBBBB');
    final container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(repoWith(ledger: other, entries: const [])),
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

  testWidgets('外觀列：標籤與 SegmentedButton 同一行（單行、標籤在左）', (tester) async {
    await _pump(tester);

    final appearanceRow = find.ancestor(of: find.text('外觀'), matching: find.byType(Row));
    expect(find.descendant(of: appearanceRow, matching: find.byKey(const Key('theme-mode-toggle'))), findsOneWidget);
  });

  testWidgets('帳本名稱儲存失敗：sheet 內顯示錯誤且維持開啟（MAJOR-2：不再用被 sheet 蓋住看不到的 SnackBar）', (tester) async {
    final container = await _pump(tester, ProviderContainer(overrides: [ledgerStateProvider.overrideWith(() => _ThrowingLedgerNotifier())]));
    final before = container.read(ledgerProvider).name;

    await tester.tap(find.text('帳本名稱'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('ledger-name-field')), '新家名稱');
    await tester.tap(find.byKey(const ValueKey('save-ledger-name-button')));
    await tester.pumpAndSettle();

    expect(find.text('儲存失敗，請重試'), findsOneWidget);
    // sheet 沒關（欄位還在），錯誤是 sheet 內的一行，不是可能被蓋住的 SnackBar。
    expect(find.byKey(const ValueKey('ledger-name-field')), findsOneWidget);
    expect(container.read(ledgerProvider).name, before);
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

  testWidgets('真主題（buildTheme）下開設定頁的幾個 sheet 都不炸', (tester) async {
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

    await tester.tap(find.text('我的名稱'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.text('成員'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('設定頁一頁顯示：390×844 下不需要捲動（spec 資訊密度）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pump(tester);

    // 去分攤比例與餘額設定後應更寬裕，但一頁顯示是硬要求：加新列前先確認這條還是綠的。
    final position = tester
        .state<ScrollableState>(find.descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        ))
        .position;
    expect(position.maxScrollExtent, 0.0);
  });

  // ── 清帳入口（v1.5） ────────────────────────────────────────────────

  testWidgets('清帳列：沒有任何清帳紀錄時顯示「尚未清帳」', (tester) async {
    await _pump(tester);
    expect(find.text('清帳'), findsOneWidget);
    expect(find.text('尚未清帳'), findsOneWidget);
  });

  testWidgets('清帳列：有紀錄時顯示「上次清帳 YYYY／MM」，取最後一個月不是最後一列', (tester) async {
    final container = ProviderContainer(overrides: [
      ledgerRepositoryProvider.overrideWithValue(repoWith(closes: [
        closeFixture(month: DateTime(2026, 6, 1)),
        closeFixture(month: DateTime(2026, 7, 1)),
        closeFixture(month: DateTime(2026, 5, 1)),
      ])),
    ]);
    await _pump(tester, container);

    expect(find.text('上次清帳 2026／07'), findsOneWidget);
  });

  testWidgets('點「清帳」進子頁 /settings/closes', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('清帳'));
    await tester.pumpAndSettle();

    expect(find.byType(ClosesPage), findsOneWidget);
    expect(find.widgetWithText(AppBar, '清帳'), findsOneWidget);
  });
}
