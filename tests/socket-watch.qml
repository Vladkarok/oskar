// Ticket 47's pure seam: the socket reconnect decision. The incident this
// owns (the install-from-zero stranger, 2026-09-14, lab journal): a daemon
// stop under a connected panel can leave quickshell's Socket reporting
// `connected: true` on a peer-closed socket (Keyboard.qml's own comment
// documents the live observation; reproduced in the lab twice — once by the
// stranger's service restarts, once on purpose). The old reconnect policy
// answered "an open socket is never torn down" with a re-hello — written
// into a dead object, unanswered forever — so the panel wedged at
// "Starting oskar.service…" with the typing gate shut, every key
// click a silent no-op, and only a shell restart escaped it.
//
// The decision table here pins the watchdog: a hello that has gone
// unanswered past its fair window rebuilds the socket WHATEVER `connected`
// claims, because a live daemon answers hello in well under a second and
// the only thing that outlives the window is a socket that cannot deliver.
//
// Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../SocketWatch.js" as SocketWatch
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("a connected socket with no hello outstanding sends one", function () {
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: false
            }), "hello")
        })

        T.test("a young outstanding hello is given its fair window", function () {
            // A configure compiling ahead of the hello can delay its answer;
            // the window exists so that never becomes a rebuild.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true,
                helloAgeMs: SocketWatch.HELLO_STALE_MS - 1
            }), "wait")
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true, helloAgeMs: 0
            }), "wait")
        })

        T.test("a stale outstanding hello rebuilds even while connected", function () {
            // THE stranger's wedge: `connected` lies true on a dead socket.
            // The hello went out, nothing answered, the window expired —
            // the only honest move is tearing the object down.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true,
                helloAgeMs: SocketWatch.HELLO_STALE_MS
            }), "rebuild")
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true,
                helloAgeMs: SocketWatch.HELLO_STALE_MS * 10
            }), "rebuild")
        })

        T.test("a disconnected socket takes the file-check path", function () {
            T.equal(SocketWatch.reconnectAction({
                connected: false, helloInFlight: false
            }), "path-check")
            T.equal(SocketWatch.reconnectAction({
                connected: false, helloInFlight: true,
                helloAgeMs: SocketWatch.HELLO_STALE_MS
            }), "path-check")
        })

        T.test("a missing age counts as young, never as stale", function () {
            // The caller guards Date.now() arithmetic itself; the decision
            // must not read an absent age as infinite.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true
            }), "wait")
        })

        T.test("an absent socket object is a path-check, not a crash", function () {
            T.equal(SocketWatch.reconnectAction(null), "path-check")
            T.equal(SocketWatch.reconnectAction(undefined), "path-check")
            T.equal(SocketWatch.reconnectAction({}), "path-check")
        })

        T.test("the fair window is seconds, not ticks: 5s", function () {
            // A 4-layout keymap compile plus the hello round trip measured
            // under 1.5s in the lab; the window keeps multiples of that in
            // hand while still recovering a wedge inside ~7s (one tick to
            // notice, the window, one tick to act).
            T.equal(SocketWatch.HELLO_STALE_MS, 5000)
        })

        // ---- ticket 54: the rebuild's own residuals ----
        //
        // The whole point of "rebuild" is that the disconnect arm never
        // runs — the socket lies `connected`, which is why the object is
        // torn down instead of waiting for a state change. Two of that
        // arm's resets therefore cannot be left to it (both named by 47's
        // review), and the ledger of what a rebuild resets belongs beside
        // the verdict that orders it, here, where the suite can pin it.

        T.test("a rebuild drains the pending text-reply FIFO", function () {
            // Residual one, the pre-fix shape: the rebuild cleared only
            // the hello mark and left the FIFO standing, so its stale
            // head was settled by the first `text-ok` after recovery —
            // the wrong reply matched to the wrong request. The drain is
            // the disconnect arm's semantics exactly: cleared, the
            // callbacks dropped rather than invoked, because the socket
            // that owed them answers on no connection this panel holds.
            var resets = SocketWatch.rebuildResets({
                pendingTextReplies: [function () {}, null, function () {}],
                sharedKeymapGen: 3
            })
            T.deepEqual(resets.pendingTextReplies, [])
            // Absent fields reset the same way: the early-boot path
            // check rebuilds a socket that never handed anything over.
            T.deepEqual(SocketWatch.rebuildResets(null).pendingTextReplies, [])
        })

        T.test("a rebuild zeroes the compositor share generation", function () {
            // Residual two, the pre-fix shape: sharedKeymapGen survived
            // the rebuild, and a restarted daemon counts its installs
            // from one again — the fresh hello's ack can repeat the
            // stale value, the once-per-generation share guard compares
            // equal and skips a re-share of a file the compositor never
            // compiled from this daemon (and nothing else re-reads an
            // unchanged path): two keymaps on the seat, silently.
            var resets = SocketWatch.rebuildResets({
                pendingTextReplies: [],
                sharedKeymapGen: 7
            })
            T.equal(resets.sharedKeymapGen, 0)
            T.equal(SocketWatch.rebuildResets(null).sharedKeymapGen, 0)
        })

        Qt.exit(T.report("socket watch"))
    }
}
