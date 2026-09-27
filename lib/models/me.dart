/// Модель текущего пользователя из `GET /users/me/`.
///
/// `last_seen` бэкенд отдаёт только здесь, в `MeSerializer`: у собеседника и участников
/// этого поля в API нет, поэтому «был в сети …» не показано нигде (разделы 5 и 9 AGENTS.md).
/// Само поле в модели не парсится — как и в эталоне, отображать его негде.
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
