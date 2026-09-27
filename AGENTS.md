# AGENTS.md — контекст для AI-ассистентов и инженеров

> Файл описывает текущее состояние Flutter-клиента: архитектуру, контракт бэкенда, паритет с
> веб-эталоном, соглашения, известные дефекты и технологический долг. Обновлять при каждом
> значимом изменении. Краткая версия для человека — [README.md](README.md).
>
> **Правило актуальности:** этот файл уже дважды расходился с кодом в обратную сторону
> (комментарии утверждали, что дефект открыт, когда он был исправлен). Любой пункт про дефект
> сверять с кодом до правки; после правки — обновлять номер в списке и строки.

## 1. Что это за проект

Клиент к Django-бэкенду [`lost-dream-messenger-server`](../lost-dream-messenger-server)
(монорепозиторий: Django в корне, Vue-фронтенд в `frontend/`).

Два эталона, и они решают разные вещи:

- **бэкенд — единственный источник правды о контракте**: формат ответа, статус-код, имя поля,
  кадр WebSocket, лимит. Спор решается чтением `messenger/views.py`, `serializers.py`,
  `consumers.py`, `routing.py`, `ratelimit.py`, `readstate.py`, `config/settings.py`,
  а не комментарием в этом клиенте;
- **`frontend/` (Vue 3 + Pinia) — эталон поведения**: какие действия доступны, в какой момент
  что перечитывается, как реагирует UI. Клиент повторяет семантику, а не код: стек, модель
  жизненного цикла и навигация разные, поэтому переносится решение, а не строки
  (карта соответствий — раздел 8).

История: до Flutter здесь было нативное Android-приложение на Kotlin/Compose (удалено из рабочего
дерева, лежит в git: `git show 433543b --stat`, каталог `app/`). Оно было корректнее Dart-переписывания
в трёх местах (порядок сообщений внутри страницы, `Origin` для WS-handshake, поведение личного канала
уведомлений). Первые два исправлены (№2, №1), третье воспроизведено на личном канале
(`_handleNotification`). При спорных случаях по личному каналу быстрее свериться с Kotlin-кодом,
чем с бэкендом: `receive` в consumers'ах описан, но тонкости сброса бейджа там нет.

**Текущее состояние: функционально завершённый клиент.** Закрыты все критичные (№1–№7),
функциональные (№8–№14) и гигиенические (№17–№20) дефекты, плюс №15 (глухие ошибки),
№16 (оживление сессии), №25 (отображаемые имена), №28–№29 (стабильность WS) и функциональные
пробелы раздела 9: presence в UI, переименование GROUP, удаление чата, добавление участников,
пагинация истории по `next`, error-кадры, системный «назад» (`PopScope`), жизненный цикл
приложения (перечитывание и оживление сокетов после фона), состояние при переключении форм.

`flutter analyze` — 0 замечаний, `flutter test` — проходит (один смоук-тест).

**Открыто:** №21–№24 (конфиги целей, кроме Android-debug), №26 (безопасность токена),
№30–№40 (остаток паритета и инженерный долг: мёртвый маршрут после 4003/4004, индикатор
соединения и подсветка непрочитанного в списке, пагинация списка чатов, env-конфиг, тесты,
`MaterialApp.title`, вызовы `Api` из экранов, коалесинг `markRead`, `copyWith`, мёртвый guard).
Разбор по severity — раздел 10.

## 2. Окружение и команды

| | |
|---|---|
| Flutter | 3.47.5 stable, Dart 3.13.4 |
| pubspec `environment.sdk` | `^3.13.4` |
| Зависимости | `http ^1.2.0`, `web_socket_channel ^3.0.0`, `provider ^6.1.0`, `shared_preferences ^2.2.0`, `cupertino_icons ^1.0.8`, dev: `flutter_lints ^6.0.0` (`intl` удалён как неиспользуемый — №19) |

```bash
flutter pub get
flutter analyze          # 0 замечаний
flutter test             # смоук-тест: без сессии приложение показывает экран входа
flutter run -d <device>  # хост бэкенда правится в lib/config.dart
```

Бэкенд поднимается отдельно: `cd ../lost-dream-messenger-server && docker compose up`
(Postgres 18 на хост-порту 5434, Redis 7, Daphne на `:8000`, Vite-фронтенд на `:5173`).
Эталонный веб-клиент для сравнения поведения — `http://localhost:5173`.

`lib/config.dart:5` — `AppConfig.host` как compile-time константа: эмулятор Android `10.0.2.2:8000`,
симулятор iOS/macOS `127.0.0.1:8000`, реальное устройство — IP машины в LAN. `--dart-define` не
поддерживается (№34).

## 3. Карта файлов

```
lib/
├── config.dart                  # AppConfig: host, apiBase (http://host/api/v1), wsBase (ws://host/ws)
├── main.dart                    # AuthState+ChatState создаются в main(), там же wiring:
│                                #   chat.onSessionExpired (4001 → popUntil + clearAll + logout(reason)
│                                #            через navigatorKey)
│                                #   chat.onNotice    (однократные ошибки → SnackBar)
│                                #   auth.addListener → chat.myUserId  (нужен для фильтра reader_id)
│                                # MultiProvider(.value) → MaterialApp → _Boot
│                                # _Boot: bootstrap(), затем watch<AuthState>:
│                                #        isAuthenticated ? ChatsScreen : LoginScreen
├── models/                      # Плоские DTO с фабриками fromJson, без codegen
│   ├── user.dart                # User(id, phone, email?, firstName?, lastName?) + displayName
│   ├── me.dart                  # Me(id, phone, email?, firstName?, lastName?) — last_seen не парсится
│   │                            #   (см. раздел 9: на бэкенде last_seen есть только в MeSerializer)
│   ├── message.dart             # Message(+copyWith(isRead)) и MessagePage(items, hasNext из `next`)
│   └── chat.dart                # ChatType{private,group}, ChatListItem(+copyWith, displayName),
│                                # ChatMember(user, isAdmin), ChatDetail(members, myIsAdmin)
├── services/
│   ├── api.dart                 # Api — синглтон. _request: 401 → refresh → один повтор.
│   │                            # ApiException(statusCode, message), _extractError (DRF detail / {field:[…]});
│   │                            # ensureFreshAccess() — refresh по claim exp перед WS-handshake (№16);
│   │                            # renameChat/deleteChat/addMember вернулись из мёртвого кода с UI (№19)
│   ├── token_store.dart         # TokenStore: статические access/refresh/save/clear поверх SharedPreferences
│   └── ws.dart                  # WsClient(path, onEvent, onClose, onReconnect, onOpen):
│                                # IOWebSocketChannel + Origin; connect() с guard _connecting → _handshake();
│                                # isConnected == _isOpen (handshake завершён), send() бросает StateError иначе;
│                                # backoff 1→60 с + джиттер, _probeAuth() после 3 сорванных handshake,
│                                # revive() — принудительное оживление из foreground,
│                                # noReconnectCodes = {4001,4003,4004,4009,4029}
├── state/
│   ├── auth_state.dart          # me, loading, error; bootstrap/login/register/updateProfile/logout;
│   │                            # clearError() — сброс ошибки при смене режима формы
│   └── chat_state.dart          # chats, messages, currentChatDetail, selectedChatId, onlineUsers,
│                                # messagesPage/hasMoreMessages/isLoadingHistory, myUserId, isForeground;
│                                # wsStatus (enum WsStatus) + wsCloseNotice;
│                                # ошибки: sendError / loadError / detailsError / listError;
│                                # onNotice, onSessionExpired;
│                                # presence-геттеры: interlocutorOnline, onlineMembersCount, otherMembers;
│                                # права: canRenameChat, canDeleteChat;
│                                # write: renameChat / deleteChat / sendMessage / markRead / closeChat;
│                                # read: loadChats / selectChat / _loadFirstPage / loadOlderMessages /
│                                #       reloadMessages / loadChatDetails;
│                                # жизненный цикл: ensureChatSocket / ensureNotificationsSocket (revive),
│                                #       clearAll() — полная очистка при logout
├── widgets/
│   └── presence_dot.dart        # PresenceDot(online) — точка онлайн/оффлайн (8×8, зелёная/серая)
└── screens/
    ├── login_screen.dart        # Вход/регистрация; _toggleMode() чистит 6 полей + auth.clearError();
    │                            # плашка auth.error; после входа НИКАКОЙ ручной навигации — решает _Boot
    ├── chats_screen.dart        # Список + плашка listError + FAB + профиль/выход;
    │                            # WidgetsBindingObserver: didChangeAppLifecycleState(resumed) →
    │                            #   isForeground, ensureNotificationsSocket, ensureChatSocket, markRead;
    │                            # initState: loadChats + openNotificationsSocket
    ├── chat_screen.dart         # reverse-лента, автоскролл по id последнего сообщения, цикл
    │                            #   дозаполнения экрана, _onScroll → loadOlderMessages;
    │                            # PopScope(canPop: false) → closeChat (системный «назад»);
    │                            # шапка: название (кнопка переименования для админа GROUP),
    │                            #   presence-строка, статус WS / wsCloseNotice;
    │                            # actions: участники (GROUP), удалить чат (двухшаговое), ×;
    │                            # плашки: sendError|loadError|detailsError, _renameRow, deleteNotice
    ├── new_chat_screen.dart     # Личный/групповой; debounced-поиск (Timer 300 мс) с «Поиск...»/«Не найдено»,
    │                            # чекбоксы по id, своя строка заблокирована, FilledButton неактивна
    │                            # без названия, `_creating` на время запроса;
    │                            # после создания — pushReplacement на ChatScreen
    ├── group_members_screen.dart# StatefulWidget: список + presence + чип «админ»,
    │                            # строка «N в сети из M», удаление других (админу), выход себя;
    │                            # админу — нижний блок _addMemberSection (debounced-поиск кандидатов
    │                            #   минус уже состоящие → addMember → loadChatDetails);
    │                            # _busy — один флажок на все три записи; после выхода popUntil(isFirst)
    └── profile_screen.dart      # PATCH своих полей; локальная проверка пустого телефона,
                                 # _saving блокирует повторную отправку, _localError инлайн под полем
test/widget_test.dart            # Смоук-тест: без сохранённой сессии _Boot показывает LoginScreen
android/ ios/ macos/ windows/ linux/ web/   # Сгенерированные `flutter create` цели (см. №21–№24)
```

