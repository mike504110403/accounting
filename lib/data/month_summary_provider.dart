/// 月摘要 provider：畫面上的衍生數字一律吃這裡（DB `month_summary` RPC 的結果），
/// 不直接顯示客戶端算完的（Mike 裁示 2026-09-03）。
///
/// watch 六個表 provider：任何一表被 refresh（寫入回填、Realtime、輪詢）都會
/// 讓這裡重打 RPC——顯示值永遠跟著 server 資料走。family key 是「算到哪一天」
/// （date-only 的 DateTime，呼叫端一律傳該月最後一天）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/mock_data.dart';
import '../domain/month_summary.dart';

final monthSummaryProvider = FutureProvider.family<MonthSummary, DateTime>((ref, until) {
  ref.watch(ledgerStateProvider);
  ref.watch(membersStateProvider);
  ref.watch(entriesProvider);
  ref.watch(allocationsProvider);
  ref.watch(settlementsProvider);
  // 清帳會把整段月份移出個人餘額公式，數字跟著變 → 清完必須重打 RPC。
  ref.watch(monthClosesProvider);
  final ledgerId = ref.watch(ledgerProvider).id;
  return ref.watch(ledgerRepositoryProvider).monthSummary(ledgerId, until);
});
