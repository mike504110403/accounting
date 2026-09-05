/// 錯誤轉譯：DB／Auth 的英文訊息一律變成使用者看得懂的中文。
///
/// 這層是「不變式的第二道防線真的被踩到時，使用者看到什麼」——
/// 前端會先擋掉大部分違規，但 DB 的 check／trigger 仍可能因為別的路徑
/// （舊資料、並行改動、另一台裝置剛清完帳）打回來，
/// 那時不能讓 constraint 名字或英文 raise 直接噴到畫面上。
library;

import 'package:accounting/data/errors.dart';
import 'package:accounting/domain/month_summary.dart';
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
    test('同分類同月第二筆預算（unique 23505）→ 說「本月已設定」', () async {
      await expectMessage(
        const PostgrestException(
          message: 'duplicate key value violates unique constraint '
              '"budget_allocation_one_per_category_month"',
          code: '23505',
        ),
        '這個分類本月已設定預算，設定後不可修改',
      );
    });

    test('預算金額 ≤ 0（23514）→ 說「必須大於 0」', () async {
      await expectMessage(
        const PostgrestException(
          message: 'new row for relation "budget_allocation" violates check constraint '
              '"budget_allocation_amount_positive"',
          code: '23514',
        ),
        '預算金額必須大於 0',
      );
    });

    test('v1.5：補入金額 ≤ 0（23514）→ 說「補入金額必須大於 0」', () async {
      await expectMessage(
        const PostgrestException(
          message: 'new row for relation "personal_topups" violates check constraint '
              '"personal_topups_amount_positive"',
          code: '23514',
        ),
        '補入金額必須大於 0',
      );
    });

    test('v1.5：收入帶付款人（23514）→ 說「收入不需要付款人」', () async {
      await expectMessage(
        const PostgrestException(
          message: 'new row for relation "entries" violates check constraint '
              '"entries_income_no_payer"',
          code: '23514',
        ),
        '收入不需要付款人',
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

  group('鎖月 trigger 與清帳 RPC', () {
    test('month closed: YYYY-MM → 「該月已清帳」（訊息帶的是被擋那筆的月份）', () async {
      await expectMessage(const PostgrestException(message: 'month closed: 2026-07'), '該月已清帳');
    });

    test('補入被鎖月擋下來也是同一句（帳目、細項、預算、補入共用同一條 trigger 訊息）', () async {
      await expectMessage(
        const PostgrestException(message: 'month closed: 2026-07 (personal_topups)'),
        '該月已清帳',
      );
    });

    test('清帳可清條件的五種訊息各自對應一句中文（v1.5 沒有「拆帳未簽完」那條）', () async {
      const cases = {
        'close_month: month must be first day': '清帳月份格式錯誤，請重新整理後再試',
        'close_month: month not ended': '本月尚未結束',
        'close_month: already closed': '該月已清帳',
        'close_month: nothing to close': '沒有可清的月份',
        'close_month: must close 2026-06 first': '請先清 2026／06',
      };
      for (final e in cases.entries) {
        await expectMessage(PostgrestException(message: e.key), e.value);
      }
    });

    test('month_close_preview 的非成員 42501 走既有的「不是成員」', () async {
      await expectMessage(
        const PostgrestException(message: 'month_close_preview: not a member', code: '42501'),
        '你不是這本帳本的成員',
      );
    });
  });

  group('RPC raise 與權限', () {
    test('錯的邀請碼', () async {
      await expectMessage(
        const PostgrestException(message: 'invalid invite code', code: 'P0001'),
        '邀請碼不正確',
      );
    });

    test('v1.5：補入寫到別人那列 → RLS 42501', () async {
      await expectMessage(
        const PostgrestException(
          message: 'new row violates row-level security policy for table "personal_topups"',
          code: '42501',
        ),
        '沒有權限執行這個操作',
      );
    });

    test('欄位級授權擋下（42501）', () async {
      await expectMessage(
        const PostgrestException(message: 'permission denied for column x', code: '42501'),
        '沒有權限執行這個操作',
      );
    });

    test('認不得的訊息 → 通用文案，不把英文原文丟給使用者', () async {
      await expectMessage(
        const PostgrestException(message: 'some brand new raise from a future migration'),
        '操作失敗，請稍後再試',
      );
    });

    test('v1.5 已廢止的結算訊息不再有專屬中文（落到通用文案）', () async {
      for (final gone in [
        'a pending settlement already exists',
        'no settleable entries',
        'not a required signer',
        'entry settled: amount locked, use an adjustment entry',
        'close_month: unsettled entries in month',
      ]) {
        await expectMessage(PostgrestException(message: gone), '操作失敗，請稍後再試');
      }
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

  test('RPC 回傳缺鍵 → parseRow 包成「格式不正確」，不會被誤報成「連線失敗」', () async {
    // `monthSummary` 走 parseRow 就是為了這件事：缺 members 的 TypeError 若掉進
    // guard 最外層，使用者會看到「連線失敗，請檢查網路」並一直重試一個跟網路無關的問題。
    await expectLater(
      guard<MonthSummary>(() async => parseRow('month_summary', const {
            'shared_balance': 1,
            'budget_total': 0,
            'spent_total': 0,
            'overspend_total': 0,
            'categories': <Object?>[],
            'shared_paid': 0,
          }, MonthSummary.fromJson)),
      throwsA(isA<LedgerException>()
          .having((e) => e.message, 'message', '伺服器回傳的「month_summary」資料格式不正確，請稍後再試')),
    );
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
