# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

BackupFlow — нативное menu-bar-first приложение для macOS на Swift/SwiftUI (с AppKit-мостами там, где SwiftUI недостаточно). Это обёртка над системным `rsync`: полное зеркалирование диска или синхронизация выбранных папок, с песочницей (App Sandbox), security-scoped bookmarks и без какой-либо сети/бэкенда — вся логика локальная.

- Target: `BackupFlow` (единственный target приложения, тип `com.apple.product-type.application`)
- Минимальная версия macOS: **15.0** (`MACOSX_DEPLOYMENT_TARGET` в `.xcodeproj`; `Package.swift` также заявляет `.macOS(.v15)`)
- Swift: `swift-tools-version: 6.0` в `Package.swift` и `SWIFT_VERSION = 6.0` в `.xcodeproj` — строгая concurrency-проверка Swift 6 включена в обеих сборках. Код использует `@concurrent` (Swift 6.2+), поэтому нужен Xcode 26+.
- UI: SwiftUI (основной слой) + точечный AppKit (`NSAlert`, `NSApp`, `NSWindow`, `NSWorkspace`) там, где SwiftUI не даёт нужного контроля.
- Тесты: XCTest, только в `Tests/BackupFlowTests/` (SwiftUI/UI-тестов нет).
- Линтеры/форматтеры: в проекте не настроены ни SwiftLint, ни SwiftFormat (конфигов не найдено). Не добавляй их самостоятельно без явного запроса — просто следуй существующему стилю кода.

Перед изменением кода необходимо изучить структуру проекта, связанные файлы, существующую архитектуру и текущие тесты.

## Architecture overview

**Двойная система сборки — это главная ловушка проекта:**
- `Package.swift` (SPM) — используется для быстрой разработки и **это единственный способ запускать тесты** (`swift test`). Компилирует голый исполняемый файл, без `.app`-бандла, entitlements, Info.plist или иконки.
- `BackupFlow.xcodeproj` — используется для сборки реального подписанного `.app` (entitlements, `Info.plist`, `Assets.xcassets`, App Sandbox). Схема `BackupFlow` **не имеет привязанного test target** (`TestAction` в `.xcscheme` пуст) — `xcodebuild test` на этом проекте гарантированно упадёт с `Scheme BackupFlow is not currently configured for the test action`. Для тестов используй только `swift test`.
- Членство файлов в `.xcodeproj` прописано явно (`PBXFileReference`/`PBXBuildFile`, не synchronized groups). Значит: новый `.swift`-файл в `Sources/BackupFlow/` подхватится `swift build`/`swift test` автоматически (SPM обходит директорию целиком), но **не попадёт в реальный `.app`**, пока не будет добавлен в target `BackupFlow` через сам Xcode (или вручную в `project.pbxproj`). Если добавляешь новый файл — не забудь про этот шаг и скажи о нём пользователю, если правишь `project.pbxproj` руками.

**Форма приложения:**
- `BackupFlowApp.swift` — `@main App`. Два поверхностных UI: `MenuBarExtra` (основной интерфейс, `LSUIElement = true` → без иконки в Dock) и вспомогательное `WindowGroup(id: "main")` с полноразмерным окном настроек. Оба получают один и тот же `@MainActor final class BackupViewModel: ObservableObject` через `.environmentObject`.
- `ViewModels/BackupViewModel.swift` (~1250 строк) — де-факто «мозг» приложения: почти всё состояние (`@Published`), логика подтверждения удалений (deletion guard), расписание, диск-watchdog, восстановление bookmarks. Самый большой и самый чувствительный к побочным эффектам файл в проекте — учитывай это при любых кросс-катующих изменениях состояния.
- `Views/*` — чисто презентационный слой, состояние не хранят.

**Синхронизация:**
- `Services/SyncEngine.swift` — `actor`, оборачивающий `Process()` для запуска `rsync`, парсит byte-stream stdout в реальном времени для прогресса. Флаги rsync и причины, почему конкретные флаги **не** используются (`--extended-attributes`, `--delete-excluded`), задокументированы прямо над `baseFlags` — прочитай этот комментарий перед тем, как трогать флаги rsync, это не пустая предосторожность, а следствие реальных инцидентов.
- Чистая, легко тестируемая логика вынесена в `static`-функции на `SyncEngine` (`outcome(forExitCode:)`, `parseTotalTransferredBytes`, `parseDeletionPaths`, `weightedProgress`) — новую подобную логику стоит писать в том же стиле (чистая функция + unit-тест), а не встраивать в `Process`-код.
- `Services/BookmarkManager.swift` — security-scoped bookmarks для персистентного доступа к дискам между запусками (App Sandbox).
- `Services/SyncHistoryManager.swift` — `@MainActor`-синглтон, хранит даты последней синхронизации в `UserDefaults`; намеренно чистится, когда пользователь выбирает **другой** диск (сравнение по volume UUID в `recordSelectedVolume` в `BackupViewModel`), чтобы не показывать устаревшие даты для другого диска. При извлечении/переподключении того же диска история сохраняется — не возвращай очистку в `didSet` у `mainDriveURL`/`secondaryDriveURL`, они срабатывают и на unmount.

