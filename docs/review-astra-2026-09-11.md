# Повторное ревью и сравнение — 2026-09-11

Новый проход по текущим исходникам по запросу владельца; два независимых Sol
прохода по стандартам/спецификации и локальная проверка основным агентом.
Сравнивается с [предыдущим review](review-2026-09-11.md) и
[планом готовности](release-readiness-plan.md). Эти документы сохраняются как
история; данный отчёт уточняет выводы, но не изменяет код и продуктовые решения.

## Проверенное состояние

- Ветка `spec/v1.1-fixes`, HEAD `d3c9017a9d6176cdb4aea1c628a1e98415e061d1`,
  36 коммитов впереди origin; рабочее дерево с незакоммиченными 25/26/27.
- Рассмотрены текущее дерево, история/diff относительно `master` (`42017b2`),
  specs, lifecycle scripts, QML/JS wiring и Rust input/transport/shutdown.
- `./tools/run-tests.sh`: **276 test cases в десяти QML/JS suites**, 38 Rust
  tests, все проходят. Это число test cases (`T.test`), не число отдельных
  `T.equal` assertions. В прошлых ответах эти понятия смешивались.
- `cargo clippy --manifest-path daemon/Cargo.toml --all-targets -- -D warnings`
  проходит; `git diff --check` проходит.
- `bash /usr/share/omarchy/bin/omarchy-plugin-validate .` **завершается с 1**:
  `symlinks are not allowed inside a plugin folder: ./CLAUDE.md`.
  `git ls-files -s CLAUDE.md` подтверждает mode `120000` — это tracked symlink.
- Дополнительно выполнены две безопасные проверки production JS/wiring в Node:
  Recent/skin tone и paste target, без обращения к clipboard/compositor.
- Нового запуска VM integration и графического теста host не было.

## Итоговая оценка

Архитектурная основа сильная: reducer modifiers, явные configure generations,
claims и dedicated helper имеют понятные обязанности. Измерения на разных
клиентах и документирование keymap dead ends — ценная часть проекта.

Но вывод прошлого review «почти все слабости — maintainability/process,
а не correctness» слишком оптимистичен. Найдены две ошибки production wiring,
несмотря на зелёные тесты и предыдущие verdict `ship`. Проверка правильности
отдельной JS-функции не доказывает, что QML вызывает её с нужным аргументом или
вообще выбирает нужный маршрут.

Первая цель — закрыть эти ошибки, получить реальные UI/lifecycle gates и
воспроизводимую установку. Массовое разделение файлов до этого не обязательно.

## Spec: подтверждённые ошибки

### R1 — Recent показывает один оттенок, отправляет другой (P2)

Файлы: `EmojiPage.qml:420–425,535`, `Panel.qml:2020–2028`,
`EmojiPage.js:82–109`; требование — `spec-v1.1.md` §1: история сохраняет точную
последовательность. Номера строк относятся к данному снимку.

Recent использует основной grid delegate. Он всегда вызывает
`emojiChosen(modelData, true)`, включая исторические записи. `true` просит Panel
заново применить текущий skin tone. Header Most Frequent передаёт `false`.

Сценарий: вставить default `👍`, добиться, чтобы он находился в Recent (а не
Most Frequent), затем выбрать тёмный оттенок и нажать эту историческую плитку.
Она рисует `👍`, а delivery получает `👍🏿`. Уже тонированные записи не меняются,
поскольку `entryForTone` возвращает их без обработки; поэтому простые проверки
на ранее тонированном emoji скрывают дефект.

Проверка существующего production JS, загруженного в Node через `vm`:

```text
recentStored: 👍
selector: 🏿
productionGridHandler: onClicked: emojiRoot.emojiChosen(modelData, true)
entryForTone(recentStored, selector, Catalog.entries()): 👍🏿
```

Исправление: происхождение записи должно определять retone; история повторяет
точные данные, каталог применяет selector. Regression должен проверять реальный
выбор этого флага, а не только правильную работу `entryForTone()`.

### R2 — Paste при поиске emoji уходит во внешнее приложение (P1)

Файлы: `Panel.qml:380–419`; требование `spec-v1.1.md:27–29`: открытый поиск
picker — intended target, когда он является активным вводом.

`pasteCurrentContent()` выделяет только `hexEditing`. Для `emojiOpen` ветки
нет. После успешного probe вызывается `keyboard.pasteCurrent(clientClass)`.
OSK search показан через `Text`; он не получит этот внешний chord.

Проверены именно извлечённые из Panel функции `pasteCurrentContent` и
`finishClipboardPasteProbe`, с настоящим `ClipboardPaste.js`, подменёнными
Process/timer/input и `emojiOpen=true`. Результат:

