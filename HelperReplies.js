.pragma library
.import "ChordAcks.js" as ChordAcks
.import "KeyboardSession.js" as Session
.import "ModifierReducer.js" as Modifiers
.import "SettleGuard.js" as SettleGuard

// What one line from the helper MEANS: the reply dispatch, as a pure
// function of the panel's reply state. Nothing here writes a line, calls
// back into QML or reads anything ambient. Each step returns
// { state, actions }: `actions` is an ordered program the keyboard runs
// verbatim (Keyboard.qml's runReplyActions), and `state` is what that
// program leaves the reply state at when nothing else moves it meanwhile —
// `apply` below is the program's reference semantics, and every step
// builds its state by applying its own actions, so the two cannot drift.
//
// Why a program and not "assign the new state, then run the effects":
// the panel's writes have synchronous consequences. Assigning `session`
// can re-fire `capsFacts`, whose handler rebuilds the rows and releases a
// key still held under the pointer (a modifierState transition, possibly
// an `up` line); a write can fail synchronously and run the drop handler.
// The original order of writes and effects is therefore part of the
// behaviour, and so is reading the LIVE value at each transition. That is
// why state transitions are actions too: `session` / `modifiers` /
// `settleGuardConnected` / `gateFromSession` name the pure transition and
// the executor applies it to the property's current value, exactly where
// the handler used to.
//
// The state the steps read and write:
//   chordAcks            the reply-correlation ledger (ChordAcks.js)
//   session              the configure/handshake session (KeyboardSession.js)
//   modifierState        the modifier reducer's state (ModifierReducer.js)
//   settleGuard          the restart-settle guard (SettleGuard.js)
//   inputReady           the typing gate
//   serviceIncompatible  the installed helper speaks another protocol
//   capsFactsFailed      keycap facts proved disagreement
//   socketReconnected    the socket reached `connected` and no hello has
//                        been answered on it yet (HelperLink's flag)
//   startupKeyboards, startupInventorySeen, startupKeyboardName,
//   anchorKeyboardName   the device inventory the `keyboards` reply fills
//
// The context the steps read: { groupCount, capsPositions } — how many
// groups the configured keymap carries, and the declared positions a caps
// request names.
//
// Actions, each { op, … }:
//   set { key, value }       write one state field (a key of STATE_KEYS)
//   session { event }        session = Session.reduce(session, event)
//   modifiers { event }      modifierState = Modifiers.reduce(…).state; the
//                            reducer's lines are NOT emitted — every
//                            transition here settles to a world the device
//                            already agrees with
//   settleGuardConnected     settleGuard = SettleGuard.connected(settleGuard)
//   gateFromSession          inputReady = Session.typingReady(session)
//   gateOpenIfReady          inputReady = true only if typingReady(session)
//   send { line }            the one write choke point; a written line
//                            occupies its ChordAcks slot
//   chordVerdict { done, success }   the armed chord's own final line was
//                            answered (PasteChords.chordAckCompleted)
//   chordTimedOut            the armed chord's wait ends failed
//                            (PasteChords.chordAckTimedOut: the ledger's
//                            chordSettled plus done(false))
//   groupConfirmed { group } the ack's group, for the restart fallback
//   pullLayouts              re-read the compositor's layouts
//   shareKeymap              point the compositor at the published keymap
//   log / warn / error { args }   one journal line

/// The reply-state fields a `set` action may name.
var STATE_KEYS = [
    "chordAcks", "session", "modifierState", "settleGuard",
    "inputReady", "serviceIncompatible", "capsFactsFailed",
    "socketReconnected",
    "startupKeyboards", "startupInventorySeen", "startupKeyboardName",
    "anchorKeyboardName"
]

function shallow(state) {
    var out = {}
    for (var name in state) out[name] = state[name]
    return out
}

/// One action's effect on the reply state. Actions that are the panel's
/// own effects (a callback, a process, a journal line) leave it as it is.
/// A `send` assumes the write succeeds; the executor's choke point pushes
/// the slot only when it does.
function apply(state, action) {
    var next = shallow(state)
    switch (action.op) {
    case "set":
        next[action.key] = action.value
        break
    case "session":
        next.session = Session.reduce(state.session, action.event)
        break
    case "modifiers":
        next.modifierState = Modifiers.reduce(state.modifierState,
            action.event).state
        break
    case "settleGuardConnected":
        next.settleGuard = SettleGuard.connected(state.settleGuard)
        break
    case "gateFromSession":
        next.inputReady = Session.typingReady(state.session)
        break
    case "gateOpenIfReady":
        if (Session.typingReady(state.session)) next.inputReady = true
        break
    case "send":
        next.chordAcks = ChordAcks.sent(state.chordAcks, action.line)
        break
    case "chordTimedOut":
        next.chordAcks = ChordAcks.chordSettled(state.chordAcks)
        break
    }
    return next
}

