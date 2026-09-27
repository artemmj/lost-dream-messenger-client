import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../services/api.dart';
import '../state/chat_state.dart';
import '../state/auth_state.dart';
import '../widgets/presence_dot.dart';
import 'group_members_screen.dart';

class ChatScreen extends StatefulWidget {
  final String chatId;
  const ChatScreen({required this.chatId, super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Прокрутка привязана к id последнего сообщения, а не к числу отправок:
  /// догрузка старых страниц тоже меняет список, но ленту трогать не должна
  /// (эталон: watch по lastMessageId — дефект №12).
  String? _handledLastId;

  /// Чат только что открыли: первая прокрутка мгновенная, все последующие —
  /// с анимацией (аналог isChatSwitch в эталоне).
  bool _justOpened = true;

  /// _syncScroll асинхронный и сам дозагружает историю — без флага два кадра
  /// запустили бы два цикла дозагрузки параллельно.
  bool _syncing = false;

  // Пиксели последней прокрутки: историю догружаем только при движении вверх
  double _lastPixels = 0;

  // ---------- Переименование и удаление (D8, D9) ----------

  final _nameInput = TextEditingController();
  bool _renaming = false;
  bool _savingName = false;
  String? _renameError;

  /// Первый тап по кнопке удаления только взводит подтверждение: чат вместе с
  /// историей невосстановим, а случайных тапов по иконке в шапке достаточно.
  bool _confirmDelete = false;
  bool _deleting = false;
  String? _deleteError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    _nameInput.dispose();
    super.dispose();
  }

  /// Закрывает чат и снимает маршрут. Единый путь для крестика в шапке и для
  /// системной «назад»: раньше по «назад» маршрут снимался, а чат оставался
  /// выбранным — сокет открытого чата и подтверждение прочтения продолжали
  /// работать для экрана, которого уже нет (дефект №13).
  void _closeChat() {
    context.read<ChatState>().closeChat();
    if (mounted) Navigator.pop(context);
  }

  void _onScroll() {
    final position = _scroll.position;
    final pixels = position.pixels;
    final movedToEnd = pixels > _lastPixels;
    _lastPixels = pixels;
    // Лента перевёрнутая (reverse: true), поэтому «верх экрана» — это конец
    // прокрутки. Движение вверх обязательно: программная прокрутка к новым
    // сообщениям не должна вызывать запрос лишней страницы.
    if (!movedToEnd || pixels < position.maxScrollExtent - 100) return;
    context.read<ChatState>().loadOlderMessages();
  }

  /// Завершается после следующего кадра: до раскладки неизвестно, заполняет ли
  /// контент экран (аналог nextTick в эталоне).
  Future<void> _pumpFrame() {
    final completer = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  /// Прокрутка после кадра: при открытии чата — мгновенно вниз (предварительно
  /// дополнив экран историей, если первой страницы не хватило), при новом
  /// сообщении — плавно вниз.
  Future<void> _syncScroll() async {
    if (_syncing || !_scroll.hasClients) return;
    _syncing = true;
    try {
      final chat = context.read<ChatState>();
      if (_justOpened) {
        // Первой страницы может не хватить на экран: тогда жеста прокрутки нет
        // и догружать историю нечем, поэтому добираем страницы, пока появится
        // скролл (тот же цикл в watcher'е lastMessageId у эталона).
        while (chat.hasMoreMessages &&
            !chat.isLoadingHistory &&
            _scroll.position.maxScrollExtent <= 0) {
          final before = chat.messages.length;
          await chat.loadOlderMessages();
          if (!mounted || !_scroll.hasClients) return;
          // Страница не пришла (конец истории или сбой сети) — без проверки
          // цикл крутился бы до упора в лимит scope `read` (у эталона её нет)
          if (chat.messages.length == before) break;
          await _pumpFrame();
          if (!mounted || !_scroll.hasClients) return;
        }
        _justOpened = false;
        _scroll.jumpTo(0); // reverse-лента: offset 0 — самое свежее сообщение
        _lastPixels = 0;
        return;
      }
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
      _lastPixels = 0;
    } finally {
      _syncing = false;
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final chat = context.read<ChatState>();
    try {
      await chat.sendMessage(text);
      _input.clear();
      // Прокрутку выполняет реакция на последнее сообщение — и для WS-эха, и для
      // REST-ответа (дефект №12: раньше скролл был только после REST).
    } catch (_) {
      // Текст отказа уже записан в ChatState.sendError — туда же попадает и
      // кадр {error: ...} от сервера (пустое сообщение, анти-флуд), который
      // раньше проглатывался (дефект №9). Поле ввода не очищаем: несообщённый
      // текст остаётся у пользователя.
    }
  }

  /// Строка присутствия под названием чата — тот же маркер, что в эталонной
  /// шапке: для личного чата «в сети / не в сети» по собеседнику, для группы
  /// «N в сети». Оба источника — initial_presence и user_status канала чата.
  Widget? _presenceLine(ChatState chat) {
    final one = chat.interlocutorOnline;
    final bool online;
    final String text;
    if (one != null) {
      online = one;
      text = one ? 'в сети' : 'не в сети';
    } else {
      final many = chat.onlineMembersCount;
      // Деталей группы ещё нет — строку не показываем вместо «все не в сети»,
      // который оказался бы неправдой
      if (many == null) return null;
      online = many > 0;
      text = online ? '$many в сети' : 'все не в сети';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PresenceDot(online: online),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  void _startRename() {
    // Название берём из элемента списка: детали группы приходят тем же
    // запросом, но могут ещё не загрузиться
    _nameInput.text = context.read<ChatState>().selectedChat?.name ?? '';
    setState(() {
      _renaming = true;
      _renameError = null;
    });
  }

  void _cancelRename() => setState(() {
        _renaming = false;
        _renameError = null;
      });

  Future<void> _saveRename() async {
    final chat = context.read<ChatState>();
    final chatId = chat.selectedChatId;
    if (chatId == null || _savingName) return;
    final name = _nameInput.text.trim();
    if (name.isEmpty) {
      setState(() => _renameError = 'Название не может быть пустым');
      return;
    }
    if (name == chat.selectedChat?.name) {
      _cancelRename();
      return;
    }
    setState(() => _savingName = true);
    try {
      await chat.renameChat(chatId, name);
      if (!mounted) return;
      setState(() {
        _savingName = false;
        _renaming = false;
        _renameError = null;
      });
    } catch (e) {
      // 400 — не GROUP или пустое название, 403 — не админ, 429 — scope `write`
      if (!mounted) return;
      setState(() {
        _savingName = false;
        _renameError = e is ApiException
            ? 'Не удалось переименовать чат: ${e.message}'
            : 'Не удалось переименовать чат: нет связи с сервером';
      });
    }
  }

  /// Удаление чата: первый тап взводит подтверждение, второй удаляет.
  Future<void> _deleteChat() async {
    final chat = context.read<ChatState>();
    final chatId = chat.selectedChatId;
    if (chatId == null || _deleting) return;
    if (!_confirmDelete) {
      setState(() {
        _confirmDelete = true;
        _deleteError = null;
      });
      return;
    }
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    try {
      // deleteChat уже закрыл чат в ChatState (removeChat → closeChat)
      await chat.deleteChat(chatId);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      // Сюда же прилетают 403 (не админ) и 429 от scope `write`
      if (!mounted) return;
      setState(() {
        _deleting = false;
        _confirmDelete = false;
        _deleteError = e is ApiException
            ? 'Не удалось удалить чат: ${e.message}'
            : 'Не удалось удалить чат: нет связи с сервером';
      });
    }
  }

  /// Название чата. Для GROUP с моими админ-правами оно ещё и кнопка: клик
  /// открывает инлайн-редактор под шапкой (эталон: chat-title-btn).
  Widget _title(ChatState chat) {
    final name = Text(chat.selectedChat?.displayName ?? '');
    if (!chat.canRenameChat) return name;
    return InkWell(
      onTap: _renaming ? null : _startRename,
      child: Tooltip(
        message: 'Переименовать чат',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: name,
        ),
      ),
    );
  }

  /// Инлайн-редактор названия группы под шапкой (эталон: chat-rename-input).
  /// Enter в поле — сохранить; отмена вынесена в видимую кнопку, потому что на
  /// мобильном у поля ввода нет клавиши Esc.
  Widget _renameRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _nameInput,
                  autofocus: true,
                  enabled: !_savingName,
                  maxLength: 255,
                  decoration: const InputDecoration(
                    hintText: 'Название чата',
                    isDense: true,
                    counterText: '',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _saveRename(),
                ),
              ),
              IconButton(
                icon: _savingName
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                tooltip: 'Сохранить',
                onPressed: _savingName ? null : _saveRename,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Отмена',
                onPressed: _cancelRename,
              ),
            ],
          ),
          if (_renameError != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(_renameError!,
                  style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final auth = context.watch<AuthState>();
    final detail = chat.currentChatDetail;
    final presence = _presenceLine(chat);
    // Общая плашка ошибок экрана: отказ отправки (включая кадр {error: ...} от
    // сервера — дефект №9), загрузка истории и деталей чата. Показываем первую
    // актуальную: при севшей сети они все появляются одновременно.
    final errorText = chat.sendError ?? chat.loadError ?? chat.detailsError;
    // Одна строка под шапкой: ошибка удаления либо текст подтверждения
    // (эталонный headerNotice). Ошибку переименования показываем в строке
    // редактора — рядом с полем, которое её вызвало.
    final deleteNotice = _deleteError ??
        (_confirmDelete
            ? 'Чат будет удалён вместе с историей, восстановить нельзя. '
                'Нажмите ещё раз для подтверждения.'
            : null);

    // Сообщения приходят асинхронно после открытия экрана, поэтому изменение
    // последнего из них ловим в build, а не в initState.
    final lastId = chat.messages.isEmpty ? null : chat.messages.last.id;
    if (lastId != null && lastId != _handledLastId) {
      _handledLastId = lastId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncScroll();
      });
    }

    return PopScope(
      // canPop: false — иначе системная «назад» снимает маршрут мимо closeChat
      // (дефект №13). Ценой предпросмотра анимации жеста.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeChat();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(chat),
              ?presence,
              // Плашка причины закрытия информативнее статуса (см. wsCloseNotice
              // в ChatState); статус — enum WsStatus (дефект №20), сравнение
              // строк больше не нужно
              if (chat.wsCloseNotice != null)
                Text(
                  chat.wsCloseNotice!,
                  style: TextStyle(fontSize: 11, color: Colors.red.shade700),
                )
              else if (chat.wsStatus != null)
                Text(
                  switch (chat.wsStatus!) {
                    WsStatus.connected => 'на связи',
                    WsStatus.connecting => 'подключение...',
                    WsStatus.disconnected => 'нет соединения',
                  },
                  style: const TextStyle(fontSize: 11),
                ),
            ],
          ),
          actions: [
            // Тип чата сравниваем с enum ChatType, а не со строкой name (дефект №20)
            if (detail?.type == ChatType.group)
              IconButton(
                icon: const Icon(Icons.people),
                onPressed: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => GroupMembersScreen(chatId: widget.chatId),
                )),
              ),
            // GROUP удаляет админ, PRIVATE — любой участник (canDeleteChat)
            if (chat.canDeleteChat)
              IconButton(
                icon: Icon(_confirmDelete
                    ? Icons.delete_forever
                    : Icons.delete_outline),
                tooltip: 'Удалить чат вместе с историей',
                onPressed: _deleting ? null : _deleteChat,
              ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _closeChat,
            ),
          ],
        ),
        body: Column(
          children: [
            if (errorText != null)
              Container(
                width: double.infinity,
                color: Colors.red.shade100,
                padding: const EdgeInsets.all(8),
                child: Text(errorText,
                    style: TextStyle(color: Colors.red.shade900)),
              ),
            if (_renaming) _renameRow(),
            if (deleteNotice != null)
              Container(
                width: double.infinity,
                color: _deleteError != null
                    ? Colors.red.shade100
                    : Colors.amber.shade100,
                padding: const EdgeInsets.all(8),
                child: Text(
                  deleteNotice,
                  style: _deleteError != null
                      ? TextStyle(color: Colors.red.shade900)
                      : null,
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                // Лента перевёрнута: индекс 0 прижат к нижней кромке. Поэтому
                // новые сообщения и догрузка старых страниц не сдвигают видимый
                // контент — в веб-версии позицию приходится якорить вручную по
                // изменению scrollHeight.
                reverse: true,
                itemCount:
                    chat.messages.length + (chat.isLoadingHistory ? 1 : 0),
                itemBuilder: (_, i) {
                  // Индикатор догрузки — над самыми старыми сообщениями, то есть
                  // в конце reverse-ленты
                  if (chat.isLoadingHistory && i == chat.messages.length) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  final m = chat.messages[chat.messages.length - 1 - i];
                  final isMine = m.sender.id == auth.me?.id;
                  return _MessageBubble(message: m, isMine: isMine);
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        decoration: const InputDecoration(
                          hintText: 'Сообщение...',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _send,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  const _MessageBubble({required this.message, required this.isMine});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMine
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
              isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isMine)
              Text(message.sender.displayName,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            Text(message.text),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${message.createdAt.hour.toString().padLeft(2, '0')}:'
                  '${message.createdAt.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(fontSize: 10),
                ),
                if (isMine) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.isRead ? Icons.done_all : Icons.done,
                    size: 14,
                    color: message.isRead ? Colors.blue : Colors.grey,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
