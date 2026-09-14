// Ticket 47's pure seam: the socket reconnect decision. The incident this
// owns (the install-from-zero stranger, 2026-09-14, lab journal): a daemon
// stop under a connected panel can leave quickshell's Socket reporting
// `connected: true` on a peer-closed socket (Keyboard.qml's own comment
// documents the live observation; reproduced in the lab twice — once by the
// stranger's service restarts, once on purpose). The old reconnect policy
// answered "an open socket is never torn down" with a re-hello — written
// into a dead object, unanswered forever — so the panel wedged at
// "Starting omarchy-osk.service…" with the typing gate shut, every key
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

        Qt.exit(T.report("socket watch"))
    }
}