function program(state) {
    return { state: shallow(state), actions: [] }
}

function emit(p, action) {
    p.state = apply(p.state, action)
    p.actions.push(action)
}

function set(p, key, value) {
    emit(p, { op: "set", key: key, value: value })
}

function send(p, line) {
    emit(p, { op: "send", line: line })
}

function result(p) {
    return { state: p.state, actions: p.actions }
}

/// The caps request for one group: the group, then the declared positions.
/// The helper answers per level from the keymap it installed, tagged with
/// that install's generation.
function capsRequestLine(group, positions) {
    var list = String(positions || "")
    return "caps " + group + (list !== "" ? " " + list : "")
}

/// The first half of every line: the correlation pop. Any line is an
/// ANSWER — ok, err, fact or generation, the helper answers in order — so
/// it pops the oldest command's slot. The chord's verdict rides on the pop
/// of its own final line, success only when the reply is a bare `ok`;
/// otherwise an err would leave the slot occupied forever and fail every
/// later chord. Returns the trimmed reply and the verb the pop settled:
/// the FIFO is the only honest witness of which command a
/// content-ambiguous err answers (`err bad group` serves three verbs).
function pop(state, line) {
    var p = program(state)
    var reply = String(line).trim()
    var ack = ChordAcks.replyReceived(p.state.chordAcks, reply === "ok")
    set(p, "chordAcks", ack.state)
    if (ack.done)
        emit(p, { op: "chordVerdict", done: ack.done, success: ack.success })
    return {
        state: p.state,
        actions: p.actions,
        reply: reply,
        verb: String(ack.verb || "")
    }
}

/// The second half: what the popped reply means. `verb` is pop's.
///
/// The chord verdict pop may emit runs arbitrary panel code (the paste's
/// completion callback), so the executor runs pop's program first and
/// hands route a state read AFTER it — route's decisions read the world
/// the callback left, as the handler's arms always did.
function route(state, reply, verb, ctx) {
    var p = program(state)
    if (reply === "hello " + Session.PROTOCOL_VERSION) {
        helloAcked(p)
    } else if (reply === "keyboards" || reply.indexOf("keyboards\t") === 0) {
        keyboardsReply(p, reply)
    } else if (reply.indexOf("configured") === 0) {
        configuredReply(p, reply, ctx)
    } else if (reply.indexOf("caps\t") === 0) {
        capsReply(p, reply)
    } else if (reply === "pong") {
        // The quiescent probe's answer: the pipe is alive end to end. The
        // transport's any-line clear already lifted the watchdog's mark;
        // pong carries no state, settles nothing, and must not reach the
        // fail-closed arm below — unrecognized replies drop the typing
        // gate, and a liveness answer is not drift.
    } else if (reply.indexOf("err") === 0) {
        errReply(p, reply, verb)
    } else if (reply.indexOf("hello ") === 0) {
        // A hello naming another version than the one this panel asked
        // for is the same incompatibility in a different shape. Defensive:
        // the current helper errs instead of greeting across versions.
        set(p, "serviceIncompatible", true)
        set(p, "inputReady", false)
    }
    return result(p)
}

/// One line from the helper: pop, then route. The executor runs the two
/// halves itself (see route); this composition is what they amount to
/// when the chord callback leaves the reply state alone.
function dispatch(state, line, ctx) {
    var popped = pop(state, line)
    var routed = route(popped.state, popped.reply, popped.verb, ctx)
    return {
        state: routed.state,
        actions: popped.actions.concat(routed.actions)
    }
}

/// The connection died (the socket flipped to disconnected, or the object
/// is being rebuilt). A chord awaiting its final line's ack settles as a
/// cancellation — the helper released everything it held on the way
/// down, no ack is coming — and the ledger of oks owed by this connection
/// dies with it, so nothing a later connection answers can settle the
/// chord a second time.
function connectionLost(state) {
    var p = program(state)
    if (p.state.chordAcks.chordDone) emit(p, { op: "chordTimedOut" })
    set(p, "chordAcks", ChordAcks.connectionLost(p.state.chordAcks))
    return result(p)
}

