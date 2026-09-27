import 'package:provider/provider.dart';
import 'package:flutter/material.dart';
import '../state/auth_state.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _passwordConfirm = TextEditingController();
  final _email = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  bool _isRegister = false;

  @override
  void dispose() {
    _phone.dispose(); _password.dispose(); _passwordConfirm.dispose();
    _email.dispose(); _firstName.dispose(); _lastName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final auth = context.read<AuthState>();
    final phone = _phone.text.trim();
    final password = _password.text;
    if (phone.isEmpty || password.isEmpty) return;

    if (_isRegister) {
      if (password != _passwordConfirm.text) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Пароли не совпадают')),
        );
        return;
      }
      await auth.register(
        phone: phone, password: password, passwordConfirm: _passwordConfirm.text,
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        firstName: _firstName.text.trim().isEmpty ? null : _firstName.text.trim(),
        lastName: _lastName.text.trim().isEmpty ? null : _lastName.text.trim(),
      );
    } else {
      await auth.login(phone, password);
    }

    // После успешного входа навигация НЕ нужна: _Boot слушает AuthState через
    // context.watch и сам перестроится на ChatsScreen. Если бы мы толкали маршрут
    // поверх _Boot (как делалось раньше), logout не возвращал бы к форме входа —
    // толкнутый ChatsScreen оставался бы поверх невидимого _Boot в стеке навигатора.
    // При отказе ничего отдельно показывать не нужно: auth.error выводится
    // плашкой под шапкой (см. build) — она же объясняет возврат к экрану входа
    // после 4001 и причину неудачного bootstrap.
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthState>();
    return Scaffold(
      appBar: AppBar(title: Text(_isRegister ? 'Регистрация' : 'Вход')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Причина, почему мы снова на экране входа: неудачный bootstrap,
            // отказ логина/регистрации или сброс сессии по 4001 (дефект №15)
            if (auth.error != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                color: Colors.red.shade100,
                padding: const EdgeInsets.all(8),
                child: Text(
                  auth.error!,
                  style: TextStyle(color: Colors.red.shade900),
                ),
              ),
            TextField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Телефон'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Пароль'),
              obscureText: true,
            ),
            if (_isRegister) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _passwordConfirm,
                decoration: const InputDecoration(labelText: 'Повтор пароля'),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _firstName,
                decoration: const InputDecoration(labelText: 'Имя (необязательно)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lastName,
                decoration: const InputDecoration(labelText: 'Фамилия (необязательно)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email (необязательно)'),
                keyboardType: TextInputType.emailAddress,
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: auth.loading ? null : _submit,
                child: auth.loading
                    ? const CircularProgressIndicator()
                    : Text(_isRegister ? 'Зарегистрироваться' : 'Войти'),
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _isRegister = !_isRegister),
              child: Text(_isRegister ? 'У меня уже есть аккаунт' : 'Создать аккаунт'),
            ),
          ],
        ),
      ),
    );
  }
}
