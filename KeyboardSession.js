.pragma library

// The keyboard session (ticket 04): one pure owner for everything the panel
// must correlate across the helper connection — the configure transaction
// queue, the handshake, and the keymap generation the keycap facts belong to.
// Events in, next state out; nothing ambient is read, no line is written
// here. The socket object, the writes and the reducer's click semantics stay
// where they were (Keyboard.qml, ModifierReducer.js); this module only
// decides what the replies MEAN, which is why it can be tested without a
// compositor (tests/keyboard-session.qml).
//
// Why the generation exists. The main and ordinary-symbols pages now draw
// from facts supplied by the same compiled keymap that performs typing
// (decisions §23, which reopens §11's separate pipeline for those pages
// while retaining §3's independent complete-keymap compilation). A reply
// computed from keymap N must never enable caps for a world where the
// helper installed N+1, so every `configured` and every `caps` reply
// carries the helper's install generation, and facts are accepted only
// when both the generation AND the group match what the helper last
// acknowledged. Superseded replies are dropped; while no accepted facts
// exist for the acknowledged world, typing is not ready — an unresolved
// mismatch is a visible unavailable state, never a silent fallback.
//
// Extensibility contract for ticket 05 (chord reachability): records are
// positional and fields are tag-dispatched, so a future field kind or a
// trailing record field can be added without breaking the parsers here.
// The only response to an unknown field tag is refusal — parseCapsReply
// returns null and the panel treats the reply as unresolved, never as an
// empty level it might silently draw over.

/// Bumped with the helper's PROTOCOL_VERSION. Version 5 adds the
/// Chromium-specific `text-unicode` delivery command; version 4 added `caps`
/// reply and the generation on `configured`; the hello gate refuses a
/// pairing of old and new before any configure is sent, which is what lets
/// both sides change reply shapes in one release.
var PROTOCOL_VERSION = 5

function initial() {
    return {
        // Outstanding configure transactions, oldest first: one per
        // configure WRITTEN, each { payload, identity, changed, seq, group }.
        // The socket is ordered, so a `configured` reply settles the OLDEST.
        queue: [],
        // The keymap identity the helper last acknowledged, and the
        // generation it answered with. The drain question ("will the helper
        // lift what we hold?") is relative to what it has INSTALLED: the
        // last acked identity when the queue is empty, else the newest
        // queued entry's.
        acked: "",
        ackedGen: 0,
        // Which group the acked configure left the device typing in.
        group: 0,
        // Monotonic configure-send counter. Chords are stamped with it at
        // press, so an equal stamp means the configure was sent before the
        // press — the helper drains it ahead of the press lines.
        sends: 0,
        // The hello handshake succeeded on THIS connection. Every not-ready
        // gate includes it: a helper that refuses our version never becomes
        // ready, whatever its configure replies say (they would still be
        // processed by a mismatched helper — which is exactly the
        // installation mismatch the version gate exists to name).
        helloOk: false,
        // The acknowledged keycap facts: { gen, byGroup } where byGroup maps
        // a group index to that group's byPosition — an xkb position name
        // ("AD01") to an array of level entries, each
        // { text: "<drawable text>" } or { none: "<why not>" }. Null before
        // the first accepted reply.
        //
        // Facts are keyed by GROUP because the helper resolves every group of
        // an install at once (its caps_per_group), so all of them can be in
        // hand before the user ever switches language. Holding one group's
        // answer made a language switch a round trip: the moment the ack
        // moved the group the drawn facts went stale, the built-in table drew
        // in their place and typing was gated until the reply came back — a
        // visible dim-and-relabel flash on every switch, for facts the helper
        // had already computed.
        caps: null
    }
}

function copy(state) {
    var out = {}
    for (var name in state) out[name] = state[name]
    // The queue is the one mutable structure: a shallow copy would share it
    // between the old and the new state, so a push or shift on the returned
    // state would rewrite history the caller still holds. Entries are copied
    // too — the rebase writes `changed` in place, and an entry shared with a
    // predecessor would silently revise it.
    out.queue = state.queue.map(function (entry) {
        return {
            payload: entry.payload,
            identity: entry.identity,
            changed: entry.changed,
            seq: entry.seq,
            group: entry.group
        }
    })
    return out
}

