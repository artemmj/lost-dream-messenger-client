/// Бэкенд отдаёт незаполненные поля пустыми строками, а модель хранит их как
/// null — иначе `displayName` склеивал бы пустые сегменты. Запись через тернарный
/// оператор с `?.isEmpty ?? true` читалась как ошибка приоритетов (дефект №27).
String? _nullIfEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;

class User {
  final String id;
  final String phone;
  final String? email;
  final String? firstName;
  final String? lastName;

  User({
    required this.id,
    required this.phone,
    this.email,
    this.firstName,
    this.lastName,
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: j['id'] as String,
        phone: j['phone'] as String? ?? '',
        email: _nullIfEmpty(j['email'] as String?),
        firstName: _nullIfEmpty(j['first_name'] as String?),
        lastName: _nullIfEmpty(j['last_name'] as String?),
      );

  String get displayName {
    final name = [firstName, lastName].where((s) => s != null && s.isNotEmpty).join(' ');
    return name.isNotEmpty ? name : phone;
  }
}
