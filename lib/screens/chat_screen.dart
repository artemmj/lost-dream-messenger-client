import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/chat.dart';
import '../models/message.dart';
import '../state/chat_state.dart';
import '../state/auth_state.dart';
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
  String? _sendError;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels < 100) {
      context.read<ChatState>().loadOlderMessages();
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final chat = context.read<ChatState>();
    setState(() => _sendError = null);
    try {
      final sent = await chat.sendMessage(text);
      _input.clear();
      if (sent != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            _scroll.animateTo(_scroll.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut);
          }
        });
      }
    } catch (e) {
      setState(() => _sendError = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final auth = context.watch<AuthState>();
    final detail = chat.currentChatDetail;
    // Общая плашка ошибок экрана: отправка (осталась локальной) и загрузка
    // истории (раньше проглатывалась молча — дефект №15)
    final errorText = _sendError ?? chat.loadError;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(chat.selectedChat?.displayName ?? ''),
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
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              chat.closeChat();
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (errorText != null)
            Container(
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(8),
              child: Text(errorText, style: TextStyle(color: Colors.red.shade900)),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: chat.messages.length + (chat.isLoadingHistory ? 1 : 0),
              itemBuilder: (_, i) {
                if (chat.isLoadingHistory && i == 0) {
                  return const Center(child: Padding(
                    padding: EdgeInsets.all(8),
                    child: CircularProgressIndicator(),
                  ));
                }
                final idx = i - (chat.isLoadingHistory ? 1 : 0);
                final m = chat.messages[idx];
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
