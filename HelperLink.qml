import QtQuick
import Quickshell
import Quickshell.Io
import "SocketWatch.js" as SocketWatch
import "KeyboardSession.js" as Session

Item {
    id: link

    // The helper connection's transport, split out of Keyboard.qml (the
    // structural split's step one): the socket object in its loader, the
    // one rebuild, the hello and reconnect timers, the socket-file check
    // and the quiescent ping. What a line MEANS is the keyboard's — every
    // reply reaches its dispatch through `lineReceived`, and every write,
    // either direction, crosses the keyboard's one choke point
    // (`sendChoked` in, `write` out) so the ChordAcks correlation ledger
    // never splits.

    // The live socket object, or null while the loader is between
    // teardown and recreation.
    readonly property QtObject socket: helperLoader.item
    // Mirrors the live socket: false before the first dial, while the
    // loader rebuilds it, and after a drop.
    readonly property bool connected: socket ? socket.connected : false

    // Set when the socket reaches `connected`, consumed by the hello reply:
    // only a genuinely new connection may reset device-held modifier state,
    // never the repair timer's re-hello of a live one. See the hello handler.
    property bool socketReconnected: false
    // The hello watchdog's ledger (ticket 47): a hello was written and
    // nothing has arrived from the helper since. `connected` alone cannot
    // be trusted to say the pipe is alive — a peer-closed quickshell
    // Socket can keep reporting true (observed live twice: the owner's
    // original note in the error handler below, and the install-from-zero
    // stranger's whole session) — so liveness is proved by traffic, and a
    // hello outstanding past SocketWatch.HELLO_STALE_MS rebuilds the
    // socket whatever `connected` claims. Cleared by every arriving line,
    // by a disconnect, and by the rebuild itself (the hello belonged to
    // the object being torn down).
    property bool helloInFlight: false
    property real helloSentAt: 0

    // The host facts the reconnect decision reads (SocketWatch's state):
    // bound from the keyboard at the usage site, because the ledgers they
    // summarise — the session's configure queue, the paste pacer, the
    // chord ledger — are the keyboard's, never the transport's.
    property bool inputReady: false
    property bool sessionSettled: false
    property bool pastePacing: false
    property bool chordAwaitingAck: false

    // The keyboard's one write choke point (sendCommandUnchecked), handed
    // down so this component's own protocol lines — hello and ping —
    // occupy their correlation slot like every command: takes the line,
    // returns whether it was written. The raw half is write() below;
    // only the choke point calls that one.
    property var sendChoked: null

    signal lineReceived(string line)
    signal connectionDropped()
    signal rebuilt()

    /// The raw write: text plus newline, flushed, while the socket
    /// object exists. No ledger here — the caller (the keyboard's
    /// sendCommandUnchecked) pushes the ChordAcks slot, which is what
    /// keeps every command counted at exactly one choke point.
    function write(text) {
        if (!socket) return false
        socket.write(text + "\n")
        socket.flush()
        return true
    }

    // The one rebuild of the socket object: destroy and recreate it
    // through the loader, on the next tick where QML is idle enough to
    // tear a live object graph down safely. onError's original home, now
    // shared with the watchdog's "rebuild" answer and the path check —
    // one place that knows a fresh socket object is the cure.
    // The state resets the rebuild used to carry are the keyboard's:
    // `rebuilt()` runs them synchronously here, before the teardown is
    // queued — the order the monolith had.
    function rebuild() {
        link.helloInFlight = false
        rebuilt()
        Qt.callLater(function () {
            helperLoader.active = false
            helperLoader.active = true
        })
    }

    /// The quiescent probe's write. ping is the daemon's own liveness
    /// word — hello-gated, one reply line, no state — through the one
    /// choke point so it occupies its correlation slot like every
    /// command. The watchdog marks carry the same meaning they carry for
    /// hello: an answer is owed, and ANY line arriving clears the debt.
    /// A hello would not do here: its reply re-handshakes (the gate
    /// drops, keyboards and configure are re-asked), which is repair
    /// when broken and a visible blink on every probe when healthy.
    function sendProbePing() {
        if (!link.sendChoked || !link.sendChoked("ping")) return
        link.helloInFlight = true
        link.helloSentAt = Date.now()
    }

    // The helper may start after the shell: systemd orders the service
    // against graphical-session.target, not against the shell, so the panel's
    // first connection attempt can find no socket. Quickshell's Socket never
    // recovers from that — a failed connect leaves its internal QLocalSocket
    // in place, and setConnected(true) only dials when that object is gone,
    // with nothing but a successful connection ever clearing it — so the
    // whole socket is rebuilt whenever the helper's socket file exists and
    // the helper has not answered hello yet. A helper that dies later needs
    // none of this: the disconnected path clears the object and the pending
    // targetConnected redials on its own. One rebuild per two seconds while
    // the helper is down; a completed handshake stops the timer.
    Loader {
        id: helperLoader
        active: true
        sourceComponent: helperComponent
    }

    Component {
        id: helperComponent

        Socket {
            id: helper
            path: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/oskar/control.sock"
            connected: true

            onConnectionStateChanged: {
                if (connected) {
                    // Readiness is not the same as "the socket answered": the
                    // helper accepts commands before the compositor keymap has
                    // been forwarded to its virtual keyboard, and would drop
                    // every key. hello therefore goes out on a short delay
                    // after the flip — inline writes were observed landing on
                    // a closed device during the VM dogfooding. The flip is
                    // also what the hello reply's reset keys off: only a
                    // genuinely new connection released the old one's holds.
                    link.socketReconnected = true
                    helloTimer.restart()
                } else {
                    // The hello this object was owed can no longer arrive;
                    // the watchdog must not keep waiting on it. Everything
                    // else the disconnect arm did is keyboard state and
                    // rides connectionDropped(), verbatim, on the other
                    // side of the split.
                    link.helloInFlight = false
                    link.connectionDropped()
                }
            }

            parser: SplitParser {
                onRead: function (line) {
                    // Any line from the helper proves the pipe alive end to
                    // end (ticket 47's watchdog): the daemon serves each
                    // connection in order, so whatever this is, a hello
                    // written before it has been answered or overtaken by
                    // work that is about to answer.
                    link.helloInFlight = false
                    // Framing only: what the line MEANS is the keyboard's
                    // dispatch, reached through the signal — after the
                    // watchdog clear, exactly the order the monolith's
                    // onRead had.
                    link.lineReceived(line)
                }
            }

            // A quickshell 0.3.1 peer close can log "Socket error for …"
            // without ever flipping `connected` (observed live: the property
            // still read true minutes after QLocalSocket::PeerClosedError),
            // which leaves inputReady stuck at true — a ready-looking
            // keyboard that cannot type, the exact silent failure §6
            // forbids. An error arriving on a socket that still reads
            // connected is therefore treated as the drop the state change
            // failed to report: enter the disconnected state and rebuild
            // the socket object, the same reset socketPathCheck uses, so
            // the gated repair timer owns the redial and the next good
            // handshake clears the notice. A failed dial reports with
            // connected false and no-ops here, so this cannot loop.
            onError: {
                if (!connected) return
                link.rebuild()
            }
        }
    }

    Timer {
        id: helloTimer
        // Gives a fresh connection attempt a moment to actually open before
        // hello goes out. When the helper is still down the write fails
        // harmlessly and the next rebuild dials again.
        interval: 150
        repeat: false
        onTriggered: () => {
            if (link.socket && link.sendChoked) {
                // The version the session negotiates, never a literal: the
                // reply matcher in the keyboard's dispatch compares
                // against the same constant, and a stale literal here
                // reads as an installation mismatch against a helper
                // this panel is actually compatible with.
                // Through the choke point like every command: a re-handshake
                // with commands unanswered must not let hello's reply pop a
                // queued slot it does not answer.
                link.sendChoked("hello " + Session.PROTOCOL_VERSION)
                // The watchdog's mark: written and unanswered. The write
                // itself cannot be trusted to fail on a dead transport
                // (quickshell may buffer it silently), so the mark is set
                // unconditionally and only ever cleared by arriving traffic.
                link.helloInFlight = true
                link.helloSentAt = Date.now()
            }
        }
    }

    Process {
        id: socketPathCheck
        command: ["test", "-S", (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/oskar/control.sock"]
        onExited: (code, ok) => {
            // The check ran a moment ago; the socket may have connected since
            // (the original attempt succeeding, or a sibling tick's rebuild).
            // Rebuilding a live connection would drop it mid-handshake.
            var item = link.socket
            if (code === 0 && !link.inputReady && !(item && item.connected)) {
                link.rebuild()
            }
        }
    }

    Timer {
        id: reconnectTimer
        // Adaptive, and NEVER stopped (the protocol round's P2): the
        // timer used to stop once the panel was healthy, so a helper
        // SIGKILLed at quiescence behind a socket that lies `connected`
        // (Quickshell 0.3.1, observed live twice) was never asked
        // anything — every keystroke wrote into the void until an
        // unrelated event or a shell restart. Healthy, the tick is slow
        // and asks with ping (below); unhealthy or with a probe still
        // outstanding, it keeps the repair cadence so a wedge is still
        // noticed, judged and acted on inside ~7 s.
        // Also while a configure is outstanding. Readiness alone stopped
        // being enough once a group-only configure no longer lowered
        // `inputReady` (ticket 16): a socket that stays `connected` but
        // never answers `configured` would leave the panel ready-looking,
        // drawing the acked group while the helper types the queued one,
        // with no tick to notice. A configure is answered in well under
        // the fast interval — the helper replies before it compiles
        // anything — so an entry still outstanding when this fires is a
        // lost reply, not a slow one.
        interval: (link.helloInFlight || !link.inputReady
            || !link.sessionSettled) ? 2000 : 15000
        repeat: true
        running: true
        onTriggered: () => {
            // Ticket 47's watchdog: the decision is SocketWatch's pure
            // table, pinned in tests/socket-watch.qml. The old inline
            // policy — an open socket is only ever re-helloed — turned a
            // socket that lies `connected` on a peer-closed transport
            // into a permanent wedge (the install-from-zero stranger's
            // dead keys: re-hellos written into a dead object, "Starting
            // oskar.service…" standing, every key click a silent no-op,
            // escape only by shell restart). Now a probe outstanding past
            // its fair window rebuilds the socket object whatever
            // `connected` claims; a live helper answers in well under a
            // second, so only a socket that cannot deliver ever sees the
            // window expire. The rebuild path is also the silent-dial
            // cure: a fresh socket that connects without ever signalling
            // gets a hello on the next tick, and the tick after that
            // treats its silence the same way.
            var item = link.socket
            var action = SocketWatch.reconnectAction({
                connected: !!(item && item.connected),
                helloInFlight: link.helloInFlight,
                helloAgeMs: Date.now() - link.helloSentAt,
                // The quiescent probe: healthy and settled asks with
                // ping; a paced paste or an armed chord holds the wire
                // (ChordAcks poisons a chord on any non-ok reply inside
                // its region — a pong included).
                idle: link.inputReady && link.sessionSettled,
                probeHold: link.pastePacing || link.chordAwaitingAck
            })
            if (action === "hello") {
                helloTimer.restart()
                return
            }
            if (action === "ping") {
                sendProbePing()
                return
            }
            if (action === "rebuild") {
                link.rebuild()
                return
            }
            if (action === "path-check") {
                socketPathCheck.running = true
                return
            }
            // "wait": the outstanding probe is still inside its window,
            // or the wire is held.
        }
    }
}