Навигация — `Navigator.push` из `chats_screen.dart` (чат, профиль, новый чат) и `chat_screen.dart`
(участники), `pushReplacement` в `new_chat_screen.dart` (открытие созданного чата),
`popUntil(isFirst)` при выходе из группы. Именованных маршрутов, `go_router`, deep links и
state restoration нет. Переходы Login↔Chats — исключительная прерогатива `_Boot`: маршруты
поверх него толкать нельзя (и logout, и сброс сессии по 4001 не вернут к форме входа).
`ChatScreen` принимает `chatId` конструктором, но данные берёт из глобального `ChatState`
(`selectedChatId`) — состояние чата живёт вне маршрута, отсюда №30.

## 4. Архитектура

**Состояние.** Два `ChangeNotifier` в `MultiProvider` (`lib/main.dart`), оба создаются в `main()`
до авторизации и передаются через `ChangeNotifierProvider.value`. Отдельных ViewModel на экран нет,
DI нет: `Api` — синглтон (`lib/services/api.dart:19-21`), `TokenStore` — статические методы.
Экраны читают через `context.watch<T>()` (пересборка) и `context.read<T>()` (вызов методов).

`ChatState` намеренно «толстый»: в нём и репозиторий (списки + пагинация + merge), и оба сокета,
и бизнес-правила (кто может переименовывать/удалять, как считать presence, что делать с
`new_message`). Это наследование структуры эталонного `stores/chat.ts`, а не осознанный выбор:
при переносе правки в `ChatState` она автоматически попадает на все экраны, но файл разросся до
740+ строк и это главный кандидат на раскадровку (раздел 10, блок B).

**Загрузка сессии.** `_Boot` показывает спиннер, пока `auth.bootstrap()` проверяет сохранённые
токены; дальше выбор экрана полностью реактивный (`watch<AuthState>` + `isAuthenticated`).
Любая смена состояния авторизации перестраивает `_Boot` сам — ручная навигация между этими
двумя экранами запрещена (история — №4).

**REST.** `Api._request` собирает заголовки (`Content-Type`, `Authorization: Bearer` из
`TokenStore`), при 401 делает `POST /auth/refresh/` и повторяет исходный запрос ровно один раз
(`retryOn401: false`); если refresh не принят — токены стираются. Методы проверяют конкретный
ожидаемый статус-код, иначе бросают `ApiException` с текстом из `_extractError` (DRF `detail`
или первое сообщение валидации поля). `DELETE` проверяется на 204, `add-member` — на 201.

**WebSocket.** Один класс `WsClient` на оба канала, различается только `path`:
`chat/<uuid>/` и `notifications/`. Токен — query-параметр `?token=<jwt>` (Authorization бэкенд
в WS не читает), заголовок `Origin` обязателен (№1, см. раздел 5).

- `connect()` — публичная обёртка с guard `_connecting` (`ws.dart:61,74-82`) поверх `_handshake()`:
  handshake асинхронный (сначала refresh токена), без guard `revive()` в момент незавершённого
  подключения создал бы второй канал, и старый сокет дублировал бы события;
- сокет чата открывается в `selectChat()` после загрузки первой страницы, деталей и `markRead`;
  статус `connecting` → `connected` через колбэк `onOpen` (`setConnected`); закрывается в
  `closeChat()`, `clearAll()`, `dispose()`;
- сокет уведомлений открывается в `ChatsScreen.initState()` и закрывается `clearAll()`;
- `isConnected == _isOpen` — «handshake завершён», а не «объект канала создан» (№28);
  `send()` при незакрытом канале бросает `StateError`, и `sendMessage` штатно уходит в REST;
- переподключение — экспоненциальный backoff 1, 2, 4, 8, …, 60 с (потолок) + джиттер ±30%
  (`_scheduleReconnect`), кроме кодов `noReconnectCodes` = {4001, 4003, 4004, 4009, 4029}
  (`ws.dart:17`). Фиксированные 2 с давали до 30 попыток/мин при лимите бэкенда 20/мин — клиент
  запирал себя сам (№29);
- отказ consumer'а **до** `accept` приходит как сорванный HTTP-upgrade без WS-кода → `catch` в
  `_handshake()` → backoff-ретрай. `noReconnectCodes` реально срабатывает только на закрытиях
  **после** accept (`member_removed`, `chat_deleted`, обрывы). Невидимые отказы различает
  `_probeAuth()`: после 3 подряд сорванных handshake (`_probeAfter`) делается пробный
  `GET /users/me/` — 401 → `onClose(4001)` → сброс сессии, иначе это просто сетевой сбой →
  продолжаем backoff (№16);
- `revive()` (`ws.dart:191`) — принудительное переподключение после возврата из фона: сбрасывает
  `_retryCount`/`_handshakeFailures`, отменяет таймер, но **не** обнуляет `_retryTimer`, потому что
  по `_retryTimer != null` `connect()` отличает первое подключение от повторного и вызывает
  `onReconnect` → `reloadMessages()` + `loadChats()`. Сокет, закрытый через `close()`
  (`_closedByUser` — logout), не воскрешается.

