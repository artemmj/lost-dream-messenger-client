import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/auth_state.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;

  @override
  void initState() {
    super.initState();
    final me = context.read<AuthState>().me;
    _phone = TextEditingController(text: me?.phone ?? '');
    _email = TextEditingController(text: me?.email ?? '');
    _firstName = TextEditingController(text: me?.firstName ?? '');
    _lastName = TextEditingController(text: me?.lastName ?? '');
  }

  @override
  void dispose() {
    _phone.dispose(); _email.dispose();
    _firstName.dispose(); _lastName.dispose();
    super.dispose();
  }

  bool _saving = false;
  String? _localError;

  Future<void> _save() async {
    if (_saving) return;
    final phone = _phone.text.trim();
    // Телефон — логин входа: пустым он быть не может, и бэкенд вернул бы 400.
    // Проверяем локально, чтобы текст появился сразу и поле не уехало в запрос
    // (эталон: save в ProfileModal.vue)
    if (phone.isEmpty) {
      setState(() => _localError = 'Телефон не может быть пустым');
      return;
    }
    setState(() {
      _saving = true;
      _localError = null;
    });
    final auth = context.read<AuthState>();
    final ok = await auth.updateProfile({
      'phone': phone,
      'email': _email.text.trim(),
      'first_name': _firstName.text.trim(),
      'last_name': _lastName.text.trim(),
    });
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Профиль обновлён' : (auth.error ?? 'Ошибка'))),
    );
    if (ok) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: _firstName,
                decoration: const InputDecoration(labelText: 'Имя')),
            const SizedBox(height: 12),
            TextField(controller: _lastName,
                decoration: const InputDecoration(labelText: 'Фамилия')),
            const SizedBox(height: 12),
            TextField(controller: _email,
                decoration: const InputDecoration(labelText: 'Email')),
            const SizedBox(height: 12),
            TextField(controller: _phone,
                decoration: const InputDecoration(
                  labelText: 'Телефон',
                  helperText: 'Телефон — логин, вход будет по новому номеру',
                )),
            if (_localError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_localError!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade900)),
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Сохранение...' : 'Сохранить'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
