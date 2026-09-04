/// 登入狀態與登入動作。
///
/// 抽成 [AuthService] 介面的理由：widget 測試不能連網，但又不想每支測試都補一次
/// 「假裝已登入」的 override——所以預設實作 [InMemoryAuthService] 就是「已登入」，
/// 既有測試照舊直接開在 `/entries`；登入頁自己的測試才注入登出狀態的實作。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app/theme_mode.dart' show sharedPrefsProvider;
import 'current_ledger.dart';
import 'errors.dart';

class AuthUser {
  const AuthUser({required this.id, this.email});

  final String id;
  final String? email;
}

abstract class AuthService {
  AuthUser? get currentUser;

  /// 登入狀態變化（含 token 續期後的重新登入）。
  Stream<AuthUser?> get changes;

  Future<void> signInWithPassword({required String email, required String password});

  /// 自動確認已開（免收信），註冊即登入。
  Future<void> signUp({required String email, required String password});

  /// Web 走 OAuth redirect（不加 `sign_in_with_apple` 套件）。
  /// provider 未開時 Supabase 會回錯，由呼叫端顯示在頁內。
  Future<void> signInWithApple();

  Future<void> signOut();
}

class SupabaseAuthService implements AuthService {
  SupabaseAuthService(this._client, {this.redirectTo});

  final SupabaseClient _client;

  /// Apple OAuth 導回的位址（Web 用目前 origin；白名單已含 8787）。
  final String? redirectTo;

  @override
  AuthUser? get currentUser {
    final u = _client.auth.currentUser;
    return u == null ? null : AuthUser(id: u.id, email: u.email);
  }

  @override
  Stream<AuthUser?> get changes => _client.auth.onAuthStateChange.map((e) {
        final u = e.session?.user;
        return u == null ? null : AuthUser(id: u.id, email: u.email);
      });

  @override
  Future<void> signInWithPassword({required String email, required String password}) =>
      guard(() => _client.auth.signInWithPassword(email: email, password: password));

  @override
  Future<void> signUp({required String email, required String password}) =>
      guard(() => _client.auth.signUp(email: email, password: password));

  @override
  Future<void> signInWithApple() =>
      guard(() => _client.auth.signInWithOAuth(OAuthProvider.apple, redirectTo: redirectTo));

  @override
  Future<void> signOut() => guard(() => _client.auth.signOut());
}

/// 記憶體版：測試與 `USE_MOCK` 用。
class InMemoryAuthService implements AuthService {
  InMemoryAuthService({AuthUser? user, Map<String, String>? credentials})
      : _current = user,
        _credentials = {...(credentials ?? const {'mike@test.local': 'password'})};

  /// 預設「已登入」，既有 widget 測試不必補 override。
  factory InMemoryAuthService.signedIn() =>
      InMemoryAuthService(user: const AuthUser(id: 'u1', email: 'mike@test.local'));

  factory InMemoryAuthService.signedOut({Map<String, String>? credentials}) =>
      InMemoryAuthService(credentials: credentials);

  AuthUser? _current;
  final Map<String, String> _credentials;
  final _controller = StreamController<AuthUser?>.broadcast();

  /// Apple provider 未開時的行為（雲端目前就是這樣），供登入頁測試用。
  bool appleEnabled = false;

  @override
  AuthUser? get currentUser => _current;

  @override
  Stream<AuthUser?> get changes => _controller.stream;

  void _emit(AuthUser? u) {
    _current = u;
    _controller.add(u);
  }

  @override
  Future<void> signInWithPassword({required String email, required String password}) async {
    if (_credentials[email.trim()] != password) {
      throw const LedgerException('Email 或密碼不正確');
    }
    _emit(AuthUser(id: 'u-${email.trim()}', email: email.trim()));
  }

  @override
  Future<void> signUp({required String email, required String password}) async {
    if (_credentials.containsKey(email.trim())) {
      throw const LedgerException('這個 Email 已經註冊過了，請直接登入');
    }
    _credentials[email.trim()] = password;
    _emit(AuthUser(id: 'u-${email.trim()}', email: email.trim()));
  }

  @override
  Future<void> signInWithApple() async {
    if (!appleEnabled) throw const LedgerException('Apple 登入尚未啟用');
    _emit(const AuthUser(id: 'u-apple', email: null));
  }

  @override
  Future<void> signOut() async => _emit(null);
}

final authServiceProvider = Provider<AuthService>((ref) => InMemoryAuthService.signedIn());

/// 目前登入者；null＝未登入。`router.redirect` 只看這個是不是 null。
class AuthNotifier extends Notifier<AuthUser?> {
  String? _lastUid;

  @override
  AuthUser? build() {
    final service = ref.watch(authServiceProvider);
    _lastUid = service.currentUser?.id;
    final sub = service.changes.listen(_onAuthChanged);
    ref.onDispose(sub.cancel);
    return service.currentUser;
  }

  /// 登入者換人（登出，或換成另一個帳號）就把上一個帳號的東西全部丟掉：
  /// 帳本選擇、整份快照、Realtime 訂閱（訂閱掛在 `currentLedgerIdProvider` 上，
  /// 它一變 null 就自動退訂）。
  ///
  /// 這是**唯一**的換人清理點——登出按鈕、token 過期、另一個分頁登入別的帳號，
  /// 全都會走到這裡；散在各個呼叫端就一定會漏掉其中一條路。
  void _onAuthChanged(AuthUser? u) {
    if (u == null || u.id != _lastUid) {
      _lastUid = u?.id;
      ref.read(currentLedgerIdProvider.notifier).clearNow();
      _forgetSavedLedger();
    }
    state = u;
  }

  /// prefs 慢一拍沒關係（畫面不看它），但例外不能逃成 uncaught。
  void _forgetSavedLedger() {
    ref
        .read(sharedPrefsProvider)
        ?.remove(kCurrentLedgerIdKey)
        .catchError((Object _) => false);
  }

  AuthService get _service => ref.read(authServiceProvider);

  Future<void> signIn({required String email, required String password}) async {
    await _service.signInWithPassword(email: email, password: password);
    state = _service.currentUser;
  }

  Future<void> signUp({required String email, required String password}) async {
    await _service.signUp(email: email, password: password);
    state = _service.currentUser;
  }

  Future<void> signInWithApple() async {
    await _service.signInWithApple();
    state = _service.currentUser;
  }

  /// 清理由 [_onAuthChanged] 統一處理（service 會發出 null）。
  Future<void> signOut() async {
    await _service.signOut();
    state = null;
  }
}

final authProvider = NotifierProvider<AuthNotifier, AuthUser?>(AuthNotifier.new);

/// `router.redirect` 用的一句話狀態。
final signedInProvider = Provider<bool>((ref) => ref.watch(authProvider) != null);