**Жизненный цикл приложения.** `ChatsScreen` — `with WidgetsBindingObserver`, и в
`didChangeAppLifecycleState` (`chats_screen.dart:36`) на `resumed`: выставляет
`ChatState.isForeground = true`, поднимает личный канал (`ensureNotificationsSocket`), а если чат
выбран — поднимает сокет чата (`ensureChatSocket`) и подтверждает прочтение (`markRead`).
Мобильный аналог `visibilitychange` из эталона, но шире: эталон перечитывает только прочтение и
оживляет личный канал, а сокет чата оживляется здесь (E4) — ОС рвёт соединения спящего процесса, а
отказ по капу 5 соединений (4009) входит в `noReconnectCodes`, так что без `revive()` чат оставался
бы мёртвым до переоткрытия. `inactive` фоном не считается (шторка, системный диалог — экран виден).

**Поток события.** Кадр WS → `WsClient.onEvent` → `ChatState._handleChatEvent` (канал открытого
чата: `user_status`, `initial_presence`, `messages_read`, сообщение без `type`, `{error}`) или
`_handleNotification` (личный канал: `new_message`, `chat_read`, `chat_deleted`, `chat_renamed`,
`member_removed`) → мутация списков → `notifyListeners()` → пересборка экранов.

Ключевая семантика, воспроизведённая из эталона:

- `initial_presence` **заменяет** набор `onlineUsers` целиком (`clear()` + `addAll`), а не
  пополняет: иначе после reconnect в списке остались бы статусы участников прошлого подключения.
  `selectChat()` тоже чистит набор перед открытием чата — чтобы до `initial_presence` не
  светились статусы предыдущего чата;
- `messages_read` фильтруется по `reader_id != myUserId`, и `markAllRead()` помечает прочитанными
  **только свои** сообщения: бэкенд рассылает событие и самому читателю (№10). `myUserId`
  проставляется из `AuthState` подпиской в `main.dart` (в payload JWT только `user_id`);
- `new_message` — «либо/либо» (`chat_state.dart` `_handleNotification`): если чат открыт
  **и** приложение на переднем плане — бейдж в 0 + `markRead`, иначе серверный `unread_count`.
  Раньше оба действия выполнялись подряд, и `unread_count` перезаписывался нулём из `markRead`,
  а в фоне курсор сдвигался сам собой — пользователь терял бейджи, не увидев сообщений;
- неизвестный чат в `new_message` (нас только что добавили в группу) → `loadChats()`: бейдж и
  превью придут вместе со списком;
- `chat_renamed` несёт `name`, `chat_deleted`/`member_removed` → `removeChat`
  (`removeChat` заодно закрывает чат, если это был он).

**Перечитывание после reconnect.** `reloadMessages()` (`chat_state.dart:565`): если вернулась
полная страница (`>= messagesPageSize = 50`), пропущенных могло быть больше страницы и в истории
возможна «дыра» → лента заменяется целиком, `messagesPage = 1`; иначе в хвост добираются
неизвестные по id, а у уже известных обновляется `is_read` (он мог измениться, пока сокет был
закрыт). Полная замена ленты в любой ветке потеряла бы ранее догруженные старшие страницы.
После — `loadChats()` (бейджи и превью за время обрыва).

**Отправка.** `ChatState.sendMessage`: сокет жив (`isConnected`) → `{'text': ...}` в WS и
возврат `null` (своё сообщение придёт эхом из broadcast-группы); иначе `POST /chats/{id}/send/`
и `addMessage`. Экран больше не смотрит на возвращаемое значение — прокрутка привязана к id
последнего сообщения (№12). Ошибка REST (включая 429 scope `send`) пишется в `sendError`
и rethrow'ится: поле ввода не очищается, текст остаётся у пользователя.

**Прочтение.** Курсор на участнике (`Membership.last_read_at`), а не read-receipt на сообщении:
`Message.is_read` — глобальный флаг, поэтому ✓✓ означает «кто-то прочитал», а не «собеседник
прочитал» (в группах прочтение одним участником помечает сообщение прочитанным для всех —
ограничение бэкенда, клиент его не обходит).

**Лента и прокрутка** (`chat_screen.dart`). Перевёрнутая `ListView.builder(reverse: true)`
(индекс 0 прижат к нижней кромке): новые сообщения и дозагрузка старых не сдвигают видимый
контент, поэтому веб-якорь `scrollTop += Δ scrollHeight` переносить не нужно. Три механизма:

- `build` сравнивает `messages.last.id` с `_handledLastId` и на изменение пост-кадром вызывает
  `_syncScroll()` — так ловятся и WS-эхо, и REST-ответ, и `reloadMessages` (в `initState` нельзя:
  сообщения приходят асинхронно после открытия экрана);
- `_syncScroll()` при первом заходе (`_justOpened`) сначала дополняет экран историями в цикле
  (`maxScrollExtent <= 0` — то есть скролла ещё нет, а без него догрузить нечем), затем
  `jumpTo(0)`; иначе `animateTo(0)` за 200 мс. Флаг `_syncing` — re-entrancy guard: функция
  асинхронная и сама дозагружает, два кадра запустили бы два цикла параллельно;
- `_onScroll()` догружает старые страницы только при движении к концу (`pixels > _lastPixels`)
  и в пределах 100 px от `maxScrollExtent` — иначе программная прокрутка вниз сама провоцировала
  бы запрос лишней страницы.

`PopScope(canPop: false)` + `onPopInvokedWithResult` → `_closeChat()` = `closeChat()` +
`Navigator.pop`: единый путь для крестика и системного «назад» (№13).

**Права на запись** считаются в `ChatState`, а не в экранах: `canRenameChat` (GROUP +
`currentChatDetail.myIsAdmin`), `canDeleteChat` (PRIVATE — всегда, GROUP — `myIsAdmin`).
`renameChat` применяет название из ответа `PATCH`, не дожидаясь `chat_renamed`; `deleteChat`
удаляет чат из списка сразу, не дожидаясь `chat_deleted` (сервер разнесёт остальным сам).
На каждую запись — один экранный флаг: `_savingName` (+ `_renaming` для режима правки),
`_deleting` (после первого тапа `_confirmDelete` взводит подтверждение), `_creating` в новом чате,
`_busy` на экране участников
(добавить/удалить/выйти) — параллельные запросы к одному составу дали бы 400.
Отдельная неочевидность: `ChatState` читается **до** первого `await` (`context.read` после
async-паузы нарушает `use_build_context_synchronously`), а перед любыми навигационными вызовами
проверяется `mounted`.

**Ошибки.** Сетевые ошибки состояния живут в полях (`sendError`/`loadError`/`detailsError`/
`listError`), `AuthState` — в `error`, экраны рисуют плашками; одноразные без своего места
(`markRead`) идут через `onNotice` → SnackBar в `main.dart`. Общий формат текста —
`_describe(что, e)`: `ApiException` → «<что>: <сообщение бэкенда>», всё остальное → «<что>:
нет связи с сервером». Молчат намеренно два catch: кривой JSON в `ws.dart` (кадр игнорируется) и
`sendMessage` при мёртвом сокете (StateError → штатный REST-фолбэк).

## 5. Контракт бэкенда

Префикс REST — `/api/v1`. Аутентификация — `Authorization: Bearer <access>`, JWT SimpleJWT
(в payload только `user_id`, поэтому профиль всегда догружается `GET /users/me/`;
`ACCESS_TOKEN_LIFETIME` — 60 мин, `settings.py:158`).
Пагинация `PageNumberPagination`, PAGE_SIZE 50, ответ `{count, next, previous, results}`.

### REST

