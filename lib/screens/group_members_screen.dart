import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user.dart';
import '../services/api.dart';
import '../state/chat_state.dart';
import '../state/auth_state.dart';
import '../widgets/presence_dot.dart';

class GroupMembersScreen extends StatefulWidget {
  final String chatId;
  const GroupMembersScreen({required this.chatId, super.key});

  @override
  State<GroupMembersScreen> createState() => _GroupMembersScreenState();
}

class _GroupMembersScreenState extends State<GroupMembersScreen> {
  // Поиск кандидатов в участники (C11): только для админа чата
  final _search = TextEditingController();
  List<User> _results = [];
  String _query = '';
  bool _searching = false;
  Timer? _searchTimer;

  /// Идёт ли сейчас запись в чат (добавление/удаление/выход). Один флаг на все
  /// три: параллельные запросы к одному составу участников давали бы 400.
  bool _busy = false;

  String? _error;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatState>();
    final auth = context.watch<AuthState>();
    final detail = chat.currentChatDetail;
    final others = chat.otherMembers;
    final onlineCount = chat.onlineMembersCount ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Участники')),
      body: detail == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    children: [
                      // Сводка присутствия: «в сети» считается без меня — тот же
                      // смысл, что у счётчика в шапке чата
                      if (others.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Row(
                            children: [
                              PresenceDot(online: onlineCount > 0),
                              const SizedBox(width: 6),
                              Text(
                                onlineCount > 0
                                    ? '$onlineCount в сети из ${others.length}'
                                    : 'никто из участников не в сети',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      for (final m in detail.members)
                        ListTile(
                          title: Row(
                            children: [
                              PresenceDot(
                                  online: chat.onlineUsers
                                      .contains(m.user.id)),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(m.user.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                              ),
                            ],
                          ),
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
                                  onPressed:
                                      _busy ? null : () => _remove(m.user.id),
                                ),
                              // Кнопка «Выйти» для себя
                              if (m.user.id == auth.me?.id)
                                IconButton(
                                  icon: const Icon(Icons.exit_to_app),
                                  tooltip: 'Выйти из чата',
                                  onPressed: _busy ? null : _leave,
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                // Добавлять участников может только админ (остальным 403)
                if (detail.myIsAdmin) _addMemberSection(),
              ],
            ),
    );
  }

  /// Поиск кандидатов и добавление в GROUP-чат (эталон: нижняя часть
  /// GroupMembersModal.vue, доступная только админу).
  Widget _addMemberSection() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_error!,
                  style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
            ),
          TextField(
            controller: _search,
            onChanged: _onQueryChanged,
            decoration: const InputDecoration(
              hintText: 'Добавить участника: телефон или имя',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: _candidatesList(),
          ),
        ],
      ),
    );
  }

  Widget _candidatesList() {
    if (_searching) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Поиск...'),
      );
    }
    if (_results.isEmpty) {
      // «Не найдено» — только когда искали и выдача пуста; пустой запрос
      // ничего не показывает
      if (_query.trim().isEmpty) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Не найдено'),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: _results.length,
      itemBuilder: (_, i) {
        final u = _results[i];
        return ListTile(
          dense: true,
          title: Text(u.displayName),
          subtitle: Text(u.phone),
          trailing: _busy
              ? null
              : const Icon(Icons.person_add_alt),
          onTap: _busy ? null : () => _addMember(u.id),
        );
      },
    );
  }

  void _onQueryChanged(String q) {
    setState(() => _query = q);
    _searchTimer?.cancel();
    if (q.trim().isEmpty) {
      setState(() {
        _results = [];
        _searching = false;
        _error = null;
      });
      return;
    }
    // Дебаунс 300 мс, как useDebounceFn в эталоне: набор телефона без него
    // выжигал лимит scope `search` (20/мин)
    _searchTimer =
        Timer(const Duration(milliseconds: 300), () => _runSearch(q.trim()));
  }

  Future<void> _runSearch(String q) async {
    if (!mounted) return;
    // Состав участников снимаем до await: после него context недоступен
    final memberIds = (context
            .read<ChatState>()
            .currentChatDetail
            ?.members ??
        [])
        .map((m) => m.user.id)
        .toSet();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await Api().searchUsers(q);
      if (!mounted) return;
      setState(() {
        // Уже состоящих не предлагаем: на них бэкенд отвечает 400
        _results = found.where((u) => !memberIds.contains(u.id)).toList();
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = [];
        _searching = false;
        _error = e is ApiException
            ? 'Поиск не удался: ${e.message}'
            : 'Поиск не удался: нет связи с сервером';
      });
    }
  }

  Future<void> _addMember(String userId) async {
    if (_busy) return;
    final chatState = context.read<ChatState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api().addMember(widget.chatId, userId);
      await chatState.loadChatDetails(widget.chatId);
      if (!mounted) return;
      // Поле и выдача очищаются: добавленный ушёл из результатов в список
      setState(() {
        _busy = false;
        _query = '';
        _results = [];
        _search.clear();
      });
    } catch (e) {
      // 400 — уже участник или чат не GROUP, 403 — не админ, 429 — scope `write`
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException
            ? 'Не удалось добавить участника: ${e.message}'
            : 'Не удалось добавить участника: нет связи с сервером';
      });
    }
  }

  /// Выйти из чата самому (дефект №6).
  ///
  /// Бэкенд позволяет участнику удалить себя из группы. После выхода закрываем чат
  /// и возвращаемся к списку.
  Future<void> _leave() async {
    if (_busy) return;
    final auth = context.read<AuthState>();
    final chatState = context.read<ChatState>();
    final myId = auth.me?.id;
    if (myId == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api().removeMember(widget.chatId, myId); // Удаляем себя по своему ID
      chatState.closeChat();
      if (!mounted) return;
      // Экран участников лежал поверх ChatScreen — одного pop хватило на него,
      // а чат остался открытым пустым окном; снимаем оба маршрута
      Navigator.of(context)
          .popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiException
            ? 'Не удалось выйти из чата: ${e.message}'
            : 'Не удалось выйти из чата: нет связи с сервером')),
      );
    }
  }

  /// Удалить участника из группы (только для админов).
  ///
  /// Бэкенд не позволяет удалить единственного админа — в этом случае вернётся ошибка 400.
  /// См. раздел 5 AGENTS.md «Контракт бэкенда».
  Future<void> _remove(String userId) async {
    if (_busy) return;
    // ChatState читаем до первого await: после async-паузы использование
    // context без mounted-проверки — lint use_build_context_synchronously
    final chatState = context.read<ChatState>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api().removeMember(widget.chatId, userId);
      await chatState.loadChatDetails(widget.chatId);
      if (!mounted) return;
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // Показываем сообщение об ошибке от бэкенда (например, «единственного админа удалить нельзя»)
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiException
            ? 'Не удалось удалить участника: ${e.message}'
            : 'Не удалось удалить участника: нет связи с сервером')),
      );
    }
  }
}