/// The configure line's keymap identity: every field the helper's
/// same-keymap short-circuit compares — rules, model, layouts, variants,
/// options, kb_file — without the trailing group, which can move on its own
/// without draining anything. The panel's copy of the helper's "will this
/// configure drain the held keys" test.
function identityOf(payload) {
    var parts = String(payload || "").split("\t")
    return parts.slice(0, 7).join("\t")
}

function groupOf(payload) {
    var parts = String(payload || "").split("\t")
    return parseInt(parts[7]) || 0
}

/// The keymap identity the helper will have installed when the next line
/// reaches the front — the newest outstanding entry, or the last acked one
/// when the queue is empty.
function installed(state) {
    return state.queue.length > 0
        ? state.queue[state.queue.length - 1].identity
        : state.acked
}

/// Whether any configure the helper will drain sits ahead of whatever lines
/// are written next. The queue is FIFO: every entry in it was written before
/// this moment, so the helper processes each one before anything written
/// from here on.
function hasDrainAhead(state) {
    for (var i = 0; i < state.queue.length; i++) {
        if (state.queue[i].changed) return true
    }
    return false
}

/// True when no configure is outstanding — the only state in which the
/// keymap on the device is fully known.
function settled(state) {
    return state.queue.length === 0
}

/// Whether the acknowledged facts answer the acknowledged world: the same
/// keymap install, and an answer in hand for the group the ack left the
/// device typing in. Facts from a superseded generation are as good as
/// absent; so is a group nothing has answered for yet.
function capsCurrent(state) {
    return state.caps !== null
        && state.caps.gen === state.ackedGen
        && state.caps.byGroup[state.group] !== undefined
}

/// The groups of an install whose facts are not in hand yet, given how many
/// groups the configured keymap carries. The panel asks for all of them at
/// once: the helper resolved every group when it installed the keymap, so a
/// later language switch is a lookup rather than a round trip.
function missingCapGroups(state, groupCount) {
    var out = []
    var have = state.caps && state.caps.gen === state.ackedGen
        ? state.caps.byGroup : {}
    for (var group = 0; group < groupCount; group++) {
        if (have[group] === undefined) out.push(group)
    }
    // The group being DRAWN is always asked for, whatever the count says.
    // `groupCount` is the panel's reading of the configured layout list, and a
    // `kb_file` keymap can carry more groups than that list names — the detect
    // script's `.layout // "us"` yields "" for a device with no `kb_layout`,
    // which counts as one. Without this the acknowledged group would never be
    // requested, `capsCurrent` would stay false, the built-in table would draw
    // and there is no retry path that would ever fix it.
    if (have[state.group] === undefined && out.indexOf(state.group) === -1)
        out.push(state.group)
    return out
}

/// The full typing gate: handshake acknowledged, no keymap-CHANGING configure
/// outstanding, and keycap facts that answer the installed keymap generation.
///
/// The queue test is hasDrainAhead rather than settled on purpose. A press is
/// unsafe in front of a configure that will compile and install a new keymap —
/// the keystroke would land in a keymap neither side has agreed on, and the
/// helper drains every key it holds on the way in. A group-only configure does
/// neither: the helper's same-keymap short-circuit just moves the group, the
/// socket is ordered so the move lands before any line written after it, and
/// nothing it holds is lifted. Gating on the whole queue made every language
/// switch dim the keyboard for the round trip; gating on the drain keeps the
/// guarantee that mattered.
function typingReady(state) {
    return state.helloOk && !hasDrainAhead(state) && capsCurrent(state)
}

/// The facts to draw with, or null while the world is unresolved. The panel
/// never draws stale facts: a null here means the built-in table draws only
/// as the logged last-resort fallback (spec-v1 §3.5) with input gated.
function capsMap(state) {
    return capsCurrent(state) ? state.caps.byGroup[state.group] : null
}

