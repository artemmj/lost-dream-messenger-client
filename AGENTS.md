# AGENTS.md — контекст для AI-ассистентов и инженеров

> Файл описывает текущее состояние Flutter-клиента: архитектуру, контракт бэкенда, соглашения
> и известные дефекты. Обновлять при значимых изменениях. Краткая версия для человека — [README.md](README.md).

## 1. Что это за проект

Клиент к Django-бэкенду [`lost-dream-messenger-server`](../lost-dream-messenger-server)
(монорепозиторий: Django в корне, Vue-фронтенд в `frontend/`). Бэкенд — **единственный источник правды о контракте**.
Любые сомнения о формате ответа, статус-коде, имени поля или кадре WebSocket решаются чтением
исходников бэкенда (`messenger/views.py`, `messenger/serializers.py`, `messenger/consumers.py`,
`messenger/routing.py`, `messenger/ratelimit.py`, `config/asgi.py`, `config/settings.py`), а не
комментариев в этом клиенте.

История: до Flutter здесь было нативное Android-приложение на Kotlin/Compose (Jetpack Compose,
Hilt, Retrofit + kotlinx.serialization, OkHttp WebSocket, DataStore). Оно удалено из рабочего
дерева, но сохранено в git: `git show 433543b --stat`, каталог `app/`. Kotlin-версия была
корректнее Dart-переписывания в трёх местах (порядок сообщений внутри страницы, заголовок `Origin`
для WS-handshake, поведение личного канала уведомлений). Первые два устранены (дефекты №2 и №1);
по личному каналу при спорных случаях всё равно быстрее свериться с Kotlin-кодом, чем с бэкендом.

Текущее состояние: **прототип**. Компилируется, основной сценарий «войти → список чатов → открыть
чат → отправить / получить» работает, в том числе real-time. Критичные дефекты №1–№7 и дебаунс
поиска (№8) исправлены, блок «Гигиена» (№17–№20) закрыт, а также №25 (отображаемые имена),
№28–№29 (стабильность WS: самоблокировка переподключений, теряющиеся отправки, незакрытый
хвост №3) и №16 (оживление сессии: refresh токена перед WS-handshake, пробный REST-запрос после
серии невидимых отказов, возврат к экрану входа по 4001); в №15 закрыта самая заметная часть
(ошибка загрузки истории показывается в чате). Остаются открытые дефекты №9–№15, №21–№24
и №26–№27 (см. раздел 7).

## 2. Окружение и команды

| | |
|---|---|
| Flutter | 3.47.5 stable, Dart 3.13.4 |
| pubspec `environment.sdk` | `^3.13.4` |
| Зависимости (разрешённые версии) | `http` 1.6.0, `web_socket_channel` 3.0.3, `provider` 6.1.5+1, `shared_preferences` 2.5.5, `flutter_lints` 6.0.0 (`intl` удалён из `pubspec.yaml` как неиспользуемый — дефект №19) |

```bash
flutter pub get
flutter analyze          # после починки widget_test.dart падать больше не должен
flutter test             # смоук-тест: без сессии приложение показывает экран входа
flutter run -d <device>  # хост бэкенда правится в lib/config.dart
```

Бэкенд поднимается отдельно: `cd ../lost-dream-messenger && docker compose up`
(Postgres 18, Redis 7, Daphne на `:8000`, Vite-фронтенд на `:5173`).

`lib/config.dart:5` — `AppConfig.host` как compile-time константа: эмулятор Android `10.0.2.2:8000`,
симулятор iOS/macOS `127.0.0.1:8000`, реальное устройство — IP машины в LAN. `--dart-define` не
поддерживается (см. TODO).

## 3. Карта файлов