function helloAcked(p) {
    set(p, "serviceIncompatible", false)
    set(p, "inputReady", false)
    // On a genuinely NEW connection the helper released everything the old
    // one held when that socket closed, so a locked modifier did not
    // survive the reconnect however the indicator looked. Reset to match,
    // and do it without emitting the releases — sending `up` for a code
    // nobody holds is a lie in the other direction. Caps is a semantic
    // panel control, not a held key on this connection, so a helper
    // restart does not turn it off. Only the real device-held modifiers
    // reset.
    //
    // The gate matters: the repair timer re-hellos an open-but-unready
    // socket (a configure refused, a helper still starting) WITHOUT the
    // connection ever dropping. That helper still holds whatever the panel
    // asked it to hold, so neither the state reset nor the `mods 0` may
    // fire here — resetting the reducer over a live hold would leave the
    // device Shift down under an idle panel.
    if (p.state.socketReconnected) {
        set(p, "socketReconnected", false)
        set(p, "capsFactsFailed", false)
        // A genuinely new connection also resets the settle guard's world
        // — the helper is back at group 0 and whatever this panel followed
        // or commanded belongs to the old socket. The next reading
        // establishes and arms the post-reconnect window.
        emit(p, { op: "settleGuardConnected" })
        emit(p, { op: "modifiers", event: { type: "releaseAll" } })
        // Session bookkeeping starts over with the connection: the next
        // configure's identity must be compared against what THIS helper
        // instance has acknowledged, and no reply can still arrive for a
        // transaction a predecessor was holding.
        emit(p, { op: "session", event: { type: "helloAcked", fresh: true } })
        send(p, "mods 0")
    } else {
        // The repair timer's re-hello of a live socket: the handshake
        // holds, nothing resets.
        emit(p, { op: "session", event: { type: "helloAcked", fresh: false } })
    }
    // Through the choke point like every command: this reply pops what it
    // answers. A restarted helper is back at group 0 and has no idea which
    // layout is current; the keyboards reply re-reads the compositor, which
    // sends the right group (the panel's group cursor would send whatever
    // it held before the first sync).
    send(p, "keyboards")
}

function keyboardsReply(p, reply) {
    var names = reply.split("\t").slice(1).filter(function (name) {
        return name.length > 0
    })
    set(p, "startupKeyboards", names)
    if (!p.state.startupInventorySeen) {
        set(p, "startupInventorySeen", true)
        set(p, "startupKeyboardName", names.length > 0 ? names[0] : "")
        if (!p.state.anchorKeyboardName)
            set(p, "anchorKeyboardName", p.state.startupKeyboardName)
    }
    emit(p, { op: "pullLayouts" })
}

function configuredReply(p, reply, ctx) {
    // The reply names the keymap generation it installed. A reply without
    // one is not a helper this panel can reason about: the shapes moved
    // together with the version, so this is an installation mismatch, not
    // a recoverable error.
    var gen = parseInt(reply.split("\t")[1])
    if (!isFinite(gen) || gen <= 0) {
        set(p, "serviceIncompatible", true)
        set(p, "inputReady", false)
        return
    }
    settleConfigure(p, gen)
    // Readiness waits for the WHOLE queue: an older reply does not make
    // typing safe while a pipelined configure is still compiling the
    // keymap a press would land in — a chord allowed through now would
    // straddle that drain and lose its release. It also waits for keycap
    // facts that answer the generation this reply just installed: request
    // them the moment the queue is settled.
    if (Session.settled(p.state.session)) {
        // Every group of this install, not just the one being drawn. The
        // helper resolved them all when it installed the keymap, so asking
        // for the rest now costs one extra reply each and makes the next
        // language switch a lookup instead of a round trip through an
        // invalidated, gated, dimmed keyboard.
        var missing = Session.missingCapGroups(p.state.session, ctx.groupCount)
        if (missing.length > 0)
            emit(p, { op: "log", args: ["[oskar] caps requested for group(s)",
                missing.join(","), "of", ctx.groupCount] })
        for (var i = 0; i < missing.length; i++)
            send(p, capsRequestLine(missing[i], ctx.capsPositions))
    }
    // Read from the live session: a write above can fail synchronously
    // and drop the connection, and the gate must answer the session that
    // drop left.
    emit(p, { op: "gateFromSession" })
}

