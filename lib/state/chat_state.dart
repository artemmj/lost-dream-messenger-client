import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat.dart';
import '../models/message.dart';
import '../services/api.dart';
import '../services/notification_service.dart';
import '../services/ws.dart';

/// PAGE_SIZE бэкенда: полная страница означает, что пропущенных сообщений
/// могло накопиться больше одной страницы (см. reloadMessages).
const int messagesPageSize = 50;

/// Состояние WebSocket открытого чата (дефект №20): раньше статус хранился
/// как строка 'connected'/'connecting'/'disconnected' — опечатки в сравнениях
/// не ловились типами. Теперь enum, как и ChatType в моделях.
enum WsStatus { connecting, connected, disconnected }

class ChatState extends ChangeNotifier {
  final Api _api = Api();

  List<ChatListItem> chats = [];
  ChatDetail? currentChatDetail;
  List<Message> messages = [];
  String? selectedChatId;

  final Set<String> onlineUsers = {};
  int messagesPage = 1;

  /// Есть ли ещё более старые сообщения. До первого ответа сервера — false:
  /// иначе лента успевала запросить страницу 2 до завершения загрузки страницы 1
  /// (гонка при открытии чата). Значение берётся из `next` пагинатора, а не из
  /// количества элементов (дефект №11).
  bool hasMoreMessages = false;
  bool isLoadingHistory = false;

  /// Ошибка загрузки истории открытого чата. Раньше в _loadFirstPage был глухой
  /// catch (_) {} — сбой сети или 401 превращался в «пустой экран без объяснений»
  /// (дефект №15). Теперь текст виден плашкой в ChatScreen.
  String? loadError;

  /// Ошибка загрузки деталей чата (участники, роль). Показывается в ChatScreen
  /// там же, где loadError: при сбое список участников просто не отрисуется.
  String? detailsError;

  /// Ошибка загрузки списка чатов (loadChats / pull-to-refresh). Плашка над
  /// списком в ChatsScreen — раньше 429 и офлайн выглядели как «Чатов пока нет».
  String? listError;

  /// Отказ при отправке: текст REST-ошибки или кадр `{error: ...}` от сервера
  /// (пустое сообщение, текст длиннее 5000 символов, анти-флуд 10/10 с).
  /// Раньше такие кадры проглатывались: у них нет ни `type`, ни `id`, поэтому
  /// поле ввода просто очищалось и сообщение молча не уходило (дефект №9).
  String? sendError;

  /// Мой id. Нужен, чтобы не рисовать ✓✓ на своих сообщениях, когда событие
  /// `messages_read` пришло на моё же прочтение (дефект №10). В payload JWT
  /// только `user_id`, профиль догружается отдельным запросом, поэтому значение
  /// проставляется из AuthState при wiring'е в main.dart.
  String? myUserId;

  /// Приложение на переднем плане. Мобильный аналог
  /// `document.visibilityState === 'visible'` из эталона: значение выставляет
  /// ChatsScreen в didChangeAppLifecycleState.
  ///
  /// Влияет на одно решение — считать ли пришедшее в открытый чат сообщение
  /// прочитанным сразу (эталон: applyNewMessage в stores/chat.ts). Без проверки
  /// фоновое приложение молча двигало курсор прочтения, и пользователь терял
  /// бейджи непрочитанного, так и не увидев сообщения.
  bool isForeground = true;

  /// Однократные ошибки без своего места в UI (например, markRead): подписчик
  /// в main.dart показывает их SnackBar'ом через navigatorKey. Плашка тут не
  /// подходит — ошибка может прийти, когда соответствующий экран не открыт.
  void Function(String message)? onNotice;

  /// Человекочитаемая причина закрытия WS-сокета чата (плашка соединения в
  /// шапке `ChatScreen`). Код виден только для закрытий ПОСЛЕ accept; отказы до accept
  /// клиент различает пробным REST-запросом в WsClient (_probeAuth).
  String? wsCloseNotice;

  /// Вызывается, когда бэкенд отверг авторизацию (4001 на любом из сокетов).
  /// Навигацией занимается подписчик (main.dart): снять толкнутые маршруты и
  /// разлогинить — сам ChatState экраны не переключает.
  void Function()? onSessionExpired;

  WsClient? _chatSocket;
  WsStatus? _wsStatus; // null — сокет чата ещё не открывался

