.pragma library

/// Which keyboard the panel reads its layout from, and which ones the
/// language button moves.
///
/// A non-typing device (a mouse's keyboard interface, an extra-buttons
/// pseudo-device) can sit on a stale group forever; reading through it
/// makes the panel show a language nobody is actually typing while the
/// real keyboards disagree. This module exists so that failure mode is
/// exercised by tests rather than caught by inspection.
///
/// The helper's `seat` reply only carries the compositor's device list;
/// every decision is here.

/// Names that are never a typed keyboard.
///
/// Power and sleep buttons, lid switches and video buses are keyboards to
/// evdev and carry an XKB group nobody advances. `hl-virtual-keyboard` is any
/// virtual keyboard on the seat, this helper's own included — the compositor
/// must not become a second writer of a group `configure` owns.
var PSEUDO = /(^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus))|oskar/i

function isTyped(name) {
    var text = String(name || "")
    return text !== "" && !PSEUDO.test(text)
}

/// Whether a device name is one the helper positively identified through
/// udev, allowing for the compositor's `-2`, `-3` … suffixes on duplicates.
function isSafe(name, safeNames) {
    var text = String(name || "")
    if (text === "") return false
    for (var i = 0; i < safeNames.length; i++) {
        var base = String(safeNames[i] || "")
        if (base === "") continue
        if (text === base) return true
        if (text.indexOf(base + "-") === 0
                && /^[0-9]+$/.test(text.slice(base.length + 1))) return true
    }
    return false
}

function groupOf(device) {
    var index = device ? device.active_layout_index : 0
    return typeof index === "number" && index >= 0 ? index : 0
}

/// The safe keyboards that share the reading device's layout list — the
/// devices an absolute group index means the same thing on.
function switchSetFor(reading, safe) {
    var layout = String((reading && reading.layout) || "")
    return safe.filter(function (device) {
        return String(device.layout || "") === layout && String(device.name || "") !== ""
    }).map(function (device) { return String(device.name) })
}

/// The group the safe set is on when its members disagree.
///
/// The most common index, and the lowest of those when it is a tie. A
/// majority cannot be dragged by one stuck member reporting a higher
/// index; the lowest-wins tie-break only decides a genuine 50/50, where
/// either answer is a guess and the same guess every time is worth more
/// than the larger one.
function consensusGroup(devices) {
    var counts = {}
    var best = -1
    var bestCount = 0
    for (var i = 0; i < devices.length; i++) {
        var group = groupOf(devices[i])
        counts[group] = (counts[group] || 0) + 1
        if (counts[group] > bestCount || (counts[group] === bestCount && group < best)) {
            best = group
            bestCount = counts[group]
        }
    }
    return best < 0 ? 0 : best
}

/// The number of layouts a device's own list actually carries: the
/// non-empty entries. A trailing or doubled separator is not a layout,
/// and an absent list carries nothing. A remembered group is only
/// meaningful while it is smaller than this: a session whose layout
/// list shrank cannot carry an index from the wider one.
function layoutCount(device) {
    if (!device) return 0
    return String(device.layout || "").split(",")
        .filter(function (code) { return String(code || "").trim() !== "" }).length
}

/// The safe keyboards of one reading, by name → group.
function safeGroups(devices, safeNames) {
    var out = {}
    var all = Array.isArray(devices) ? devices : []
    for (var i = 0; i < all.length; i++) {
        var device = all[i]
        if (device && isTyped(device.name) && isSafe(device.name, safeNames))
            out[String(device.name)] = groupOf(device)
    }
    return out
}

/// The keyboard that moved BY ITSELF between two readings, or "".
///
/// A group toggle is per device: Alt+Shift moves the one keyboard its keys
/// came from and nothing else. So when `movedDevice` — a positively
/// identified keyboard — is the ONLY safe keyboard whose group differs
/// from `previous`, it moved alone. An empty `movedDevice` asks for
/// whichever one keyboard changed (the reading after a reconnect, when no
/// event could name it). Anything else is not that evidence: no previous
/// reading, a safe set that gained or lost a member (hotplug), several
/// keyboards changed, or the named one did not change. Whether the move
/// was part of a burst in TIME — the panel's own click, a compositor-wide
/// switch, a keymap re-application — is SeatMotion's question, answered
/// before this one is asked.
function loneMover(previous, devices, safeNames, movedDevice) {
    var moved = String(movedDevice || "")
    var names = Array.isArray(safeNames) ? safeNames : []
    if (!Array.isArray(previous) || previous.length === 0) return ""
    if (moved !== "" && (!isTyped(moved) || !isSafe(moved, names))) return ""
    var before = safeGroups(previous, names)
    var after = safeGroups(devices, names)
    var changed = []
    for (var name in after) {
        if (!(name in before)) return ""
        if (after[name] !== before[name]) changed.push(name)
    }
    for (var gone in before) {
        if (!(gone in after)) return ""
    }
    if (changed.length !== 1) return ""
    return moved === "" || changed[0] === moved ? changed[0] : ""
}

