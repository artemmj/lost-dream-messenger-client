import 'user.dart';

class Message {
  final String id;
  final String chat;
  final User sender;
  final String text;
  final DateTime createdAt;
  final bool isRead;

  Message({
    required this.id, required this.chat, required this.sender,
    required this.text, required this.createdAt, required this.isRead,
  });

  factory Message.fromJson(Map<String, dynamic> j) => Message(
        id: j['id'],
        chat: j['chat'],
        sender: User.fromJson(j['sender']),
        text: j['text'],
        createdAt: DateTime.parse(j['created_at']).toLocal(),
        isRead: j['is_read'] ?? false,
      );

  Message copyWith({bool? isRead}) => Message(
        id: id, chat: chat, sender: sender, text: text,
        createdAt: createdAt, isRead: isRead ?? this.isRead,
      );
}

/// Страница истории: сами сообщения и признак того, что есть более старые.
///
/// `hasNext` берётся из поля `next` пагинатора, а не из количества элементов:
/// раньше «ещё страница есть» угадывалось по `length == 50` и врало, когда
/// сообщений ровно 50 (дефект №11).
class MessagePage {
  final List<Message> items;
  final bool hasNext;

  MessagePage({required this.items, required this.hasNext});

  factory MessagePage.fromJson(Map<String, dynamic> j) => MessagePage(
        items: (j['results'] as List)
            .map((e) => Message.fromJson(e as Map<String, dynamic>))
            .toList(),
        hasNext: j['next'] != null,
      );
}