  WsStatus? get wsStatus => _wsStatus;

  /// Превращает исключение сетевого слоя в человекочитаемый текст (дефект №15):
  /// ApiException уже несёт сообщение бэкенда на нужном языке, всё остальное
  /// (SocketException, таймаут) — «нет связи с сервером».
  static String _describe(String what, Object e) =>
      e is ApiException ? '$what: ${e.message}' : '$what: нет связи с сервером';

  ChatListItem? get selectedChat {
    if (selectedChatId == null) return null;
    try {
      return chats.firstWhere((c) => c.id == selectedChatId);
    } catch (_) {
      return null;
    }
  }

  /// Собеседник в сети (для личного чата). null — показывать нечего: чат не
  /// личный, либо собеседник ещё не пришёл со списком чатов.
  ///
  /// Источник — снимок initial_presence и кадры user_status канала чата.
  bool? get interlocutorOnline {
    final chat = selectedChat;
    if (chat == null || chat.type != ChatType.private) return null;
    final other = chat.interlocutor;
    if (other == null) return null;
    return onlineUsers.contains(other.id);
  }

  /// Сколько участников группы в сети. null — детали группы ещё не загружены.
  ///
  /// Себя не считаем: «в сети» здесь про остальных (как в эталонном
  /// onlineMembersCount).
  int? get onlineMembersCount {
    final detail = currentChatDetail;
    if (detail == null || detail.type != ChatType.group) return null;
    return detail.members
        .where((m) => m.user.id != myUserId && onlineUsers.contains(m.user.id))
        .length;
  }

  /// Участники группы без меня — знаменатель счётчика «N в сети из M».
  List<ChatMember> get otherMembers {
    final detail = currentChatDetail;
    if (detail == null) return const [];
    return detail.members.where((m) => m.user.id != myUserId).toList();
  }

  /// GROUP переименовывает только админ (сервер вернёт 403 остальным).
  bool get canRenameChat {
    final chat = selectedChat;
    return chat != null &&
        chat.type == ChatType.group &&
        (currentChatDetail?.myIsAdmin ?? false);
  }

  /// GROUP удаляет только админ, PRIVATE — любой участник: в личном чате мы
  /// состоим по определению, поэтому прав там проверять нечего.
  bool get canDeleteChat {
    final chat = selectedChat;
    if (chat == null) return false;
    if (chat.type == ChatType.private) return true;
    return currentChatDetail?.myIsAdmin ?? false;
  }

  /// Загружает список чатов с бэкенда и обновляет состояние.
  ///
  /// Сейчас всегда загружает первую страницу (50 чатов) — см. дефект №33 в AGENTS.md.
  /// Ошибка больше не глушится: текст ложится в listError и виден плашкой над
  /// списком (дефект №15).
  Future<void> loadChats() async {
    try {
      chats = await _api.listChats();
      listError = null;
      notifyListeners();
    } catch (e) {
      listError = _describe('Не удалось загрузить список чатов', e);
      notifyListeners();
    }
  }

  /// Выбирает чат для отображения: сбрасывает сообщения, загружает первую страницу,
  /// детали чата, отмечает как прочитанный и открывает WebSocket.
  ///
  /// selectedChatId устанавливается здесь, но данные берутся из глобального состояния,
  /// а не из маршрута — см. раздел 3 AGENTS.md про навигацию.
  Future<void> selectChat(String chatId) async {
    selectedChatId = chatId;
    messages = [];
    messagesPage = 1;
    hasMoreMessages = false;
    onlineUsers.clear();
    currentChatDetail = null;
    loadError = null;
    detailsError = null;
    sendError = null;
    wsCloseNotice = null;
    notifyListeners();

    // Загружаем параллельно: первую страницу сообщений, детали чата и markRead
    await Future.wait([
      _loadFirstPage(chatId),
      loadChatDetails(chatId),
      markRead(chatId),
    ]);

    // Открываем сокет только после загрузки данных
    _openChatSocket(chatId);
  }

