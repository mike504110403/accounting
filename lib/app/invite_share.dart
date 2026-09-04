/// 邀請另一半／家人的系統分享（onboarding 分享關與設定頁共用）。
///
/// iOS 原生沒有網頁 origin（`Uri.base` 是 file://），分享文字改帶 TestFlight
/// 公開連結——對方點連結直接進 TestFlight 下載，不用走邀請信。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// TestFlight 公開連結（external 群組 friends，2026-09-04 建）。
const kTestFlightUrl = 'https://testflight.apple.com/join/cdzzXD1J';

String inviteMessage({required String ledgerName, required String inviteCode}) {
  if (kIsWeb && Uri.base.hasScheme) {
    return '跟我一起記帳！打開 ${Uri.base.origin} 登入後，用邀請碼 $inviteCode 加入「$ledgerName」。';
  }
  return '跟我一起記帳！先裝 app：$kTestFlightUrl ，登入後用邀請碼 $inviteCode 加入「$ledgerName」。';
}

/// 系統分享；環境不支援（桌面瀏覽器等）就複製到剪貼簿。
/// [context] 用來給 iPad 的分享 popover 一個錨點（不給會直接閃退）。
Future<void> shareInvite(
  BuildContext context, {
  required String ledgerName,
  required String inviteCode,
}) async {
  final text = inviteMessage(ledgerName: ledgerName, inviteCode: inviteCode);
  final box = context.findRenderObject() as RenderBox?;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await SharePlus.instance.share(ShareParams(
      text: text,
      sharePositionOrigin:
          box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('已複製邀請訊息，貼給另一半吧')));
  }
}
