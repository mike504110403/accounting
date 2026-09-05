/// Realtime：訂閱五張進 publication 的表（v1.5：`personal_topups` 取代 `settlements`），
/// 事件到達就重抓該表。
///
/// 只送「哪張表變了」，不吃 payload——payload 仍吃 RLS 也仍可能漏（批次寫入合併事件），
/// 重抓整表才是唯一能保證與 DB 一致的做法。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/mock_data.dart';
import 'current_ledger.dart';

enum LedgerTable { entries, personalTopups, listItems, budgetAllocation, monthCloses }

const _tableNames = {
  LedgerTable.entries: 'entries',
  LedgerTable.personalTopups: 'personal_topups',
  LedgerTable.listItems: 'list_items',
  LedgerTable.budgetAllocation: 'budget_allocation',
  LedgerTable.monthCloses: 'month_closes',
};

abstract class RealtimeSource {
  void subscribe(String ledgerId, void Function(LedgerTable table) onChange);
  Future<void> unsubscribe();
}

/// 沒有連線時什麼都不做（測試與 `USE_MOCK` 的預設）。
class NoopRealtimeSource implements RealtimeSource {
  const NoopRealtimeSource();

  @override
  void subscribe(String ledgerId, void Function(LedgerTable table) onChange) {}

  @override
  Future<void> unsubscribe() async {}
}

class SupabaseRealtimeSource implements RealtimeSource {
  SupabaseRealtimeSource(this._client);

  final SupabaseClient _client;
  RealtimeChannel? _channel;

  @override
  void subscribe(String ledgerId, void Function(LedgerTable table) onChange) {
    var channel = _client.channel('ledger:$ledgerId');
    for (final entry in _tableNames.entries) {
      // migration 0026／0027 起五表 replica identity full：DELETE payload 也帶 ledger_id，
      // 單一帶 filter 的訂閱就收得到刪除事件（原「不帶 filter 的 DELETE 補丁」已拆）。
      channel = channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: entry.value,
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'ledger_id',
          value: ledgerId,
        ),
        callback: (_) => onChange(entry.key),
      );
    }
    _channel = channel..subscribe();
  }

  @override
  Future<void> unsubscribe() async {
    final channel = _channel;
    _channel = null;
    if (channel != null) await _client.removeChannel(channel);
  }
}

final realtimeSourceProvider = Provider<RealtimeSource>((ref) => const NoopRealtimeSource());

/// 收到事件後重抓對應的表。
///
/// 清帳事件連帶重抓 entries：清完之後那個月（與更早的月份）整段鎖住，而且
/// 「一鍵記共同收入」會在同一段交易裡多記一筆收入——只重抓 closes 的話，
/// 對方那台的列表會少一筆收入，還以為那些帳目可以改。
Future<void> applyRealtimeChange(Ref ref, LedgerTable table) async {
  try {
    switch (table) {
      case LedgerTable.entries:
        await ref.read(entriesProvider.notifier).refresh();
      case LedgerTable.personalTopups:
        await ref.read(topupsProvider.notifier).refresh();
      case LedgerTable.listItems:
        await ref.read(listItemsProvider.notifier).refresh();
      case LedgerTable.budgetAllocation:
        await ref.read(allocationsProvider.notifier).refresh();
      case LedgerTable.monthCloses:
        await ref.read(monthClosesProvider.notifier).refresh();
        await ref.read(entriesProvider.notifier).refresh();
    }
  } catch (e, st) {
    // 背景刷新失敗不能變成 uncaught，也不該打斷使用者當下的操作。
    debugPrint('Realtime 重抓失敗（$table）: $e\n$st');
  }
}

/// 訂閱的生命週期掛在這個 provider 上：`AccountingApp` watch 它，換帳本自動重訂、登出自動退訂。
final ledgerRealtimeProvider = Provider<void>((ref) {
  final ledgerId = ref.watch(currentLedgerIdProvider);
  final source = ref.watch(realtimeSourceProvider);
  if (ledgerId == null) return;
  source.subscribe(ledgerId, (table) => applyRealtimeChange(ref, table));
  ref.onDispose(source.unsubscribe);
});