```text
external paste chord: foot
refresh external clipboard preview
```

Это воспроизведение управляющей логики; реальная вставка во внешнее окно не
выполнялась. Важность выше косметической ошибки: действие направляется в другую
цель. Исправление: единое определение target (emoji search, colour input,
external client) перед выбором способа доставки. Локальный clipboard read тоже
нуждается в ограничении времени и защите от смены/закрытия target.

### Не объявлено ошибкой без уточнения требований

Независимый spec reviewer отметил, что при malformed `state.json` selector
оттенка и usage меняются в памяти, а `saveState()` отказывается записывать.
Это наблюдаемая неперсистентность, но §5 можно понимать как сохранение состояния
при неудачном reload, а не заморозку дальнейшего UI. Drag geometry ведёт себя
похоже, ошибка state уже видима. Нужно определить ожидаемое поведение;
категорического требования блокировать usage/history из этого review не следует.

Непрошеного расширения функциональности в проверенном scope не найдено.

## Standards и эксплуатационная готовность

### R3 — distributable plugin сейчас не проходит validator (release blocker)

Ошибка воспроизведена выше. Причина — tracked `CLAUDE.md` symlink; developer
symlinks также не должны попадать в публикуемое дерево. Простой commit текущего
дерева не устраняет дефект, а AUR сам по себе не решает регистрацию plugin.

До публикации нужен проверенный runtime payload и install/update/remove test
в чистой VM. Это уже было в lifecycle analysis и моём плане, но не вошло в
перечень release blockers документа `review-2026-09-11.md`.

### R4 — QML-check существенно уже, чем подразумевает «static clean»

`tools/qml-check.sh:43–53` возвращает успех при отсутствии инструмента/types;
строки 62–73 учитывают только текст `no matching signal found for handler`,
игнорируют exit code qmllint и перечисляют **только tracked** QML.
Следовательно, новый untracked `HoverTooltip.qml` этим проходом не проверяется.
Ограничение осознанно объяснено в самом скрипте; это не скрытый баг, но зелёный
результат нельзя трактовать как успешную загрузку production UI.

Следующий шаг: простой VM smoke загрузки настоящих Panel/Keyboard, плюс
проверки маршрутов R1/R2 через используемый QML interface. Не превращать все
известные ложные qmllint warnings в ошибки одним переключателем.

### R5 — политика exit status в unit не соответствует helper (P2)

`systemd/omarchy-osk.service:27` задаёт `RestartPreventExitStatus=78`, но
постоянные startup errors в `main.rs:2820–2870` возвращаются через `Result`
как exit 1. Exit 78 в текущем коде не используется. При неподдерживаемом
compositor/отсутствии seat/втором экземпляре срабатывают повторы до StartLimit.

Это несогласованный lifecycle contract, а не доказанный сбой обычного старта
на Hyprland. При packaging явно разделить временные ошибки подключения и
постоянные отказы, согласовать коды с unit, проверить сценарии в VM.

### Подтверждённые мелкие замечания предыдущего review

- **F5:** в `Keyboard.qml:1347–1371` остался dead list bare text errors после
  protocol 5. `text-err` обрабатывается раньше. Удаление — небольшая уборка.
- **F6:** `main.rs:2417–2418` принимает `hello garbage`/`helloxyz` как текущую
  версию через `unwrap_or(PROTOCOL_VERSION)`. Кроме того, fixed-arity verbs в
  `parse()` принимают лишние trailing arguments. Валидные version mismatches
  по-прежнему отвергаются; это не обход аутентификации (hello не auth).
  Строгая грамматика и табличные parser tests полезны, приоритет P3.

### Эвристики, а не доказанные hard violations

Большие файлы содержат несколько причин изменения, а delivery routes дублируют
части lift/swap/restore. Это хорошие кандидаты на выделение модулей.
Но `main.rs` содержит 2932 строки до `#[cfg(test)]` и около 1650 строк тестов;
цифру 4585 не следует целиком выдавать за production implementation.
Правило «800 max» не найдено в проверенных project instructions. Модельные
настройки Astra/Sol — явно записанный workflow, а `.scratch` deliberately ignored.
Они могут меняться по решению владельца, но сейчас не нарушают сами себя.

## Риски, требующие consumer/VM проверки

### F4: mutex нужен для атомарности, но длительность недооценена

`apply()` держит global mutex во время text transaction. Это защищает общий
virtual keyboard от вклинивания чужого configure/key между swap и restore.
Просто отпустить lock на время sleep нельзя: это разрушает защиту.