| Метод | Путь | Статус | Клиент |
|-------|------|--------|--------|
| POST | `/auth/register/` | 201, `{user, access, refresh}` | `Api.register` (токены сохраняются, отдельный `login` не нужен — №14) |
| POST | `/auth/login/` | 200, `{access, refresh}`, поле `phone` | `Api.login` |
| POST | `/auth/refresh/` | 200, `{access}` | `Api._refreshToken` |
| GET | `/users/me/` | 200, `Me` (**единственное** место, где есть `last_seen`) | `Api.me` |
| PATCH | `/users/me/` | 200, `Me`; поля опциональны, `email` допускает `""`, телефон нормализуется, `username` меняется следом | `Api.updateMe` |
| GET | `/users/search/?q=` | 200, страница `User`; **исключает себя** (`views.py:631`), срез 20 (`[:20]`), телефон ищется по цифрам `normalize_phone(q)` | `Api.searchUsers` |
| GET | `/chats/?page=` | 200, страница `ChatListItem` с `last_message`, `interlocutor`, `unread_count` | `Api.listChats` (параметр `page` есть, но зовётся только с 1 — №33) |
| POST | `/chats/` | 201, `ChatDetail`; для GROUP обязателен `name` (max_length 255), допустим `member_ids` | `Api.createGroupChat` |
| POST | `/chats/private/` | 200 или 201, `ChatDetail`; идемпотентно для пары (`select_for_update`) | `Api.createPrivateChat` |
| GET | `/chats/{id}/` | 200, `ChatDetail` с `members[].is_admin` и `my_is_admin` | `Api.chatDetail` |
| PATCH | `/chats/{id}/` | 200, `ChatDetail`; тело **только** `{name}` (`ChatRenameSerializer`), GROUP + админ (иначе 400/403), то же название — no-op; участникам идёт `chat_renamed` в личный канал | `Api.renameChat` ✅ |
| DELETE | `/chats/{id}/` | 204; GROUP — только админ, PRIVATE — любой участник; остальным 4004 в сокет и `chat_deleted` в личный канал | `Api.deleteChat` ✅ |
| GET | `/chats/{id}/messages/?page=` | 200, страница `Message`; страница 1 — последние 50 (`-created_at`), но внутри страницы порядок по возрастанию времени (`MessageSerializer(page[::-1])`) | `Api.messages` → `MessagePage` |
| POST | `/chats/{id}/send/` | 201, `Message` + broadcast в группу чата | `Api.sendMessage` |
| POST | `/chats/{id}/read/` | 200, `{"unread_count": 0}`; сдвигает `Membership.last_read_at`; не-участник → 404 | `Api.markRead` |
| POST | `/chats/{id}/add-member/` | 201, `{detail}`; тело `{"user_id": …}`; только GROUP и только админ (403 остальным), PRIVATE → 400, уже состоит → 400 | `Api.addMember` ✅ |
| POST | `/chats/{id}/remove-member/` | 200; тело `{"user_id": …}`; админ удаляет других, участник — себя; единственного админа удалить нельзя (400); опустевший чат удаляется | `Api.removeMember` |

`ChatViewSet.http_method_names = [get, post, patch, delete]` — PUT нет намеренно.

### WebSocket

| Endpoint | Назначение |
|----------|------------|
| `ws/chat/<uuid>/?token=<jwt>` | real-time одного чата (открыт, пока чат выбран) |
| `ws/notifications/?token=<jwt>` | личный канал: события по всем чатам, presence, ведёт `last_seen` |

Кадры канала чата (сервер → клиент) и обработка:

| Кадр | Payload | Обработка в клиенте |
|------|---------|---------------------|
| *(нет `type`)* | `{id, chat, sender{id,phone,first_name,last_name}, text, created_at, is_read}` | `addMessage` (дедуп по id, превью в списке) |
| `user_status` | `{user_id, status: online\|offline}` | `onlineUsers` add/remove → presence в шапке и на экране участников |
| `initial_presence` | `{user_ids: [...]}` — снимок при подключении | `onlineUsers` **заменяется** целиком |
| `messages_read` | `{reader_id}` — приходит и самому читателю | фильтр `reader_id == myUserId` → nothing; иначе `markAllRead()` только по своим (`№10`) |
| `{error: "..."}` | пустой текст, >5000 символов, анти-флуд 10/10 с | `sendError` → плашка; соединение остаётся живым (`№9`) |

Клиент → сервер: только `{"text": "..."}`.

Кадры личного канала:

| `type` | Payload | Обработка |
|--------|---------|-----------|
| `new_message` | `{chat, message, unread_count}` | открытый на переднем плане → 0 + `markRead`; иначе серверный `unread_count`; чата нет в списке → `loadChats()` |
| `chat_read` | `{chat}` | бейдж в 0 (прочитано на другом устройстве) |
| `chat_deleted` | `{chat}` | `removeChat` (закрывает чат, если это он) |
| `chat_renamed` | `{chat, name}` | `applyRename` |
| `member_removed` | `{chat}` | `removeChat` (нас исключили) |

В личный канал отправлять нечего: `receive()` — no-op.

Коды закрытия (важно: **все** перечисленные отказывают **до** `accept`, то есть клиент видит
сорванный HTTP-upgrade без WS-кода; `noReconnectCodes` на них не срабатывает и клиент выходит на
backoff-ретрай. WS-код виден только на закрытиях после accept — `member_removed`, `chat_deleted`,
обрыв сети. Невидимые отказы различает пробный `GET /users/me/` после 3 сорванных handshake —
раздел 4 и №16):

| Код | Причина | Реакция клиента |
|-----|---------|-----------------|
| 4001 | невалидный/просроченный JWT | не переподключаться; `onSessionExpired` → `popUntil` + `clearAll` + `logout(reason)` → экран входа |
| 4003 | не участник / исключён | не переподключаться, `removeChat`; плашка «Вы больше не участник чата» (маршрут остаётся — №30) |
| 4004 | чат удалён | не переподключаться, `removeChat`; плашка «Чат удалён» (там же — №30) |
| 4009 | кап одновременных соединений (5 на пользователя) | не переподключаться; оживляется из foreground (`revive`) |
| 4029 | частые подключения (>20/мин) | не переподключаться; оживляется из foreground |
| 403 (HTTP, не WS-код) | handshake отклонён `AllowedHostsOriginValidator` | исправлено: клиент шлёт `Origin` (№1) |

### Лимиты бэкенда

Превышение → HTTP 429 + `Retry-After`, тело `{"detail": "Request was throttled..."}` (по-английски,
`LANGUAGE_CODE = "en-us"`; показывается как есть).

| Scope | Лимит | Что задевает в клиенте |
|-------|-------|------------------------|
| `anon` | 120/мин на IP | вход/регистрация без токена |
| `user` | 600/мин на пользователя | все авторизованные запросы |
| `auth` | 10/мин на IP | `login`; лишний `login` после `register` убран (№14) |
| `register` | 5/мин на IP | регистрация |
| `send` | 60/мин | REST-фолбэк отправки |
| `read` | 120/мин | `markRead`: при открытии чата, при каждом возврате из фона и при каждом сообщении в открытом чате — коалесинга нет (№38 в разделе 10) |
| `write` | 30/мин | создание/переименование/удаление чата, add/remove участника |
| `search` | 20/мин | два места: поиск в новом чате и поиск кандидатов на экране участников — оба с дебаунсом 300 мс и отменой таймера (№8, №19) |
| `profile` | 20/мин | `PATCH /users/me/` (только на PATCH) |

WS-лимиты (`messenger/ratelimit.py`): сообщения 10/10 с → кадр `{error}` в тот же сокет;
подключения 20/60 с → 4029; не более 5 одновременных соединений на пользователя → 4009
(открытый чат + личный канал = 2 из 5). Backoff клиента держит частоту попыток ниже лимита (№29).

