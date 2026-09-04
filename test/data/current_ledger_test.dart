/// 目前帳本 id 的持久化：選過的帳本要活過重開 App。
///
/// 沒有這條，「切到第二本帳本 → 關掉 App → 再開」會靜靜回到第一本，
/// 而且因為兩本資料看起來都像真的，使用者不會馬上發現自己記錯帳本。
library;

import 'package:accounting/app/theme_mode.dart';
import 'package:accounting/data/current_ledger.dart';
import 'package:accounting/domain/mock_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ProviderContainer makeContainer(LedgerRepository repo) {
    final c = ProviderContainer(overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      ledgerRepositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('select 寫進 SharedPreferences，重建 container 仍讀得回同一本', () async {
    final repo = UnselectedLedgerRepository(); // 本機還沒選過
    final first = makeContainer(repo);
    expect(first.read(currentLedgerIdProvider), isNull);

    await first.read(currentLedgerIdProvider.notifier).select(kLedgerId);
    expect(first.read(currentLedgerIdProvider), kLedgerId);
    expect(prefs.getString(kCurrentLedgerIdKey), kLedgerId);

    // 重開 App＝新的 ProviderContainer、同一份 prefs。
    final second = makeContainer(UnselectedLedgerRepository());
    expect(second.read(currentLedgerIdProvider), kLedgerId, reason: '選過的帳本要活過重開');
  });

  test('clear 把 SharedPreferences 裡的選擇也清掉', () async {
    final c = makeContainer(repoWith());
    await c.read(currentLedgerIdProvider.notifier).select(kLedgerId);
    expect(prefs.getString(kCurrentLedgerIdKey), kLedgerId);

    await c.read(currentLedgerIdProvider.notifier).clear();

    expect(c.read(currentLedgerIdProvider), isNull);
    expect(prefs.getString(kCurrentLedgerIdKey), isNull);
    // 重開＝新 container ＋ 沒有快照的 repository（登出後 Supabase 就是這個狀態）。
    expect(makeContainer(UnselectedLedgerRepository()).read(currentLedgerIdProvider), isNull,
        reason: '重開之後也不該又冒出上一個帳號的帳本');
  });

  test('clearNow 是同步的：快照與 state 當場就空，不必等 prefs', () {
    final c = makeContainer(repoWith());
    expect(c.read(entriesProvider), isNotEmpty);

    c.read(currentLedgerIdProvider.notifier).clearNow();

    expect(c.read(currentLedgerIdProvider), isNull);
    expect(c.read(snapshotProvider).isEmpty, isTrue);
    expect(c.read(entriesProvider), isEmpty);
  });

  test('selectFirstAvailable：存過的那本優先，沒存過才取第一本', () async {
    await prefs.setString(kCurrentLedgerIdKey, kLedgerId);
    final c = makeContainer(UnselectedLedgerRepository());

    expect(await c.read(currentLedgerIdProvider.notifier).selectFirstAvailable(), isTrue);
    expect(c.read(currentLedgerIdProvider), kLedgerId);
  });

  test('selectFirstAvailable：一本帳本都沒有時回 false（該去首登頁）', () async {
    final c = makeContainer(NoLedgerRepository());
    expect(await c.read(currentLedgerIdProvider.notifier).selectFirstAvailable(), isFalse);
    expect(c.read(currentLedgerIdProvider), isNull);
  });

  group('開機還原（restoreSelectedLedger）', () {
    test('沒有 session → 清掉已選的帳本，避免登入後閃出上一個帳號的殼', () async {
      await prefs.setString(kCurrentLedgerIdKey, kLedgerId);

      final error = await restoreSelectedLedger(
        prefs: prefs,
        repo: UnselectedLedgerRepository(),
        hasSession: false,
      );

      expect(error, isNull);
      expect(prefs.getString(kCurrentLedgerIdKey), isNull);
    });

    test('有 session 且載得起來 → 沒有錯誤，快照就緒', () async {
      await prefs.setString(kCurrentLedgerIdKey, kLedgerId);
      final repo = UnselectedLedgerRepository();

      final error = await restoreSelectedLedger(prefs: prefs, repo: repo, hasSession: true);

      expect(error, isNull);
      expect(repo.snapshot.isEmpty, isFalse);
      expect(prefs.getString(kCurrentLedgerIdKey), kLedgerId);
    });

    test('載入失敗 → 回錯誤訊息，但**不清掉**已選的帳本', () async {
      await prefs.setString(kCurrentLedgerIdKey, kLedgerId);

      final error = await restoreSelectedLedger(
        prefs: prefs,
        repo: FlakyLoadRepository(),
        hasSession: true,
      );

      expect(error, '連線失敗，請檢查網路後再試');
      expect(prefs.getString(kCurrentLedgerIdKey), kLedgerId,
          reason: '連不上網不等於帳本沒了；清掉的話下次開機會被丟去首登頁，看起來像帳本消失');
    });

    test('沒存過帳本 id → 什麼都不做，也不算錯誤', () async {
      final error = await restoreSelectedLedger(
        prefs: prefs,
        repo: UnselectedLedgerRepository(),
        hasSession: true,
      );
      expect(error, isNull);
    });
  });
}