`text-unicode` спит примерно `(6 + число hex digits) × 10 ms` **на scalar**:
обычный supplementary emoji — около 110 ms, семья `👨‍👩‍👧‍👦` — около 740 ms,
16 пятизначных scalar — примерно 1.76 s только запланированных sleeps
(для допустимых protocol шестизначных кодов — 1.92 s). Compilation,
flush/roundtrip и scheduling добавляют время; это не верхняя latency guarantee.
Один panel client тоже ставит последующие commands в очередь за текущим text.
Поэтому фраза F4 «с одним клиентом невидимо» не обоснована.

При этом shutdown fallback завершает процесс через 500 ms после сигнала
(`main.rs:2910–2915`), пока graceful release может ждать mutex. Это не доказывает
залипшие клавиши: compositor может очистить удалённое устройство. Но обещание
graceful cleanup надо проверить сигналом посреди длинного ZWJ delivery.

Transient US map в Unicode route живёт заметно дольше 60 ms, описанных для
direct route в §39. Ввод физической клавиатурой/смена фокуса во время composition
нуждаются в отдельной проверке. Mutex helper не замораживает внешний compositor
и другие устройства.

### Изоляция held modifiers не одинакова у двух text routes

`deliver_text()` оставляет Ctrl/Alt/Super из `shared.held`, снимая только
мешающие level bits; `deliver_unicode_text()` снимает все held keys. При двух
protocol clients сценарий `A: down LCTL`, `B: text 🙂` может подавить текст или
вызвать shortcut. Какая именно реакция будет — проверить в named consumer.
Обычный **latched** Ctrl на панели не равен физическому `down LCTL`, поэтому
утверждать тот же баг от одного latch click нельзя.

Это аргумент для общего transaction interface с явной modifier policy, когда
затрагивается delivery; не для слепого переноса функции в другой файл.

## Сравнение с review-2026-09-11.md

| Пункт | Оценка свежего прохода |
|---|---|
| F1 uncommitted work | Commit важен, но «critical» завышено. Commit на том же диске не backup; `git checkout .` не удаляет untracked files. |
| F2 line limits/split now | Модули нужны, но ограничение 800 не подтверждено. Стоимость split заранее не измерена; разумнее начать с конкретного seam. |
| F3 comments | Часть comments уже НЕ точна: `sendText` описывает старые replies. Сначала исправить ложные контракты, затем сокращать дубли. |
| F4 mutex | Факт верен; добавлены длительность ZWJ, shutdown interaction и необходимость сохранить atomicity. |
| F5 dead errors | Подтверждено; небольшая уборка. |
| F6 hello | Подтверждено; добавить проверку trailing arguments. |
| F7 README | Устаревшие формулировки есть. Предупреждение WIP и installer с autostart логически совместимы; менять по реальным gates. |
| F8 vendor-specific workflow | Рекомендация переносимости, не release blocker. Нельзя молча отменять явные owner model preferences. |
| F9 local board | Риск переноса/backup реальный; versioning выбран сознательно. Достаточно сохранять durable specs/handoff и настроить backup. |
| F10 “fine” | Правильные проверки механики не доказывают отсутствие других дефектов. FIFO replies сами по себе не определяют нужный UI target/session. |
| Порядок работ | Уборка → массовый refactor → acceptance откладывает проверку поведения слишком далеко. Нужны ранние R1/R2/VM/load gates. |

Новый документ лучше моего первого общего review конкретикой F4–F6 и перечнем
кандидатов для модулей. Мой `release-readiness-plan.md` полнее сохраняет owner
feedback, Proton, packaging/validator и разделение предложений от утверждённых
решений. Оба прежних документа пропустили R1/R2; именно их нужно добавить
к ближайшей реализации.

## Рекомендуемый следующий порядок

1. Сверить dirty tree, записать реальные статусы и сохранить checkpoint с assets.
   Не заставлять сложную ручную staging-разбивку создавать неработающие commits.
2. Исправить R1 — точное повторение Recent и R2 — paste target. Regression должен
   пересекать production seam выбора поведения. Независимое review.
3. VM: загрузка UI, clipboard live/dead, popup/mouse; затем owner acceptance.
4. Delivery: измерить длинный Unicode ввод, release/shutdown, physical typing и
   target changes. После этого проектировать Proton compatibility с владельцем.
5. Подготовить проверенный plugin payload и package lifecycle; классифицировать
   startup errors; небольшие parser fixes допустимо сделать раньше.
6. Разделять по одному модулю там, где тест фиксирует контракт. Один большой
   structural rewrite не является обязательным условием первого release.

Исходники в этом проходе не исправлялись; коммиты, push, установка helper и
перезапуск shell не выполнялись. Новые факты не закрывают старые человеческие
gates автоматически.
