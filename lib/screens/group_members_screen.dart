import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api.dart';
import '../state/chat_state.dart';
import '../state/auth_state.dart';

class GroupMembersScreen extends StatelessWidget {
  final String chatId;
  const GroupMembersScreen({required this.chatId, super.key});

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final auth = context.watch<AuthState>();
    final detail = chat.currentChatDetail;

    return Scaffold(
      appBar: AppBar(title: const Text('Участники')),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                for (final m in detail.members)
                  ListTile(
                    title: Text(m.user.displayName),
                    subtitle: Text(m.user.phone),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.isAdmin)
                          const Chip(label: Text('админ')),
                        // Дефект №6: сравниваем ID пользователя с моим ID из AuthState, а не с ID чата.
                        // Кнопка удаления показывается только для других участников.
                        // Если я админ — могу удалять других.
                        // Если не админ — могу удалить только себя (выйти из чата).
                        if (m.user.id != auth.me?.id && detail.myIsAdmin)
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () => _remove(context, m.user.id),
                          ),
                        // Кнопка «Выйти» для себя
                        if (m.user.id == auth.me?.id)
                          IconButton(
                            icon: const Icon(Icons.exit_to_app),
                            tooltip: 'Выйти из чата',
                            onPressed: () => _leave(context),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  /// Выйти из чата самому (дефект №6).
  ///
  /// Бэкенд позволяет участнику удалить себя из группы. После выхода закрываем чат
  /// и возвращаемся к списку.
  Future<void> _leave(BuildContext context) async {
    final auth = context.read<AuthState>();
    final myId = auth.me?.id;
    if (myId == null) return;

    try {
      await Api().removeMember(chatId, myId); // Удаляем себя по своему ID
      // После выхода закрываем чат и возвращаемся к списку
      if (context.mounted) {
        final chatState = context.read<ChatState>();
        chatState.closeChat();
        Navigator.pop(context);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiException
              ? 'Не удалось выйти из чата: ${e.message}'
              : 'Не удалось выйти из чата: нет связи с сервером')),
        );
      }
    }
  }

  /// Удалить участника из группы (только для админов).
  ///
  /// Бэкенд не позволяет удалить единственного админа — в этом случае вернётся ошибка 400.
  /// См. раздел 5 AGENTS.md «Контракт бэкенда».
  Future<void> _remove(BuildContext context, String userId) async {
    // ChatState читаем до первого await: после async-паузы использование
    // context без mounted-проверки — lint use_build_context_synchronously
    final chatState = context.read<ChatState>();
    try {
      await Api().removeMember(chatId, userId);
      await chatState.loadChatDetails(chatId);
    } catch (e) {
      if (context.mounted) {
        // Показываем сообщение об ошибке от бэкенда (например, «единственного админа удалить нельзя»)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiException
              ? 'Не удалось удалить участника: ${e.message}'
              : 'Не удалось удалить участника: нет связи с сервером')),
        );
      }
    }
  }
}
