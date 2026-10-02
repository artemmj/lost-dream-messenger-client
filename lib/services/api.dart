import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import '../models/chat.dart';
import '../models/me.dart';
import '../models/message.dart';
import '../models/user.dart';
import 'token_store.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  ApiException(this.statusCode, this.message);
  @override
  String toString() => message;
}

class Api {
  static final Api _instance = Api._();
  factory Api() => _instance;
  Api._();

  Future<Map<String, String>> _headers({bool auth = true}) async {
    final h = {'Content-Type': 'application/json'};
    if (auth) {
      final token = await TokenStore.access;
      if (token != null) h['Authorization'] = 'Bearer $token';
    }
    return h;
  }

  String _extractError(http.Response r) {
    try {
      final body = jsonDecode(utf8.decode(r.bodyBytes));
      if (body is Map) {
        if (body['detail'] != null) return body['detail'].toString();
        // DRF: {field: ["..."]}
        for (final entry in body.entries) {
          final v = entry.value;
          if (v is List && v.isNotEmpty) return '${entry.key}: ${v.first}';
          if (v is String) return v;
        }
      }
    } catch (_) {}
    return 'Ошибка ${r.statusCode}';
  }

  Future<http.Response> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
    bool retryOn401 = true,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBase}$path');
    final headers = await _headers(auth: auth);
    late http.Response res;

    switch (method) {
      case 'GET':
        res = await http.get(uri, headers: headers);
        break;
      case 'POST':
        res = await http.post(
          uri,
          headers: headers,
          body: jsonEncode(body ?? {}),
        );
        break;
      case 'PATCH':
        res = await http.patch(
          uri,
          headers: headers,
          body: jsonEncode(body ?? {}),
        );
        break;
      case 'DELETE':
        res = await http.delete(uri, headers: headers);
        break;
      default:
        throw ArgumentError('Unknown method $method');
    }

    if (res.statusCode == 401 && auth && retryOn401) {
      final ok = await _refreshToken();
      if (ok) {
        return _request(
          method,
          path,
          body: body,
          auth: auth,
          retryOn401: false,
        );
      } else {
        await TokenStore.clear();
      }
    }
    return res;
  }

  Future<bool> _refreshToken() async {
    final refresh = await TokenStore.refresh;
    if (refresh == null) return false;
    final res = await http.post(
      Uri.parse('${AppConfig.apiBase}/auth/refresh/'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'refresh': refresh}),
    );
    if (res.statusCode == 200) {
      final data = jsonDecode(res.body);
      final access = data['access'] as String;
      await TokenStore.save(access, refresh);
      return true;
    }
    return false;
  }

  /// Возвращает заведомо живой access-токен, обновив пару JWT при истечении.
  ///
  /// Нужен WebSocket-клиенту: у бэкенда ACCESS_TOKEN_LIFETIME — 60 минут, а
  /// отказ 4001 приходит до accept handshake: клиент не видит WS-код и ретраит
  /// вечно (дефект №16). REST-запросы чинят токен сами на 401, но WS-handshake
  /// идёт мимо REST — поэтому токен проверяется до подключения здесь.
  /// Возвращает null, если refresh не принят (токены стёрты — сессии больше нет).
  Future<String?> ensureFreshAccess() async {
    final token = await TokenStore.access;
    if (token == null) return null;
    if (!_jwtExpired(token)) return token;
    final ok = await _refreshToken();
    if (!ok) {
      await TokenStore.clear();
      return null;
    }
    return TokenStore.access;
  }

  /// True, если у JWT истёк срок (claim exp) или до истечения меньше 5 секунд
  /// (handshake ещё идёт, а сервер проверит токен в своём темпе).
  /// Неразбираемый токен считаем живым: решение за сервером.
  bool _jwtExpired(String token) {
    try {
      final payload = token.split('.')[1];
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(payload))),
      ) as Map<String, dynamic>;
      final exp = claims['exp'];
      if (exp is! int) return false;
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return exp <= nowSec + 5;
    } catch (_) {
      return false;
    }
  }

  // ---------- AUTH ----------

  Future<Map<String, dynamic>> login(String phone, String password) async {
    final res = await _request(
      'POST',
      '/auth/login/',
      body: {'phone': phone, 'password': password},
      auth: false,
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    final data = jsonDecode(res.body);
    await TokenStore.save(data['access'], data['refresh']);
    return data;
  }

  Future<void> register({
    required String phone,
    required String password,
    required String passwordConfirm,
    String? email,
    String? firstName,
    String? lastName,
  }) async {
    final body = <String, dynamic>{
      'phone': phone,
      'password': password,
      'password_confirm': passwordConfirm,
    };
    if (email != null && email.isNotEmpty) body['email'] = email;
    if (firstName != null && firstName.isNotEmpty) {
      body['first_name'] = firstName;
    }
    if (lastName != null && lastName.isNotEmpty) body['last_name'] = lastName;

    final res = await _request(
      'POST',
      '/auth/register/',
      body: body,
      auth: false,
    );
    if (res.statusCode != 201) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    // Бэкенд отдаёт пару JWT сразу (views.py RegisterView.create), поэтому
    // отдельный login после регистрации не нужен — он лишь жгёт лимит scope
    // `auth` (10/мин). См. дефект №14.
    final data = jsonDecode(res.body);
    await TokenStore.save(data['access'], data['refresh']);
  }

  // ---------- USERS ----------

  Future<Me> me() async {
    final res = await _request('GET', '/users/me/');
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return Me.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  Future<Me> updateMe(Map<String, dynamic> payload) async {
    final res = await _request('PATCH', '/users/me/', body: payload);
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return Me.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  Future<void> registerDeviceToken(String token) async {
    final res = await _request(
      'POST',
      '/devices/',
      body: {'token': token, 'platform': 'android'},
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
  }

  Future<void> revokeDeviceToken(String token) async {
    final res = await _request(
      'POST',
      '/devices/revoke/',
      body: {'token': token},
    );
    if (res.statusCode != 204) {
      throw ApiException(res.statusCode, _extractError(res));
    }
  }

  Future<List<User>> searchUsers(String query) async {
    final res = await _request(
      'GET',
      '/users/search/?q=${Uri.encodeQueryComponent(query)}',
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    return (data['results'] as List).map((j) => User.fromJson(j)).toList();
  }

  // ---------- CHATS ----------

  Future<List<ChatListItem>> listChats({int page = 1}) async {
    final res = await _request('GET', '/chats/?page=$page');
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes));
    return (data['results'] as List)
        .map((j) => ChatListItem.fromJson(j))
        .toList();
  }

  Future<ChatDetail> chatDetail(String chatId) async {
    final res = await _request('GET', '/chats/$chatId/');
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return ChatDetail.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  Future<ChatDetail> createPrivateChat(String interlocutorId) async {
    final res = await _request(
      'POST',
      '/chats/private/',
      body: {'interlocutor_id': interlocutorId},
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return ChatDetail.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  Future<ChatDetail> createGroupChat({
    required String name,
    required List<String> memberIds,
  }) async {
    final res = await _request(
      'POST',
      '/chats/',
      body: {'type': 'GROUP', 'name': name, 'member_ids': memberIds},
    );
    if (res.statusCode != 201) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return ChatDetail.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// Переименование GROUP-чата. Только админ (остальным 403), не-GROUP → 400.
  Future<ChatDetail> renameChat(String chatId, String name) async {
    final res = await _request(
      'PATCH',
      '/chats/$chatId/',
      body: {'name': name},
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return ChatDetail.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  /// Удаление чата вместе с историей. GROUP — только админ, PRIVATE — любой
  /// участник. Остальным сервер сам разнесёт `chat_deleted` и закрытие 4004.
  Future<void> deleteChat(String chatId) async {
    final res = await _request('DELETE', '/chats/$chatId/');
    if (res.statusCode != 204) {
      throw ApiException(res.statusCode, _extractError(res));
    }
  }

  Future<MessagePage> messages(String chatId, {int page = 1}) async {
    final res = await _request('GET', '/chats/$chatId/messages/?page=$page');
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return MessagePage.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  Future<Message> sendMessage(String chatId, String text) async {
    final res = await _request(
      'POST',
      '/chats/$chatId/send/',
      body: {'text': text},
    );
    if (res.statusCode != 201) {
      throw ApiException(res.statusCode, _extractError(res));
    }
    return Message.fromJson(jsonDecode(utf8.decode(res.bodyBytes)));
  }

  Future<void> markRead(String chatId) async {
    final res = await _request('POST', '/chats/$chatId/read/');
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
  }

  /// Добавление участника в GROUP-чат. Только админ (остальным 403),
  /// в личный чат — 400, уже состоящий — 400.
  Future<void> addMember(String chatId, String userId) async {
    final res = await _request(
      'POST',
      '/chats/$chatId/add-member/',
      body: {'user_id': userId},
    );
    if (res.statusCode != 201) {
      throw ApiException(res.statusCode, _extractError(res));
    }
  }

  Future<void> removeMember(String chatId, String userId) async {
    final res = await _request(
      'POST',
      '/chats/$chatId/remove-member/',
      body: {'user_id': userId},
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _extractError(res));
    }
  }
}