```
lib/
├── config.dart                  # AppConfig: host, apiBase (http://host/api/v1), wsBase (ws://host/ws)
├── main.dart                    # AuthState+ChatState создаются в main(), там же wiring
│                                # chat.onSessionExpired (4001 → popUntil + logout через navigatorKey)
│                                # → MultiProvider(.value) → MaterialApp → _Boot
│                                # _Boot: bootstrap(), далее выбор экрана через watch<AuthState>
│                                # (isAuthenticated ? ChatsScreen : LoginScreen) — без ручной навигации
├── models/                      # Плоские DTO с фабриками fromJson, без codegen
│   ├── user.dart                # User(id, phone, email?, firstName?, lastName?) + displayName
│   ├── me.dart                  # Me(id, phone, email?, firstName?, lastName?) — last_seen не парсится
│   ├── message.dart             # Message(id, chat, sender, text, createdAt, isRead) + copyWith(isRead)
│   └── chat.dart                # ChatType{private,group}, ChatListItem(+copyWith, displayName),
│                                # ChatMember(user, isAdmin), ChatDetail(members, myIsAdmin)
├── services/
│   ├── api.dart                 # Api — синглтон. _request(method, path): 401 → refresh → один повтор.
│   │                            # ApiException(statusCode, message), _extractError — DRF detail / {field:[...]};
│   │                            # ensureFreshAccess() — refresh по JWT exp перед WS-handshake (дефект №16)
│   ├── token_store.dart         # TokenStore: статические access/refresh/save/clear поверх SharedPreferences
│   └── ws.dart                  # WsClient(path, onEvent, onClose, onReconnect, onOpen):
│                                # IOWebSocketChannel + заголовок Origin, connect/ready/listen,
│                                # токен берётся через Api.ensureFreshAccess, isConnected = «handshake
│                                # завершён» (_isOpen), реконнект — экспоненциальный backoff 1→60 с
│                                # с джиттером, после 3 сорванных handshake без кода — пробный Api.me()
│                                # (_probeAuth → 4001 при мёртвой сессии),
│                                # noReconnectCodes = {4001,4003,4004,4009,4029}
├── state/
│   ├── auth_state.dart          # me, loading, error; bootstrap/login/register/updateProfile/logout
│   └── chat_state.dart          # chats, currentChatDetail, messages, selectedChatId, onlineUsers,
│                                # wsStatus (enum WsStatus), loadError, wsCloseNotice, onSessionExpired,
│                                # пагинация истории; сокет чата + сокет уведомлений;
│                                # clearAll() — полная очистка при logout
└── screens/
    ├── login_screen.dart        # Вход/регистрация в одном экране, переключение _isRegister;
    │                            # после входа НИКАКОЙ ручной навигации — экран решает _Boot
    ├── chats_screen.dart        # Список чатов, FAB «новый чат», иконки профиля и выхода
    ├── chat_screen.dart         # Лента, поле ввода, шапка со статусом WS / причиной закрытия сокета
    │                            # (wsCloseNotice), плашка ошибок отправки и загрузки истории
    ├── new_chat_screen.dart     # Поиск с дебаунсом на Timer, режим «личный / групповой», чипы;
    │                            # после создания — pushReplacement на ChatScreen
    ├── group_members_screen.dart# Участники: чип «админ», удаление других (админу), выход из чата (себе)
    └── profile_screen.dart      # PATCH своих полей (имя, фамилия, email, телефон)
test/widget_test.dart            # Смоук-тест: без сохранённой сессии _Boot показывает LoginScreen
android/ ios/ macos/ windows/ linux/ web/   # Сгенерированные `flutter create` цели
```

Навигация — только `Navigator.push(MaterialPageRoute(...))` из `chats_screen.dart` и
`chat_screen.dart`, плюс `pushReplacement` в `new_chat_screen.dart` (открытие созданного чата).
Именованных маршрутов, `go_router`, deep links и state restoration нет. Переходы Login↔Chats —
исключительная прерогатива `_Boot`: маршруты поверх него толкать нельзя (иначе logout не
возвращает к форме входа). `ChatScreen` получает `chatId` конструктором, но данные берёт из
глобального `ChatState` (`selectedChatId`), то есть состояние чата живёт вне маршрута.

## 4. Архитектура

**Состояние.** Два `ChangeNotifier` в `MultiProvider` (`lib/main.dart`), оба создаются
в `main()` до авторизации и передаются через `ChangeNotifierProvider.value`; там же навешен
`chat.onSessionExpired` (4001 от бэкенда → `popUntil(isFirst)` по `navigatorKey`, `clearAll()`,
`logout()`) — иначе толкнутый ChatScreen оставался бы поверх формы входа (см. дефект №4).
Экраны читают через `context.watch<T>()` (пересборка) и
`context.read<T>()` (вызов методов). Отдельных ViewModel на экран нет, DI нет: `Api` — синглтон
(`lib/services/api.dart:19-21`), `TokenStore` — статические методы.

**Загрузка сессии.** `_Boot` (`lib/main.dart`) сначала показывает спиннер, пока `auth.bootstrap()`
проверяет сохранённые токены; дальше выбор экрана полностью реактивный: `context.watch<AuthState>()`
в `build()` и `isAuthenticated ? ChatsScreen() : LoginScreen()`. Любая смена состояния авторизации
(login, logout, `bootstrap`) перестраивает `_Boot` сам — ручная навигация между этими экранами
запрещена (см. дефект №4 в истории и раздел 3).

**REST.** `Api._request` собирает заголовки (`Content-Type`, `Authorization: Bearer` из
`TokenStore`), при 401 делает `POST /auth/refresh/` и повторяет исходный запрос ровно один раз
(`retryOn401: false`); если refresh не принят — токены стираются. Методы проверяют конкретный
ожидаемый статус-код и иначе бросают `ApiException` с текстом из `_extractError` (DRF `detail`
или первое сообщение валидации поля).

**WebSocket.** Один класс `WsClient` на оба канала, различаются только `path`:
`chat/<uuid>/` и `notifications/`. Токен передаётся query-параметром `?token=<jwt>` (Authorization в
WS-handshake бэкенд не читает), но заголовок `Origin` обязателен — его шлёт клиент через
`IOWebSocketChannel.connect` (см. дефект №1). Жизненный цикл:

- сокет чата открывается в `ChatState.selectChat()` после загрузки первой страницы, деталей и
  `markRead`; статус `connecting` сменяется на `connected` через колбэк `onOpen` (`setConnected()`);
  закрывается в `closeChat()`, `clearAll()` и `dispose()`;