/// Apply a parsed caps reply. A stale generation (or a null parse) is
/// refused: the returned state is unchanged and `accepted` is false, so the
/// panel cannot clear capsFactsFailed from a reply the session dropped. Any
/// group of the acknowledged generation is accepted — a pre-fetched group is
/// stored without becoming the drawn map, which capsCurrent still decides.
function applyCapsReply(state, parsed) {
    if (!parsed || parsed.gen !== state.ackedGen)
        return { state: state, accepted: false }
    return {
        state: reduce(state, {
            type: "capsFacts",
            gen: parsed.gen,
            group: parsed.group,
            byPosition: parsed.byPosition
        }),
        accepted: true
    }
}

/// spec-v1.1 §6 lifecycle kind the header notice keys off. A connected
/// helper whose facts failed is unavailable, never "starting": decisions
/// §23 requires a visible mismatch, not the service-boot notice.
function lifecycleKind(flags) {
    if (flags.serviceIncompatible) return "incompatible"
    if (!flags.inputReady && !flags.serviceConnected) return "stopped"
    // `keycapsFailed` is gone with the §11 pipeline (ticket 18): it reported a
    // compile nothing drew from, so a failure there raised "keymap
    // unavailable" over caps that were entirely the helper's facts and
    // perfectly good. `capsFactsFailed` is the one that describes what is
    // drawn. A caller still passing the old flag is honoured so the two sides
    // can move independently.
    if (flags.capsFactsFailed || flags.keycapsFailed) return "unavailable"
    if (!flags.inputReady) return "starting"
    return "ready"
}

function reset() {
    return {
        queue: [], acked: "", ackedGen: 0, group: 0,
        sends: 0, helloOk: false, caps: null
    }
}

/// The one state transition. Returns the next state; the caller reassigns
/// its property wholesale, which is what re-fires every QML binding that
/// reads the session.
function reduce(state, event) {
    var out = copy(state)
    switch (event.type) {
    case "configureSent":
        // The transaction's seq is assigned HERE, before the caller writes
        // the payload, so a chord stamped sends === entry.seq was pressed at
        // or after the send.
        var identity = identityOf(event.payload)
        out.sends += 1
        out.queue.push({
            payload: event.payload,
            identity: identity,
            changed: identity !== installed(state),
            seq: out.sends,
            group: groupOf(event.payload)
        })
        return out
    case "configureAck":
        // Pops the oldest outstanding transaction for the reply that just
        // arrived, records its identity, generation and group as installed.
        // Without an entry (a duplicate or late reply) there is nothing to
        // settle: keep the state, the queue is the authority.
        var entry = out.queue.shift()
        if (!entry) return out
        out.acked = entry.identity
        out.ackedGen = event.gen
        out.group = entry.group
        return out
    case "configureFailed":
        // A configure the helper refused lifted nothing: its own entry
        // drops, and the helper still has the last acked keymap installed,
        // so every surviving entry's drain test re-runs against that
        // instead of against the refused payload.
        var dropped = out.queue.shift()
        if (!dropped) return out
        var installedNow = out.acked
        for (var i = 0; i < out.queue.length; i++) {
            out.queue[i].changed = out.queue[i].identity !== installedNow
            installedNow = out.queue[i].identity
        }
        return out
    case "capsFacts":
        // Accepted only against the acknowledged GENERATION — the fact that
        // says which keymap install answered. The group is a key into the
        // answer, not a staleness test: the panel deliberately asks for every
        // group of an install, so a reply naming a group it is not currently
        // drawing is the pre-fetch arriving, not a stale answer. What keeps
        // the wrong group off the caps is capsCurrent, which reads the group
        // the ack left the device in and nothing else.
        if (event.gen !== out.ackedGen) return out
        var byGroup = {}
        if (out.caps && out.caps.gen === event.gen) {
            for (var g in out.caps.byGroup) byGroup[g] = out.caps.byGroup[g]
        }
        byGroup[event.group] = event.byPosition
        out.caps = { gen: event.gen, byGroup: byGroup }
        return out
    case "helloAcked":
        out.helloOk = true
        if (event.fresh) {
            // A genuinely NEW connection: the helper released everything the
            // old one held, acknowledges nothing and has sent nothing, so
            // every tracked fact starts over. The repair timer's re-hello of
            // a live connection lands here with fresh false and keeps
            // everything — resetting over a live hold would leave the device
            // Shift down under an idle panel.
            var fresh = reset()
            fresh.helloOk = true
            return fresh
        }
        return out
    case "connectionDown":
        out.helloOk = false
        return out
    default:
        return out
    }
}

