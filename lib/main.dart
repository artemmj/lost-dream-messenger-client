import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'state/auth_state.dart';
import 'state/chat_state.dart';
import 'screens/login_screen.dart';
import 'screens/chats_screen.dart';

// Ключ навигатора нужен для сброса сессии по 4001: без него не снять
// толкнутые поверх _Boot маршруты (ChatScreen, участники группы, новый чат),
// и экран остался бы поверх перестроенного _Boot с формой входа (см. дефект №4).
final _navigatorKey = GlobalKey<NavigatorState>();

void main() {
  final auth = AuthState();
  final chat = ChatState();

  // Бэкенд отверг авторизацию (4001 на канале чата или уведомлений):
  // снимаем все маршруты поверх home и разлогиниваем — _Boot через
  // watch<AuthState> сам покажет LoginScreen. ChatState.clearAll закрывает
  // оба сокета, чтобы мёртвая сессия не порождала новые ретраи.
  // reason попадёт в AuthState.error, и экран входа объяснит, почему сброс
  // произошёл сам (дефект №15).
  chat.onSessionExpired = () {
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    chat.clearAll();
    auth.logout(reason: 'Сессия истекла — войдите заново');
  };

  // Однократные ошибки ChatState (markRead и т.п.): показываем SnackBar'ом над
  // текущим экраном — у них нет своей плашки, а молчать они не должны.
  // Контекст из navigatorKey указывает ниже MaterialApp, поэтому ScaffoldMessenger
  // его находит.
  chat.onNotice = (message) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  };

  // ChatState нужен мой id, чтобы отличать своё прочтение от чужого в кадре
  // messages_read (дефект №10) и помечать прочитанными только свои сообщения.
  // Профиль догружается асинхронно (bootstrap/login/register), поэтому следим
  // за AuthState, а не снимаем значение один раз.
  void syncMyId() => chat.myUserId = auth.me?.id;
  auth.addListener(syncMyId);
  syncMyId();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: chat),
      ],
      child: MessengerApp(navigatorKey: _navigatorKey),
    ),
  );
}

class MessengerApp extends StatelessWidget {
  /// Опционален: в тестах навигация при сбросе сессии не проверяется,
  /// MaterialApp работает и с null-ключом.
  final GlobalKey<NavigatorState>? navigatorKey;
  const MessengerApp({this.navigatorKey, super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Мессенджер',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const _Boot(),
    );
  }
}

class _Boot extends StatefulWidget {
  const _Boot();
  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  /// Проверяет сохранённые токены и догружает профиль через bootstrap().
  Future<void> _check() async {
    final auth = context.read<AuthState>();
    await auth.bootstrap();
    if (mounted) setState(() => _checking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Следим за AuthState через watch: login/logout вызывают notifyListeners(),
    // и это дерево перестраивается само — ручная навигация между экранами не нужна.
    // Важно: экраны НЕ должны толкать маршруты поверх _Boot (как делал LoginScreen
    // после входа), иначе logout не возвращал бы к форме входа — толкнутый маршрут
    // ChatsScreen оставался бы в стеке поверх перестроенного _Boot.
    final auth = context.watch<AuthState>();
    return auth.isAuthenticated ? const ChatsScreen() : const LoginScreen();
  }
}