## General development rules

- Сначала анализируй существующий код, затем предлагай изменения.
- Перед сложной задачей составляй краткий план.
- Не изменяй несвязанные файлы.
- Не переписывай рабочий код без необходимости.
- Не добавляй зависимости без объяснения причины.
- Предпочитай стандартные Apple API и системные фреймворки.
- Используй простую, читаемую и поддерживаемую архитектуру.
- Следуй стилю и соглашениям, уже используемым в проекте.
- Не дублируй существующую логику.
- Не оставляй закомментированный или неиспользуемый код.
- Не скрывай ошибки с помощью бездумного использования `try?`, force unwrap или force cast.
- Не игнорируй compiler warnings.
- Не меняй публичные интерфейсы без необходимости.
- Не утверждай, что задача завершена, пока проверки фактически не выполнены.

## Swift and SwiftUI

- Используй современные Swift и SwiftUI API, совместимые с минимальной версией macOS проекта (15.0+).
- Учитывай Swift 6 и правила строгой concurrency — проект уже это делает (`SyncEngine` — `actor`, `BackupViewModel`/`SyncHistoryManager` — `@MainActor`).
- Правильно используй `@MainActor`, `async/await`, actors и `Sendable`.
- Не выполняй тяжёлые операции на главном потоке.
- Не создавай лишние Observable-объекты и глобальное состояние.
- Разделяй представление, состояние и бизнес-логику.
- Учитывай светлую и тёмную тему.
- Проверяй корректность состояний загрузки, пустого состояния и ошибок.
- Используй AppKit только там, где SwiftUI действительно недостаточно (проект уже так делает — см. `Extensions/NSAlert+Extension.swift`).

## Testing rules

- Для каждого нетривиального изменения добавляй или обновляй тесты.
- При исправлении бага сначала создай regression test.
- Проверяй обычные, граничные и ошибочные сценарии.
- Не тестируй детали реализации без необходимости.
- Проект построен на XCTest (`Tests/BackupFlowTests/`) — используй его, а не Swift Testing.
- Не удаляй существующие тесты для устранения ошибки сборки.
- После изменения тестов запускай соответствующий набор тестов через `swift test` (см. раздел «Команды проверки» — `xcodebuild test` на `.xcodeproj` не работает, см. Architecture overview).

## Required validation

После каждого существенного изменения:

1. Проверь изменённый код.
2. Собери проект (`swift build`, и `xcodebuild ... build`, если менялось что-то, влияющее на `.app`-бандл — entitlements, Info.plist, ассеты).
3. Запусти релевантные unit-тесты (`swift test`).
4. UI-тестов в проекте нет — этот пункт неприменим, пока они не появятся.
5. Проверь compiler warnings.
6. SwiftLint/SwiftFormat в проекте не настроены — этот пункт неприменим, пока их не добавят явным запросом.
7. Проведи review итогового diff.
8. Проверь, что не изменены несвязанные файлы — в частности, что новый `.swift`-файл (если добавлялся) действительно добавлен в target `BackupFlow` в `.xcodeproj`, а не только виден через SPM.

Сначала используй минимальную проверку, затем полный набор проверок.

## Error handling

При обнаружении ошибки:

1. Воспроизведи её.
2. Определи минимальный сценарий воспроизведения.
3. Найди вероятную причину.
4. Добавь regression test.
5. Исправь проблему минимальным изменением.
6. Повтори сборку и тесты.
7. Укажи, что именно было проверено.

## Final response format

В конце каждой задачи сообщай:

- что было изменено;
- какие файлы изменены;
- какие команды проверки выполнены;
- результат каждой команды;
- какие warnings или проблемы остались;
- что не удалось проверить и почему.

## Команды проверки

Список схем/таргетов:
```bash
xcodebuild -list -project BackupFlow.xcodeproj
```

Сборка (SPM, быстрая, для разработки и тестов):
```bash
swift build
```

Если `swift build`/`swift test` падает на `CodeSign … BackupFlow_BackupFlow.bundle` с `resource fork, Finder information, or similar detritus not allowed` — это не код: проект лежит в `~/Documents`, синхронизируемой iCloud, и File Provider вешает `com.apple.FinderInfo` на каталоги внутри `.build`. Собирай с build-каталогом вне iCloud (то же для `swift test`):
```bash
swift build --scratch-path ~/Library/Caches/BackupFlow-spm
```

Сборка реального `.app` (Xcode-проект, с entitlements/Info.plist/ассетами):
```bash
xcodebuild -project BackupFlow.xcodeproj -scheme BackupFlow -configuration Debug build
```

Все тесты (единственный рабочий способ — см. Architecture overview):
```bash
swift test
```

Один тестовый класс:
```bash
swift test --filter SyncEngineOutcomeTests
```

Один тест:
```bash
swift test --filter SyncEngineOutcomeTests/testExitCodeZeroIsSuccess
```

`xcodebuild test -project BackupFlow.xcodeproj -scheme BackupFlow` **не используй** — падает с `Scheme BackupFlow is not currently configured for the test action`, потому что тестовый target не привязан к схеме.
