/// Supabase 連線設定與初始化。
///
/// 環境切換全靠 `--dart-define`：
/// - `SUPABASE_URL`／`SUPABASE_ANON_KEY`：不給就是雲端 dev 專案。
/// - `USE_MOCK=true`：完全不連網，走 `InMemoryLedgerRepository`。
/// - `INTEGRATION=true`：跑 `test/data` 的 Supabase 契約測試（預設略過）。
///
/// 這裡只放**公開**金鑰（anon／publishable）。service_role 之類的祕密金鑰不進程式碼。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 雲端 dev 專案（公開資訊，可進版控）。
const kSupabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://wxqbxsagfvtxnvaloklr.supabase.co',
);

const kSupabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue: 'sb_publishable_POjCFxKYG1jcHU6uDF2mbQ_L0ffWjXQ',
);

/// 純記憶體模式：不初始化 Supabase，資料層維持 `InMemoryLedgerRepository`。
const kUseMock = bool.fromEnvironment('USE_MOCK');

/// 整合測試旗標：`test/data` 的 Supabase 契約測試只有帶這個才跑。
const kIntegration = bool.fromEnvironment('INTEGRATION');

Future<void> initSupabase() => Supabase.initialize(url: kSupabaseUrl, publishableKey: kSupabaseAnonKey);

/// 由 `main.dart` override 成 `Supabase.instance.client`；預設 null＝沒有連線（測試／USE_MOCK）。
final supabaseClientProvider = Provider<SupabaseClient?>((ref) => null);
