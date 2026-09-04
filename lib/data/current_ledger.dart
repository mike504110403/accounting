/// 目前選定的帳本 id（持久化到 SharedPreferences），以及「換帳本＝整份快照失效」的唯一入口。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app/theme_mode.dart' show sharedPrefsProvider;
import 'ledger_repository.dart';

const kCurrentLedgerIdKey = 'currentLedgerId';

/// 開機時把上次選的帳本載回來。回傳非 null ＝ 要顯示給使用者的錯誤訊息。
///
/// 兩條規則，都被 `main.dart` 依賴：
/// 1. **沒有 session 就清掉已選的帳本**——否則登入後會有一瞬間被 redirect 判成
///    「有帳本」而放行到帳目頁，閃出上一個帳號的殼。
/// 2. **載入失敗不清**——連不上網跟「這本帳本沒了」是兩回事。清掉的話下次開機
///    會被 redirect 丟去首登頁，看起來像帳本憑空消失，而且使用者無從補救。
///
/// 抽成純函式是為了測得動：`main()` 本身在 widget test 裡跑不到。
Future<String?> restoreSelectedLedger({
  required SharedPreferences prefs,
  required LedgerRepository repo,
  required bool hasSession,
}) async {
  if (!hasSession) {
    await prefs.remove(kCurrentLedgerIdKey);
    return null;
  }
  final ledgerId = prefs.getString(kCurrentLedgerIdKey);
  if (ledgerId == null || ledgerId.isEmpty) return null;
  try {
    await repo.loadSnapshot(ledgerId);
    return null;
  } catch (e) {
    return e is LedgerException ? e.message : '載入帳本失敗，請稍後再試';
  }
}

class CurrentLedgerNotifier extends Notifier<String?> {
  @override
  String? build() {
    final saved = ref.read(sharedPrefsProvider)?.getString(kCurrentLedgerIdKey);
    if (saved != null && saved.isNotEmpty) return saved;
    // 沒有存過就看 repository 手上有沒有快照（記憶體實作永遠有，測試因此直接開在 /entries）。
    final id = ref.read(ledgerRepositoryProvider).snapshot.ledger.id;
    return id.isEmpty ? null : id;
  }

  /// 選定並載入一本帳本。失敗會把例外往上丟，呼叫端負責顯示錯誤。
  ///
  /// `invalidate(snapshotProvider)` 是快取失效的**唯一**時機之一（另一個是 [clear]）：
  /// 所有 Notifier 的 `build()` 都 watch 它，這行一下去整份資料就換掉了。
  Future<void> select(String ledgerId) async {
    await ref.read(ledgerRepositoryProvider).loadSnapshot(ledgerId);
    await ref.read(sharedPrefsProvider)?.setString(kCurrentLedgerIdKey, ledgerId);
    state = ledgerId;
    ref.invalidate(snapshotProvider);
  }

  /// 登入／首登完成後選一本帳本。回傳 false＝這個帳號還沒有任何帳本（該去 `/onboarding`）。
  Future<bool> selectFirstAvailable() async {
    final ledgers = await ref.read(ledgerRepositoryProvider).myLedgers();
    if (ledgers.isEmpty) return false;
    final saved = ref.read(sharedPrefsProvider)?.getString(kCurrentLedgerIdKey);
    final pick = ledgers.firstWhere((l) => l.id == saved, orElse: () => ledgers.first);
    await select(pick.id);
    return true;
  }

  /// 登出／換帳號：清掉快照。
  ///
  /// **同步的部分先做完再 await**：呼叫端（`AuthNotifier` 的登入狀態監聽）不會 await 這支，
  /// 若把 `clearSnapshot`／`state = null` 排在 `await prefs` 之後，中間就會有幾個 frame
  /// 還畫著上一個帳號的資料。清快照這件事一個 frame 都不能晚。
  void clearNow() {
    ref.read(ledgerRepositoryProvider).clearSnapshot();
    state = null;
    ref.invalidate(snapshotProvider);
  }

  Future<void> clear() async {
    clearNow();
    await ref.read(sharedPrefsProvider)?.remove(kCurrentLedgerIdKey);
  }
}

final currentLedgerIdProvider =
    NotifierProvider<CurrentLedgerNotifier, String?>(CurrentLedgerNotifier.new);

/// `router.redirect` 用的一句話狀態。
final hasLedgerProvider = Provider<bool>((ref) => ref.watch(currentLedgerIdProvider) != null);

/// 開機載快照失敗時的訊息（`main.dart` override 進來）。
///
/// 失敗**不清掉**已選的帳本 id：連不上網跟「這本帳本沒了」是兩回事，
/// 清掉的話下次開機會被 redirect 丟去首登頁，看起來像帳本消失了。
class BootErrorNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? message) => state = message;

  /// 重試載入目前選定的帳本。
  Future<void> retry() async {
    final ledgerId = ref.read(currentLedgerIdProvider);
    if (ledgerId == null) {
      state = null;
      return;
    }
    try {
      await ref.read(currentLedgerIdProvider.notifier).select(ledgerId);
      state = null;
    } catch (e) {
      state = e is LedgerException ? e.message : '載入失敗，請稍後再試';
    }
  }
}

final bootErrorProvider = NotifierProvider<BootErrorNotifier, String?>(BootErrorNotifier.new);
