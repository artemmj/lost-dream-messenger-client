import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/user.dart';
import '../services/api.dart';
import '../state/chat_state.dart';
import 'chat_screen.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});
  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _search = TextEditingController();
  final _groupName = TextEditingController();
  List<User> _results = [];

  // Выбор участников храним по id пользователя (дефект №7): каждый поиск
  // создаёт новые экземпляры User, а равенство у модели не переопределено,
  // поэтому Set<User> не узнавал «того же человека» — чекбоксы сбрасывались,
  // а в member_ids попадали дубли (бэкенд отвечал 400).
  // Map даёт стабильный ключ (id), дедупликацию и нужное для чипов имя.
  final Map<String, User> _selected = {};
  bool _isGroup = false;
  
  // Timer для дебаунса поиска — отменяет предыдущие запросы (дефект №8)
  Timer? _searchTimer;

  // Ошибка последнего запроса поиска: раньше catch (_) {} молчал, и 429 по
  // scope `search` выглядел как «ничего не найдено» (дефект №15)
  String? _searchError;

  @override
  void dispose() {
    // Отменяем все отложенные запросы поиска при закрытии экрана
    _searchTimer?.cancel();
    _search.dispose();
    _groupName.dispose();
    super.dispose();
  }

  /// Выполняет поиск пользователей с дебаунсом 300 мс.
  ///
  /// Предыдущий таймер отменяется, чтобы не делать лишних запросов при быстром наборе текста.
  /// Это решает дефект №8: поиск без отменяемого дебаунса создавал десяток запросов в scope `search` (20/мин).
  void _debouncedSearch(String q) {
    // Отменяем предыдущий таймер
    _searchTimer?.cancel();
    
    if (q.trim().isEmpty) {
      setState(() {
        _results = [];
        _searchError = null;
      });
      return;
    }
    
    // Создаём новый таймер на 300 мс
    _searchTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final r = await Api().searchUsers(q.trim());
        if (mounted) {
          setState(() {
            _results = r;
            _searchError = null;
          });
        }
      } catch (e) {
        // Показываем причину пустой выдачи: текст бэкенда или «нет связи»
        if (mounted) {
          setState(() => _searchError = e is ApiException
              ? 'Поиск не удался: ${e.message}'
              : 'Поиск не удался: нет связи с сервером');
        }
      }
    });
  }

  /// Добавляет или снимает пользователя из выбора (ключ — id, см. дефект №7).
  void _toggleSelected(User u) {
    setState(() {
      if (_selected.containsKey(u.id)) {
        _selected.remove(u.id);
      } else {
        _selected[u.id] = u;
      }
    });
  }

  /// Создаёт личный чат с пользователем и открывает его.
  ///
  /// После создания загружаем список чатов, выбираем новый чат (открывает сокет),
  /// затем заменяем текущий экран на ChatScreen вместо возврата в список (дефект №5).
  Future<void> _createPrivate(User u) async {
    // ChatState читаем до первого await: после async-паузы context использовать
    // нельзя (use_build_context_synchronously)
    final chat = context.read<ChatState>();
    try {
      final detail = await Api().createPrivateChat(u.id);
      await chat.loadChats();
      await chat.selectChat(detail.id);
      
      // Вместо pop() используем pushReplacement, чтобы открыть чат напрямую
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => ChatScreen(chatId: detail.id),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiException
              ? 'Не удалось создать чат: ${e.message}'
              : 'Не удалось создать чат: нет связи с сервером')),
        );
      }
    }
  }

  /// Создаёт групповой чат и открывает его.
  ///
  /// После создания загружаем список чатов, выбираем новый чат (открывает сокет),
  /// затем заменяем текущий экран на ChatScreen вместо возврата в список (дефект №5).
  Future<void> _createGroup() async {
    if (_groupName.text.trim().isEmpty || _selected.isEmpty) return;
    // ChatState читаем до первого await (см. комментарий в _createPrivate)
    final chat = context.read<ChatState>();
    try {
      final detail = await Api().createGroupChat(
        name: _groupName.text.trim(),
        // Ключи Map — id пользователей; дубликаты исключены самой структурой
        memberIds: _selected.keys.toList(),
      );
      await chat.loadChats();
      await chat.selectChat(detail.id);
      
      // Вместо pop() используем pushReplacement, чтобы открыть чат напрямую
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(
          builder: (_) => ChatScreen(chatId: detail.id),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiException
              ? 'Не удалось создать группу: ${e.message}'
              : 'Не удалось создать группу: нет связи с сервером')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isGroup ? 'Новый групповой чат' : 'Новый личный чат'),
        actions: [
          TextButton(
            onPressed: () => setState(() => _isGroup = !_isGroup),
            child: Text(_isGroup ? 'Личный' : 'Групповой'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isGroup)
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _groupName,
                decoration: const InputDecoration(labelText: 'Название группы'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                labelText: 'Поиск по телефону или имени',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _debouncedSearch, // Используем дебаунс вместо Future.delayed
            ),
          ),
          if (_isGroup && _selected.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 6,
                children: _selected.values.map((u) => Chip(
                  label: Text(u.displayName),
                  onDeleted: () => setState(() => _selected.remove(u.id)),
                )).toList(),
              ),
            ),
          // Заметная причина пустой выдачи поиска (дефект №15)
          if (_searchError != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(8),
              child: Text(_searchError!,
                  style: TextStyle(color: Colors.red.shade900)),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (_, i) {
                final u = _results[i];
                return ListTile(
                  title: Text(u.displayName),
                  subtitle: Text(u.phone),
                  trailing: _isGroup
                      ? Checkbox(
                          value: _selected.containsKey(u.id),
                          onChanged: (_) => _toggleSelected(u),
                        )
                      : null,
                  onTap: _isGroup
                      ? () => _toggleSelected(u)
                      : () => _createPrivate(u),
                );
              },
            ),
          ),
          if (_isGroup)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _createGroup,
                  child: const Text('Создать группу'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
