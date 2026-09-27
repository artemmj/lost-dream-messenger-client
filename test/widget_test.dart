import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lost_dream_messenger_client/main.dart';
import 'package:lost_dream_messenger_client/state/auth_state.dart';
import 'package:lost_dream_messenger_client/state/chat_state.dart';

void main() {
  // Смоук-тест сценария из дефекта №4: без сохранённой сессии _Boot показывает
  // форму входа, а не пустой экран или список чатов.
  //
  // Предыдущий тест был шаблонным `flutter create` и ссылался на MyApp, которого
  // в проекте нет (класс называется MessengerApp) — из-за этого падали
  // `flutter analyze` и `flutter test` (дефект №17).
  testWidgets('Без сессии приложение показывает экран входа', (tester) async {
    // Пустое хранилище: TokenStore не находит токены, bootstrap() возвращает false
    // без сетевых запросов.
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AuthState()),
          ChangeNotifierProvider(create: (_) => ChatState()),
        ],
        child: const MessengerApp(),
      ),
    );

    // Дать _Boot завершить bootstrap() и перестроить дерево на LoginScreen
    await tester.pumpAndSettle();

    expect(find.text('Вход'), findsOneWidget);
    expect(find.text('Телефон'), findsOneWidget);
    expect(find.text('Пароль'), findsOneWidget);
  });
}
