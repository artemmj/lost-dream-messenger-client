/// Модель текущего пользователя из `GET /users/me/`.
///
/// Поле `last_seen` бэкенд отдаёт, но клиент его не парсил и нигде не показывал
/// (дефект №19) — оно вернётся вместе с реализацией presence (раздел 8 AGENTS.md).
class Me {
  final String id;
  final String phone;
  final String? email;
  final String? firstName;
  final String? lastName;

  Me({required this.id, required this.phone, this.email,
      this.firstName, this.lastName});

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'],
        phone: j['phone'],
        email: j['email'],
        firstName: j['first_name'],
        lastName: j['last_name'],
      );
}
