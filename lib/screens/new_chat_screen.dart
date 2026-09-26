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
      setState(() => _results = []);
      return;
    }
    
    // Создаём новый таймер на 300 мс
    _searchTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final r = await Api().searchUsers(q.trim());
        if (mounted) {
          setState(() => _results = r);
        }
      } catch (_) {
        // Ошибки поиска silently игнорируются
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
    try {
      final detail = await Api().createPrivateChat(u.id);
      final chat = context.read<ChatState>();
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
          SnackBar(content: Text(e.toString())),
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
    try {
      final detail = await Api().createGroupChat(
        name: _groupName.text.trim(),
        // Ключи Map — id пользователей; дубликаты исключены самой структурой
        memberIds: _selected.keys.toList(),
      );
      final chat = context.read<ChatState>();
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
          SnackBar(content: Text(e.toString())),
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