- сокет уведомлений открывается в `ChatsScreen.initState()` (`lib/screens/chats_screen.dart:18-23`)
  и закрывается при выходе из аккаунта (`clearAll()`);
- переподключение — экспоненциальный backoff 1, 2, 4, 8, 16, 32, 60 с (потолок) плюс
  джиттер ±30% (`lib/services/ws.dart`, `_scheduleReconnect`), кроме кодов `noReconnectCodes`
  (`lib/services/ws.dart:16`). Фиксированные 2 с, как было раньше, давали до 30 попыток/мин —
  больше лимита бэкенда 20/мин, и при обрыве клиент сам запирал себя от подключений (дефект №29);
- отказ consumer'а до `accept` (`close(code=...)` до handshake) клиент видит не как код
  закрытия, а как сорванный upgrade без кода → `catch` в `connect()` → backoff-ретрай;
  `noReconnectCodes` реально срабатывает только для закрытий **после** accept
  (например `member_removed`/`chat_deleted` в `receive`-пути consumers);
- так как самый частый невидимый отказ — просроченный JWT (4001; access живёт 60 мин,
  `settings.py:158`), токен перед handshake берётся через `Api.ensureFreshAccess()`
  (парсит `exp` из payload, при истечении делает refresh), а после 3 подряд сорванных
  handshake `_probeAuth()` выполняет пробный `GET /users/me/`: 401 → `onClose(4001)`
  → сброс сессии и возврат к экрану входа вместо вечного «подключение...» (дефект №16).
  Дисклеймер: симметричную блокировку «один клиент держит чат — второй не грузит» мог
  вызывать и мусор в Redis-хеше `messenger:presence` (кап 5 соединений, переживает
  рестарты Daphne и kill эмулятора) — это правка данных, не кода:
  `redis-cli hgetall messenger:presence`, `hdel messenger:presence <user_id>`;
- `isConnected` означает «handshake завершён» (флаг `_isOpen`), а не «объект канала создан»:
  `ChatState.sendMessage` при незакрытом сокете корректно уходит в REST-фолбэк (дефект №28).

**Поток события.** Кадр WS → `WsClient.onEvent` → `ChatState._handleChatEvent` (события открытого
чата: сообщение без `type`, `user_status`, `initial_presence`, `messages_read`) или
`_handleNotification` (личный канал: `new_message`, `chat_read`, `chat_deleted`, `chat_renamed`,
`member_removed`) → мутация списков → `notifyListeners()` → пересборка экранов.

**Отправка.** `ChatState.sendMessage`: если сокет жив — «жив» означает `WsClient.isConnected`
(handshake завершён, флаг `_isOpen`) — это `{'text': ...}` в WS и возврат `null`
(своё сообщение придёт эхом из broadcast группы), иначе `POST /chats/{id}/send/` и добавление
в ленту. Экран по возврату `null`/не-`null` решает, скроллить ли ленту — отсюда дефект №12.

## 5. Контракт бэкенда

Префикс REST — `/api/v1`. Аутентификация — `Authorization: Bearer <access>`, JWT SimpleJWT
(в payload только `user_id`, поэтому профиль всегда догружается `GET /users/me/`).
Пагинация `PageNumberPagination`, страница 50, ответ `{count, next, previous, results}`.

### REST

| Метод | Путь | Статус | Клиент |
|-------|------|--------|--------|
| POST | `/auth/register/` | 201, `{user, access, refresh}` | `Api.register` |
| POST | `/auth/login/` | 200, `{access, refresh}`, поле `phone` | `Api.login` |
| POST | `/auth/refresh/` | 200, `{access}` | `Api._refreshToken` |
| GET | `/users/me/` | 200, `Me` | `Api.me` |
| PATCH | `/users/me/` | 200, `Me`; поля опциональны, `email` допускает пустую строку, телефон нормализуется | `Api.updateMe` |
| GET | `/users/search/?q=` | 200, страница `User`, исключает себя, лимит 20 | `Api.searchUsers` |
| GET | `/chats/?page=` | 200, страница `ChatListItem` с `last_message`, `interlocutor`, `unread_count` | `Api.listChats` |
| POST | `/chats/` | 201, `ChatDetail`; для GROUP обязательны `name` и допустим `member_ids` | `Api.createGroupChat` |
| POST | `/chats/private/` | 200 или 201, `ChatDetail`; идемпотентно для пары | `Api.createPrivateChat` |
| GET | `/chats/{id}/` | 200, `ChatDetail` с `members[].is_admin` и `my_is_admin` | `Api.chatDetail` |
| PATCH | `/chats/{id}/` | 200, `ChatDetail`; только GROUP и только админ | метода нет — был мёртвым, удалён (дефект №19); вернётся с UI переименования |
| DELETE | `/chats/{id}/` | 204 | метода нет — был мёртвым, удалён (дефект №19); вернётся с UI удаления |
| GET | `/chats/{id}/messages/?page=` | 200, страница `Message`; **страница 1 — последние 50, но внутри страницы порядок по возрастанию времени** (`views.py` сериализует `page[::-1]`) | `Api.messages` |
| POST | `/chats/{id}/send/` | 201, `Message` | `Api.sendMessage` |
| POST | `/chats/{id}/read/` | 200, `{"unread_count": 0}`; сдвигает курсор `Membership.last_read_at` | `Api.markRead` |
| POST | `/chats/{id}/add-member/` | 201; только GROUP, только админ | метода нет — `Api.addMember` удалён как мёртвый (дефект №19) |
| POST | `/chats/{id}/remove-member/` | 200; админ удаляет других, участник — себя; единственного админа удалить нельзя | `Api.removeMember` |

