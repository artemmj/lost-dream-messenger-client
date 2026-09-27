import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
// IOWebSocketChannel нужен для нативных платформ (Android/iOS/macOS/Linux/Windows),
// чтобы передать заголовок Origin в handshake. На web-платформе заголовки WS недоступны.
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import '../config.dart';
import 'api.dart';
import 'token_store.dart';

// Коды закрытия, при которых повторное подключение бессмысленно:
// 4001 — невалидный JWT, 4003 — исключён из чата, 4004 — чат удалён,
// 4009 — превышен лимит одновременных соединений, 4029 — слишком частые подключения.
// См. AGENTS.md раздел 5 «Коды закрытия».
const noReconnectCodes = {4001, 4003, 4004, 4009, 4029};

class WsClient {
  /// Путь к endpoint без схемы и хоста, например `chat/<uuid>/` или `notifications/`
  final String path;

  /// Колбэк для каждого полученного кадра от сервера
  final void Function(Map<String, dynamic> event) onEvent;

  /// Вызывается при закрытии соединения с кодом причины
  final void Function(int? code)? onClose;

  /// Вызывается после успешного переподключения (не первого подключения!)
  final void Function()? onReconnect;

  /// Вызывается сразу после успешного handshake, когда соединение открыто.
  /// Нужен для обновления статуса в UI — см. дефект №3 в AGENTS.md.
  final void Function()? onOpen;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _retryTimer;
  bool _closedByUser = false;

  // Открыт ли канал на самом деле: _channel создаётся до завершения handshake,
  // поэтому «канал != null» не означает «можно слать» (см. дефект с исчезающими
  // отправками: sendMessage писал в мёртвый сокет и не уходил в REST-фолбэк).
  bool _isOpen = false;

  // Счётчик неудачных подключений для экспоненциального backoff'а
  int _retryCount = 0;
  final math.Random _rng = math.Random();

  // Сколько сорванных handshake без кода подряд накопилось. После
  // _probeAfter штук добавляется пробный REST-запрос: отказы до accept
  // (4001/4009/4029) приходят как неудачный upgrade БЕЗ WS-кода, и без
  // проверки клиент с мёртвой сессией ретраил бы вечно (дефект №16).
  int _handshakeFailures = 0;
  static const _probeAfter = 3;

  // Идёт ли handshake прямо сейчас. connect() асинхронный (сначала refresh
  // токена), поэтому без этого флага revive() в момент незавершённого
  // подключения создал бы второй канал поверх первого — старый сокет остался
  // бы жив и дублировал события.
  bool _connecting = false;

  WsClient({
    required this.path,
    required this.onEvent,
    this.onClose,
    this.onReconnect,
    this.onOpen,
  });