  /// Загружает первую (самую свежую) страницу сообщений чата.
  ///
  /// Бэкенд отдаёт последнюю страницу в обратном порядке (от новых к старым),
  /// но затем сериализует её как page[::-1] — то есть уже по возрастанию времени.
  /// Поэтому .reversed здесь не нужен: messages добавляются в естественном порядке
  /// (старые сверху, новые снизу).
  Future<void> _loadFirstPage(String chatId) async {
    try {
      final page = await _api.messages(chatId, page: 1);
      // Страница могла прийти после смены чата — не затираем данные нового
      if (selectedChatId != chatId) return;
      // Бэкенд уже отдал страницу по возрастанию времени (views.py: MessageSerializer(page[::-1]))
      messages = page.items;
      messagesPage = 1;
      hasMoreMessages = page.hasNext;
      loadError = null;
      notifyListeners();
    } catch (e) {
      if (selectedChatId != chatId) return;
      // Больше не глушим: без этого сбоя пользователь видел пустую ленту
      // и «ничего не происходит» (дефект №15)
      loadError = _describe('Не удалось загрузить историю', e);
      notifyListeners();
    }
  }

  /// Загружает детали чата (список участников, моя роль админа).
  ///
  /// Ошибка больше не глушится: текст ложится в detailsError и показывается
  /// той же плашкой, что и ошибка истории (дефект №15).
  Future<void> loadChatDetails(String chatId) async {
    try {
      currentChatDetail = await _api.chatDetail(chatId);
      detailsError = null;
      notifyListeners();
    } catch (e) {
      detailsError = _describe('Не удалось загрузить детали чата', e);
      notifyListeners();
    }
  }

  /// Подгружает более старые сообщения (пагинация назад во времени).
  ///
  /// Бэкенд отдаёт каждую страницу по возрастанию времени, поэтому при объединении
  /// старая страница вставляется в начало списка: [...older, ...messages].
  /// .reversed не нужен — см. комментарий к _loadFirstPage.
  Future<void> loadOlderMessages() async {
    final chatId = selectedChatId;
    if (chatId == null || !hasMoreMessages || isLoadingHistory) return;
    isLoadingHistory = true;
    notifyListeners();
    try {
      final next = messagesPage + 1;
      final older = await _api.messages(chatId, page: next);
      // Чат могли переключить, пока шёл запрос — не подмешиваем чужую историю
      if (selectedChatId != chatId) return;
      // Границы страниц разъезжаются, если во время запроса пришли новые
      // сообщения, поэтому дубли отсекаем по id
      final known = messages.map((m) => m.id).toSet();
      messages = [
        ...older.items.where((m) => !known.contains(m.id)),
        ...messages,
      ];
      messagesPage = next;
      hasMoreMessages = older.hasNext;
      loadError = null;
    } catch (e) {
      if (selectedChatId != chatId) return;
      // Дозагрузка старых страниц тоже больше не молчит (дефект №15):
      // 429 по scope `user` или офлайн иначе выглядят как «список не листается»
      loadError = _describe('Не удалось загрузить более старые сообщения', e);
    } finally {
      isLoadingHistory = false;
    }
    notifyListeners();
  }

  /// Отмечает чат как прочитанный на сервере и обнуляет счётчик непрочитанного в списке.
  ///
  /// Бэкенд сдвигает курсор Membership.last_read_at, но Message.is_read остаётся глобальным
  /// флагом (кто-то прочитал ≠ конкретный собеседник). См. раздел 5 AGENTS.md.
  Future<void> markRead(String chatId) async {
    try {
      await _api.markRead(chatId);
      final idx = chats.indexWhere((c) => c.id == chatId);
      if (idx != -1) {
        chats[idx] = chats[idx].copyWith(unreadCount: 0);
        notifyListeners();
      }
    } catch (e) {
      // Ошибка курсора прочтения не должна выглядеть как «бейдж не сбросился»:
      // одноразовое сообщение через onNotice (плашка чата для этого не место —
      // markRead приходит и из WS-уведомлений, когда экран чата может быть закрыт)
      onNotice?.call(_describe('Не удалось отметить чат прочитанным', e));
    }
  }

