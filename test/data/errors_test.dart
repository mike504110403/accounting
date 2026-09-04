/// 錯誤轉譯：DB／Auth 的英文訊息一律變成使用者看得懂的中文。
///
/// 這層是「不變式的第二道防線真的被踩到時，使用者看到什麼」——
/// 前端的 `Entry` 建構子已經先擋掉 funding 違規，但 DB 的 check 仍可能因為
/// 別的路徑（舊資料、並行改動）打回來，那時不能讓 constraint 名字直接噴到畫面上。
library;

import 'package:accounting/data/errors.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> expectMessage(PostgrestException e, String expected) async {
  await expectLater(
    guard<void>(() async => throw e),
    throwsA(isA<LedgerException>().having((x) => x.message, 'message', expected)),
  );
}

void main() {
  group('check constraint', () {
    test('代墊／私人走信封（23514）→ 說清楚哪種帳目才能用信封', () async {
      await expectMessage(
        const PostgrestException(
          message: 'new row for relation "entries" violates check constraint "entries_funding_common_wallet_only"',
          code: '23514',
        ),
        '只有共同錢包的共同支出可以從信封（預算）支出，代墊與私人帳目請改成餘額',
      );
    });

    test('負數金額未開修正筆', () async {
      await expectMessage(
        const PostgrestException(
          message: 'violates check constraint "entries_amount_sign"',
          code: '23514',
        ),
        '負數金額請開啟「修正筆」',
      );
    });
  });

  group('settled 鎖定 trigger', () {
    test('金額鎖住 → 導向修正筆', () async {
      await expectMessage(
        const PostgrestException(message: 'entry settled: amount locked, use an adjustment entry'),
        '這筆已結帳，金額鎖住，請改用修正筆',
      );
    });

    test('刪除被擋', () async {
      await expectMessage(
        const PostgrestException(message: 'entry settled: delete blocked, use an adjustment entry'),
        '已結帳的帳目不能刪除，請改用修正筆',
      );
    });

    test('子表被鎖（upsert_entry 帶子表）', () async {
      await expectMessage(
        const PostgrestException(message: 'entry settled: child tables locked'),
        '這筆已結帳，只能改分類與備註',
      );
    });
  });

  group('RPC raise 與權限', () {
    test('錯的邀請碼', () async {
      await expectMessage(
        const PostgrestException(message: 'join_ledger: invalid invite code'),
        '邀請碼不正確',
      );
    });

    test('已有 pending 結算', () async {
      await expectMessage(
        const PostgrestException(message: 'a pending settlement already exists'),
        '已經有一筆結算正在等待簽核',
      );
    });

    test('不是需簽者', () async {
      await expectMessage(
        const PostgrestException(message: 'not a required signer'),
        '你不是這筆結算的簽核人',
      );
    });

    test('欄位級授權擋下（42501）', () async {
      await expectMessage(
        const PostgrestException(message: 'permission denied for table entries', code: '42501'),
        '沒有權限執行這個操作',
      );
    });

    test('認不得的訊息 → 通用文案，不把英文原文丟給使用者', () async {
      await expectMessage(
        const PostgrestException(message: 'some brand new postgres error nobody mapped yet'),
        '操作失敗，請稍後再試',
      );
    });
  });

  group('Auth', () {
    Future<void> expectAuthMessage(AuthException e, String expected) => expectLater(
          guard<void>(() async => throw e),
          throwsA(isA<LedgerException>().having((x) => x.message, 'message', expected)),
        );

    test('密碼錯', () async {
      await expectAuthMessage(const AuthException('Invalid login credentials'), 'Email 或密碼不正確');
    });

    test('Apple provider 沒開', () async {
      await expectAuthMessage(
        const AuthException('Unsupported provider: provider is not enabled'),
        'Apple 登入尚未啟用',
      );
    });

    test('認不得的 auth 錯誤 → 通用文案，英文原文只留在 cause／code', () async {
      const raw = AuthException('weird internal gotrue detail', code: 'unexpected_failure');
      await expectLater(
        guard<void>(() async => throw raw),
        throwsA(
          isA<LedgerException>()
              .having((x) => x.message, 'message', '登入失敗，請稍後再試')
              .having((x) => x.message, 'message 不含英文原文', isNot(contains('gotrue')))
              .having((x) => x.code, 'code', 'unexpected_failure')
              .having((x) => x.cause, 'cause', raw),
        ),
      );
    });
  });

  group('RPC 回傳列解析（requireId）', () {
    test('Map 或單元素 List 都取得到 id', () {
      expect(requireId({'id': 'abc'}), 'abc');
      expect(requireId([
        {'id': 'abc'},
      ]), 'abc');
    });

    test('id 不是字串／是空字串／整列格式不對 → 說「格式錯誤」，不是「連線失敗」', () {
      for (final bad in <Object?>[
        {'id': 42},
        {'id': null},
        {'id': ''},
        <String, dynamic>{},
        null,
        'not a row',
        <Object?>[],
      ]) {
        expect(
          () => requireId(bad),
          throwsA(isA<LedgerException>()
              .having((e) => e.message, 'message', '伺服器回應格式錯誤，請稍後再試')),
          reason: '$bad',
        );
      }
    });

    test('包在 guard 裡仍是格式錯誤，不會被最外層誤判成網路問題', () async {
      await expectLater(
        guard<String>(() async => requireId({'id': 42})),
        throwsA(isA<LedgerException>()
            .having((e) => e.message, 'message', '伺服器回應格式錯誤，請稍後再試')),
      );
    });
  });

  test('非 Supabase 的例外（網路斷線等）→ 通用連線錯誤', () async {
    await expectLater(
      guard<void>(() async => throw const SocketExceptionStub()),
      throwsA(isA<LedgerException>().having((x) => x.message, 'message', '連線失敗，請檢查網路後再試')),
    );
  });

  test('已經是 LedgerException 就原封不動往上丟（不會被包兩層）', () async {
    await expectLater(
      guard<void>(() async => throw const LedgerException('已經中文化過了')),
      throwsA(isA<LedgerException>().having((x) => x.message, 'message', '已經中文化過了')),
    );
  });
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
