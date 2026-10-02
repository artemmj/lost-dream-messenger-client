class AppConfig {
  // Для Android-эмулятора localhost хоста = 10.0.2.2
  // Для iOS-симулятора и macOS = 127.0.0.1
  // Для реального устройства = IP твоего компа в локальной сети
  static const String host = '217.25.228.173:8000';

  static const String apiBase = 'http://$host/api/v1';
  static const String wsBase  = 'ws://$host/ws';
}