Прочтение — курсор на участнике, а не read-receipt на сообщение: `Message.is_read` остаётся
глобальным флагом, поэтому галочка ✓✓ означает «кто-то прочитал», а не «собеседник прочитал».

### WebSocket

| Endpoint | Назначение |
|----------|------------|
| `ws/chat/<uuid>/?token=<jwt>` | real-time одного чата (открыт, пока чат выбран) |
| `ws/notifications/?token=<jwt>` | личный канал: события по всем чатам, presence, `last_seen` |

Кадры канала чата (сервер → клиент):

| `type` | Payload | Обработка в клиенте |
|--------|---------|---------------------|
| *(нет)* | `{id, chat, sender{id,phone,first_name,last_name}, text, created_at, is_read}` | `_handleChatEvent`, ветка `null` |
| `user_status` | `{user_id, status: online\|offline}` | `onlineUsers` (не отображается) |
| `initial_presence` | `{user_ids: [...]}` — снимок при подключении | `onlineUsers` (не отображается) |
| `messages_read` | `{reader_id}` — приходит и самому читателю | помечает все сообщения прочитанными |
| `{error: "..."}` | пустой текст, длина > 5000, анти-флуд | **не обрабатывается** (дефект №9) |

Клиент → сервер: только `{"text": "..."}`.

Кадры личного канала:

| `type` | Payload | Обработка |
|--------|---------|-----------|
| `new_message` | `{chat, message, unread_count}` | обновляет превью и бейдж; неизвестный чат → `loadChats()` |
| `chat_read` | `{chat}` | бейдж в 0 (прочитано на другом устройстве) |
| `chat_deleted` | `{chat}` | `removeChat` |
| `chat_renamed` | `{chat, name}` | `applyRename` |
| `member_removed` | `{chat}` | `removeChat` (нас исключили) |

Коды закрытия (все в таблице — отказ **до** `accept`, т.е. клиент получает сорванный HTTP
upgrade без WS-кода; `noReconnectCodes` на них не срабатывает, и клиент выходит на
backoff-ретрай. WS-код виден только для закрытий после accept — `member_removed`,
`chat_deleted`, обрывы сети. Невидимые отказы до accept различает пробный `GET /users/me/`
после 3 сорванных handshake подряд — см. раздел 4 и дефект №16):

| Код | Причина | Реакция клиента |
|-----|---------|-----------------|
| 4001 | невалидный/просроченный JWT | не переподключаться; сброс сессии и возврат к экрану входа (`onSessionExpired` → `popUntil` + `logout`, дефект №16) |
| 4003 | не участник чата / исключён | не переподключаться, `removeChat` |
| 4004 | чат удалён | не переподключаться, `removeChat` |
| 4009 | кап одновременных соединений (5 на пользователя) | не переподключаться |
| 4029 | частые подключения (>20/мин) | не переподключаться |
| 403 (HTTP, не WS-код) | handshake отклонён `AllowedHostsOriginValidator` | исправлено: клиент шлёт `Origin` через `IOWebSocketChannel` (дефект №1) |

### Лимиты бэкенда

Превышение → HTTP 429 + `Retry-After`, тело `{"detail": "Request was throttled..."}` (по-английски).

| Scope | Лимит | Что задевает в клиенте |
|-------|-------|------------------------|
| `anon` | 120/мин на IP | — |
| `user` | 600/мин на пользователя | все авторизованные запросы |
| `auth` | 10/мин на IP | `login`, лишний `login` после `register` (дефект №14) |
| `register` | 5/мин на IP | регистрация |
| `send` | 60/мин | REST-фолбэк отправки |
| `read` | 120/мин | `markRead` при каждом открытии чата |
| `write` | 30/мин | создание/переименование/удаление чата, участники |
| `search` | 20/мин | поиск в `new_chat_screen` — дебаунс с отменой на `Timer` исправлен (дефект №8) |
| `profile` | 20/мин | `PATCH /users/me/` |

WS-лимиты (`messenger/ratelimit.py`): сообщения 10/10 с (иначе кадр `{error}`), подключения 20/60 с
(4029), не более 5 одновременных соединений на пользователя (4009).