/// (devices, anchor, safeNames, fallbackGroup, movedDevice, motion)
///   -> { reading, typing, lone, movedAlone, switchSet, group }
///
/// `anchor` is the keyboard the caller believes is typed on. It is learned
/// from two kinds of evidence and nothing else: the seat's `main` flag on a
/// safe keyboard, and a keyboard that moved by itself (loneMover). A bare
/// layout event is not evidence: every `switch` this panel issues emits
/// one, so an anchor fed from every event points at whichever device the
/// panel itself moved last — the panel reading its own echo, and then
/// rearranging the seat around it.
///
/// `movedDevice` is the keyboard the most recent compositor layout event
/// named — the one that just moved, whatever moved it. On its own it is
/// evidence about MOTION, not about typing, and it only breaks a diverged
/// seat open when it names the anchor.
///
/// `motion` is what makes a mover evidence about typing: { base,
/// candidate, gap } from SeatMotion.reading — a move the seat stayed quiet
/// around, uncommanded, and the reading from before it (or, after a
/// reconnect, the reading from before the gap). When the candidate is the
/// only safe keyboard changed since `base` it is `lone`: its live group is
/// the reading, exactly as for a keyboard holding `main`, and the caller
/// adopts it as the anchor once the move is followed (anchorAfter). A safe
/// keyboard holding `main`
/// outranks it: the flag moves on every key press, so a safe `main` that is
/// not the mover says the mover is not under the user's hands (a script
/// moved it). The flag only ever sits off the typed keyboard when an IME's
/// virtual keyboard re-emits the keys (fcitx5 holds it on the owner's seat
/// for good) or right after this panel types — which is exactly when the
/// lone mover is the only evidence left.
///
/// `reading` is the device whose group, layout list and RMLVO the panel
/// follows, or null when nothing can answer — at startup, before the helper's
/// device snapshot has arrived, that is the honest answer and the caller must
/// send no configure rather than guess a group.
///
/// `reading` and `switchSet` come from the SAME set. That is the invariant
/// this module exists to hold: a group read off a device the language button
/// never moves is a group the keyboard will not be typing in.
function select(devices, namedDevice, safeNames, fallbackGroup, movedDevice, motion) {
    var all = Array.isArray(devices) ? devices : []
    var names = Array.isArray(safeNames) ? safeNames : []
    var named = String(namedDevice || "")
    var moved = String(movedDevice || "")

    var safe = all.filter(function (device) {
        return device && isTyped(device.name) && isSafe(device.name, names)
    })
    if (safe.length === 0) {
        return { reading: null, typing: "", lone: "", movedAlone: "",
            switchSet: [], group: 0 }
    }

    // The seat's current keyboard first — HyprCtl prints IKeyboard::m_active
    // as `main`, and it is literally "where the next physical key comes from".
    // Then the named anchor — the keyboard that just moved by itself when
    // there is one (loneMover), else the one learned before. Then the
    // remembered group, then the set's own consensus.
    var current = safe.filter(function (device) { return device.main === true })[0]
    var alone = motion
        ? loneMover(motion.base, all, names,
            motion.gap === true ? "" : String(motion.candidate || "")) : ""
    var lone = current ? "" : alone
    if (lone !== "") named = lone
    var namedMatch = safe.filter(function (device) { return device.name === named })[0]
    var reading = current || namedMatch || null

    // A DIVERGED seat is resolved by who just moved, never by a vote.
    // One twin moves and the rest sleep: an external per-device toggle
    // (Hyprland's own grp:alt_shift_toggle) does it — and so does the
    // compositor itself flipping a group on a keystroke that carries no
    // toggle at all. With a pseudo vkb holding `main`, the reading is
    // then only the NAMED anchor:
    //
    // - The mover IS the anchor: the keyboard under the user's hands is
    //   the one that just moved, and its own live index answers through
    //   the fall-through return. Outvoting it with consensus + remembered
    //   — two devices that never receive keys voting down the typist —
    //   would leave every indicator saying English while the fingers type
    //   Ukrainian, resyncing only on the next Alt+Shift.
    //
    // - The mover is NOT the anchor, or there is no mover at all: the
    //   anchor may itself name a sleeper (seeded by enumeration, not
    //   typing evidence), and the mover did not move alone — it moved in
    //   a burst with others, it was the panel's own echo, or there is no
    //   reading before it to tell. Neither live index is trustworthy
    //   then, so consensus device + remembered group answer — the same
    //   tie-break the cold-start arm uses.
    var moverIsAnchor = lone !== "" || (moved !== "" && moved === named)
    var divergedWithAnchor = !moverIsAnchor && reading && !current
        && safe.length > 1 && safe.some(function (device) {
            return groupOf(device) !== groupOf(safe[0])
        })

    // The safe set DISAGREES with itself when Hyprland's group toggle has
    // moved the keyboard the user types on while its sleeping siblings never
    // receive it (the toggle is per-device). A majority of sleepers would
    // then vote the panel into the wrong group on every shell restart. The
    // panel's remembered group, persisted with the rest of its state, is the
    // honest tie-breaker in that window; the helper's own device index
    // cannot serve (Hyprland reports a virtual keyboard's layout slot, never
    // the group its modifiers set).
    var diverged = safe.length > 1 && safe.some(function (device) {
        return groupOf(device) !== groupOf(safe[0])
    })
    if (divergedWithAnchor) diverged = true
    var remembered = typeof fallbackGroup === "number"
        && isFinite(fallbackGroup) && fallbackGroup >= 0
        && fallbackGroup === Math.floor(fallbackGroup)
        ? fallbackGroup : -1
    if ((!reading || divergedWithAnchor) && diverged && remembered >= 0) {
        var facts = safe.filter(function (device) {
            return groupOf(device) === consensusGroup(safe)
        })[0] || safe[0]
        // The remembered group is bounded by the CURRENT map: a session
        // that shrank its layout list (four→two, two→one) cannot carry an
        // index from the wider one, and asking for it would leave caps
        // refused and typing gated. Fall through to the
        // consensus fallback — the same answer a panel with no memory
        // gives — instead of honoring a group the keymap does not have.
        if (remembered < Math.max(layoutCount(facts), 1)) {
            return {
                reading: facts,
                typing: "",
                lone: "",
                movedAlone: "",
                switchSet: switchSetFor(facts, safe),
                group: remembered
            }
        }
    }
    if (!reading) {
        var agreed = consensusGroup(safe)
        reading = safe.filter(function (device) { return groupOf(device) === agreed })[0]
    }

    // Same layout list as the reading device: a device with its own
    // `kb_layout` has its own group space, and an absolute index means
    // something different there.
    var switchSet = switchSetFor(reading, safe)

    return {
        reading: reading,
        // The keyboard the seat's flag says produced the last key, when it
        // is one this panel may act on. Empty means "no evidence right now"
        // — the helper's own virtual keyboard holds the flag for a moment
        // after every OSK keystroke — and the caller keeps what it last
        // knew rather than adopting a guess.
        typing: String((current || {}).name || ""),
        // The keyboard that moved by itself and answers this reading, or "".
        lone: lone,
        // The same keyboard when it answers this reading for either reason:
        // as the lone mover, or because it is the one holding the flag.
        movedAlone: alone !== "" && alone === reading.name ? alone : "",
        switchSet: switchSet,
        group: groupOf(reading)
    }
}

