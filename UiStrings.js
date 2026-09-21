.pragma library

// The UI string table (ticket 52): every word the panel draws as chrome —
// tooltips, accessible names, settings labels and hints, status lines —
// lives here behind an id, carried in the three languages we ship. The
// panel's QML holds no English of its own; what it draws is
// UiStrings.tr(id, lang). Keymap-derived text (cap glyphs, layout titles,
// the catalogue's emoji names) is data, not chrome, and never passes
// through here.
//
// The language is the ACTIVE LAYOUT with an override on top — the
// searchPlaceholder mechanism (EmojiPage.js, ticket 36) generalised:
// "auto" (the default) answers uk for a ua layout, ru for ru, English
// for everything else, and the settings row pins en/ru/uk regardless of
// the layout. A language we do not ship reads as English rather than a
// guess, exactly like the placeholder always did for a custom code.
//
// The table is data and fails loudly: an id that is absent or empty
// throws, so a typo'd call site dies in the offscreen suite
// (tests/ui-strings.qml resolves every UiStrings.tr("…") literal in the
// QML) instead of rendering a blank at first hover in production.
// Substitution is Qt's qsTr idiom — "%1", "%2" filled in order.

var LANGUAGES = ["en", "ru", "uk", "it"]

var STRINGS = {
    // ---- the header's status lines (spec-v1.1 §6) ----
    "hint.clipboardGone": {
        en: "Clipboard content is no longer available",
        ru: "Содержимое буфера обмена больше недоступно",
        uk: "Вміст буфера обміну більше недоступний",
        it: "Il contenuto degli appunti non è più disponibile"
    },
    "hint.pickRefused": {
        en: "Too many picks in a row — try again in a moment",
        ru: "Слишком много быстрых выборов — попробуйте ещё раз через мгновение",
        uk: "Забагато швидких виборів — спробуйте ще за мить",
        it: "Troppe scelte di fila — riprova tra un istante"
    },
    "hint.pickFailed": {
        en: "The pick did not go through — try again in a moment",
        ru: "Выбор не прошёл — попробуйте ещё раз через мгновение",
        uk: "Вибір не пройшов — спробуйте ще за мить",
        it: "La scelta non è andata a buon fine — riprova tra un istante"
    },
    "hint.pasteBusy": {
        en: "Paste did not start — try again in a moment",
        ru: "Вставка не началась — попробуйте ещё раз через мгновение",
        uk: "Вставка не почалася — спробуйте ще за мить",
        it: "Incolla non è partito — riprova tra un istante"
    },
    "hint.langMenuBlocked": {
        en: "Close the open page first — then switch language",
        ru: "Сначала закройте открытую страницу — потом смените язык",
        uk: "Спочатку закрийте відкриту сторінку — потім змініть мову",
        it: "Chiudi prima la pagina aperta — poi cambia lingua"
    },
    "hint.needsUpdate": {
        en: "oskar.service needs updating",
        ru: "oskar.service требует обновления",
        uk: "oskar.service потребує оновлення",
        it: "oskar.service va aggiornato"
    },
    "hint.notRunning": {
        en: "oskar.service is not running",
        ru: "oskar.service не работает",
        uk: "oskar.service не запущено",
        it: "oskar.service non è in esecuzione"
    },
    "hint.keymapUnavailable": {
        en: "Keymap unavailable — drawn caps may not match what typing produces",
        ru: "Раскладка недоступна — нарисованные клавиши могут не совпадать с тем, что вводится",
        uk: "Розкладка недоступна — намальовані клавіші можуть не збігатися з тим, що вводиться",
        it: "Layout non disponibile — i tasti disegnati potrebbero non corrispondere a ciò che viene digitato"
    },
    "hint.shareFailed": {
        en: "Layout sync with the compositor failed — apps may flip layouts until the next switch",
        ru: "Не удалось синхронизировать раскладку с композитором — в приложениях раскладка может сбиваться до следующего переключения",
        uk: "Не вдалося синхронізувати розкладку з композитором — у застосунках розкладка може збиватися до наступного перемикання",
        it: "Sincronizzazione del layout con il compositor non riuscita — le app potrebbero cambiare layout fino al prossimo cambio"
    },
    "hint.saveFailed": {
        en: "Settings were not saved — check free space and permissions",
        ru: "Настройки не сохранены — проверьте свободное место и права",
        uk: "Налаштування не збережено — перевірте вільне місце та права",
        it: "Impostazioni non salvate — verifica spazio e permessi"
    },
    "banner.deps.fetching": {
        en: "Fetching missing components\u2026",
        ru: "Получаю недостающие компоненты\u2026",
        uk: "Отримую відсутні компоненти\u2026",
        it: "Recupero i componenti mancanti…"
    },
    "banner.deps.missing": {
        en: "Missing input components",
        ru: "Не хватает компонентов ввода",
        uk: "Бракує компонентів вводу",
        it: "Componenti di input mancanti"
    },
    "banner.deps.busy": {
        en: "Busy\u2026",
        ru: "Занято\u2026",
        uk: "Зайнято\u2026",
        it: "Occupato…"
    },
    "banner.deps.setup": {
        en: "Set up",
        ru: "Настроить",
        uk: "Налаштувати",
        it: "Configura"
    },
    "color.slider.hue": {
        en: "Hue",
        ru: "Тон",
        uk: "Тон",
        it: "Tonal"
    },
    "color.slider.sat": {
        en: "Sat",
        ru: "Нас",
        uk: "Нас",
        it: "Satur"
    },
    "color.slider.val": {
        en: "Val",
        ru: "Ярк",
        uk: "Яскр",
        it: "Lum"
    },
    "color.slider.red": {
        en: "Red",
        ru: "Красн",
        uk: "Черв",
        it: "Ross"
    },
    "color.slider.green": {
        en: "Green",
        ru: "Зел",
        uk: "Зелен",
        it: "Verd"
    },
    "color.slider.blue": {
        en: "Blue",
        ru: "Син",
        uk: "Син",
        it: "Blu"
    },
    "hint.starting": {
        en: "Starting oskar.service…",
        ru: "Запуск oskar.service…",
        uk: "Запуск oskar.service…",
        it: "Avvio di oskar.service…"
    },

    // ---- the header's action chips ----
    "action.copy": {
        en: "Copy",
        ru: "Копировать",
        uk: "Копіювати",
        it: "Copia"
    },
    "action.retry": {
        en: "Retry",
        ru: "Повторить",
        uk: "Повторити",
        it: "Riprova"
    },

    // ---- bar chrome ----
    "tooltip.settings": {
        en: "Settings",
        ru: "Настройки",
        uk: "Налаштування",
        it: "Impostazioni"
    },
    "tooltip.closeKeyboard": {
        en: "Close keyboard",
        ru: "Закрыть клавиатуру",
        uk: "Закрити клавіатуру",
        it: "Chiudi la tastiera"
    },
    "tooltip.paste": {
        en: "Paste clipboard",
        ru: "Вставить из буфера",
        uk: "Вставити з буфера",
        it: "Incolla dagli appunti"
    },
    "access.paste": {
        en: "Paste",
        ru: "Вставить",
        uk: "Вставити",
        it: "Incolla"
    },
    // %1 is the layout's own title (keymap data, never translated here).
    "access.currentLayout": {
        en: "%1 (current)",
        ru: "%1 (текущая)",
        uk: "%1 (поточна)",
        it: "%1 (corrente)"
    },
    "access.switchTo": {
        en: "Switch to %1",
        ru: "Переключить на %1",
        uk: "Перемкнути на %1",
        it: "Passa a %1"
    },

    // ---- the settings card ----
    "settings.title": {
        en: "Settings",
        ru: "Настройки",
        uk: "Налаштування",
        it: "Impostazioni"
    },
    "settings.section.mode": {
        en: "MODE",
        ru: "РЕЖИМ",
        uk: "РЕЖИМ",
        it: "MODALITÀ"
    },
    "settings.row.mode": {
        en: "Mode",
        ru: "Режим",
        uk: "Режим",
        it: "Modalità"
    },
    "mode.chip.tooltip": {
        en: "Toggle docked / floating",
        ru: "Закреплённая / плавающая",
        uk: "Закріплена / плаваюча",
        it: "Ancorata / flottante"
    },
    "settings.mode.docked": {
        en: "Docked",
        ru: "Закреплена",
        uk: "Закріплена",
        it: "Ancorata"
    },
    "settings.mode.floating": {
        en: "Floating",
        ru: "Плавающая",
        uk: "Плаваюча",
        it: "Flottante"
    },
    "settings.section.size": {
        en: "SIZE",
        ru: "РАЗМЕР",
        uk: "РОЗМІР",
        it: "DIMENSIONE"
    },
    "settings.row.size": {
        en: "Size",
        ru: "Размер",
        uk: "Розмір",
        it: "Dimensione"
    },
    // Ticket 52's own row: the override this whole module hangs off.
    // The segment labels beside it are language endonyms (English,
    // Русский, Українська) and stay fixed — a chooser's entries name
    // themselves, whatever the UI is speaking.
    "settings.section.language": {
        en: "LANGUAGE",
        ru: "ЯЗЫК",
        uk: "МОВА",
        it: "LINGUA"
    },
    "settings.row.language": {
        en: "Interface language",
        ru: "Язык интерфейса",
        uk: "Мова інтерфейсу",
        it: "Lingua dell'interfaccia"
    },
    "settings.lang.auto": {
        en: "Auto",
        ru: "Авто",
        uk: "Авто",
        it: "Auto"
    },

    // ---- the input profile (ticket 58) ----
    //
    // The row's three segments share the language row's fixed-width
    // discipline: the widest translated label ("Сенсор") measures 43px at
    // fontBody in the mono face, inside the 43.3px slice a 150-unit
    // three-way control gives (pinned offscreen in tests/input-profile.qml).
    "settings.section.input": {
        en: "INPUT",
        ru: "ВВОД",
        uk: "ВВЕДЕННЯ",
        it: "INPUT"
    },
    "settings.row.inputProfile": {
        en: "Pointer profile",
        ru: "Профиль ввода",
        uk: "Профіль введення",
        it: "Profilo di input"
    },
    "settings.profile.autoTouch": {
        en: "Auto+touch",
        ru: "Авто+тач",
        uk: "Авто+тач",
        it: "Auto+tatt"
    },
    "settings.profile.auto": {
        en: "Auto",
        ru: "Авто",
        uk: "Авто",
        it: "Auto"
    },
    "settings.profile.mouse": {
        en: "Mouse",
        ru: "Мышь",
        uk: "Мишка",
        it: "Mouse"
    },
    "settings.profile.touch": {
        en: "Touch",
        ru: "Сенсор",
        uk: "Сенсор",
        it: "Tattile"
    },
    "settings.section.emoji": {
        en: "EMOJI PAGE",
        ru: "СТРАНИЦА ЭМОДЗИ",
        uk: "СТОРІНКА ЕМОДЗІ",
        it: "PAGINA EMOJI"
    },
    "settings.row.emojiPicking": {
        en: "Emoji picking",
        ru: "Выбор эмодзи",
        uk: "Вибір емодзі",
        it: "Scelta emoji"
    },
    // The pair names the behaviour after a pick, short enough for the
    // 70px segments the two-way control slices ("Оставить" is 58px at
    // fontBody; "Оставлять открытой" would not fit).
    "settings.emoji.keepOpen": {
        en: "Keep open",
        ru: "Оставить",
        uk: "Залишити",
        it: "Lascia"
    },
    "settings.emoji.close": {
        en: "Close",
        ru: "Закрыть",
        uk: "Закрити",
        it: "Chiudi"
    },
    "settings.row.emojiPageSize": {
        en: "Emoji page size",
        ru: "Размер страницы эмодзи",
        uk: "Розмір сторінки емодзі",
        it: "Dimensione pagina emoji"
    },
    "settings.section.superMark": {
        en: "SUPER MARK",
        ru: "МЕТКА SUPER",
        uk: "МІТКА SUPER",
        it: "MARCA SUPER"
    },
    "settings.row.superMark": {
        en: "Super mark",
        ru: "Метка Super",
        uk: "Мітка Super",
        it: "Marca Super"
    },
    // Omarchy, Windows and macOS are names; the word and the penguin
    // are ours to say.
    "settings.superMark.word": {
        en: "Word",
        ru: "Слово",
        uk: "Слово",
        it: "Parola"
    },
    "settings.superMark.penguin": {
        en: "Penguin",
        ru: "Пингвин",
        uk: "Пінгвін",
        it: "Pinguino"
    },
    "settings.section.sound": {
        en: "SOUND",
        ru: "ЗВУК",
        uk: "ЗВУК",
        it: "SUONO"
    },
    "settings.row.sound": {
        en: "Key click sound",
        ru: "Звук нажатия",
        uk: "Звук натискання",
        it: "Suono del tasto"
    },
    "settings.sound.unavailable": {
        en: "unavailable",
        ru: "недоступен",
        uk: "недоступний",
        it: "non disponibile"
    },
    "settings.section.theme": {
        en: "THEME",
        ru: "ТЕМА",
        uk: "ТЕМА",
        it: "TEMA"
    },
    "settings.row.followTheme": {
        en: "Follow Omarchy theme",
        ru: "Следовать теме Omarchy",
        uk: "Слідувати темі Omarchy",
        it: "Segui il tema Omarchy"
    },
    "settings.section.dwell": {
        en: "DWELL",
        ru: "ЗАДЕРЖКА",
        uk: "ЗАТРИМКА",
        it: "SOSTA"
    },
    "settings.row.dwellTyping": {
        en: "Dwell typing",
        ru: "Ввод по задержке",
        uk: "Ввід із затримкою",
        it: "Digitazione per sosta"
    },
    "settings.row.dwellDelay": {
        en: "Dwell delay",
        ru: "Задержка ввода",
        uk: "Затримка вводу",
        it: "Ritardo della sosta"
    },
    "settings.hint.dwellDelay": {
        en: "Rest a key this long to type it; resting past the type opens its hold-column menu",
        ru: "Сколько указатель должен покоиться на клавише, чтобы нажать её; дальнейший покой открывает меню удержания",
        uk: "Скільки вказівник має спокоюватися на клавіші, щоб натиснутися; триваліший спокій відкриває меню утримання",
        it: "Quanto a lungo il puntatore deve restare su un tasto per premerlo; restare oltre apre il menu di pressione"
    },
    "settings.section.appearance": {
        en: "APPEARANCE",
        ru: "ВНЕШНИЙ ВИД",
        uk: "ВИГЛЯД",
        it: "ASPETTO"
    },
    "settings.hint.followingOn": {
        en: "Following the Omarchy theme — an override pins its own field",
        ru: "Следует теме Omarchy — переопределение закрепляет только своё поле",
        uk: "Слідує темі Omarchy — перевизначення закріплює лише своє поле",
        it: "Segue il tema Omarchy — una personalizzazione fissa solo il proprio campo"
    },
    "settings.hint.followingOff": {
        en: "Theme following is off — appearance holds the look it had",
        ru: "Следование теме отключено — вид остаётся прежним",
        uk: "Слідування темі вимкнено — вигляд лишається незмінним",
        it: "Seguire il tema è disattivato — l'aspetto resta com'era"
    },
    "settings.row.keyRadius": {
        en: "Key radius",
        ru: "Радиус клавиш",
        uk: "Радіус клавіш",
        it: "Raggio dei tasti"
    },
    "settings.hint.keyRadius": {
        en: "0–24 relative to M; 24 stays a circle at L and XL",
        ru: "0–24 относительно M; при L и XL 24 остаётся кругом",
        uk: "0–24 відносно M; на L і XL 24 лишається колом",
        it: "0–24 relativo a M; a L ed XL 24 resta un cerchio"
    },
    "settings.row.panelRadius": {
        en: "Panel radius",
        ru: "Радиус панели",
        uk: "Радіус панелі",
        it: "Raggio del pannello"
    },
    "settings.row.keyBackground": {
        en: "Key background",
        ru: "Фон клавиш",
        uk: "Фон клавіш",
        it: "Sfondo dei tasti"
    },
    "settings.row.panelBackground": {
        en: "Panel background",
        ru: "Фон панели",
        uk: "Фон панелі",
        it: "Sfondo del pannello"
    },
    "settings.row.textColor": {
        en: "Text colour",
        ru: "Цвет текста",
        uk: "Колір тексту",
        it: "Colore del testo"
    },
    "settings.row.accentColor": {
        en: "Accent colour",
        ru: "Акцентный цвет",
        uk: "Акцентний колір",
        it: "Colore d'accento"
    },
    "settings.row.borderColor": {
        en: "Border colour",
        ru: "Цвет границы",
        uk: "Колір рамки",
        it: "Colore del bordo"
    },
    "settings.hint.hex": {
        en: "Hex fields accept #RGB / #RRGGBB (an alpha form too); the check commits the draft. Type with the keyboard.",
        ru: "Поля принимают #RGB / #RRGGBB (и с альфа-каналом); галочка применяет черновик. Вводите с клавиатуры.",
        uk: "Поля приймають #RGB / #RRGGBB (також із альфа-каналом); галочка застосовує чернетку. Уводьте з клавіатури.",
        it: "I campi esadecimali accettano #RGB / #RRGGBB (anche con alfa); la spunta applica la bozza. Digita dalla tastiera."
    },
    // %1 is the store's own diagnostic (Config.js's parse error, English
    // by contract — it names the file and the bad key, near-technical
    // register); the sentence around it is chrome and translates.
    "settings.hint.configError": {
        en: "config.json: %1 — showing the last valid settings; fix the file to change them",
        ru: "config.json: %1 — показаны последние верные настройки; исправьте файл, чтобы изменить их",
        uk: "config.json: %1 — показано останні чинні налаштування; виправте файл, щоб їх змінити",
        it: "config.json: %1 — mostro le ultime impostazioni valide; correggi il file per cambiarle"
    },
    "settings.hint.stateError": {
        en: "state.json: %1 — showing the last valid state; fix the file to change it",
        ru: "state.json: %1 — показано последнее верное состояние; исправьте файл, чтобы изменить его",
        uk: "state.json: %1 — показано останній чинний стан; виправте файл, щоб його змінити",
        it: "state.json: %1 — mostro l'ultimo stato valido; correggi il file per cambiarlo"
    },
    "settings.resetAll": {
        en: "Reset all",
        ru: "Сбросить всё",
        uk: "Скинути все",
        it: "Ripristina tutto"
    },
    "settings.resetAllConfirm": {
        en: "Reset every override?",
        ru: "Сбросить все переопределения?",
        uk: "Скинути всі перевизначення?",
        it: "Ripristinare ogni personalizzazione?"
    },
    "settings.reset": {
        en: "Reset",
        ru: "Сбросить",
        uk: "Скинути",
        it: "Ripristina"
    },
    "settings.keep": {
        en: "Keep",
        ru: "Оставить",
        uk: "Залишити",
        it: "Mantieni"
    },
    "settings.decrease": {
        en: "Decrease",
        ru: "Уменьшить",
        uk: "Зменшити",
        it: "Riduci"
    },
    "settings.increase": {
        en: "Increase",
        ru: "Увеличить",
        uk: "Збільшити",
        it: "Aumenta"
    },
    "access.decreaseValue": {
        en: "Decrease value",
        ru: "Уменьшить значение",
        uk: "Зменшити значення",
        it: "Riduci il valore"
    },
    "access.increaseValue": {
        en: "Increase value",
        ru: "Увеличить значение",
        uk: "Збільшити значення",
        it: "Aumenta il valore"
    },
    "access.resetSetting": {
        en: "Reset this setting",
        ru: "Сбросить этот параметр",
        uk: "Скинути цей параметр",
        it: "Ripristina questa impostazione"
    },
    "common.custom": {
        en: "Custom",
        ru: "Другой",
        uk: "Інший",
        it: "Personalizzato"
    },

    // ---- the colour rows and the custom editor ----
    // %1 is the row's own label, %2 a hex value.
    "color.currently": {
        en: "%1 is currently %2",
        ru: "%1 сейчас: %2",
        uk: "%1 зараз: %2",
        it: "%1 al momento è %2"
    },
    "color.setTo": {
        en: "Set %1 to %2",
        ru: "Установить %1: %2",
        uk: "Встановити %1: %2",
        it: "Imposta %1: %2"
    },
    "color.openEditor": {
        en: "Open the custom colour editor for %1",
        ru: "Открыть редактор цвета для %1",
        uk: "Відкрити редактор кольору для %1",
        it: "Apri l'editor dei colori per %1"
    },
    "color.confirmHex": {
        en: "Confirm %1 hex",
        ru: "Применить hex для %1",
        uk: "Застосувати hex для %1",
        it: "Applica l'hex per %1"
    },
    "color.invalidHex": {
        en: "invalid hex — use #RGB or #RRGGBB",
        ru: "неверный hex — используйте #RGB или #RRGGBB",
        uk: "хибний hex — використовуйте #RGB або #RRGGBB",
        it: "hex non valido — usa #RGB o #RRGGBB"
    },
    "color.editor.title": {
        en: "Edit colors",
        ru: "Редактирование цвета",
        uk: "Редагування кольору",
        it: "Modifica colori"
    },
    "color.editor.cancelDraft": {
        en: "Cancel the custom colour draft",
        ru: "Отменить черновик цвета",
        uk: "Скасувати чернетку кольору",
        it: "Annulla la bozza del colore"
    },
    "color.editor.confirm": {
        en: "Confirm the custom %1 colour",
        ru: "Применить свой цвет для %1",
        uk: "Застосувати власний колір для %1",
        it: "Applica il colore personalizzato per %1"
    },
    "color.editor.cancelEdit": {
        en: "Cancel colour edit",
        ru: "Отменить изменение цвета",
        uk: "Скасувати редагування кольору",
        it: "Annulla la modifica del colore"
    },
    "color.editor.invalid": {
        en: "invalid",
        ru: "неверно",
        uk: "хибно",
        it: "non valido"
    },

    // ---- the emoji page ----
    // The placeholder stays word-for-word what ticket 36 shipped
    // (Пошук/Поиск/Search); tests/ui-strings.qml pins the parity.
    "emoji.searchPlaceholder": {
        en: "Search",
        ru: "Поиск",
        uk: "Пошук",
        it: "Cerca"
    },
    "emoji.clearSearch": {
        en: "Clear search",
        ru: "Очистить поиск",
        uk: "Очистити пошук",
        it: "Cancella la ricerca"
    },
    "emoji.chooseTone": {
        en: "Choose skin tone",
        ru: "Выбрать тон кожи",
        uk: "Вибрати тон шкіри",
        it: "Scegli il tono della pelle"
    },
    "emoji.mostFrequent": {
        en: "Most Frequent",
        ru: "Частые",
        uk: "Часті",
        it: "Frequenti"
    },
    "emoji.recent": {
        en: "Recent",
        ru: "Недавние",
        uk: "Нещодавні",
        it: "Recenti"
    },
    "emoji.noMatches": {
        en: "No matches",
        ru: "Ничего не найдено",
        uk: "Нічого не знайдено",
        it: "Nessun risultato"
    },
    // %1 is the emoji's own catalogue name (data, English by §37).
    "access.insert": {
        en: "Insert %1",
        ru: "Вставить %1",
        uk: "Вставити %1",
        it: "Inserisci %1"
    },
    // The tone picker's names; EmojiPage.js's table keeps the English
    // label as data and toneNameId maps each value here.
    "emoji.tone.default": {
        en: "Default skin tone",
        ru: "Стандартный тон кожи",
        uk: "Стандартний тон шкіри",
        it: "Tono della pelle predefinito"
    },
    "emoji.tone.light": {
        en: "Light skin tone",
        ru: "Светлый тон кожи",
        uk: "Світлий тон шкіри",
        it: "Tono della pelle chiaro"
    },
    "emoji.tone.mediumLight": {
        en: "Medium-light skin tone",
        ru: "Средне-светлый тон кожи",
        uk: "Середньо-світлий тон шкіри",
        it: "Tono della pelle medio-chiaro"
    },
    "emoji.tone.medium": {
        en: "Medium skin tone",
        ru: "Средний тон кожи",
        uk: "Середній тон шкіри",
        it: "Tono della pelle medio"
    },
    "emoji.tone.mediumDark": {
        en: "Medium-dark skin tone",
        ru: "Средне-тёмный тон кожи",
        uk: "Середньо-темний тон шкіри",
        it: "Tono della pelle medio-scuro"
    },
    "emoji.tone.dark": {
        en: "Dark skin tone",
        ru: "Тёмный тон кожи",
        uk: "Темний тон шкіри",
        it: "Tono della pelle scuro"
    }
}

