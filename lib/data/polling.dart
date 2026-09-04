/// 背景輪詢保底（Mike 裁示 2026-09-03；同日改 30 秒＋背景暫停，省 Supabase egress）：
/// Realtime 是即推主力、輪詢只是保底；兩者走同一條「整表重抓 server 資料」的路，
/// 畫面永遠顯示 Supabase 回來的列，不顯示客戶端自己攢的狀態。
/// 分頁退到背景（hidden／paused）就整個停掉，回前景立刻補抓一輪再繼續計時。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/mock_data.dart';
import 'current_ledger.dart';
import 'supabase_client.dart';

/// 輪詢週期（獨立成常數：測試與之後想調頻率只動這裡）。
const kPollInterval = Duration(seconds: 30);

/// app 是否在前景（resumed／inactive 都算「看得到」；hidden／paused／detached 算背景）。
class AppForegroundNotifier extends Notifier<bool> with WidgetsBindingObserver {
  @override
  bool build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    return _visible(WidgetsBinding.instance.lifecycleState);
  }

  bool _visible(AppLifecycleState? s) =>
      s == null || s == AppLifecycleState.resumed || s == AppLifecycleState.inactive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => this.state = _visible(state);
}

final appForegroundProvider =
    NotifierProvider<AppForegroundNotifier, bool>(AppForegroundNotifier.new);

Future<void> _refreshAll(Ref ref) => Future.wait([
      ref.read(ledgerStateProvider.notifier).refresh(),
      ref.read(membersStateProvider.notifier).refresh(),
      ref.read(categoriesStateProvider.notifier).refresh(),
      ref.read(entriesProvider.notifier).refresh(),
      ref.read(allocationsProvider.notifier).refresh(),
      ref.read(listItemsProvider.notifier).refresh(),
      ref.read(settlementsProvider.notifier).refresh(),
    ]);

/// 生命週期與 Realtime 訂閱同款：`AccountingApp` watch 它，換帳本自動重掛、
/// 登出自動停；退背景 dispose、回前景重建（重建時先補抓一輪）。
final ledgerPollingProvider = Provider<void>((ref) {
  final ledgerId = ref.watch(currentLedgerIdProvider);
  if (ledgerId == null) return;
  // USE_MOCK／widget test：沒有連線就不開 timer（開了會讓 pumpAndSettle 永遠等不到靜止）。
  if (ref.watch(supabaseClientProvider) == null) return;
  // 背景暫停：不在前景就不掛 timer（egress 歸零）；回前景 provider 重建走下面的補抓。
  if (!ref.watch(appForegroundProvider)) return;

  var inFlight = false;
  Future<void> tick() async {
    if (inFlight) return; // 上一輪還沒回來就跳過，不讓慢網路堆請求
    inFlight = true;
    try {
      await _refreshAll(ref);
    } catch (e, st) {
      // 背景輪詢失敗不能變 uncaught；下一輪自然重試。
      debugPrint('輪詢刷新失敗: $e\n$st');
    } finally {
      inFlight = false;
    }
  }

  // 掛上（含背景回前景）先補抓一輪，錯過的變更立刻追上，不等 30 秒。
  scheduleMicrotask(tick);
  final timer = Timer.periodic(kPollInterval, (_) => tick());
  ref.onDispose(timer.cancel);
});