/// Parses one `caps` reply line into { gen, group, byPosition }, or null for
/// anything malformed — including an unknown field tag, which is refused
/// rather than guessed at (see the header). Level entries keep the helper's
/// three honest kinds: text, a named characterless symbol, and nothing.
function parseCapsReply(line) {
    var parts = String(line || "").split("\t")
    if (parts.length < 4 || parts[0] !== "caps") return null
    var gen = parseInt(parts[1])
    var group = parseInt(parts[2])
    if (!isFinite(gen) || gen < 0 || !isFinite(group) || group < 0) return null
    var byPosition = {}
    var records = parts.slice(3).join("\t").split("\u001E")
    for (var r = 0; r < records.length; r++) {
        var record = records[r]
        if (record === "") continue
        var fields = record.split("\u001F")
        if (fields[0] === "") return null
        var levels = []
        for (var f = 1; f < fields.length; f++) {
            var field = fields[f]
            var tag = field.charAt(0)
            if (tag === "t") levels.push({ text: field.slice(1) })
            else if (tag === "n") levels.push({ none: "" })
            else if (tag === "x") levels.push({ none: field.slice(1) })
            else return null
        }
        byPosition[fields[0]] = levels
    }
    return { gen: gen, group: group, byPosition: byPosition }
}

/// The wire shape of one text delivery (ticket 24, step 4): the verb, one
/// separator space, then the payload — which the helper takes as the whole
/// rest of the line, spaces included, because the payload is the user's
/// string and not a word list. The only refusals here are payloads that
/// could not survive the line protocol at all: an empty string (the helper
/// would not know a bare "text" as a command either) and one carrying a
/// newline, the frame separator — an emoji sequence from the catalogue can
/// carry neither, so the guard is the protocol's, not a data opinion.
/// Returns "" for a refusal; the caller sends nothing.
function textLine(s) {
    var text = String(s === undefined || s === null ? "" : s)
    if (text.length === 0 || text.indexOf("\n") >= 0) return ""
    return "text " + text
}

/// Ticket 06: the published keymap's absolute path, built exactly from the
/// runtime directory the helper publishes into. Trailing separators on the
/// environment value are normalized so the identity comparison below is
/// about the path, not the spelling; an empty environment answers empty and
/// compares equal to nothing.
function publishedKeymapPath(runtimeDir) {
    var base = String(runtimeDir || "").replace(/\/+$/, "")
    if (base === "") return ""
    return base + "/oskar/keymap.xkb"
}

/// Whether a compositor-reported kb_file IS the published keymap — exact
/// identity, never a substring. A user's own file under a directory that
/// happens to end in our suffix is the user's: the substring test adopted
/// it as ours and silently dropped it (audit 06).
function isPublishedKeymap(kbFile, runtimeDir) {
    var path = String(kbFile || "")
    return path !== "" && path === publishedKeymapPath(runtimeDir)
}

/// Quote a path for interpolation into a single-quoted Lua string literal
/// (hyprctl eval's config values). The security audit's finding 3: a
/// filename carrying ' or a closing brace sequence escaped the literal
/// and executed as config-side Lua — verified in a stub by the auditor.
/// Lua single-quoted literals escape \\ and \'; every other unsafe byte
/// (quotes, braces, control characters — filenames may legally carry
/// newlines) becomes a \\ddd decimal escape, which no filename spelling
/// can close. The empty string still quotes as ''.
function luaQuote(value) {
    var text = String(value === undefined || value === null ? "" : value)
    var out = "'"
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i)
        var ch = text.charAt(i)
        // Backslash, single quote (the Lua layer) AND double quote (the
        // bash layer the literal travels through) ride as escapes; the
        // audit's bash-side catch.
        if (ch === "\\" || ch === "'" || ch === '"') out += "\\" + ch
        else if (code < 32 || code > 126) out += "\\" + code
        else out += ch
    }
    return out + "'"
}