**`Origin` обязателен.** `config/asgi.py` оборачивает WS-роутер в `AllowedHostsOriginValidator`;
в `channels/security/websocket.py::OriginValidator.valid_origin` отсутствие заголовка трактуется
как отказ, если в `ALLOWED_HOSTS` нет `*`. Браузер шлёт `Origin` сам, `dart:io` — нет. Хост из
`Origin` должен входить в `ALLOWED_HOSTS` бэкенда (`config/settings.py:8-14`, `10.0.2.2` там есть).

## 6. Соглашения кода

- UI-строки — по-русски, захардкожены (локализации нет); тексты ошибок приходят с бэкенда
  по-английски для 429 и по-русски для бизнес-ошибок — показываются как есть.
- Модели: обычные классы с `final`-полями и фабрикой `fromJson`, snake_case ключи JSON читаются
  напрямую, `copyWith` только там, где реально нужен. Codegen (`json_serializable`, `freezed`)
  не используется и не добавлять без необходимости.
- Все сетевые вызовы идут через `Api` (синглтон), состояние — через `ChatState`/`AuthState`.
  Экраны не должны дёргать `Api` напрямую; сейчас это нарушено в `new_chat_screen.dart` и
  `group_members_screen.dart`.
- `DateTime.parse(...).toLocal()` — сервер отдаёт ISO-8601 со смещением.
- Линты — дефолтный `flutter_lints`; `analysis_options.yaml` исключает сгенерированные каталоги
  платформ. Стиль существующего кода (короткие строки с несколькими объявлениями, `catch (_) {}`)
  местами линтам не отвечает — не устраивать массовую чистку вместе с функциональной правкой.

## 7. Известные дефекты

Порядок — по важности. Строки указаны на текущее состояние рабочего дерева.

### Критичные (ломают основной сценарий)

1. **WS-handshake без `Origin` → 403.** ✅ **ИСПРАВЛЕНО**. `WsClient.connect()` (`lib/services/ws.dart:82`)
   теперь использует `IOWebSocketChannel.connect(uri, headers: {'Origin': 'http://<host>'})`.
   На web-платформе заголовки недоступны браузером — требуется настройка бэкенда (см. №24).
2. **Порядок сообщений перевёрнут.** ✅ **ИСПРАВЛЕНО**. Убраны `.reversed` в `ChatState._loadFirstPage`
   и `ChatState.loadOlderMessages`, так как бэкенд уже отдаёт страницу по возрастанию времени
   (`messenger/views.py`: `MessageSerializer(page[::-1])`).
3. **Статус соединения не обновляется.** ✅ **ИСПРАВЛЕНО (доделано)**. Колбэк `onOpen` был объявлен
   и подключён к `setConnected()`, но в `WsClient.connect()` **никогда не вызывался** — шапка чата
   вечно показывала «подключение...» даже при живом сокете (реальный симптом на двух эмуляторах).
   Теперь `onOpen?.call()` стоит сразу после `await _channel!.ready` (`lib/services/ws.dart:99`),
   до `onReconnect`. Статус `connected` ставится только когда handshake реально прошёл.
4. **Выход из аккаунта → пустой экран.** ✅ **ИСПРАВЛЕНО**. `_Boot` в `lib/main.dart` выбирает экран через
   `context.watch<AuthState>()` прямо в `build()`: login/logout вызывают `notifyListeners()` и дерево
   перестраивается само — `isAuthenticated ? ChatsScreen() : LoginScreen()`. Ручная навигация убрана с двух
   сторон: из `chats_screen.dart` (кнопка выхода больше не пушит `_RedirectToLogin` с `SizedBox.shrink()`)
   и из `login_screen.dart:52-55` (после входа больше не пушится `ChatsScreen` маршрутом поверх `_Boot` —
   именно этот толкнутый маршрут оставался поверх перестроенного `_Boot` и блокировал возврат к форме входа
   при logout). Правило: экраны не должны толкать маршруты поверх `_Boot`, навигацию между Login/Chats
   решает только `_Boot`. Побочный хвост того же дефекта: после logout продолжали идти REST- и
   WS-запросы — добавлен `ChatState.clearAll()` (закрывает оба сокета и обнуляет всё состояние),
   вызывается из кнопки выхода в `chats_screen.dart` перед `auth.logout()`.
5. **Созданный чат не открывается.** ✅ **ИСПРАВЛЕНО**. В `_createPrivate` и `_createGroup`
   (`lib/screens/new_chat_screen.dart`) вместо `Navigator.pop()` теперь
   `Navigator.pushReplacement(... ChatScreen(chatId: detail.id) ...)`.
   После создания чата пользователь сразу попадает в него, а не возвращается в список.
6. **Удаление себя из группы.** ✅ **ИСПРАВЛЕНО**. В `lib/screens/group_members_screen.dart:30` сравнение исправлено с
   `ChatState.selectedChatId` (id чата) на `AuthState.me?.id`. Добавлена кнопка выхода из чата для себя (иконка
   `exit_to_app`). Обработка ошибки «единственного админа удалить нельзя» делегирована бэкенду — сообщение об ошибке
   показывается пользователю.
