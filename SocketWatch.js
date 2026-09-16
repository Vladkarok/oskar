.pragma library

// The socket reconnect decision (ticket 47), split out of
// Keyboard.qml's reconnect timer as a pure seam.
//
// Why this exists. Quickshell 0.3.1's Socket can fail to report a peer
// close: the daemon stops, the transport dies, and the `connected`
// property still reads true — Keyboard.qml's error handler documents the
// live observation, and the install-from-zero stranger's whole session
// (2026-09-14, lab journal) ran inside the resulting wedge: the panel
// re-helloed a dead object every two seconds, nothing ever answered, the
// typing gate stayed shut with "Starting omarchy-osk.service…" standing
// and every key click a silent no-op, and only a shell restart escaped.
// The one escape the code had — the path check that rebuilds the socket —
// is guarded by `!connected`, so a socket that lies true never reaches it.
//
// The watchdog here closes that hole from the other side: the caller
// marks a hello as outstanding the moment it is written and clears the
// mark the moment ANY line arrives from the helper. A daemon that is
// alive answers hello in well under a second, so a hello still
// outstanding past HELLO_STALE_MS means the socket cannot deliver —
// whatever `connected` claims — and the only honest move is rebuilding
// the object. The window is deliberately generous: the helper serves
// each connection in order, so a configure compiling ahead of the hello
// delays its answer, and that ordinary round trip must never earn a
// rebuild (measured in the lab: a 4-layout compile plus the reply lands
// inside 1.5s; the window keeps multiples of that in hand).

/// How long an unanswered hello is believed before the socket is torn
/// down anyway. One reconnect tick (2s) to notice, this window, one tick
/// to act: a wedge recovers inside ~7s.
var HELLO_STALE_MS = 5000

/// One reconnect tick's decision.
///
/// state.connected — whether the socket object claims to be open. May lie
///   true on a dead transport (see above); the decision never trusts it
///   alone.
/// state.helloInFlight — a hello was written and nothing has arrived
///   since. The caller sets it on write and clears it on any read, so any
///   reply — not just the hello's — proves the pipe alive end to end.
/// state.helloAgeMs — milliseconds since that hello was written.
///
/// Returns "hello" (write a hello and mark it outstanding), "wait" (the
/// outstanding hello is still inside its fair window), "rebuild" (tear
/// the socket object down and let the loader recreate it), or
/// "path-check" (no socket claims to be open: probe the helper's socket
/// file and rebuild only if it exists — the pre-watchdog behavior).
function reconnectAction(state) {
    if (!state || typeof state !== "object")
        return "path-check"
    var connected = state.connected === true
    if (!connected)
        return "path-check"
    if (state.helloInFlight !== true)
        return "hello"
    var age = state.helloAgeMs
    if (typeof age !== "number" || !isFinite(age) || age < 0)
        return "wait"
    return age >= HELLO_STALE_MS ? "rebuild" : "wait"
}

/// Ticket 54: what the rebuild path resets beyond the socket object
/// itself. The whole point of a rebuild is that the disconnect arm never
/// runs — a socket that lies `connected` is why "rebuild" exists — so two
/// of that arm's resets cannot be left to it (both named by 47's review):
///
///   - the pending text-reply FIFO. A stale head left standing is settled
///     by the first `text-ok` after recovery: the wrong reply matched to
///     the wrong request. The rebuild drains it with the disconnect arm's
///     semantics — cleared, the callbacks dropped rather than invoked,
///     because the socket that owed them answers on no connection this
///     panel holds.
///   - the compositor share generation. A restarted daemon counts its
///     installs from one again, so the fresh connection's ack can repeat
///     the generation the panel last shared; the once-per-generation guard
///     would compare equal and skip a re-share of a file the compositor
///     never saw from this daemon — and nothing else re-reads an unchanged
///     path: two keymaps on the seat, silently.
///
/// The ledger lives beside the verdict that orders it so the decision and
/// its resets cannot drift apart; the caller packs its properties in and
/// assigns the returned fields back, the reconnectAction discipline.
function rebuildResets(state) {
    return { pendingTextReplies: [], sharedKeymapGen: 0 }
}
