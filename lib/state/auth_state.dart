import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/me.dart';
import '../services/api.dart';
import '../services/notification_service.dart';
import '../services/token_store.dart';

class AuthState extends ChangeNotifier {
  Me? _me;
  bool _loading = false;
  String? _error;

  Me? get me => _me;
  bool get loading => _loading;
  String? get error => _error;
  bool get isAuthenticated => _me != null;

  /// Человекочитаемый текст ошибки: сообщение бэкенда из ApiException либо
  /// «нет связи» для сетевых исключений (дефект №15).
  static String _describe(Object e) =>
      e is ApiException ? e.message : 'Нет связи с сервером';

  /// Восстанавливает сессию из сохранённых токенов при старте.
  ///
  /// Причина отказа теперь видна на экране входа (LoginScreen показывает
  /// `error` плашкой): «история не грузится, пустой экран» без текста нельзя
  /// отличить от сорванной сети (дефект №15).
  Future<bool> bootstrap() async {
    final token = await TokenStore.access;
    if (token == null) return false;
    try {
      _me = await Api().me();
      unawaited(NotificationService.syncDeviceToken());
      notifyListeners();
      return true;
    } catch (e) {
      // Токен не принят (или связи нет) — сбрасываем хранилище: повторный
      // bootstrap с тем же мусором смысла не имеет
      await TokenStore.clear();
      _error = 'Не удалось восстановить сессию: ${_describe(e)}';
      notifyListeners();
      return false;
    }
  }

  Future<bool> login(String phone, String password) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      await Api().login(phone, password);
      _me = await Api().me();
      unawaited(NotificationService.syncDeviceToken());
      return true;
    } catch (e) {
      // Не только ApiException: SocketException при офлайне раньше вылетал
      // из future и ошибка до UI не доходила вообще (дефект №15)
      _error = _describe(e);
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> register({
    required String phone,
    required String password,
    required String passwordConfirm,
    String? email,
    String? firstName,
    String? lastName,
  }) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      // Api.register уже сохранил пару JWT из ответа (201 {user, access,
      // refresh}), поэтому отдельный login не нужен: он дублировал запрос
      // и жёг лимит scope `auth` — 10/мин (дефект №14).
      await Api().register(
        phone: phone,
        password: password,
        passwordConfirm: passwordConfirm,
        email: email,
        firstName: firstName,
        lastName: lastName,
      );
      _me = await Api().me();
      unawaited(NotificationService.syncDeviceToken());
      return true;
    } catch (e) {
      _error = _describe(e);
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Сбрасывает текст ошибки. Экрану нужна чистая форма при переключении
  /// вход ↔ регистрация: в эталоне это `watch(isRegister) → clearError()`.
  void clearError() {
    _error = null;
    notifyListeners();
  }

  Future<bool> updateProfile(Map<String, dynamic> payload) async {
    try {
      _me = await Api().updateMe(payload);
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = _describe(e);
      notifyListeners();
      return false;
    }
  }

  /// Выход из аккаунта.
  ///
  /// Очищает токены, сбрасывает состояние пользователя и очищает все данные чатов,
  /// чтобы предотвратить дальнейшие запросы к бэкенду с просроченными токенами.
  /// [reason] — если выход не по воле пользователя (4001 от бэкенда), причина
  /// показывается плашкой на экране входа: без неё возврат к логину выглядит
  /// как произвольный сброс (дефект №15).
  Future<void> logout({String? reason}) async {
    await NotificationService.revokeDeviceToken();
    await TokenStore.clear();
    _me = null;
    _error = reason;
    notifyListeners();
  }
}