/// A `configured` reply settles the OLDEST outstanding configure (FIFO),
/// not the newest sent. A changed-keymap entry drained every key the
/// helper held for us on its way in (install_config lifts each held code
/// and zeroes the modifiers), so the device-held modifier state resets
/// WITHOUT emitting — an `up` for a code the device no longer holds would
/// be a lie in the other direction — while Caps and Fn stay, being
/// semantic panel controls. A same-keymap entry (a group move, a
/// byte-identical refresh) leaves holds and reducer state exactly as they
/// are. The reply's generation becomes the acknowledged one, which is also
/// what invalidates any keycap facts computed from the superseded install.
function settleConfigure(p, gen) {
    // The FIFO head is the transaction this reply settles; the session
    // pops the same entry, so capture its facts first — the previous
    // acknowledged generation too, before the reduce consumes it.
    var session = p.state.session
    var entry = session.queue.length > 0 ? session.queue[0] : null
    var previousGen = session.ackedGen
    emit(p, { op: "session", event: { type: "configureAck", gen: gen } })
    // The ack is the truthful moment the helper's world — group included —
    // matches the panel's; persist it for the restart fallback
    // (LayoutDevices).
    emit(p, { op: "groupConfirmed", group: p.state.session.group })
    if (!entry) return
    // A GENERATION JUMP on a same-identity ack means the helper's installed
    // map changed since the panel's last ack (another client configured
    // it), so this configure took the FULL path: it drained every held
    // claim and zeroed the mask, and a ledger that still believes them
    // draws a locked Shift over a device holding nothing. The jump IS the
    // drain, whatever the entry promised. (previousGen 0 is the first ack
    // of a session — its entry is `changed` by construction.)
    var drained = entry.changed
        || (previousGen !== 0 && gen !== previousGen)
    if (!drained) return
    emit(p, { op: "modifiers",
        event: { type: "configureDrain", stamp: entry.seq } })
}

function capsReply(p, reply) {
    // The helper's keycap facts for the world it has installed. The
    // session refuses any reply whose generation no longer matches the
    // acknowledged one — a superseded answer computed from a keymap the
    // helper no longer has can never enable caps, and while nothing current
    // exists the typing gate stays shut.
    var parsed = Session.parseCapsReply(reply)
    if (!parsed) {
        // A reply the parser refuses is protocol drift, not an empty
        // keymap: refuse the world rather than draw a guessed level.
        emit(p, { op: "error", args: ["[oskar] unreadable keycap facts reply"] })
        set(p, "capsFactsFailed", true)
        set(p, "inputReady", false)
        return
    }
    var applied = Session.applyCapsReply(p.state.session, parsed)
    set(p, "session", applied.state)
    if (!applied.accepted) return
    set(p, "capsFactsFailed", false)
    emit(p, { op: "shareKeymap" })
    // Judged against the LIVE session when the action runs, not the
    // planned copy: the session write above rebuilds the rows, which can
    // release a held key, whose `up` can fail and drop the connection in
    // the same call — and a dropped connection has shut the gate. Only
    // ever opens; facts for another group never close a gate that stands.
    emit(p, { op: "gateOpenIfReady" })
}

function errReply(p, reply, verb) {
    if (reply.indexOf("err protocol") === 0) {
        // The helper answered hello with the version it speaks, and it is
        // not ours: the installed binary predates (or postdates) this
        // panel. The panel never installs anything on its own; the offer
        // is the copied install command.
        set(p, "serviceIncompatible", true)
        set(p, "inputReady", false)
    } else if (reply === "err not ready") {
        // A helper fresh out of systemd start answers err until its default
        // keymap is installed; it cannot become ready without a configure,
        // and nothing else sends one — so ask the compositor now instead of
        // waiting out the repair timer.
        emit(p, { op: "pullLayouts" })
    } else if (reply === "err key held" || reply === "err not holding") {
        // Ownership refusals mean the helper's hold state is ahead of ours;
        // the device is fine and typing stays enabled. The panel's chords
        // never produce them, so one appearing is a client bug worth a
        // journal line without bricking the keyboard.
        emit(p, { op: "warn", args: ["[oskar] ownership refusal:", reply] })
    } else if (reply === "err bad group") {
        badGroup(p, verb)
    } else if (reply === "err cannot configure keymap") {
        cannotConfigure(p)
    } else if (reply === "err unknown command") {
        // The two sides disagree about the command set one way or the
        // other — an older helper, or a peer panel sending a verb it should
        // not. Status-only either way, never a typing gate: the handshake's
        // version check is the compatibility contract.
        emit(p, { op: "warn", args: ["[oskar] helper refused a command:", reply] })
    } else {
        // An unrecognized reply can only be protocol drift; fail closed
        // and leave a trace.
        set(p, "inputReady", false)
        emit(p, { op: "warn", args: ["[oskar] unrecognized reply:", reply] })
    }
}