7. **Выбор участников группы теряет состояние.** ✅ **ИСПРАВЛЕНО**. `_selected` переведён с
   `Set<User>` на `Map<String, User>` (ключ — id): `User` не переопределяет `==`/`hashCode`,
   каждый поиск создавал новые экземпляры, чекбоксы сбрасывались, а в `member_ids` попадались
   дубли (бэкенд отвечал 400 на `validate_member_ids`). Ключ Map стабилен, дедупликация
   бесплатна, `displayName` для чипов берётся из значения.

### Функциональные

8. **Поиск без отменяемого дебаунса.** ✅ **ИСПРАВЛЕНО**. В `lib/screens/new_chat_screen.dart` вместо
   `Future.delayed` на каждое изменение поля теперь `Timer? _searchTimer` с `cancel()` перед новым
   запросом (`_debouncedSearch`) и отменой в `dispose()`: набор имени больше не сжигает лимит
   `search` (20/мин) серией лишних запросов.
9. **Кадры `{error: ...}` теряются.** `lib/state/chat_state.dart:268-303` (`_handleChatEvent`): у
   error-кадра нет ни `type`, ни `id`, поэтому switch не делает ничего. Пустое сообщение, текст
   длиннее 5000 символов и срабатывание анти-флуда (10 сообщений/10 с) пользователь не видит —
   ввод просто очищается (`lib/screens/chat_screen.dart:47`).
10. **`messages_read` обрабатывается грубо.** `lib/state/chat_state.dart:295-301` помечает
    прочитанными все сообщения и игнорирует `reader_id` (поле читается в кадре, но не
    используется), хотя бэкенд рассылает событие и самому читателю.
11. **Пагинация игнорируется.** `Api.listChats` (`lib/services/api.dart:167-172`) всегда берёт
    страницу 1 — чаты дальше первых 50 не видны; `Api.messages` (`:202`) выбрасывает `next`,
    поэтому `hasMoreMessages` угадывается по `length == 50` (`lib/state/chat_state.dart:91,127`) и
    врёт, когда сообщений ровно 50.
12. **Лента не прокручивается к новому сообщению.** Автоскролл завязан на `sent != null`
    (`lib/screens/chat_screen.dart:46-56`), а WS-эхо возвращает `null`
    (`lib/state/chat_state.dart:163`). Кроме того, `ListView` не `reverse: true`, а при
    дозагрузке истории (`:34-38`) позиция скролла не сохраняется — список прыгает.
13. **Системный «назад» не закрывает чат.** `closeChat()` вызывается только с крестика в шапке
    (`lib/screens/chat_screen.dart:95-101`); `PopScope` нет, поэтому свайп/кнопка назад оставляет
    сокет открытым и `selectedChatId` установленным.
14. **Регистрация делает лишний вход.** Бэкенд возвращает токены сразу
    (`messenger/views.py:552-580`), `Api.register` их сохраняет (`lib/services/api.dart:138-140`),
    но `AuthState.register` (`lib/state/auth_state.dart:53-59`) затем всё равно вызывает `login()`
    — лишний запрос в scope `auth` (10/мин). Комментарий `lib/services/api.dart:136-137`
    («Register возвращает токены?») устарел и вводит в заблуждение.
15. **Ошибки глушатся.** ⚠️ **ИСПРАВЛЕНО ЧАСТИЧНО**. Самое заметное заделано: ошибка
    загрузки истории (`ChatState._loadFirstPage`) больше не прячется в `catch (_) {}` —
    ложится в `loadError` и показывается плашкой в `ChatScreen` (раньше сбой сети/401
    выглядел как «пустой экран и ничего не происходит», симптом двух эмуляторов).
    Остальные тихие catch остались: `ChatState.loadChats` / `loadChatDetails` /
    `loadOlderMessages` / `markRead`, `AuthState.bootstrap`, поиск в `new_chat_screen` —
    ни офлайн, ни 429, ни 403 там до UI не доходят.
16. **Нет обработки смены токена и сессии в живых сокетах.** ✅ **ИСПРАВЛЕНО**.
    Симптом на двух эмуляторах («история грузится только на одном клиенте, после закрытия
    чата блокировка переходит другому») — это невидимый отказ WS-handshake: отказ до
    `accept` приходит без WS-кода, а access-токен живёт 60 мин (`settings.py:158`).
    Три правки: (1) токен перед handshake берётся через `Api.ensureFreshAccess()` —
    парсит `exp` из JWT и делает refresh до подключения; (2) после 3 сорванных handshake
    без кода `WsClient._probeAuth()` дёргает `GET /users/me/` — если сессия мертва,
    сигналим `onClose(4001)`; (3) `ChatState.onSessionExpired` (wiring в `main.dart`)
    снимает маршруты через `navigatorKey.popUntil`, делает `clearAll()` и `logout()` —
    экран входа вместо вечного «подключение...». Если симптом вернётся — проверить
    фантомные счётчики в Redis `messenger:presence` (см. раздел 4).
