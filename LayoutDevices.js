.pragma library

/// Which keyboard the panel reads its layout from, and which ones the
/// language button moves.
///
/// This lived in a jq program inside a shell string in Keyboard.qml, where
/// nothing could test it, and it broke three times: a mouse poisoned the
/// indicator (decisions §5), a guessed device was advanced while another kept
/// typing the old group (ticket 19), and then the reading came from a set the
/// switch did not move (ticket 21) — `ideapad-extra-buttons` and a Razer
/// mouse's keyboard interface sat on group 1 forever, so the panel read
/// Ukrainian off a device that cannot type while the real keyboards produced
/// English. Same shape every time, and every time invisible to the suites.
///
/// It is ordinary domain logic and it belongs where it can be exercised. The
/// shell now only dumps `hyprctl devices -j`; every decision below is here.

/// Names that are never a typed keyboard.
///
/// Power and sleep buttons, lid switches and video buses are keyboards to
/// evdev and carry an XKB group nobody advances. `hl-virtual-keyboard` is any
/// virtual keyboard on the seat, this helper's own included — the compositor
/// must not become a second writer of a group `configure` owns (§6).
var PSEUDO = /(^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus))|omarchy-osk/i

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

/// The group the safe set is on when its members disagree.
///
/// The most common index, and the lowest of those when it is a tie. The old
/// answer was the highest index any of them had reached — "layout progress" —
/// and it read group 1 off one stuck keyboard while the two the user actually
/// types on sat on group 0. A majority cannot be dragged by one member; the
/// lowest-wins tie-break only decides a genuine 50/50, where either answer is
/// a guess and the same guess every time is worth more than the larger one.
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

/// (devices, anchor, safeNames)
///   -> { reading, typing, switchSet, group }
///
/// `anchor` is the keyboard the caller last saw the seat produce a key on.
/// It is NOT a device name taken from a layout event: every `switchxkblayout`
/// this panel issues emits one, so an anchor fed from events points at
/// whichever device the panel itself moved last — the panel reading its own
/// echo, and then rearranging the seat around it.
///
/// `reading` is the device whose group, layout list and RMLVO the panel
/// follows, or null when nothing can answer — at startup, before the helper's
/// device snapshot has arrived, that is the honest answer and the caller must
/// send no configure rather than guess a group.
///
/// `reading` and `switchSet` come from the SAME set. That is the invariant
/// this module exists to hold: a group read off a device the language button
/// never moves is a group the keyboard will not be typing in.
function select(devices, namedDevice, safeNames) {
    var all = Array.isArray(devices) ? devices : []
    var names = Array.isArray(safeNames) ? safeNames : []
    var named = String(namedDevice || "")

    var safe = all.filter(function (device) {
        return device && isTyped(device.name) && isSafe(device.name, names)
    })
    if (safe.length === 0) {
        return { reading: null, typing: "", switchSet: [], group: 0 }
    }

    // The seat's current keyboard first — HyprCtl prints IKeyboard::m_active
    // as `main`, and it is literally "where the next physical key comes from".
    // Then the device the last layout event named, which is what a deliberate
    // switch produces. Then the set's own consensus.
    var current = safe.filter(function (device) { return device.main === true })[0]
    var namedMatch = safe.filter(function (device) { return device.name === named })[0]
    var reading = current || namedMatch || null
    if (!reading) {
        var agreed = consensusGroup(safe)
        reading = safe.filter(function (device) { return groupOf(device) === agreed })[0]
    }

    // Same layout list as the reading device: a device with its own
    // `kb_layout` has its own group space, and an absolute index means
    // something different there.
    var layout = String((reading && reading.layout) || "")
    var switchSet = safe.filter(function (device) {
        return String(device.layout || "") === layout && String(device.name || "") !== ""
    }).map(function (device) { return String(device.name) })

    return {
        reading: reading,
        // The keyboard the seat says produced the last key, when it is one
        // this panel may act on. Empty means "no evidence right now" — the
        // helper's own virtual keyboard holds the flag for a moment after
        // every OSK keystroke — and the caller keeps what it last knew rather
        // than adopting a guess.
        typing: String((current || {}).name || ""),
        switchSet: switchSet,
        group: groupOf(reading)
    }
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