function ids() {
    var out = []
    for (var id in STRINGS) {
        if (Object.prototype.hasOwnProperty.call(STRINGS, id)) out.push(id)
    }
    return out
}

// The effective UI language. An explicit en/ru/uk wins; "auto" (and
// anything else — the store rejects junk at the file, this is the
// runtime's own last word) follows the ACTIVE LAYOUT's code: ua speaks
// Ukrainian, ru Russian, every other code English. Lowercased before
// comparing, the placeholder's own rule.
function languageFor(layoutCode, override, layoutCodes) {
    // The owner's 2026-09-17 rule: an override pins the UI only when
    // its language is offered — see languageChoices; anything else is
    // inert (stale file, hand edit, layouts shrank) and the layout
    // answers. Nothing is ever shoved into a seat that cannot type it.
    var choice = String(override || "").toLowerCase()
    // "auto" rides the offered list so the ROW can show it selected —
    // but for resolution it means "no override": the layout answers.
    var offered = languageChoices(layoutCodes)
    if (choice !== "auto" && offered.indexOf(choice) !== -1) return choice
    var code = String(layoutCode || "").toLowerCase()
    if (code === "ua") return "uk"
    if (code === "ru") return "ru"
    if (code === "it") return "it"
    return "en"
}

/// The languages the LANGUAGE row may offer: Auto and English always
/// (English is the product's fallback), plus each translation whose
/// layout code the seat carries. `layoutCodes` is the seat's installed
/// xkb list (Keyboard.layoutCodes); junk, case and duplicates cost
/// nothing. The owner's call: a us,ua seat sees Auto/English/
/// Українська — no Русский segment for a language it cannot type;
/// a seat with ru gains it.
function languageChoices(layoutCodes) {
    var codes = Array.isArray(layoutCodes) ? layoutCodes : []
    var lower = []
    for (var i = 0; i < codes.length; i++)
        lower.push(String(codes[i] || "").toLowerCase())
    var out = ["auto", "en"]
    if (lower.indexOf("ru") !== -1) out.push("ru")
    if (lower.indexOf("ua") !== -1) out.push("uk")
    if (lower.indexOf("it") !== -1) out.push("it")
    return out
}

// The one lookup. Throws on an unknown id or an empty translation —
// loudly, where a suite can hear it. `args` is optional and fills
// "%1", "%2", … in order (Qt's qsTr idiom).
function tr(id, lang, args) {
    var entry = Object.prototype.hasOwnProperty.call(STRINGS, id)
        ? STRINGS[id] : undefined
    if (!entry)
        throw new Error("UiStrings: unknown id '" + id + "'")
    var choice = LANGUAGES.indexOf(lang) !== -1 ? lang : "en"
    var text = entry[choice]
    if (typeof text !== "string" || text.trim() === "")
        throw new Error("UiStrings: id '" + id + "' has no " + choice)
    if (args) {
        for (var i = 0; i < args.length; i++) {
            text = text.replace("%" + (i + 1), String(args[i]))
        }
    }
    return text
}