**`Origin` обязателен.** `config/asgi.py` оборачивает WS-роутер в `AllowedHostsOriginValidator`;
в `channels/security/websocket.py::OriginValidator.valid_origin` отсутствие заголовка = отказ,
если в `ALLOWED_HOSTS` нет `*`. Браузер шлёт `Origin` сам, `dart:io` — нет. Хост из `Origin` должен
входить в `ALLOWED_HOSTS` (`config/settings.py:8-14`, `10.0.2.2` там есть).

**Нюансы presence, которые клиент не обходит (ограничения бэкенда):**

- `user_status` анонсируется только на переходах 0→1 и 1→0, а `initial_presence` отдаётся
  подключившемуся. Поэтому у участника, добавленного в группу после того как мы открыли чат,
  точка будет «не в сети» до перезахода в чат;
- presence-счётчик живёт в Redis-хеше `messenger:presence` и переживает рестарт Daphne и
  `kill` эмулятора: фантомные значения способны выдать 4009 («один клиент держит чат — второй
  не грузит»). Это правка данных: `redis-cli hgetall messenger:presence`,
  `hdel messenger:presence <user_id>`;
- `chat_renamed` идёт только в личные каналы — в группе чата обработчика нет и не нужно,
  название берётся из элемента списка.

## 6. Соглашения кода

- UI-строки — по-русски, захардкожены (локализации нет); тексты ошибок от бэкенда — 429 по-английски,
  бизнес-ошибки по-русски; показываются как есть.
- Модели: обычные классы с `final`-полями и фабрикой `fromJson`, ключи JSON snake_case читаются
  напрямую, `copyWith` только там, где реально нужен. Ограничение: `copyWith` не умеет
  **сбрасывать** nullable-поля (`name ?? this.name`), поэтому «очистить превью» через него не делается
  (№39 в разделе 7). Codegen (`json_serializable`, `freezed`) не используется и не добавлять.
- Все сетевые вызовы должны идти через `Api` (синглтон), бизнес-логика — через
  `ChatState`/`AuthState`. Правило нарушено осознанно и давно: `new_chat_screen.dart`
  (`searchUsers`, `createPrivateChat`, `createGroupChat`) и `group_members_screen.dart`
  (`searchUsers`, `addMember`, `removeMember`) дёргают `Api` напрямую, минуя состояние
  (№37 — кандидат на перенос в `ChatState`).
- Ошибки сетевого слоя форматируются одинаково: `e is ApiException ? '<что>: ${e.message}' :
  '<что>: нет связи с сервером'` (в `ChatState` — `_describe`, в экранах пока своими руками).
- Нормализация телефона: бэкенд хранит только цифры и нормализует на входе, поэтому клиент
  отправляет телефон как введён (нормализация не нужна), а пустой телефон отсекает локально
  до запроса (`profile_screen.dart`).
- `DateTime.parse(...).toLocal()` — сервер отдаёт ISO-8601 со смещением; время в ленте и в списке
  форматируется вручную (`HH:mm`), `intl` не подключён.
- Асинхронность: `context.read<T>()` до первого `await`, `if (!mounted) return;` после каждого
  `await` перед любым использованием контекста (`use_build_context_synchronously`), таймеры
  (`Timer? _searchTimer`) отменяются в `dispose()`, контроллеры полей disposed там же.
- Одна запись в полёт: на каждое mutating-действие экрана ровно один флаг занятости
  (`_busy`, `_creating`, `_savingName`, `_deleting`, `_saving`), кнопка/строка с ним дизейблится.
- Линты — дефолтный `flutter_lints`; `analysis_options.yaml` исключает сгенерированные каталоги
  платформ. `flutter analyze` обязан быть чистым (0 замечаний, включая info-подсказки вроде
  `use_null_aware_elements` — они решаются, а не игнорируются). Стиль существующего кода
  (короткие строки с несколькими объявлениями, `catch (_) {}`) местами линтам не отвечает —
  не устраивать массовую чистку вместе с функциональной правкой.

## 7. Известные дефекты

Номера стабильные, новые проблемы заводятся под следующими номерами (№30+).
Строки указаны на текущее рабочее дерево (коммит `b36fdb7` + правки комментариев).

### Критичные (ломают основной сценарий)

1. **WS-handshake без `Origin` → 403.** ✅ `WsClient._handshake()` использует
   `IOWebSocketChannel.connect(uri, headers: {'Origin': 'http://<host>'})` (`ws.dart:120-123`).
   На web заголовки недоступны — см. №24.
2. **Порядок сообщений перевёрнут.** ✅ `.reversed` убраны из `_loadFirstPage` и
   `loadOlderMessages`: бэкенд отдаёт страницу по возрастанию времени.
3. **Статус соединения не обновлялся.** ✅ `onOpen?.call()` стоит сразу после
   `await _channel!.ready` (`ws.dart:138`), до `onReconnect`; `WsStatus.connected` ставится только
   когда handshake реально прошёл.
4. **Выход из аккаунта → пустой экран.** ✅ `_Boot` выбирает экран через `watch<AuthState>` в
   `build()`, ручная навигация с обеих сторон убрана; побочный хвост (запросы после logout) закрыт
   `ChatState.clearAll()`.
5. **Созданный чат не открывался.** ✅ `pushReplacement` на `ChatScreen` после `loadChats` +
   `selectChat`.
6. **Кнопка «удалить» рисовалась на себе.** ✅ Сравнение `m.user.id != auth.me?.id` + отдельная
   кнопка «Выйти из чата»; ошибка «единственного админа удалить нельзя» показывается как текст бэкенда.
7. **Выбор участников сбрасывался между поисками.** ✅ `_selected: Map<String, User>` (ключ — id):
   `User` не переопределяет `==`/`hashCode`, `Set<User>` не узнавал «того же человека», отсюда
   сброс чекбоксов и дубли в `member_ids` (400 на `validate_member_ids`).
8. **Поиск без отменяемого дебаунса.** ✅ `Timer? _searchTimer` + `cancel()` перед новым запросом и
   отмена в `dispose()`; то же теперь и на экране участников.

### Функциональные

9. **Кадры `{error: ...}` терялись.** ✅ В `_handleChatEvent` ветка `case null / case ''`:
   `event['error'] → sendError`, плашка в шапке чата, текст несообщённого сообщения остаётся в
   поле ввода (`chat_screen.dart:139-154`). Пустой текст, >5000 символов и анти-флуд 10/10 с
   теперь видны.
10. **`messages_read` обрабатывался грубо.** ✅ `reader_id` читается и своё прочтение отсекается;
    `markAllRead()` помечает прочитанными только сообщения `sender.id == myUserId`
    (`chat_state.dart:486-492, 512-519`). `myUserId` проставляется из `AuthState` подпиской в `main.dart`.
11. **Пагинация игнорировалась.** ✅ для истории / ⚠️ остаток для списка чатов.
    `Api.messages` возвращает `MessagePage(items, hasNext)`, `hasNext` берётся из `next`
    (`models/message.dart:36-47`), `hasMoreMessages = page.hasNext` в `_loadFirstPage`,
    `loadOlderMessages` и `reloadMessages`; дубли на границе страниц отсекаются по id.
    Список чатов по-прежнему всегда страница 1 → №33.
12. **Лента не прокручивалась к новому сообщению.** ✅ Автоскролл привязан к `messages.last.id`
    (`chat_screen.dart:358-366`), а не к `sent != null`; `ListView(reverse: true)` + `_onScroll`
    с направлением движения → дозагрузка старых не сбрасывает позицию; при открытии — `jumpTo(0)`,
    дальше — `animateTo(0, 200 ms)`. Совместно с E4/E5 (раздел 8).
