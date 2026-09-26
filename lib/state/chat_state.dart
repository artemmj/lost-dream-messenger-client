import 'package:flutter/foundation.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../services/api.dart';
import '../services/ws.dart';

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
  bool hasMoreMessages = true;
  bool isLoadingHistory = false;

  WsClient? _chatSocket;
  WsStatus? _wsStatus; // null — сокет чата ещё не открывался

  WsStatus? get wsStatus => _wsStatus;

  ChatListItem? get selectedChat {
    if (selectedChatId == null) return null;
    try {
      return chats.firstWhere((c) => c.id == selectedChatId);
    } catch (_) {
      return null;
    }
  }

  /// Загружает список чатов с бэкенда и обновляет состояние.
  ///
  /// Сейчас всегда загружает первую страницу (50 чатов) — см. дефект №11 в AGENTS.md.
  /// Ошибки сети и 429 silently игнорируются — дефект №15.
  Future<void> loadChats() async {
    try {
      chats = await _api.listChats();
      notifyListeners();
    } catch (_) {}
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
    hasMoreMessages = true;
    onlineUsers.clear();
    currentChatDetail = null;
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
  ///
  /// hasMoreMessages определяется по количеству сообщений == 50, что неточно:
  /// если сообщений ровно 50, мы не знаем, есть ли ещё страницы. См. дефект №11 в AGENTS.md.
  Future<void> _loadFirstPage(String chatId) async {
    try {
      final page = await _api.messages(chatId, page: 1);
      // Бэкенд уже отдал страницу по возрастанию времени (views.py: MessageSerializer(page[::-1]))
      messages = page;
      hasMoreMessages = page.length == messagesPageSize;
      notifyListeners();
    } catch (_) {}
  }

  /// Загружает детали чата (список участников, моя роль админа).
  ///
  /// Ошибки silently игнорируются — дефект №15.
  Future<void> loadChatDetails(String chatId) async {
    try {
      currentChatDetail = await _api.chatDetail(chatId);
      notifyListeners();
    } catch (_) {}
  }

  /// Подгружает более старые сообщения (пагинация назад во времени).
  ///
  /// Бэкенд отдаёт каждую страницу по возрастанию времени, поэтому при объединении
  /// старая страница вставляется в начало списка: [...older, ...messages].
  /// .reversed не нужен — см. комментарий к _loadFirstPage.
  ///
  /// hasMoreMessages опять определяется по длине == 50, что неточно (дефект №11).
  Future<void> loadOlderMessages() async {
    if (!hasMoreMessages || isLoadingHistory || selectedChatId == null) return;
    isLoadingHistory = true;
    notifyListeners();
    try {
      final next = messagesPage + 1;
      final older = await _api.messages(selectedChatId!, page: next);
      if (older.isEmpty) {
        // Пустая страница — значит, дошли до самого старого сообщения
        hasMoreMessages = false;
      } else {
        // Вставляем старую страницу в начало (сообщения идут от старых к новым)
        messages = [...older, ...messages];
        messagesPage = next;
        hasMoreMessages = older.length == messagesPageSize;
      }
    } catch (_) {}
    isLoadingHistory = false;
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
    } catch (_) {}
  }

  /// Отправляет сообщение в выбранный чат.
  ///
  /// Если WebSocket подключён — отправляет через WS (возвращает null, своё сообщение придёт эхом).
  /// Иначе использует REST-фолбэк POST /chats/{id}/send/ и добавляет сообщение в ленту сразу.
  ///
  /// Экран проверяет возвращаемое значение: если не-null (REST), скроллит к сообщению.
  /// При WS-эхо (null) скролла нет — дефект №12 в AGENTS.md.
  Future<Message?> sendMessage(String text) async {
    if (selectedChatId == null) return null;

    // Пытаемся отправить через WebSocket
    if (_chatSocket != null && _chatSocket!.isConnected) {
      try {
        _chatSocket!.send({'text': text});
        return null; // своё сообщение придёт через WS-эхо из broadcast группы
      } catch (_) {}
    }

    // Fallback на REST, если сокет недоступен
    try {
      final msg = await _api.sendMessage(selectedChatId!, text);
      addMessage(msg);
      return msg;
    } on ApiException {
      rethrow;
    }
  }

  /// Обновляет имя чата в локальном списке и деталях.
  ///
  /// Если чат не найден в списке (удалили из другого места), перезагружает весь список.
  void applyRename(String chatId, String name) {
    final idx = chats.indexWhere((c) => c.id == chatId);
    if (idx == -1) { loadChats(); return; }
    chats[idx] = chats[idx].copyWith(name: name);
    if (currentChatDetail?.id == chatId) {
      currentChatDetail = ChatDetail(
        id: currentChatDetail!.id, type: currentChatDetail!.type,
        name: name, members: currentChatDetail!.members,
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
  /// Вызывается при нажатии на крестик в шапке чата или при удалении чата из списка.
  /// Системная кнопка «назад» этот метод не вызывает — дефект №13 в AGENTS.md.
  void closeChat() {
    selectedChatId = null;
    messages = [];
    currentChatDetail = null;
    onlineUsers.clear();
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

  /// Обрабатывает кадры WebSocket канала чата.
  ///
  /// Типы кадров от сервера:
  /// - null/'' (нет type) — новое сообщение, приходит без поля type
  /// - 'user_status' — пользователь онлайн/оффлайн (onlineUsers не отображается в UI)
  /// - 'initial_presence' — снимок онлайн-пользователей при подключении
  /// - 'messages_read' — кто-то прочитал сообщения (reader_id объявлен, но не используется — дефект №10)
  /// - '{error: ...}' — ошибка от сервера (пустой текст, >5000 символов, анти-флуд) — НЕ обрабатывается, дефект №9
  void _handleChatEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case null:
      case '':
        // Новое сообщение — бэкенд присылает его без поля type
        if (event['id'] != null) {
          final msg = Message.fromJson(event);
          addMessage(msg);
        }
        break;
      case 'user_status':
        // Обновляем набор онлайн-пользователей (пока не отображается в UI)
        final uid = event['user_id'] as String;
        if (event['status'] == 'online') {
          onlineUsers.add(uid);
        } else {
          onlineUsers.remove(uid);
        }
        notifyListeners();
        break;
      case 'initial_presence':
        // При подключении получаем снимок всех онлайн-пользователей чата
        final ids = (event['user_ids'] as List).cast<String>();
        onlineUsers.addAll(ids);
        notifyListeners();
        break;
      case 'messages_read':
        // Кто-то прочитал все сообщения в чате.
        // reader_id есть в кадре, но игнорируется — помечаем ВСЕ сообщения прочитанными (дефект №10).
        // Бэкенд рассылает событие и самому читателю, поэтому галочки обновляются у всех.
        messages = messages.map((m) => m.copyWith(isRead: true)).toList();
        notifyListeners();
        break;
    }
  }

  /// Обрабатывает закрытие WebSocket чата.
  ///
  /// При кодах 4003 (исключён из чата) или 4004 (чат удалён) удаляет чат из списка
  /// и закрывает его, если он был открыт. См. раздел 5 AGENTS.md «Коды закрытия».
  void _handleChatClose(int? code) {
    _wsStatus = WsStatus.disconnected;
    if (code == 4003 || code == 4004) {
      if (selectedChatId != null) removeChat(selectedChatId!);
    }
    notifyListeners();
  }

  /// Вызывается после успешного переподключения сокета (не первого подключения!).
  ///
  /// Перезагружает первую страницу сообщений и список чатов, чтобы синхронизировать
  /// состояние с сервером после разрыва связи. Статус уже 'connected' — он установлен
  /// в onOpen, который срабатывает раньше onReconnect.
  void _handleChatReconnect() async {
    // Перечитываем историю и список чатов, как описано в AGENTS.md
    if (selectedChatId != null) {
      await _loadFirstPage(selectedChatId!);
    }
    await loadChats();
  }

  /// Устанавливает статус WebSocket в WsStatus.connected.
  ///
  /// Вызывается из WsClient.onOpen после успешного handshake. Раньше этот метод не вызывался
  /// ниоткуда (дефект №3), теперь он подключён в _openChatSocket через колбэк onOpen.
  void setConnected() {
    _wsStatus = WsStatus.connected;
    notifyListeners();
  }

  // ---------- Уведомления (личный канал) ----------

  WsClient? _notificationsSocket;

  void openNotificationsSocket() {
    _notificationsSocket?.close();
    final socket = WsClient(
      path: 'notifications/',
      onEvent: _handleNotification,
    );
    _notificationsSocket = socket;
    socket.connect();
  }

  void closeNotificationsSocket() {
    _notificationsSocket?.close();
    _notificationsSocket = null;
  }

  void _handleNotification(Map<String, dynamic> event) {
    final type = event['type'];
    switch (type) {
      case 'new_message':
        final chatId = event['chat'];
        final unread = event['unread_count'] as int? ?? 0;
        final idx = chats.indexWhere((c) => c.id == chatId);
        if (idx == -1) {
          loadChats();
        } else {
          final msg = event['message'] != null
              ? Message.fromJson(event['message']) : null;
          chats[idx] = chats[idx].copyWith(
            unreadCount: unread, lastMessage: msg,
          );
          // если чат открыт и совпадает — сразу подтверждаем прочтение
          if (chatId == selectedChatId && unread > 0) {
            markRead(chatId);
          }
          notifyListeners();
        }
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
    hasMoreMessages = true;
    isLoadingHistory = false;
    
    notifyListeners();
  }
}
