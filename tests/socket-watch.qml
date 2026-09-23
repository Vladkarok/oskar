// A pure seam: the socket reconnect decision. A daemon stop under a
// connected panel can leave quickshell's Socket reporting
// `connected: true` on a peer-closed socket (Keyboard.qml's own comment
// documents the live observation). A reconnect policy that treats "an
// open socket is never torn down" as license to re-hello into it writes
// into a dead object, unanswered forever — the panel wedges at
// "Starting oskar.service…" with the typing gate shut, every key
// click a silent no-op, and only a shell restart escapes it.
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

        // ---- the quiescent probe (the timer stays armed when healthy) ----
        //
        // The watchdog above only ever judges a hello it had reason to
        // send — and nothing sends one once the panel is healthy, so a
        // SIGKILLed helper behind a lying `connected` would go silent
        // forever. The slow always-armed tick asks with ping instead;
        // the table decides which word.

        T.test("an idle healthy tick asks with ping, not hello", function () {
            // A hello reply re-handshakes — the gate drops, everything is
            // re-asked — which is repair when broken and a visible blink
            // when healthy. ping carries no state.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: false, idle: true
            }), "ping")
            // Non-idle keeps the old behavior word for word.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: false, idle: false
            }), "hello")
        })

        T.test("a held wire is never probed", function () {
            // A paced paste or armed chord owns the connection's reply
            // stream: ChordAcks poisons a chord on ANY non-ok reply
            // popped inside its region — a pong included. The tick holds
            // even when idle.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: false,
                idle: true, probeHold: true
            }), "wait")
        })

        T.test("an outstanding probe outranks idle and hold alike", function () {
            // The window judgement is the same whatever word went out;
            // the hold never excuses a stale probe from rebuilding.
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true,
                helloAgeMs: SocketWatch.HELLO_STALE_MS,
                idle: true, probeHold: true
            }), "rebuild")
            T.equal(SocketWatch.reconnectAction({
                connected: true, helloInFlight: true,
                helloAgeMs: 0, idle: true, probeHold: true
            }), "wait")
        })

        // ---- the rebuild's own residuals ----
        //
        // The whole point of "rebuild" is that the disconnect arm never
        // runs — the socket lies `connected`, which is why the object is
        // torn down instead of waiting for a state change. Some of that
        // arm's resets therefore cannot be left to it, and the ledger of
        // what a rebuild resets belongs beside the verdict that orders
        // it, here, where the suite can pin it.

        T.test("a rebuild zeroes the compositor share generation", function () {
            // The text-reply FIFO left with the typed delivery routes;
            // the ledger's one remaining field is the share generation
            // (see the module).
            var resets = SocketWatch.rebuildResets({
                sharedKeymapGen: 7
            })
            T.equal(resets.sharedKeymapGen, 0)
            T.equal(SocketWatch.rebuildResets(null).sharedKeymapGen, 0)
        })


        Qt.exit(T.report("socket watch"))
    }
}