13. **Системный «назад» не закрывал чат.** ✅ `PopScope(canPop: false)` +
    `onPopInvokedWithResult → _closeChat()` (`chat_screen.dart:368-374`); единый путь с крестиком.
    Осталось смежное: закрытие маршрута при внешнем удалении чата → №30.
14. **Регистрация делала лишний вход.** ✅ `Api.register` сохраняет пару JWT из ответа 201,
    `AuthState.register` больше не вызывает `login()`; устаревший комментарий в `api.dart`
    («Register возвращает токены?») заменён на верный.
15. **Ошибки глушились.** ✅ Закрыто полностью, кроме двух намеренно тихих веток (кривой JSON в
    `ws.dart`, `sendMessage` при мёртвом сокете). Плашки `sendError`/`loadError`/`detailsError`/
    `listError`/`_searchError`, `AuthState.error`, SnackBar через `onNotice`, `logout(reason)` после
    4001, `ApiException` вместо сырого `e.toString()`, «Соединение закрыто (код N)» на неизвестном коде.
16. **Нет обработки смены токена и сессии в живых сокетах.** ✅ `ensureFreshAccess()` перед
    handshake (парсит `exp`, с запасом 5 с), `_probeAuth()` после 3 сорванных handshake,
    `onSessionExpired` → `popUntil(isFirst)` + `clearAll()` + `logout(reason: 'Сессия истекла…')`.
    Фантомный кейс с presence-хешем — в разделе 5.

### Стабильность real-time (заводились попутно)

28. **Теряющиеся отправки при переподключении.** ✅ Флаг `_isOpen` (ставится после handshake,
    сбрасывается в `_handleClose`/`close`/`catch`), `isConnected => _isOpen`, `send()` бросает
    `StateError` → `sendMessage` уходит в REST.
29. **Reconnect-шторм сам себя запирал.** ✅ Экспоненциальный backoff 1→60 с + джиттер ±30%
    (`_scheduleReconnect`), счётчик неудач сбрасывается после успеха.

### Гигиена

17. **`test/widget_test.dart`.** ✅ Шаблонный тест со ссылкой на несуществующий `MyApp` заменён
    смоук-тестом: `setMockInitialValues({})` → `_Boot` → `LoginScreen` (тексты «Вход»/«Телефон»/
    «Пароль»). Покрытие — 1 тест, см. №35.
18. **Неиспользуемый импорт `dart:async`** в `chat_state.dart`. ✅ Удалён (ныне нужен в других
    местах: `dart:async` в `chat_screen.dart` для `Completer`, в экранах для `Timer`).
19. **Мёртвый код.** ✅ Выбран путь «удалять»; четыре метода из этого пункта **вернулись** вместе
    с UI: `Api.renameChat`, `Api.deleteChat`, `Api.addMember`, `ChatState.renameChat`,
    `ChatState.deleteChat`. По-прежнему удалено: поле `Me.lastSeen` (вернуться не может — см.
    раздел 9), пакет `intl`. `ChatState.onlineUsers` теперь используется по назначению (presence).
20. **Строковая типизация там, где есть enum.** ✅ `ChatType` в сравнениях типа чата,
    `WsStatus {connecting, connected, disconnected}` для статуса сокета.
25. **Устаревшие отображаемые имена.** ✅ `description` в `pubspec.yaml`, `android:label`,
    `CFBundleDisplayName`/`CFBundleName`, web-манифест и `<title>` — «Lost Dream Messenger».
    Идентификаторы сборки (`applicationId`, `namespace`, `PRODUCT_NAME`, `BINARY_NAME`, пути
    пакетов, ссылки на `.app`) осознанно не трогались: их переименование — перенос пакетов и
    перевыпуск артефактов, задача релизной подготовки. Хвост: `MaterialApp.title` — №36.

### Платформенные конфиги (открыты по согласованию — вне рамок паритета)

21. **Android**: `android/app/src/main/AndroidManifest.xml` без `INTERNET` (есть только в
    `src/debug/` и `src/profile/`) и без `usesCleartextTraffic`/`network_security_config` →
    release-сборка не выйдет в сеть. Проверено в этом дереве: `grep -c INTERNET` по main-манифесту = 0.
22. **macOS**: в `DebugProfile.entitlements` и `Release.entitlements` нет
    `com.apple.security.network.client` (в шаблоне Flutter он есть) → песочница блокирует исходящие.
    Проверено: совпадений нет.
23. **iOS**: в `ios/Runner/Info.plist` нет `NSLocalNetworkUsageDescription` — нужно для обращения к
    IP в локальной сети на iOS 14+. `10.0.2.2` работает только на эмуляторе Android. Проверено: нет.
24. **web**: цель нерабочая без правок бэкенда — `CORS_ALLOWED_ORIGINS` разрешает только
    `localhost:5173`/`127.0.0.1:5173`, браузерный `Origin` с порта Flutter-web не входит в
    `ALLOWED_HOSTS` (WS снова 403), а заголовки в `IOWebSocketChannel` на web недоступны в принципе.

### Безопасность и читаемость

26. JWT лежит открытым текстом в `SharedPreferences` (`lib/services/token_store.dart`); трафик —
    HTTP без TLS. Для прод-сборки нужен `flutter_secure_storage` (Keychain/Keystore) — это новая
    зависимость, поэтому в текущих рамках не делалось.
27. **Нормализация пустых строк читалась как ошибка приоритетов.** ✅ Запись вынесена в
    `_nullIfEmpty()` с явным `(value == null || value.isEmpty)` (`user.dart:4-5`), вызовы —
    `user.dart:25-27`.

### Остаток паритета с эталоном (открыты)

30. **Чат остаётся открытым «мёртвым» окном после внешнего удаления/исключения.**
    `_handleChatClose` при 4003/4004 делает `removeChat` → `closeChat`, то есть состояние снимается,
    но маршрут `ChatScreen` остаётся: пустая лента, неактивное поле ввода, непонятная плашка.
    В эталоне окно чата реагирует на смену `selectedChatId` (`ws !== socket`, `CLOSE_NOTICES` +
    `FORGET_CHAT_CODES` в `ChatWindow.vue`) и показывает empty-state вместо мёртвого окна.
    Здесь состояние живёт вне маршрута (раздел 3), поэтому экран обязан сам следить за
    `selectedChatId == null` и снимать маршрут. Частично закрыто на этом же месте: после выхода из
    группы `popUntil(isFirst)` больше не оставляет чат открытым.
31. **Нет индикатора состояния сокета в списке чатов.** Эталон: `ChatSidebar.vue` рисует точку +
    «на связи / подключение... / нет соединения» второй строкой под приветствием, но только когда
    чат выбран. Здесь `wsStatus` есть в состоянии и расходуется только в шапке чата.
32. **Непрочитанный чат не выделяется в списке.** Эталон: при `unread_count > 0` имя жирное и
    подсвечено, плюс круглый бейдж. Здесь (`_ChatTile`) только бейдж.
33. **Пагинация списка чатов.** `Api.listChats({int page = 1})` принимает страницу, но
    `ChatState.loadChats()` зовёт её без параметра → видно только первые 50 чатов, при этом
    `new_message` по неизвестному чату тоже зовёт `loadChats()` (первую страницу). В эталоне
    сайдбар так же ограничен первой страницей — то есть это паритетное ограничение, но не
    достаточность клиента: бэкенд отдаёт `next`, и он игнорируется.
34. **Конфиг окружения.** `AppConfig.host` — compile-time константа; смена хоста = правка кода.
    Перевод на `String.fromEnvironment` + `--dart-define=API_HOST=…` не сделан.
35. **Тестовое покрытие.** Один смоук-тест. Не покрыты: слияние в `reloadMessages`, фильтр
    `reader_id`, `hasMoreMessages` из `next`, error-кадры, «либо/либо» в `new_message`,
    presence-геттеры, права `canRenameChat`/`canDeleteChat`, `PopScope → closeChat`,
    дебаунс поиска, `WsClient` (backoff, `revive`, `_probeAuth`). CI нет.
