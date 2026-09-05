/// 登入 → 首登 → 帳目頁的完整開機路徑，以及 `router.redirect` 的三態。
///
/// redirect 是這一層唯一的安全邊界：漏掉任何一態，重新整理就能直接開到不該看到的畫面。
library;

import 'package:accounting/app/router.dart';
import 'package:accounting/data/auth.dart';
import 'package:accounting/data/current_ledger.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:accounting/domain/models.dart';
import 'package:accounting/features/auth/login_page.dart';
import 'package:accounting/features/auth/onboarding_page.dart';
import 'package:accounting/features/entries/entries_page.dart';
import 'package:accounting/main.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

/// 改名寫入炸掉的成員 notifier（驗「首登改名失敗不擋進 app」）。
class _ThrowingMembersNotifier extends MembersNotifier {
  @override
  Future<void> update(Member m) => throw Exception('boom');
}

/// 模擬 `main.dart` 在開機載快照失敗時 override 進來的初值。
class _PresetBootError extends BootErrorNotifier {
  @override
  String? build() => '連線失敗，請檢查網路後再試';
}


Future<ProviderContainer> pumpApp(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const AccountingApp()));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('redirect 三態（純函式）', () {
    test('沒有 session → 一律送去 /login', () {
      expect(authRedirect(signedIn: false, hasLedger: false, location: '/entries'), '/login');
      expect(authRedirect(signedIn: false, hasLedger: true, location: '/settings'), '/login');
      expect(authRedirect(signedIn: false, hasLedger: false, location: '/onboarding'), '/login');
    });

    test('已經在 /login 就不再導（否則會無限重導）', () {
      expect(authRedirect(signedIn: false, hasLedger: false, location: '/login'), isNull);
    });

    test('有 session 但沒有帳本 → 送去 /onboarding', () {
      expect(authRedirect(signedIn: true, hasLedger: false, location: '/entries'), '/onboarding');
      expect(authRedirect(signedIn: true, hasLedger: false, location: '/budget'), '/onboarding');
      expect(authRedirect(signedIn: true, hasLedger: false, location: '/onboarding'), isNull);
    });

    test('有 session 又有帳本 → 放行，且不再停在登入／首登頁', () {
      expect(authRedirect(signedIn: true, hasLedger: true, location: '/entries'), isNull);
      expect(authRedirect(signedIn: true, hasLedger: true, location: '/lists'), isNull);
      expect(authRedirect(signedIn: true, hasLedger: true, location: '/login'), '/entries');
      // /onboarding 允許停留（建立帳本後的分享關）；頁面自己會把老使用者送走。
      expect(authRedirect(signedIn: true, hasLedger: true, location: '/onboarding'), isNull);
    });
  });

  group('登入頁', () {
    ProviderContainer signedOutContainer({LedgerRepository? repo}) => ProviderContainer(overrides: [
          authServiceProvider.overrideWithValue(InMemoryAuthService.signedOut()),
          if (repo != null) ledgerRepositoryProvider.overrideWithValue(repo),
        ]);

    testWidgets('未登入開機 → 停在登入頁，看不到帳目', (tester) async {
      await pumpApp(tester, signedOutContainer());
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(EntriesPage), findsNothing);
      expect(find.text('本月買菜'), findsNothing, reason: '沒登入不該看到任何帳本資料');
    });

    testWidgets('錯密碼 → 頁內紅字、按鈕恢復可按、仍停在登入頁', (tester) async {
      await pumpApp(tester, signedOutContainer());

      await tester.enterText(find.byKey(const Key('login-email-field')), 'mike@test.local');
      await tester.enterText(find.byKey(const Key('login-password-field')), 'wrong');
      await tester.tap(find.byKey(const Key('login-button')));
      await tester.pumpAndSettle();

      final error = find.byKey(const Key('login-error'));
      expect(error, findsOneWidget);
      expect(tester.widget<Text>(error).data, 'Email 或密碼不正確');
      expect(
        tester.widget<Text>(error).style?.color,
        Theme.of(tester.element(error)).colorScheme.error,
      );
      expect(tester.widget<FilledButton>(find.byKey(const Key('login-button'))).onPressed, isNotNull,
          reason: '失敗要解除 loading，否則使用者只能重整');
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('對的密碼 → 載入帳本快照並進帳目頁', (tester) async {
      final c = await pumpApp(tester, signedOutContainer());

      await tester.enterText(find.byKey(const Key('login-email-field')), 'mike@test.local');
      await tester.enterText(find.byKey(const Key('login-password-field')), 'password');
      await tester.tap(find.byKey(const Key('login-button')));
      await tester.pumpAndSettle();

      expect(find.byType(EntriesPage), findsOneWidget);
      expect(c.read(currentLedgerIdProvider), kLedgerId);
      expect(find.text('本月買菜'), findsOneWidget);
    });

    testWidgets('登入成功但這個帳號還沒有帳本 → 進首登頁', (tester) async {
      await pumpApp(tester, signedOutContainer(repo: NoLedgerRepository()));

      await tester.enterText(find.byKey(const Key('login-email-field')), 'mike@test.local');
      await tester.enterText(find.byKey(const Key('login-password-field')), 'password');
      await tester.tap(find.byKey(const Key('login-button')));
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingPage), findsOneWidget);
    });

    testWidgets('Apple 登入：provider 未開時錯誤顯示在頁內', (tester) async {
      await pumpApp(tester, signedOutContainer());
      await tester.tap(find.byKey(const Key('apple-signin-button')));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const Key('login-error'))).data, 'Apple 登入尚未啟用');
      expect(find.byType(LoginPage), findsOneWidget);
    });

    testWidgets('iOS 只放 Apple 登入：email／密碼／註冊整段藏起來（Mike 裁示 2026-09-04）', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await pumpApp(tester, signedOutContainer());

        expect(find.byKey(const Key('apple-signin-button')), findsOneWidget);
        expect(find.byKey(const Key('login-email-field')), findsNothing);
        expect(find.byKey(const Key('login-password-field')), findsNothing);
        expect(find.byKey(const Key('login-button')), findsNothing);
        expect(find.byKey(const Key('signup-button')), findsNothing);
      } finally {
        // 一定要在測試本體內歸零：framework 的 invariant 檢查跑在 tearDown 之前。
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('首登頁', () {
    ProviderContainer onboardingContainer({LedgerRepository? repo}) => ProviderContainer(overrides: [
          ledgerRepositoryProvider.overrideWithValue(repo ?? NoLedgerRepository()),
        ]);

    testWidgets('有 session 但沒有帳本 → 開機停在首登頁', (tester) async {
      await pumpApp(tester, onboardingContainer());
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.byType(EntriesPage), findsNothing);
    });

    testWidgets('路 1：建立帳本 → 選定該帳本並進帳目頁', (tester) async {
      final c = await pumpApp(tester, onboardingContainer());

      await tester.tap(find.byKey(const Key('onboarding-choose-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-my-name-field')), '阿米');
      await tester.enterText(find.byKey(const Key('onboarding-name-field')), '小家庭');
      await tester.tap(find.byKey(const Key('onboarding-create-button')));
      await tester.pumpAndSettle();

      // 建立完先到分享關：顯示邀請碼與分享鈕，按「開始使用」才進 app。
      expect(find.byKey(const Key('onboarding-invite-code')), findsOneWidget);
      expect(find.byKey(const Key('onboarding-share-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('onboarding-start-button')));
      await tester.pumpAndSettle();

      expect(find.byType(EntriesPage), findsOneWidget);
      expect(c.read(ledgerProvider).name, '小家庭');
      expect(c.read(currentLedgerIdProvider), c.read(ledgerProvider).id);
      expect(c.read(entriesProvider), isEmpty, reason: '新帳本沒有帳目');
      expect(c.read(categoriesProvider), isNotEmpty, reason: 'create_ledger 會灌預設分類');
      expect(c.read(membersProvider).firstWhere((m) => m.id == c.read(currentMemberIdProvider)).displayName, '阿米',
          reason: '首登填的名稱要寫進自己的成員列，不留 RPC 的 email 前綴');
    });

    testWidgets('建立帳本：改名寫入失敗 → 仍進分享關與 app，SnackBar 提示到設定頁改', (tester) async {
      final c = await pumpApp(
        tester,
        ProviderContainer(overrides: [
          ledgerRepositoryProvider.overrideWithValue(NoLedgerRepository()),
          membersStateProvider.overrideWith(_ThrowingMembersNotifier.new),
        ]),
      );
      await tester.tap(find.byKey(const Key('onboarding-choose-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-my-name-field')), '阿米');
      await tester.enterText(find.byKey(const Key('onboarding-name-field')), '小家庭');
      await tester.tap(find.byKey(const Key('onboarding-create-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('onboarding-invite-code')), findsOneWidget, reason: '帳本已建，不擋');
      expect(find.text('名稱儲存失敗，可到設定頁再改'), findsOneWidget);
      expect(c.read(currentLedgerIdProvider), isNotNull);
    });

    testWidgets('建立帳本：沒填你的名稱 → 頁內錯誤、不建帳本、不離開首登頁', (tester) async {
      final c = await pumpApp(tester, onboardingContainer());
      await tester.tap(find.byKey(const Key('onboarding-choose-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-my-name-field')), '   ');
      await tester.tap(find.byKey(const Key('onboarding-create-button')));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const Key('onboarding-error'))).data, '請輸入你的名稱');
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(c.read(currentLedgerIdProvider), isNull, reason: '名稱沒過驗證就不該打 create_ledger');
    });

    testWidgets('路 2：輸入 10 碼邀請碼加入 → 進同一本帳本', (tester) async {
      final c = await pumpApp(tester, onboardingContainer());

      await tester.tap(find.byKey(const Key('onboarding-choose-join')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-my-name-field')), '阿米');
      await tester.enterText(find.byKey(const Key('onboarding-code-field')), 'a7k3qzm4xb');
      await tester.tap(find.byKey(const Key('onboarding-join-button')));
      await tester.pumpAndSettle();

      expect(find.byType(EntriesPage), findsOneWidget);
      expect(c.read(currentLedgerIdProvider), kLedgerId);
      expect(c.read(ledgerProvider).name, '我們的家');
      expect(c.read(membersProvider).firstWhere((m) => m.id == c.read(currentMemberIdProvider)).displayName, '阿米');
    });

    testWidgets('加入帳本：沒填你的名稱 → 頁內錯誤，邀請碼對也不加入', (tester) async {
      final c = await pumpApp(tester, onboardingContainer());
      await tester.tap(find.byKey(const Key('onboarding-choose-join')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-code-field')), 'a7k3qzm4xb');
      await tester.tap(find.byKey(const Key('onboarding-join-button')));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const Key('onboarding-error'))).data, '請輸入你的名稱');
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(c.read(currentLedgerIdProvider), isNull);
    });

    testWidgets('邀請碼碼長不對 → 頁內錯誤，不離開首登頁', (tester) async {
      await pumpApp(tester, onboardingContainer());

      await tester.tap(find.byKey(const Key('onboarding-choose-join')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-my-name-field')), '阿米');
      await tester.enterText(find.byKey(const Key('onboarding-code-field')), 'ABC');
      await tester.tap(find.byKey(const Key('onboarding-join-button')));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const Key('onboarding-error'))).data, '請輸入 10 碼邀請碼');
      expect(find.byType(OnboardingPage), findsOneWidget);
    });

    testWidgets('邀請碼錯 → 頁內顯示資料層錯誤，按鈕恢復可按', (tester) async {
      await pumpApp(tester, onboardingContainer());

      await tester.tap(find.byKey(const Key('onboarding-choose-join')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('onboarding-my-name-field')), '阿米');
      await tester.enterText(find.byKey(const Key('onboarding-code-field')), 'ZZZZZZZZZZ');
      await tester.tap(find.byKey(const Key('onboarding-join-button')));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const Key('onboarding-error'))).data, '邀請碼不正確');
      expect(tester.widget<FilledButton>(find.byKey(const Key('onboarding-join-button'))).onPressed,
          isNotNull);
      expect(find.byType(OnboardingPage), findsOneWidget);
    });
  });

  group('本機沒選過帳本，但雲端有（換裝置／清過瀏覽器資料）', () {
    testWidgets('不停在首登頁：自動選定既有帳本並進帳目頁', (tester) async {
      // 「有沒有帳本」的可靠判定是 myLedgers()，不是本機存過的 id。
      // 少了這一步，老使用者換一台裝置就會被丟進只有「建帳本／輸邀請碼」兩條路的
      // 首登頁——自己的帳本反而回不去，是條死路。
      final c = await pumpApp(
        tester,
        ProviderContainer(overrides: [
          ledgerRepositoryProvider.overrideWithValue(UnselectedLedgerRepository()),
        ]),
      );

      expect(find.byType(EntriesPage), findsOneWidget);
      expect(find.byType(OnboardingPage), findsNothing);
      expect(find.byKey(const Key('onboarding-create-button')), findsNothing,
          reason: '有帳本就不該看到「建立帳本」那兩條路');
      expect(c.read(currentLedgerIdProvider), kLedgerId);
      expect(find.text('本月買菜'), findsOneWidget);
    });

    testWidgets('真的一本都沒有時才顯示兩條路', (tester) async {
      await pumpApp(
        tester,
        ProviderContainer(overrides: [
          ledgerRepositoryProvider.overrideWithValue(NoLedgerRepository()),
        ]),
      );
      expect(find.byType(OnboardingPage), findsOneWidget);
      expect(find.byKey(const Key('onboarding-choose-create')), findsOneWidget);
    });
  });

  group('換帳號', () {
    test('auth 事件一到就清掉快照與帳本選擇（不必等呼叫端做任何事）', () async {
      final service = InMemoryAuthService(
        user: const AuthUser(id: 'u1', email: 'mike@test.local'),
        credentials: const {'someone-else@test.local': 'x'},
      );
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(service),
        ledgerRepositoryProvider.overrideWithValue(repoWith()),
      ]);
      addTearDown(container.dispose);

      container.read(authProvider); // 啟動登入狀態監聽
      expect(container.read(entriesProvider), isNotEmpty);
      expect(container.read(currentLedgerIdProvider), kLedgerId);

      // 另一個帳號登入（uid 不同）。呼叫端完全沒做清理動作，全靠 AuthNotifier 的監聽。
      await service.signInWithPassword(email: 'someone-else@test.local', password: 'x');
      await pumpEventQueue();

      expect(container.read(snapshotProvider).isEmpty, isTrue,
          reason: '換人之後快照必須空掉，不能留給下一個帳號看到');
      expect(container.read(currentLedgerIdProvider), isNull);
      expect(container.read(entriesProvider), isEmpty);
    });

    testWidgets('登入 B 之後，任何一 frame 都不得出現 A 的帳本資料', (tester) async {
      // repository 手上還留著 A 的快照（上一個使用者留下的），B 一本帳本也沒有。
      final container = ProviderContainer(overrides: [
        authServiceProvider.overrideWithValue(InMemoryAuthService.signedOut()),
        ledgerRepositoryProvider.overrideWithValue(StaleSnapshotRepository()),
      ]);
      await pumpApp(tester, container);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('本月買菜'), findsNothing);

      await tester.enterText(find.byKey(const Key('login-email-field')), 'mike@test.local');
      await tester.enterText(find.byKey(const Key('login-password-field')), 'password');
      await tester.tap(find.byKey(const Key('login-button')));

      // 一 frame 一 frame 走完整個切換過程，中間不能閃出 A 的資料。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('本月買菜'), findsNothing, reason: '第 $i 個 frame 漏了清快照');
      }
      await tester.pumpAndSettle();

      expect(find.byType(OnboardingPage), findsOneWidget, reason: 'B 沒有帳本 → 首登頁');
      expect(find.text('本月買菜'), findsNothing);
      expect(container.read(entriesProvider), isEmpty);
    });
  });

  group('開機載快照失敗', () {
    testWidgets('顯示錯誤與重試，且不清掉已選的帳本；重試成功後進帳目頁', (tester) async {
      final repo = FlakyLoadRepository();
      final container = ProviderContainer(overrides: [
        ledgerRepositoryProvider.overrideWithValue(repo),
        bootErrorProvider.overrideWith(_PresetBootError.new),
      ]);
      await pumpApp(tester, container);

      expect(find.byKey(const Key('boot-error-message')), findsOneWidget);
      expect(find.byType(EntriesPage), findsNothing);
      expect(container.read(currentLedgerIdProvider), kLedgerId,
          reason: '連不上網不等於帳本沒了，不能把選擇清掉');

      repo.failLoad = false; // 網路恢復
      await tester.tap(find.byKey(const Key('boot-retry-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('boot-error-message')), findsNothing);
      expect(find.byType(EntriesPage), findsOneWidget);
      expect(find.text('本月買菜'), findsOneWidget);
    });

    testWidgets('重試又失敗 → 停在錯誤畫面，按鈕恢復可按', (tester) async {
      final container = ProviderContainer(overrides: [
        ledgerRepositoryProvider.overrideWithValue(FlakyLoadRepository()),
        bootErrorProvider.overrideWith(_PresetBootError.new),
      ]);
      await pumpApp(tester, container);

      await tester.tap(find.byKey(const Key('boot-retry-button')));
      await tester.pumpAndSettle();

      expect(tester.widget<Text>(find.byKey(const Key('boot-error-message'))).data,
          '連線失敗，請檢查網路後再試');
      expect(tester.widget<FilledButton>(find.byKey(const Key('boot-retry-button'))).onPressed,
          isNotNull);
    });
  });

  group('登出', () {
    testWidgets('設定頁登出 → 回登入頁，快照清空（換帳號看不到上一本的資料）', (tester) async {
      final c = await pumpApp(tester, ProviderContainer());
      expect(find.text('本月買菜'), findsOneWidget);

      c.read(routerProvider).go('/settings');
      await tester.pumpAndSettle();
      await tester.tap(find.text('登出'));
      await tester.pumpAndSettle();

      expect(find.byType(LoginPage), findsOneWidget);
      expect(c.read(currentLedgerIdProvider), isNull);
      expect(c.read(entriesProvider), isEmpty, reason: '登出要清整份快照');
      expect(c.read(ledgerProvider).id, isEmpty);
      expect(find.text('本月買菜'), findsNothing);
    });
  });
}