  /// Отправляет сообщение в выбранный чат.
  ///
  /// При живом WebSocket отправляет через WS и возвращает null: своё сообщение придёт
  /// эхом из broadcast-группы. Иначе — REST-фолбэк `POST /chats/{id}/send/`, и ответ
  /// уходит в ленту сразу.
  ///
  /// Прокрутку ленты экран выполняет по изменению id последнего сообщения, а не
  /// по возвращаемому значению (дефект №12 исправлен): эхо и REST-ответ
  /// обрабатываются одинаково.
  ///
  /// Ошибку не глотает: отказ ложится в `sendError` и пробрасывается дальше, чтобы
  /// экран вернул несообщённый текст в поле ввода.
  Future<Message?> sendMessage(String text) async {
    final chatId = selectedChatId;
    if (chatId == null) return null;
    sendError = null;

    // Пытаемся отправить через WebSocket. «Жив» означает завершённый handshake
    // (WsClient.isConnected): при неподтверждённом соединении send() бросает
    // StateError, и отправка штатно уходит в REST, а не в мёртвый сокет (№28).
    if (_chatSocket != null && _chatSocket!.isConnected) {
      try {
        _chatSocket!.send({'text': text});
        notifyListeners();
        return null; // своё сообщение придёт через WS-эхо из broadcast группы
      } catch (_) {}
    }

    // Fallback на REST, если сокет недоступен
    try {
      final msg = await _api.sendMessage(chatId, text);
      addMessage(msg);
      return msg;
    } catch (e) {
      // Сюда же прилетает 429 от REST-scope `send` (60/мин)
      sendError = _describe('Сообщение не отправлено', e);
      notifyListeners();
      rethrow;
    }
  }

  /// Обновляет имя чата в локальном списке и деталях.
  ///
  /// Если чат не найден в списке (удалили из другого места), перезагружает весь список.
  void applyRename(String chatId, String name) {
    final idx = chats.indexWhere((c) => c.id == chatId);
    if (idx == -1) {
      loadChats();
      return;
    }
    chats[idx] = chats[idx].copyWith(name: name);
    if (currentChatDetail?.id == chatId) {
      currentChatDetail = ChatDetail(
        id: currentChatDetail!.id,
        type: currentChatDetail!.type,
        name: name,
        members: currentChatDetail!.members,
        myIsAdmin: currentChatDetail!.myIsAdmin,
      );
    }
    notifyListeners();
  }

  /// Удаляет чат из локального списка. Если этот чат был открыт — закрывает его.
  void removeChat(String chatId) {
    chats.removeWhere((c) => c.id == chatId);
    if (selectedChatId == chatId) closeChat();
    notifyListeners();
  }

  /// Переименовывает GROUP-чат (только админ, иначе 403).
  ///
  /// Название применяем сразу по ответу PATCH, не дожидаясь `chat_renamed` из
  /// личного канала. Ошибку не глотаем: текст detail нужен экрану.
  Future<void> renameChat(String chatId, String name) async {
    final detail = await _api.renameChat(chatId, name);
    applyRename(chatId, detail.name ?? name);
  }

  /// Удаляет чат вместе с историей (PRIVATE — любой участник, GROUP — админ).
  ///
  /// Список обновляем сразу, не дожидаясь `chat_deleted`: сервер разнесёт его
  /// остальным участникам секундой позже. closeChat вызывает removeChat.
  Future<void> deleteChat(String chatId) async {
    await _api.deleteChat(chatId);
    removeChat(chatId);
  }

  /// Добавляет новое сообщение в локальный список и обновляет превью в списке чатов.
  ///
  /// Если сообщение из другого чата (selectedChatId != msg.chat) — игнорируется.
  /// Если сообщение с таким id уже есть — дубликат не добавляется.
  void addMessage(Message msg) {
    if (msg.chat != selectedChatId) return;
    if (messages.any((m) => m.id == msg.id)) return;
    messages.add(msg);
    final idx = chats.indexWhere((c) => c.id == msg.chat);
    if (idx != -1) {
      chats[idx] = chats[idx].copyWith(lastMessage: msg);
    }
    notifyListeners();
  }

  /// Закрывает текущий чат: сбрасывает состояние и закрывает WebSocket.
  ///
  /// Вызывается с крестика в шапке, из `PopScope` при системном «назад»
  /// (дефект №13 исправлен) и при удалении чата из списка.
  void closeChat() {
    selectedChatId = null;
    messages = [];
    currentChatDetail = null;
    onlineUsers.clear();
    loadError = null;
    detailsError = null;
    sendError = null;
    wsCloseNotice = null;
    _closeChatSocket();
    notifyListeners();
  }

  // ---------- WebSocket ----------