28. **Исчезающие отправки при переподключении сокета.** ✅ **ИСПРАВЛЕНО**. `WsClient.isConnected`
   возвращал `_channel != null`, но канал присваивается **до** `await ready` — в фазе подключения
   и ретраев `ChatState.sendMessage` (`lib/state/chat_state.dart:160`) считал сокет живым, писал
   `{'text': ...}` в несуществующее соединение и возвращал `null`. REST-фолбэк не срабатывал, поле
   ввода очищалось, сообщение не уходило вообще. Теперь есть флаг `_isOpen` (ставится после
   успешного handshake, сбрасывается в `_handleClose`/`close`/`catch`), `isConnected => _isOpen`,
   а `send()` бросает `StateError` если канал не открыт — `sendMessage` уходит в REST. Дефект был
   не каталогизирован, проявился на двух эмуляторах.
29. **Reconnect-шторм сам себя запирал от бэкенда.** ✅ **ИСПРАВЛЕНО**. Фиксированный ретрай через
   2 с = до 30 попыток/мин при лимите бэкенда `CONNECT_LIMITER` 20/мин на пользователя
   (`messenger/ratelimit.py`). Отказ 4029 приходит **до** `accept` → клиент не видит WS-код, не
   попадает в `noReconnectCodes` и ретраит вечно: кратковременный обрыв сети запускал петлю,
   которой клиент сам блокировал себе переподключение (вечно «подключение...», не приходят
   сообщения и бейджи). Заменили на экспоненциальный backoff 1→60 с с джиттером ±30%
   (`_scheduleReconnect`), счётчик неудач сбрасывается после успеха — частота попыток держится
   ниже лимита, соединение восстанавливается само.

### Гигиена

17. **`test/widget_test.dart`.** ✅ **ИСПРАВЛЕНО**. Шаблонный тест счётчика, ссылавшийся на
    несуществующий `MyApp`, заменён смоук-тестом: `SharedPreferences.setMockInitialValues({})` →
    прогон `_Boot` → ожидаем `LoginScreen` (тексты «Вход»/«Телефон»/«Пароль»). Тест проверяет
    поведение, починенное в дефекте №4, и больше не требует сети. `flutter analyze` и `flutter test`
    компилируются.
18. **Неиспользуемый импорт** `dart:async` в `lib/state/chat_state.dart`. ✅ **ИСПРАВЛЕНО** — удалён.
19. **Мёртвый код.** ✅ **ИСПРАВЛЕНО** (выбран путь «удалять», а не «доводить до UI»):
    удалены `ChatState.renameChat`, `ChatState.deleteChat`, `Api.renameChat`, `Api.deleteChat`,
    `Api.addMember` (эндпоинты бэкенда остаются — методы вернутся вместе с UI, см. раздел 8);
    поле `Me.lastSeen` убрано (вернётся с presence); пакет `intl` удалён из `pubspec.yaml`
    (время форматируется вручную в `lib/screens/chat_screen.dart`).
    `ChatState.onlineUsers` намеренно оставлен: он наполняется обработчиками `user_status`/
    `initial_presence` и нужен для реализации presence (раздел 8) — это функциональный пробел,
    а не мёртвый код.
20. **Строковая типизация там, где есть enum.** ✅ **ИСПРАВЛЕНО**. `lib/screens/chat_screen.dart`
    сравнивает `detail?.type == ChatType.group` (импорт `models/chat.dart` добавлен); статус WS
    переведён на enum `WsStatus { connecting, connected, disconnected }` в
    `lib/state/chat_state.dart` — строковых сравнений больше нет.

### Платформенные конфиги

21. **Android**: `android/app/src/main/AndroidManifest.xml` без `INTERNET` (разрешение есть
    только в `src/debug/` и `src/profile/`) → release-сборка не выйдет в сеть; для HTTP без TLS
    нужен `android:usesCleartextTraffic="true"` либо `network_security_config`.
22. **macOS**: в `macos/Runner/DebugProfile.entitlements` и `Release.entitlements` нет
    `com.apple.security.network.client` (в стандартном шаблоне Flutter он есть) → исходящие
    соединения блокирует песочница.
23. **iOS**: в `ios/Runner/Info.plist` нет `NSLocalNetworkUsageDescription` — нужно для обращения
    к IP в локальной сети (iOS 14+). `10.0.2.2` работает только на эмуляторе Android.
24. **web**: цель нерабочая без правок бэкенда — `CORS_ALLOWED_ORIGINS` (`config/settings.py:207`)
    разрешает только `localhost:5173`/`127.0.0.1:5173`, а браузерный `Origin` с порта Flutter-web
    не входит в `ALLOWED_HOSTS` (снова 403 на WS). Заголовки в `IOWebSocketChannel` на web
    недоступны в принципе.