36. **`MaterialApp.title` = «Мессенджер»** (`lib/main.dart:70`) — подпись в переключателе задач
    Android и `document.title` на web; расходится с «Lost Dream Messenger» в манифестах (хвост №25).

### Инженерные (не паритет, а долг)

37. **Экраны дёргают `Api` напрямую** (`new_chat_screen.dart`, `group_members_screen.dart`) вразрез
    с §6: бизнес-вызовы (поиск, создание чата, добавление/удаление участника) живут в виджете, а не
    в `ChatState`, поэтому их нельзя протестировать без дерева виджетов и они не видны в единой
    картине ошибок состояния.
38. **`markRead` без коалесинга**: вызывается при открытии чата, при каждом возврате из фона и при
    каждом сообщении в открытом чате → в активном групповом чате легко упереться в scope `read`
    (120/мин). В эталоне та же схема (`applyNewMessage → markRead`), поэтому это унаследованное
    поведение, а не регресс; лечится троттлингом/объединением в один отложенный вызов.
39. **`copyWith` не умеет сбрасывать nullable-поля** (`chat.dart:40-48`, `message.dart:25-28`):
    `lastMessage ?? this.lastMessage` означает, что «очистить превью» через модель невозможно.
40. **Защитная мёртвая ветка**: `isSelf` в `new_chat_screen.dart:300` не срабатывает —
    `/users/search/` исключает себя на бэкенде (`views.py:631`). Оставлена как зеркало эталона
    (там тот же guard), но она ложно документирует «клиент сам отсекает себя».

## 8. Паритет с веб-эталоном

Эталон — `frontend/` (Vue 3 + TS + Pinia + axios + `@vueuse/core`, composables `useChatSocket.ts` /
`useNotificationsSocket.ts`). Стек и модель жизненного цикла другие, поэтому соответствия
приходится переводить, а не копировать. Карта перевода (полезно при следующей правке):

| Эталон (веб) | Клиент (Flutter) | Комментарий |
|---|---|---|
| `document.visibilitychange`, `visibilityState === 'visible'` | `WidgetsBindingObserver.didChangeAppLifecycleState`, `ChatState.isForeground` | `inactive` не фон; `resumed` = фокус |
| `useDebounceFn(fn, 300)` | `Timer? _searchTimer` + `cancel()` | отмена обязательна: набор выжигает scope `search` |
| `onKeyStroke(Esc)` → `closeChat()` | `PopScope(canPop: false)` + `onPopInvokedWithResult` | цена — нет предпросмотра жеста; Esc у полей ввода заменён явной кнопкой ✕ |
| `watch(lastMessageId)` + `nextTick()` | сравнение `messages.last.id` в `build` + `Completer` на `addPostFrameCallback` (`_pumpFrame`) | до раскладки неизвестно, заполняет ли контент экран |
| `el.scrollTop = el.scrollHeight`, якорь `scrollTop += Δ scrollHeight` | `reverse: true` + `jumpTo(0)`/`animateTo(0)` | перевёрнутая лента якорится сама |
| `scrollTop < 100` и движение вверх | `pixels >= maxScrollExtent - 100` и `pixels > _lastPixels` | в reverse-ленте «верх экрана» = конец прокрутки |
| localStorage | `SharedPreferences` | см. №26 |
| `ChatSidebar.vue` (индикатор WS, жирное имя) | — | №31, №32 |
| пустой выбранный чат → empty-state | — | №30 |
| роутер + `requiresAuth` guard | `_Boot` + `watch<AuthState>` | маршруты поверх `_Boot` запрещены (№4) |
| `Pinia` stores | `ChangeNotifier` | `ChatState` ≈ `stores/chat.ts`, `AuthState` ≈ `stores/auth.ts` |
| `axios` interceptors (Bearer, retry на 401) | `Api._request` (`retryOn401`) | в эталоне retry запрещён для `AUTH_URLS` (`api.ts:17`); здесь то же: `auth: false` у login/register, а refresh — отдельный сырой `http.post` мимо `_request` |

### Осознанные отступления (E1–E6)

| # | Клиент | Эталон | Обоснование |
|---|--------|--------|-------------|
| E1 | backoff 1→60 с + джиттер ±30% | фиксированные 2 с | 30 попыток/мин > лимита 20/мин, 4029 приходит до accept → self-lock (№29) |
| E2 | `Api.ensureFreshAccess()` до handshake | токен из localStorage как есть | 4001 до accept не виден кодом, access живёт 60 мин (№16) |
| E3 | `_probeAuth()` после 3 сорванных handshake | — | отличить мёртвую сессию от сетевого сбоя; иначе вечное «подключение...» |
| E4 | `revive()` сокета **чата** при `resumed` | оживает только личный канал | ОС рвёт соединения спящего процесса, 4009 ∈ `noReconnectCodes`; плюс `onReconnect` добирает пропущенное |
| E5 | в цикле дозаполнения экрана — проверка «страница не пришла → break» | тот же цикл без проверки | без неё пустой/ошибочный ответ крутил бы запросы до упора в scope `read` |
| E6 | `_justOpened`/`_handledLastId` + `_syncing` re-entrancy guard | `isChatSwitch` + `nextTick` | в Flutter два кадра могут запустить два цикла дозагрузки одновременно |

Унаследованное от эталона ограничение (не правилось): новое сообщение всегда прокручивает ленту
вниз, даже если пользователь читает историю. Вариант «прилипать, только если уже у нижней
кромки» — правка сразу в обе реализации; в согласованный список не входил.

## 9. Что не реализовано (по сравнению с бэкендом и эталоном)

Из контракта бэкенда не востребовано:

- **пагинация списка чатов** (`next` в `GET /chats/`) — см. №33;
- **`last_seen`** — поле отдаётся только в `MeSerializer` (`/users/me/`), то есть про самого себя;
  для собеседника и участников группы этих данных в API нет, поэтому «был в сети …» нереализуемо
  без правки бэкенда. В эталонном Vue-клиенте этого тоже нет;
- `count`/`previous` пагинатора, `GET /docs/` и `/schema/` — не нужны клиенту;
- PUT `/chats/{id}/` — отсутствует на бэкенде намеренно.

Из поведения эталона не перенесено: №30 (empty-state вместо мёртвого окна), №31 (индикатор WS в
списке), №32 (подсветка непрочитанного). Остальное — в разделе 7.

Вообще не предусмотрено ни клиентом, ни бэкендом: оптимистичная отправка и очередь сообщений при
обрыве, «печатает…», пересылка, вложения (MEDIA_* на бэкенде заданы, но media не раздаётся),
редактирование/удаление отдельного сообщения, push-уведомления, локализация, поиск по истории,
темы (кроме seed Material 3), deep links, CI.

## 10. Технологический долг

По убыванию цены. Формат: что болит → чем это грозит → как чинится.

### A. Обязательное до любого релиза (блокеры выпуска)

1. **Платформенные конфиги №21–№24.** Release-сборка Android без `INTERNET` и без
   `usesCleartextTraffic` не выходит в сеть вообще; macOS без `com.apple.security.network.client`
   блокируется песочницей; iOS без `NSLocalNetworkUsageDescription` не говорит с LAN; web не
   работает в принципе (CORS + `ALLOWED_HOSTS` + невозможность `Origin` на web). Чинится правкой
   манифестов/entitlements (Android, macOS, iOS — по 1–3 строки, без кода) и решением по web:
   либо настраивать бэкенд (это уже вне правила «бэкенд не править»), либо официально объявить
   web неподдерживаемой целью и убрать из `README`.
