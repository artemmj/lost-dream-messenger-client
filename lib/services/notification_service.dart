import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api.dart';
import 'token_store.dart';

class NotificationService {
  NotificationService._();

  static const highChannelId = 'mdm_messages_high';
  static const lowChannelId = 'mdm_messages_low';

  static final _messaging = FirebaseMessaging.instance;
  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static final pendingChatId = ValueNotifier<String?>(null);
  static StreamSubscription<String>? _tokenSubscription;
  static bool _initialized = false;

  static String get _devicePlatform => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    _ => throw UnsupportedError('Push notifications require Android or iOS'),
  };

  static Future<void> initialize() async {
    if (_initialized) return;

    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        _queueChatFromPayload(response.payload);
      },
    );

    final android = _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        highChannelId,
        'Личные сообщения',
        description: 'Новые сообщения в личных чатах',
        importance: Importance.high,
      ),
    );
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        lowChannelId,
        'Групповые сообщения',
        description: 'Новые сообщения в групповых чатах',
        importance: Importance.low,
      ),
    );

    FirebaseMessaging.onMessage.listen((message) {
      if (kDebugMode) debugPrint('[push] foreground FCM received');
      unawaited(_showRemoteMessage(message));
    });
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (kDebugMode) debugPrint('[push] opened from FCM notification');
      _queueChatFromRemoteMessage(message);
    });
    _tokenSubscription ??= _messaging.onTokenRefresh.listen((token) {
      unawaited(_registerTokenIfAuthenticated(token));
    });

    final initialMessage = await _messaging.getInitialMessage();
    if (initialMessage != null) _queueChatFromRemoteMessage(initialMessage);

    final launchDetails = await _localNotifications
        .getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      _queueChatFromPayload(launchDetails?.notificationResponse?.payload);
    }

    _initialized = true;
  }

  static Future<void> syncDeviceToken() async {
    if (!_initialized) return;
    try {
      final permission = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) {
        if (kDebugMode) debugPrint('[push] notification permission denied');
        return;
      }

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        String? apnsToken;
        for (var attempt = 0; attempt < 20; attempt++) {
          apnsToken = await _messaging.getAPNSToken();
          if (apnsToken != null) break;
          await Future.delayed(const Duration(milliseconds: 250));
        }
        if (apnsToken == null) {
          if (kDebugMode) debugPrint('[push] APNs token not available yet');
          return;
        }
      }

      final token = await _messaging.getToken();
      if (token == null) {
        if (kDebugMode) debugPrint('[push] FCM returned no registration token');
        return;
      }
      await _registerTokenIfAuthenticated(token);
    } catch (error) {
      // Push is optional; Firebase or network failures must not block sign-in.
      if (kDebugMode) {
        debugPrint('[push] token sync failed (${error.runtimeType})');
      }
    }
  }

  static Future<void> revokeDeviceToken() async {
    if (!_initialized) return;
    try {
      final token = await _messaging.getToken();
      if (token != null) await Api().revokeDeviceToken(token);
    } catch (_) {
      // Logout remains local even when the server cannot revoke the token.
    }
  }

  static Future<void> showChatMessage({
    required String chatId,
    required String messageId,
    required String title,
    required String body,
    required String channelId,
  }) async {
    if (!_initialized) return;
    await _show(
      id: _notificationId(messageId),
      messageId: messageId,
      title: title,
      body: body,
      channelId: channelId,
      data: {'type': 'new_message', 'chat_id': chatId, 'message_id': messageId},
    );
  }

  static Future<void> _registerTokenIfAuthenticated(String token) async {
    try {
      if (await TokenStore.access == null) {
        if (kDebugMode) debugPrint('[push] token not registered: no auth session');
        return;
      }
      await Api().registerDeviceToken(token, platform: _devicePlatform);
      if (kDebugMode) debugPrint('[push] device token registered');
    } on ApiException catch (error) {
      if (kDebugMode) {
        debugPrint('[push] device token registration rejected: HTTP ${error.statusCode}');
      }
    } catch (error) {
      // The next app start or token refresh retries registration.
      if (kDebugMode) {
        debugPrint('[push] device token registration failed (${error.runtimeType})');
      }
    }
  }

  static Future<void> _showRemoteMessage(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) {
      if (kDebugMode) debugPrint('[push] FCM message has no notification payload');
      return;
    }

    final data = message.data.map((key, value) => MapEntry(key, '$value'));
    final messageId = data['message_id'] ?? data['type'] ?? 'push';
    await _show(
      id: _notificationId(messageId),
      messageId: messageId,
      title: notification.title ?? 'Lost Dream Messenger',
      body: notification.body ?? '',
      channelId: notification.android?.channelId ?? highChannelId,
      data: data,
    );
  }

  static Future<void> _show({
    required int id,
    required String messageId,
    required String title,
    required String body,
    required String channelId,
    required Map<String, String> data,
  }) async {
    final highImportance = channelId == highChannelId;
    await _localNotifications.show(
      id,
      title,
      _preview(body),
      NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          highImportance ? 'Личные сообщения' : 'Групповые сообщения',
          channelDescription: highImportance
              ? 'Новые сообщения в личных чатах'
              : 'Новые сообщения в групповых чатах',
          icon: 'ic_notification',
          importance: highImportance ? Importance.high : Importance.low,
          priority: highImportance ? Priority.high : Priority.low,
          tag: messageId,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: jsonEncode(data),
    );
  }

  static String _preview(String text) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 180) return collapsed;
    return '${collapsed.substring(0, 179).trimRight()}…';
  }

  static int _notificationId(String value) {
    final normalized = value.replaceAll('-', '');
    final prefix = normalized.length > 8
        ? normalized.substring(0, 8)
        : normalized;
    final parsed = int.tryParse(prefix, radix: 16);
    return (parsed ?? value.hashCode) & 0x7fffffff;
  }

  static void _queueChatFromRemoteMessage(RemoteMessage message) {
    final chatId = message.data['chat_id'];
    if (chatId is String && chatId.isNotEmpty) pendingChatId.value = chatId;
  }

  static void _queueChatFromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return;
    try {
      final data = jsonDecode(payload);
      final chatId = data is Map ? data['chat_id'] : null;
      if (chatId is String && chatId.isNotEmpty) pendingChatId.value = chatId;
    } catch (_) {
      // Ignore notification payloads from older app versions.
    }
  }

  static String? takePendingChatId() {
    final chatId = pendingChatId.value;
    pendingChatId.value = null;
    return chatId;
  }
}