25. **Устаревшие отображаемые имена из нативной Android-версии.** ✅ **ИСПРАВЛЕНО**. Правки:
    `description` в `pubspec.yaml:2`, `android:label` (`android/app/src/main/AndroidManifest.xml:3`),
    `CFBundleDisplayName`/`CFBundleName` (`ios/Runner/Info.plist:10,19`),
    `<title>`/`meta description`/`apple-mobile-web-app-title` (`web/index.html`) и
    `name`/`short_name`/`description` (`web/manifest.json`) — везде «Lost Dream Messenger».
    **Осознанно не трогали**: идентификаторы сборки — `applicationId`/`namespace`
    (`android/app/build.gradle.kts:8,19`) с `com.example.lost_dream_messenger_android`, пакет и путь
    `MainActivity.kt`, `PRODUCT_NAME` (`macos/Runner/Configs/AppInfo.xcconfig:8`),
    `BINARY_NAME`/`project()` (`linux/CMakeLists.txt:7`, `windows/CMakeLists.txt:3,7`),
    `Runner.rc`, заголовки окон в `linux/runner/my_application.cc` и `windows/runner/main.cpp`,
    ссылки на `.app` в `macos/Runner.xcodeproj`. Их переименование — это перенос пакетов и
    перевыпуск Artifacts/подписей, а не косметика: делать отдельной правкой и только когда
    понадобится релизный канал. Имя пакета Dart в `pubspec.yaml:1` — `lost_dream_messenger_client`.

### Безопасность

26. JWT лежит открытым текстом в `SharedPreferences` (`lib/services/token_store.dart`) — для
    прод-сборки нужен `flutter_secure_storage` (Keychain/Keystore). Трафик — HTTP без TLS.
27. `lib/models/user.dart:19-21` — нормализация пустых строк в `null` записана через
    `?.isEmpty ?? true ? null : ...`: работает, но читается как ошибка приоритетов; при правке
    добавить скобки.

## 8. Что не реализовано (по сравнению с бэкендом и Kotlin-версией)

- переименование группы и удаление чата из UI — клиентских методов нет: раньше это был мёртвый
  код, удалён при починке дефекта №19; эндпоинты бэкенда (`PATCH`/`DELETE /chats/{id}/`) живы,
  методы вернутся вместе с UI;
- добавление участника в существующую группу (`Api.addMember` удалён как мёртвый код, см. №19;
  эндпоинт `POST /chats/{id}/add-member/` на бэкенде жив);
- отображение presence: точки «в сети» в шапке чата и в списке участников, счётчик
  «N в сети из M», `last_seen` («был в сети …»);
- пагинация списка чатов и корректный `next` в истории;
- оптимистичная отправка и очередь сообщений при обрыве связи;
- плашки состояния: человекочитаемые причины закрытия сокета в шапке чата сделаны
  (`ChatState.wsCloseNotice`, дефект №16; в Kotlin-версии это `closeNotice(code)`); не хватает
  индикатора соединения в списке чатов и текста error-кадров бэкенда (дефект №9);
- пустые состояния и скелетоны загрузки (сейчас `CircularProgressIndicator` только в списке
  участников и при дозагрузке истории);
- поиск по истории, пересылка, вложения — на бэкенде этого тоже нет;
- push-уведомления;
- локализация и темы;
- тесты: только смоук-тест `test/widget_test.dart` (см. №17); unit для `ChatState`/`Api`,
  widget-тесты экранов и CI отсутствуют;

## 9. Правила для ассистентов

- Контракт сверять с исходниками бэкенда, а не с комментариями клиента: комментарии здесь уже
  расходились с реальностью. Живой пример — `lib/services/api.dart:136` («Register возвращает
  токены?», устарел, см. дефект №14).
- Бэкенд не править. Если клиент упирается в ограничение бэкенда (CORS, `ALLOWED_HOSTS`,
  `Origin`, лимиты) — фиксировать это в разделе 7 и предлагать правку клиента либо явно
  спрашивать про бэкенд.
- Не добавлять codegen, DI-фреймворки и новые пакеты без явной необходимости: текущий стек
  намеренно плоский (`http` + `provider` + ручной JSON).
- Не вводить `go_router`/именованные маршруты попутно с функциональной правкой.
- Строки UI — по-русски.
- Не запускать сборку, тесты и приложение «для проверки» и не коммитить: это делает пользователь.
  Исключение — если он явно попросил прогнать `flutter analyze`/`flutter test`.
- Не устраивать массовую чистку стиля и линтов вместе с содержательной правкой.

## 10. Порядок работ, если доводить до рабочего состояния

1. ~~Дефекты №1–№3~~ ✅; ~~№4–№7~~ ✅; ~~№8 (дебаунс)~~ ✅ — критичный блок закрыт полностью.
2. №9–№14 и остаток №15 (тихие catch вне загрузки истории) — поведение под нагрузкой и
   обратная связь: error-кадры, пагинация, скролл, системный «назад» (`PopScope`), лишний
   login при регистрации; ~~reconnect-шторм и теряющиеся отправки~~ ✅ (№28–№29);
   ~~№16 (оживление сессии при 4001)~~ ✅.
3. ~~№17–№20 (гигиена)~~ ✅ — анализатор, тест, мёртвый код, enum'ы.
4. №21–№24 — платформенные конфиги, если нужны не-Android цели; ~~№25 (имена)~~ ✅, кроме
   идентификаторов сборки (осознанно отложены — см. текст дефекта).
5. Раздел 8 — функциональные пробелы (presence, переименование, удаление, добавление участников).