2. **№26 — JWT открытым текстом + HTTP без TLS.** На реальном устройстве это читаемый дамп
   `SharedPreferences` и токен в clear-text в сети. Лечится `flutter_secure_storage` (новая
   зависимость — против §11, поэтому требует явного решения) и HTTPS/WSS.
3. **№35 — отсутствие тестов при ~3400 строк Dart (lib + test) и 20+ исправленных дефектах.** Сейчас регрессию
   ловит только `flutter analyze` и один смоук-тест. Это самая дорогая позиция: почти все закрытые
   дефекты (№3, №4, №7, №12, №13, №16, №28, №29) — регрессии поведения, которые можно было
   зафиксировать тестом. Минимальный набор: unit на `ChatState` (слияние в `reloadMessages`,
   `messages_read` с фильтром, `hasMoreMessages` из `next`, `{error}`-кадр, `new_message`
   «либо/либо», presence-геттеры, права), unit на `MessagePage`/`ChatListItem.fromJson`,
   widget на `PopScope → closeChat` и на дебаунс поиска, fake-transport вместо живого
   `Api`-синглтона (сейчас это упирается в №37: `Api` нельзя подменить).

### B. Архитектурный долг (мешает править, не мешает работать)

4. **`ChatState` — 740+ строк, один объект на всё** (списки, пагинация, merge, presence, права,
   оба сокета, обратные вызовы навигации). Любая правка чата требует знания всей картинки, а
   тестировать его без `Api`-синглтона нельзя. Направление: выписать `ChatRepository` (REST) и
   `WsSession` (управление сокетами) за интерфейсами, оставить `ChatState` витриной.
   Big-bang не нужен: достаточно одного нового класса-зависимости с конструктором по умолчанию.
5. **№37 — бизнес-вызовы в экранах.** `new_chat_screen` и `group_members_screen` дёргают `Api`
   напрямую, поэтому их ошибки живут в локальных `setState`-полях, а не в состоянии, и их нельзя
   покрыть unit-тестом. Перенос: `ChatState.searchUsers/addMember/removeMember/createPrivate/
   createGroup` + тесты.
6. **Состояние чата вне маршрута** (`selectedChatId` в глобальном стейте, `chatId` в конструкторе
   экрана — два источника истины). Порождает №30 и мешает реализовать «два открытых чата».
   Направление: экран слушает `selectedChatId` и снимается сам, либо `chatId` становится ключом
   всех выборок.
7. **`Api` — синглтон с `factory Api()`, `TokenStore` — статика.** Нет точки подмены
   (нет DI, нет fake-клиента) → пункт A3 упирается сюда же. Минимальная правка:
   `Api({http.Client? client})` и инъекция в `ChatState`.
8. **Нет модели маршрутов**: `Navigator.push` с `MaterialPageRoute` в пяти местах, `popUntil`
   вручную, deep links и state restoration нет. `go_router` запрещён (§11), поэтому решение —
   не фреймворк, а один файл-обёртка с именованными builder'ами, если число переходов вырастет.

### C. Поведенческий долг (видно пользователю, но не ломает сценарий)

9. **№30 / №31 / №32** — остаток паритета списка чатов и мёртвый маршрут. Дёшево: 1–2 плашки +
   слушатель `selectedChatId`.
10. **№38 — `markRead` без коалесинга**: риск 429 в активном групповом чате (120/мин).
    Лечится одним отложенным `Timer` на пачку.
11. **Автоскролл на каждое новое сообщение** (унаследовано от эталона) — мешает читать историю.
12. **№33 — список чатов ограничен 50** и молча: ни `next`, ни «показать ещё».
13. **Нет skeleton/empty-состояний кроме «Чатов пока нет»**: при `listError` список остаётся
    пустым под плашкой, при загрузке — пустой экран (не спиннер).
14. **№34 — хост в коде**: сборка под другое окружение = правка `lib/config.dart` и риск
    закоммитить локальный IP.

### D. Косметика и мелочи (не требовать, но знать)

15. **№36 — `MaterialApp.title` «Мессенджер»**; **№39 — `copyWith` не сбрасывает null**;
    **№40 — мёртвый guard `isSelf`**.
16. **Дублирование формата текстов ошибок** (`e is ApiException ? '…: ${e.message}' : '… нет связи'`)
    в пяти экранах вместо общего хелпера: при смене формулировки правка в пяти местах.
17. **Комментарии-номера дефектов в коде** (57 вхождений «дефект №N») — привязка к нумерации
    внешнего файла: при перенумерации ссылки устаревают и начинают врать. В этом дереве врали
    дважды — комментарии к №12/№13 утверждали, что дефект открыт (`chat_state.dart:303, :394`),
    и устарели ссылки на разделы/номера в `models/me.dart:3`, `chat_state.dart:74, :155`;
    всё поправлено этим проходом. Держать правило: в комментарии описано текущее состояние,
    а не только номер.

## 11. Правила для ассистентов

- Контракт сверять с исходниками бэкенда, а не с комментариями клиента — они уже расходились
  с реальностью (живой пример был в `api.dart:136`, см. №14).
- Поведение сверять с `frontend/` (раздел 8), но **не копировать код**: переносить решение с
  переводом под Flutter-модель (таблица соответствий — раздел 8). Отступления оформлять как E#
  с обоснованием.
- Бэкенд не править. Если клиент упирается в ограничение бэкенда (CORS, `ALLOWED_HOSTS`, `Origin`,
  лимиты, отсутствие `last_seen` у собеседника) — фиксировать в разделах 5 и 10 и спрашивать явно.
- Не добавлять codegen, DI-фреймворки и новые пакеты без явной необходимости: стек намеренно
  плоский (`http` + `provider` + ручной JSON). `go_router`/именованные маршруты не вводить попутно
  с функциональной правкой.
- Строки UI — по-русски.
- `flutter analyze` обязан оставаться чистым (включая info-подсказки), `flutter test` — passing.
  Новые `dynamic` и заглушки вместо типизации не вносить.
- Не устраивать массовую чистку стиля и линтов вместе с содержательной правкой.
- Каждый логический шаг — отдельный коммит; **коммиты и запуск приложения делает пользователь**
  (правило подтверждено в этой работе: «Не делай коммиты, оставь это мне, только код»).
  `flutter analyze`/`flutter test` — запускать можно и нужно.
- После любой правки дефекта: обновить его номер и статус в разделе 7, раздел 1 README,
  раздел 9 «Что не реализовано» и, если появилась новая открытая проблема, завести №41+.
  Статусы в коде и в этом файле должны сходиться в том же коммите.

## 12. Порядок работ, если доводить до production

1. ~~№1–№8~~ ✅, ~~№9–№14~~ ✅, ~~№15–№20~~ ✅, ~~№25, №27~~ ✅, ~~№28–№29~~ ✅,
   функциональные пробелы (presence, переименование, удаление, добавление участников) ✅.
2. **A1–A2 (раздел 10)**: манифесты целей (№21–№23), решение по web (№24) или официальное
   «не поддерживается», хранилище токена и TLS (№26).
3. **A3 (раздел 10)**: тесты на `ChatState` + `MessagePage` + `PopScope`, для чего сначала
   инъекция `Api` (B7) и вынос бизнес-вызовов из экранов (№37).
4. **C9–C10**: остаток паритета (№30–№32), коалесинг `markRead` (№38), пагинация списка (№33).
5. **B4–B6**: раскадровка `ChatState`, состояние чата в маршруте — по мере роста.
6. **D**: косметика (№36, №39, №40) — попутно, отдельными проходами.
7. Релизный канал (вне этого файла): переименование идентификаторов сборки, подпись,
   CI, prod-конфиг бэкенда (env вместо захардкоженных SECRET_KEY/DEBUG).