  /// Открывает WebSocket для конкретного чата.
  ///
  /// Закрывает предыдущий сокет (если был), ставит WsStatus.connecting,
  /// создаёт новый WsClient с обработчиками событий и подключается к серверу.
  /// Статус connected будет установлен в колбэке onOpen, когда handshake пройдёт успешно.
  void _openChatSocket(String chatId) {
    _closeChatSocket();
    _wsStatus = WsStatus.connecting;
    wsCloseNotice = null;
    notifyListeners();
    final socket = WsClient(
      path: 'chat/$chatId/',
      onEvent: _handleChatEvent,
      onClose: _handleChatClose,
      onReconnect: _handleChatReconnect,
      onOpen: setConnected, // <-- дефект №3: теперь статус обновляется при успешном подключении
    );
    _chatSocket = socket;
    socket.connect();
  }

  /// Закрывает текущий WebSocket чата и сбрасывает статус в WsStatus.disconnected.
  ///
  /// Вызывается при смене чата, закрытии чата или уничтожении состояния.
  void _closeChatSocket() {
    _chatSocket?.close();
    _chatSocket = null;
    _wsStatus = WsStatus.disconnected;
  }

  /// Оживляет сокет открытого чата после возврата из фона.
  ///
  /// Мобильная специфика: ОС рвёт соединения спящего приложения, а отказ по
  /// лимиту одновременных подключений (4009 — старые соединения сервер ещё
  /// считает живыми) входит в noReconnectCodes, и сокет остаётся мёртвым, пока
  /// чат не переоткрыть. Переподключение заодно добирает пропущенные сообщения
  /// (onReconnect → reloadMessages).
  void ensureChatSocket() {
    final socket = _chatSocket;
    if (socket == null || socket.isConnected) return;
    _wsStatus = WsStatus.connecting;
    notifyListeners();
    socket.revive();
  }