/// One err, three verbs it can answer: a caps pre-fetch for a group the
/// keymap does not carry, a `group` command, or a configure whose own
/// incoming map cannot carry its group. The pop says WHICH this one
/// settled, and the ledgers part ways on it.
function badGroup(p, verb) {
    if (verb === "configure" && p.state.session.queue.length > 0) {
        // The refusal answered a QUEUED configure: its entry must settle or
        // it orphans the queue — settled() false forever, and the repair
        // timer's 2 s hello → keyboards → compositor → configure cycle runs
        // until a socket rebuild. Failed clean, no modifier lift: this
        // refusal happens before any install or drain, so a lock the panel
        // shows is a lock the device still holds.
        emit(p, { op: "session", event: { type: "configureFailed" } })
        return
    }
    var failed = !Session.capsCurrent(p.state.session)
    if (verb === "caps" || verb === "group") {
        // For the group being DRAWN a refusal is keymap-wide disagreement
        // about the world, and the hint says so instead of letting the
        // built-in table pass for it. For another group the panel
        // pre-fetches it is not: the drawn group still has current facts,
        // typing still answers the installed keymap, and switching INTO
        // that group will go the slow way. Refusing the whole world over
        // it would gate a keyboard that is working.
        set(p, "capsFactsFailed", failed)
        if (failed) {
            set(p, "inputReady", false)
        } else {
            emit(p, { op: "error", args: ["[oskar] helper has no"
                + " facts for a pre-fetched group;"
                + " that group will resolve on switch"] })
        }
        return
    }
    // An unattributable pop (a slot from before verbs carried, or a
    // bypassed write): the caps-shaped reading is the conservative one —
    // it can gate, it can never corrupt the configure ledger.
    set(p, "capsFactsFailed", failed)
    if (failed) set(p, "inputReady", false)
}

/// A FAILED configure is authoritative about the device world in a way
/// the error text cannot qualify: a compile or rate-limit refusal happens
/// BEFORE install_config drains anything (the helper still holds whatever
/// the panel had down), while an upload failure happens AFTER the drain
/// (the helper holds nothing) — and both answer with this same err. The
/// panel therefore settles to the drained world UNCONDITIONALLY, then
/// makes the device agree: an explicit `up` for every modifier the panel
/// had locked — a real lift when the helper never drained, a forwarded
/// no-op when it already did — plus `mods 0`, so the compositor's mask
/// cannot keep the stale modifier alive (the helper re-asserts its mask
/// from its held set on the next key event, so `mods 0` alone would not
/// survive). A pending chord survives untouched: its own key hold is real
/// in the never-drained case, and in the drained case its mouse-up is a
/// forwarded no-op. A release that ran while this configure was
/// outstanding left the lock standing on purpose (the reply owns the
/// settle), so the capture below still sees the modifiers it must lift.
function cannotConfigure(p) {
    emit(p, { op: "session", event: { type: "configureFailed" } })
    var lockedPositions = []
    for (var m = 0; m < Modifiers.ORDER.length; m++) {
        if (p.state.modifierState[Modifiers.ORDER[m]] === "locked")
            lockedPositions.push(Modifiers.positionFor(Modifiers.ORDER[m]))
    }
    // stamp -1: a failed configure drained nothing a pending chord depends
    // on for certain, so every pending record survives (minus its restore
    // plan, which would re-press a lock the panel just dropped).
    emit(p, { op: "modifiers", event: { type: "configureDrain", stamp: -1 } })
    for (var u = 0; u < lockedPositions.length; u++)
        send(p, "up " + lockedPositions[u])
    send(p, "mods 0")
    set(p, "inputReady", false)
}