  /// Подключается к WebSocket-серверу.
  ///
  /// Вызов во время незавершённого handshake игнорируется (см. _connecting).
  Future<void> connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      await _handshake();
    } finally {
      _connecting = false;
    }
  }

  /// Сам handshake: освежение токена, открытие канала и подписка на поток кадров.
  ///
  /// Для нативных платформ (Android/iOS/macOS/Linux/Windows) используется IOWebSocketChannel
  /// с заголовком Origin, который требует бэкенд (AllowedHostsOriginValidator).
  /// Без этого заголовка Django отвечает 403 до accept(), и клиент уходит в бесконечный ретрай.
  ///
  /// На web-платформе заголовки WebSocket-handshake недоступны браузером, поэтому
  /// используется обычный WebSocketChannel.connect. Для работы на web нужно настроить
  /// CORS_ALLOWED_ORIGINS и ALLOWED_HOSTS на бэкенде.
  Future<void> _handshake() async {
    _closedByUser = false;
    // Токен берём «освежённым»: просроченный JWT бэкенд отклоняет до accept,
    // клиент не видит кода закрытия и уходит в вечный backoff (дефект №16,
    // симптом на двух эмуляторах: «история грузится только на одном»).
    // ensureFreshAccess сам сделает refresh; при сетевой ошибке fallback —
    // пробуем с сохранённым токеном, вдруг он ещё жив.
    String? token;
    try {
      token = await Api().ensureFreshAccess();
    } catch (_) {
      token = await TokenStore.access;
    }
    if (token == null) {
      // Нет токена (или refresh не принят — сессия сброшена) — сообщаем
      // подписчику о закрытии с кодом «неавторизован»
      onClose?.call(4001);
      return;
    }

    // Формируем URI с токеном в query-параметре (заголовки в WS бэкенд не читает)
    final uri = Uri.parse('${AppConfig.wsBase}/$path?token=$token');

    try {
      // На нативных платформах добавляем заголовок Origin, иначе бэкенд вернёт 403.
      // AppConfig.host должен входить в ALLOWED_HOSTS Django (по умолчанию там 10.0.2.2).
      // На web этот конструктор недоступен — там заголовки игнорируются браузером.
      _channel = IOWebSocketChannel.connect(
        uri,
        headers: {'Origin': 'http://${AppConfig.host}'},
      );

      // ready завершается, когда handshake прошёл и соединение открыто
      await _channel!.ready;

      // Handshake успех: только с этого момента соединение реально открыто
      // и в него можно писать (см. флаг _isOpen).
      _isOpen = true;
      _retryCount = 0; // backoff сбрасывается после успешного подключения
      _handshakeFailures = 0;

      // onOpen вызываем ПЕРЕД onReconnect: UI сначала получает статус
      // 'connected' (setConnected в ChatState), и только потом идёт
      // перезагрузка истории. Раньше onOpen не вызывался вообще — шапка
      // чата вечно показывала «подключение...» даже при живом сокете.
      onOpen?.call();

      // Если это реконнект (первое подключение идёт с _retryTimer == null),
      // уведомляем подписчика, чтобы он перезагрузил состояние чата и список чатов
      if (_retryTimer != null) {
        onReconnect?.call();
      }

      // Подписываемся на поток сообщений от сервера
      _sub = _channel!.stream.listen(
        (data) {
          try {
            // Парсим JSON-кадр и передаём обработчику состояния
            final decoded = jsonDecode(data as String) as Map<String, dynamic>;
            onEvent(decoded);
          } catch (_) {
            // Некорректный JSON тихо игнорируется — дефект №15 в AGENTS.md
          }
        },
        // onDone вызывается при нормальном закрытии соединения
        onDone: () => _handleClose(_channel?.closeCode),
        // onError — при сетевых ошибках (разрыв, таймаут)
        onError: (_) => _handleClose(_channel?.closeCode),
      );
    } catch (_) {
      // Ошибка handshake (403, сеть, отказ 4001/4003/4029 ДО accept — кода
      // закрытия клиент при этом не видит, только сорванный upgrade).
      // Канал обнуляем, чтобы send() не написал в мёртвый сокет, и уходим
      // в реконнект с backoff'ом (см. _scheduleReconnect).
      _isOpen = false;
      _channel = null;
      _handshakeFailures++;
      if (_handshakeFailures >= _probeAfter) {
        // Серия отказов без кода — проверяем, жива ли сессия
        // (возможно, это 4001 из-за истёкшего токена), и только потом ретраим.
        await _probeAuth();
        return;
      }
      _scheduleReconnect();
    }
  }

  /// Принудительно переподключиться, сбросив backoff.
  ///
  /// Нужен после возврата приложения в foreground: на кодах из noReconnectCodes
  /// (4001 — сессия, 4009/4029 — лимиты подключений) клиент перестаёт
  /// переподключаться навсегда, а эталон поднимает канал заново, как только
  /// вкладка снова становится видимой (handleVisibility в useNotificationsSocket.ts).
  /// Сокет, закрытый через close() (logout), не воскрешаем.
  ///
  /// Отменённый таймер намеренно не обнуляем: по `_retryTimer != null` в connect()
  /// отличается первое подключение от повторного, и воскрешение — это повторное
  /// (подписчик должен перечитать пропущенные события в onReconnect).
  void revive() {
    if (_isOpen || _closedByUser) return;
    _retryCount = 0;
    _handshakeFailures = 0;
    _retryTimer?.cancel();
    connect();
  }

  /// Пробный аутентифицированный REST-запрос после серии невидимых отказов
  /// handshake. Api.me() на 401 сам обновит токен и повторит запрос; если
  /// refresh не принят — токены стёрты, и это мёртвая сессия: сигнализируем
  /// onClose(4001), чтобы UI вернулся к экрану входа вместо вечного
  /// «подключение...». Сетевые сбои сессию не трогают — продолжаем backoff.
  Future<void> _probeAuth() async {
    _handshakeFailures = 0;
    try {
      await Api().me();
      _scheduleReconnect();
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        // 4001 в noReconnectCodes — переподключение бессмысленно,
        // реконнект не планируем
        onClose?.call(4001);
        return;
      }
      _scheduleReconnect();
    } catch (_) {
      // Сервер/сеть недоступны — не признак мёртвой сессии
      _scheduleReconnect();
    }
  }

  /// Обрабатывает закрытие соединения.
  ///
  /// Отменяет подписку на поток, обнуляет канал и уведомляет подписчика о коде закрытия.
  /// Если соединение закрыто пользователем (_closedByUser) или код входит в noReconnectCodes,
  /// реконнект не планируется — это окончательное закрытие.
  /// В остальных случаях (обрыв сети, таймаут сервера) переподключение откладывается
  /// по экспоненциальному backoff'у — см. _scheduleReconnect.
  void _handleClose(int? code) {
    _isOpen = false;
    _sub?.cancel();
    _sub = null;
    _channel = null;

    // Уведомляем ChatState о закрытии — он обновит wsStatus и, возможно, удалит чат
    onClose?.call(code);

    // Если пользователь сам вызвал close() или сервер вернул «фатальный» код — не реконнектим
    if (_closedByUser) return;
    if (code != null && noReconnectCodes.contains(code)) return;

    // Во всех остальных случаях планируем переподключение с растущей задержкой
    _scheduleReconnect();
  }

  /// Планирует повторное подключение с экспоненциальным backoff'ом:
  /// 1, 2, 4, 8, 16, 32, 60 с (далее потолок 60 с) плюс джиттер ±30%,
  /// чтобы два клиента не ретраили синхронно.
  ///
  /// Почему не фиксированные 2 с (как было раньше): у бэкенда лимит
  /// подключений 20/мин на пользователя (messenger/ratelimit.py CONNECT_LIMITER),
  /// а отказ 4029 происходит до accept — клиент не видит код закрытия,
  /// не попадает в noReconnectCodes и ретраит вечно. Фиксированные 2 с = до
  /// 30 попыток/мин: кратковременный обрыв сети запускал петлю, которой
  /// клиент сам блокировал себе переподключение (симптом: вечно «подключение...»,
  /// не приходят сообщения и бейджи). Растущая задержка держит частоту
  /// попыток ниже лимита, и соединение восстанавливается само.
  void _scheduleReconnect() {
    _retryTimer?.cancel();
    const stepsS = [1, 2, 4, 8, 16, 32, 60];
    final baseS = stepsS[math.min(_retryCount, stepsS.length - 1)];
    _retryCount++;
    final jitter = 0.7 + _rng.nextDouble() * 0.6; // 0.7x .. 1.3x
    _retryTimer = Timer(
      Duration(milliseconds: (baseS * 1000 * jitter).round()),
      connect,
    );
  }

  /// Отправляет JSON-кадр в WebSocket.
  ///
  /// Клиент отправляет только {"text": "..."} — бэкенд сам добавит id, chat, sender, created_at, is_read
  /// и вернёт полное сообщение обратно через broadcast-группу чата (эхо).
  /// Если канал не открыт — бросает StateError: вызывающий (ChatState.sendMessage)
  /// переводит отправку на REST-фолбэк, а не пишет в мёртвый сокет.
  void send(Map<String, dynamic> payload) {
    if (_channel == null || !_isOpen) {
      throw StateError('Socket not connected');
    }
    _channel!.sink.add(jsonEncode(payload));
  }

  /// True только когда handshake завершён и в канал реально можно писать.
  ///
  /// Раньше возвращал `_channel != null`, но канал создаётся до handshake —
  /// из-за этого sendMessage считал сокет живым во время переподключения
  /// и сообщения терялись (не срабатывал REST-фолбэк).
  bool get isConnected => _isOpen;

  /// Закрывает соединение нормально (код 1000) и отменяет все таймеры реконнекта.
  ///
  /// После этого WsClient можно выбросить — повторное использование невозможно.
  void close() {
    _closedByUser = true;
    _isOpen = false;
    _retryTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close(ws_status.normalClosure);
    _channel = null;
  }
}