  /// Обрабатывает кадры WebSocket канала чата.
  ///
  /// Типы кадров от сервера:
  /// - 'user_status' — пользователь онлайн/оффлайн
  /// - 'initial_presence' — снимок онлайн-пользователей при подключении
  /// - 'messages_read' — кто-то прочитал сообщения (фильтруем своё прочтение, дефект №10)
  /// - '{error: ...}' — отказ сервера (пустой текст, >5000 символов, анти-флуд);
  ///   соединение остаётся живым, текст идёт в sendError (дефект №9)
  /// - *(нет type)* — новое сообщение
  void _handleChatEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'user_status':
        // Обновляем набор онлайн-пользователей
        final uid = event['user_id'] as String;
        if (event['status'] == 'online') {
          onlineUsers.add(uid);
        } else {
          onlineUsers.remove(uid);
        }
        notifyListeners();
        break;
      case 'initial_presence':
        // Снимок заменяет набор целиком: addAll накапливал бы статусы
        // участников прошлого подключения после reconnect'а
        final ids = (event['user_ids'] as List).cast<String>();
        onlineUsers
          ..clear()
          ..addAll(ids);
        notifyListeners();
        break;
      case 'messages_read':
        // Бэкенд рассылает событие и самому читателю, поэтому своё прочтение
        // отсекаем: иначе мои сообщения получали ✓✓ от того, что прочитал я сам
        // (дефект №10).
        final readerId = event['reader_id'] as String?;
        if (readerId != null && readerId == myUserId) return;
        markAllRead();
        break;
      case null:
      case '':
        // Кадр без type: либо отказ сервера ({error}), либо новое сообщение
        final error = event['error'];
        if (error != null) {
          sendError = error.toString();
          notifyListeners();
          return;
        }
        if (event['id'] != null) {
          addMessage(Message.fromJson(event));
        }
        break;
    }
  }

  /// Помечает прочитанными только МОИ сообщения: ✓✓ означает «собеседник
  /// прочитал», чужих сообщений этот флаг не касается (дефект №10).
  void markAllRead() {
    final me = myUserId;
    if (me == null) return;
    messages = [
      for (final m in messages)
        m.sender.id == me && !m.isRead ? m.copyWith(isRead: true) : m,
    ];
    notifyListeners();
  }

  /// Обрабатывает закрытие WebSocket чата.
  ///
  /// Ставит человекочитаемую плашку причины (wsCloseNotice). При 4003/4004
  /// удаляет чат из списка и закрывает его, если он был открыт. При 4001 —
  /// сессия невалидна, переподключаться бессмысленно: инициируем возврат к
  /// экрану входа через onSessionExpired. См. раздел 5 AGENTS.md «Коды закрытия».
  void _handleChatClose(int? code) {
    _wsStatus = WsStatus.disconnected;
    wsCloseNotice = _closeNotice(code);
    if (code == 4001) {
      notifyListeners();
      onSessionExpired?.call();
      return;
    }
    if (code == 4003 || code == 4004) {
      if (selectedChatId != null) removeChat(selectedChatId!);
    }
    notifyListeners();
  }

  /// Тексты причин закрытия сокета для шапки чата. null code — обрыв сети или
  /// сервера: это НЕ отказ до accept (те приходят без кода и различаются
  /// пробным запросом в WsClient), поэтому честно говорим «переподключаемся».
  String? _closeNotice(int? code) => switch (code) {
    null => 'Соединение потеряно, переподключаемся...',
    4001 => 'Сессия истекла — войдите заново',
    4003 => 'Вы больше не участник чата',
    4004 => 'Чат удалён',
    4009 => 'Слишком много открытых соединений',
    4029 => 'Слишком частые переподключения',
    // Неизвестный код тоже показываем: пустая плашка = молчаливая потеря
    // информации (дефект №15)
    _ => 'Соединение закрыто (код $code)',
  };

  /// Перечитывание истории после WS-reconnect: добираем сообщения, пришедшие,
  /// пока соединение было разорвано.
  ///
  /// Полная замена ленты (как делал `_loadFirstPage`) теряла уже догруженные
  /// старшие страницы. Поэтому: вернулась полная страница — значит, пропущенных
  /// сообщений может быть больше одной страницы и в истории возможна «дыра»,
  /// перечитываем её с конца; иначе добираем только новые в хвост и обновляем
  /// `is_read` у уже известных.
  Future<void> reloadMessages() async {
    final chatId = selectedChatId;
    if (chatId == null) return;
    try {
      final page = await _api.messages(chatId, page: 1);
      if (selectedChatId != chatId) return;
      final latest = page.items;
      if (latest.length >= messagesPageSize) {
        messages = latest;
        messagesPage = 1;
        hasMoreMessages = page.hasNext;
      } else {
        final known = messages.map((m) => m.id).toSet();
        final fresh = <Message>[];
        final nowRead = <String>{};
        for (final msg in latest) {
          if (!known.contains(msg.id)) {
            fresh.add(msg);
          } else if (msg.isRead) {
            // Статус прочтения мог измениться, пока сокет был закрыт
            nowRead.add(msg.id);
          }
        }
        if (nowRead.isNotEmpty) {
          messages = [
            for (final m in messages)
              nowRead.contains(m.id) ? m.copyWith(isRead: true) : m,
          ];
        }
        if (fresh.isNotEmpty) messages = [...messages, ...fresh];
      }
      loadError = null;
    } catch (e) {
      if (selectedChatId != chatId) return;
      loadError = _describe('Не удалось обновить историю', e);
    }
    notifyListeners();
  }

  /// Вызывается после успешного переподключения сокета (не первого подключения!).
  ///
  /// Статус уже 'connected' — он установлен в onOpen, который срабатывает раньше
  /// onReconnect. Прокрутку к новым сообщениям берёт на себя экран.
  Future<void> _handleChatReconnect() async {
    // Пока сокет был разорван, сообщения приходили мимо нас — добираем их через
    // REST и перечитываем список чатов (бейджи и превью последнего сообщения)
    await reloadMessages();
    await loadChats();
  }

  /// Устанавливает статус WebSocket в WsStatus.connected.
  ///
  /// Вызывается из WsClient.onOpen после успешного handshake. Раньше этот метод не вызывался
  /// ниоткуда (дефект №3), теперь он подключён в _openChatSocket через колбэк onOpen.
  void setConnected() {
    _wsStatus = WsStatus.connected;
    wsCloseNotice = null; // соединение живое — плашка причины больше не нужна
    notifyListeners();
  }

  // ---------- Уведомления (личный канал) ----------

  WsClient? _notificationsSocket;

  void openNotificationsSocket() {
    _notificationsSocket?.close();
    final socket = WsClient(
      path: 'notifications/',
      onEvent: _handleNotification,
      // Мёртвая сессия на личном канале — тот же случай, что и 4001 на канале
      // чата: без этой ветки приложение висело бы на устаревших экранах с
      // вечно переподключающимся сокетом (дефект №16).
      onClose: (code) {
        if (code == 4001) onSessionExpired?.call();
      },
    );
    _notificationsSocket = socket;
    socket.connect();
  }

  void closeNotificationsSocket() {
    _notificationsSocket?.close();
    _notificationsSocket = null;
  }

  /// Поднимает личный канал, если он не жив.
  ///
  /// После отказа по лимиту (4009/4029) или невалидной сессии (4001) WsClient
  /// сам больше не переподключается — эти коды в noReconnectCodes. Эталон
  /// поднимает канал заново на visibilitychange (handleVisibility в
  /// useNotificationsSocket.ts), мобильный аналог — AppLifecycleState.resumed:
  /// без этого приложение, вернувшись из фона, навсегда оставалось без бейджей.
  void ensureNotificationsSocket() {
    if (_notificationsSocket == null) {
      openNotificationsSocket();
    } else {
      _notificationsSocket!.revive();
    }
  }

  void _handleNotification(Map<String, dynamic> event) {
    final type = event['type'];
    switch (type) {
      case 'new_message':
        final chatId = event['chat'] as String?;
        if (chatId == null) return;
        final idx = chats.indexWhere((c) => c.id == chatId);
        if (idx == -1) {
          // Чата нет в списке — например, нас только что добавили в группу:
          // перечитываем список, бейдж и превью придут вместе с ним
          loadChats();
          return;
        }
        final msg = event['message'] != null
            ? Message.fromJson(event['message'] as Map<String, dynamic>)
            : null;
        // Открытый на переднем плане чат считаем прочитанным сразу, иначе
        // наращиваем бейдж (эталон: applyNewMessage в stores/chat.ts). Раньше
        // делались оба действия сразу — unread_count перезаписывался нулём
        // из markRead, а в фоне курсор читался сам собой.
        final opened = chatId == selectedChatId && isForeground;
        if (!opened && msg != null) {
          final chatItem = chats[idx];
          final sender = msg.sender.displayName;
          final title = chatItem.type == ChatType.private
              ? sender
              : '${chatItem.displayName} · $sender';
          final channelId = chatItem.type == ChatType.private
              ? NotificationService.highChannelId
              : NotificationService.lowChannelId;
          final unreadCount = event['unread_count'] as int? ?? 1;
          final body = unreadCount > 1
              ? '${msg.text} · ещё ${unreadCount - 1}'
              : msg.text;
          unawaited(
            NotificationService.showChatMessage(
              chatId: chatId,
              messageId: msg.id,
              title: title,
              body: body,
              channelId: channelId,
            ),
          );
        }
        chats[idx] = chats[idx].copyWith(
          unreadCount: opened ? 0 : (event['unread_count'] as int? ?? 0),
          lastMessage: msg,
        );
        notifyListeners();
        // Курсор сдвигаем на сервере: он разнесёт chat_read остальным устройствам
        if (opened) markRead(chatId);
        break;
      case 'chat_read':
        final chatId = event['chat'];
        final idx = chats.indexWhere((c) => c.id == chatId);
        if (idx != -1) {
          chats[idx] = chats[idx].copyWith(unreadCount: 0);
          notifyListeners();
        }
        break;
      case 'chat_deleted':
        removeChat(event['chat']);
        break;
      case 'chat_renamed':
        applyRename(event['chat'], event['name']);
        break;
      case 'member_removed':
        removeChat(event['chat']);
        break;
    }
  }

  @override
  void dispose() {
    _closeChatSocket();
    closeNotificationsSocket();
    super.dispose();
  }

  /// Полная очистка состояния при logout.
  ///
  /// Закрывает все WebSocket-соединения, очищает списки чатов и сообщений,
  /// сбрасывает выбранный чат. Это предотвращает дальнейшие запросы к бэкенду
  /// с просроченными токенами после выхода из аккаунта.
  void clearAll() {
    // Закрываем сокеты
    _closeChatSocket();
    closeNotificationsSocket();

    // Очищаем всё состояние
    chats = [];
    messages = [];
    currentChatDetail = null;
    selectedChatId = null;
    onlineUsers.clear();
    messagesPage = 1;
    hasMoreMessages = false;
    isLoadingHistory = false;
    loadError = null;
    detailsError = null;
    listError = null;
    sendError = null;
    wsCloseNotice = null;

    notifyListeners();
  }
}
