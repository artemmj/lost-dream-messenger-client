import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../models/chat.dart';
import '../services/notification_service.dart';
import '../state/auth_state.dart';
import '../state/chat_state.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'profile_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});
  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final chat = context.read<ChatState>();
    chat.loadChats();
    chat.openNotificationsSocket();
    NotificationService.pendingChatId.addListener(_openPendingNotificationChat);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openPendingNotificationChat();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotificationService.pendingChatId.removeListener(
      _openPendingNotificationChat,
    );
    super.dispose();
  }

  void _openPendingNotificationChat() {
    final chatId = NotificationService.takePendingChatId();
    if (chatId == null || !mounted) return;

    final chat = context.read<ChatState>();
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    chat.selectChat(chatId);
    navigator.push(
      MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)),
    );
  }

  /// Мобильный аналог `visibilitychange` из эталона (ChatView.vue и
  /// useNotificationsSocket.ts): возвращение в приложение — повод перечитать
  /// открытый чат и оживить личный канал уведомлений.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (kDebugMode) debugPrint('[push] app lifecycle: $state');
    final chat = context.read<ChatState>();
    // `inactive` не считаем фоном: это, например, открытая шторка или системный
    // диалог — приложение по-прежнему видно пользователю.
    final foreground = state == AppLifecycleState.resumed;
    chat.isForeground = foreground;
    if (!foreground) {
      if (state == AppLifecycleState.paused) {
        chat.closeNotificationsSocket();
        if (kDebugMode) debugPrint('[push] notification websocket closed');
      }
      return;
    }
    chat.ensureNotificationsSocket();
    final chatId = chat.selectedChatId;
    if (chatId != null) {
      chat.ensureChatSocket();
      // Всё, что пришло в отсутствие пользователя, считаем прочитанным
      chat.markRead(chatId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final auth = context.watch<AuthState>();
    return Scaffold(
      appBar: AppBar(
        title: Text(auth.me?.firstName ?? auth.me?.phone ?? 'Чаты'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              // clearAll закрывает оба сокета и обнуляет состояние, поэтому
              // отдельные closeNotificationsSocket/closeChat здесь не нужны:
              // без очистки после выхода продолжали идти запросы с протухшим
              // токеном (дефект №4).
              // _Boot сам покажет LoginScreen через watch<AuthState>.
              chat.clearAll();
              await auth.logout();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Ошибка загрузки списка: без неё 429 и офлайн выглядели как
          // «Чатов пока нет» (дефект №15)
          if (chat.listError != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(8),
              child: Text(
                chat.listError!,
                style: TextStyle(color: Colors.red.shade900),
              ),
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: chat.loadChats,
              child: chat.chats.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 200),
                        Center(child: Text('Чатов пока нет')),
                      ],
                    )
                  : ListView.builder(
                      itemCount: chat.chats.length,
                      itemBuilder: (_, i) {
                        final c = chat.chats[i];
                        return _ChatTile(chat: c);
                      },
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const NewChatScreen()),
        ),
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  final ChatListItem chat;
  const _ChatTile({required this.chat});

  @override
  Widget build(BuildContext context) {
    final preview = chat.lastMessage?.text ?? 'Нет сообщений';
    return ListTile(
      title: Text(
        chat.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: chat.unreadCount > 0
          ? CircleAvatar(
              radius: 12,
              child: Text(
                chat.unreadCount > 99 ? '99+' : '${chat.unreadCount}',
                style: const TextStyle(fontSize: 10),
              ),
            )
          : null,
      onTap: () {
        context.read<ChatState>().selectChat(chat.id);
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => ChatScreen(chatId: chat.id)),
        );
      },
    );
  }
}