/// The anchor a reading teaches, once the caller knows whether the settle
/// guard let the reading's group through: the seat's flag always, and a
/// keyboard that moved by itself only when its move was followed. A lone
/// move the guard holds is a candidate like any uncommanded flip; if the
/// guard later judges it churn, the anchor never moved, and the re-read
/// answers from the anchor the panel had.
function anchorAfter(picked, followed) {
    if (!picked) return ""
    if (picked.typing) return picked.typing
    return followed === true ? String(picked.lone || "") : ""
}

/// Whether the reading is a lone move of the keyboard the caller already
/// reads: `anchor` is the anchor from BEFORE this reading, and the mover
/// answers this reading, as the lone mover or as the holder of the seat's
/// flag (a seat without an input method keeps it on the typed keyboard).
/// That keyboard's
/// group is what the panel draws whether or not it moved, so its move tells
/// the settle guard about the user's hands and nothing about which keyboard
/// to read.
function loneAnchor(picked, anchor) {
    var mover = picked ? String(picked.movedAlone || "") : ""
    return mover !== "" && mover === String(anchor || "")
}

/// The layout code the reading device is currently on, by index into its own
/// list. The index is authoritative and the code is a label: `us,us` with
/// distinct variants repeats the code, and looking the code up by name always
/// found the first twin.
function activeLayout(reading) {
    if (!reading) return ""
    var layouts = String(reading.layout || "us").split(",")
    var group = groupOf(reading)
    return String(layouts[group] || layouts[0] || "").trim()
}

/// The layout CODE at an explicit group index — for the caller that knows
/// the group by other means than the reading device's own index (the
/// remembered-group fallback answers from a consensus device's facts while
/// the group itself came from the panel's state).
function activeLayoutForGroup(reading, group) {
    if (!reading) return ""
    var layouts = String(reading.layout || "us").split(",")
    var index = typeof group === "number" && group >= 0
        && group === Math.floor(group) ? group : -1
    return String(layouts[index] || layouts[0] || "").trim()
}
