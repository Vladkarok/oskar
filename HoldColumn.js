.pragma library

// Ticket 37: hold a character cap — its keymap column, not a repeat.
//
// Two pure decisions, kept out of QML so the host suite can pin them
// (tests/hold-column.qml), in the spirit of ModifierReducer.js:
//
//   columnEntries — what one keymap position offers as a hold column:
//     the layout's OWN extra levels 3..4 and nothing else. Level 2 is not
//     menu content: it is the cap's own drawn Shift face (capOverlay
//     writes the keymap's level 2 into chrShift), so offering it would
//     duplicate a character the cap already types and — worse — give
//     every two-level letter cap a menu, when the ticket's own honest
//     expectation is that stock `us`/`ua`/`ru` letters hold-repeat as
//     today and the menu lights up only where the map actually carries
//     levels 3-4. Levels 5..8 are the reserved symbol block's (decisions
//     §33) and stay on the &123 page: ONE route per character, no split
//     authority. A level that carries no drawable text is skipped, and a
//     position left with nothing offers no column at all — such a cap
//     keeps press-types plus the compositor's own repeat (spec-v1 §6).
//
//   shouldDefer — which caps move their typing from mouse-press to
//     mouse-release so a hold can open the column menu without typing
//     first. ONLY character caps with a column defer: a deferred cap
//     sends nothing at press, so the threshold firing strands no stray
//     character and starts no compositor repeat — the entire point. The
//     search arm (typeCap) feeds the emoji query on press and stays
//     immediate; exact caps (the &123 glyph caps, whose press IS the
//     level-routing this menu offers), `key` caps (modifiers, commands,
//     keysym caps like BackSpace and the arrows), fixed-label caps
//     (Space — the most-held key on the board keeps its repeat), and
//     anything the readiness or availability gates already refuse never
//     defer.

/// How long the button must stay down before the hold counts as a hold
/// rather than a click, in milliseconds. ~300-350 ms reads as deliberate
/// and stays under the compositor's repeat_delay (Hyprland defaults to
/// 600 ms). The number matters for feel only: a deferred cap has sent no
/// press line at threshold, so no repeat can have started whatever the
/// user's settings say.
var HOLD_THRESHOLD_MS = 320

/// The hold column for one position's caps facts: an array of
/// `{ level, text }` for levels 3..4 in level order, or an empty array
/// when the position has nothing to offer. `facts` is the position's
/// record from the caps facts map (decisions §23) — an array with one
/// `{ text }` / `{ none }` entry per level, exactly as the helper
/// resolved them against the installed keymap. Levels past the record's
/// length are no symbol at this level, same as a `{ none }` entry.
function columnEntries(facts) {
    if (!Array.isArray(facts)) return []
    var out = []
    for (var level = 3; level <= 4; level++) {
        if (level > facts.length) break
        var entry = facts[level - 1]
        if (!entry || typeof entry.text !== "string" || entry.text === "")
            continue
        out.push({ level: level, text: entry.text })
    }
    return out
}

/// Whether this cap defers its typing to mouse-release: `capData` is the
/// resolved cap, `entries` the cap's column from columnEntries (computed
/// by the caller so the press decision and the menu content cannot
/// disagree), `searchMode` the keyboard's search interception state and
/// `inputReady` its typing gate. See the module header for the whole
/// rule; the short form is: a ready, non-searching character cap that is
/// neither exact nor fixed-label, has a position, and has a column.
function shouldDefer(capData, entries, searchMode, inputReady) {
    if (inputReady !== true) return false
    if (searchMode === true) return false
    if (!capData) return false
    if (capData.unavailable === true) return false
    // `key` names the modifier, command and keysym caps; every one of
    // them keeps the semantics it has today.
    if (capData.key) return false
    // A fixed label means the panel draws its own text (Space's is
    // empty on purpose): not a character the keymap resolved, so not
    // this menu's to offer. drawsFixedLabel's own rule, restated here
    // because KeyboardLayout.js is not this module's to import.
    if (Object.prototype.hasOwnProperty.call(capData, "label")) return false
    // Exactness is typeCap's own test (exact flag or a baseLvl) and is
    // restated, not re-derived, so the two cannot drift.
    if (capData.exact === true || capData.baseLvl !== undefined) return false
    if (!capData.xkb) return false
    return Array.isArray(entries) && entries.length > 0
}
