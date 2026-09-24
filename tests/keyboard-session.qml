// The keyboard session, driven as a pure module: the
// configure transaction queue, and the
// generation correlation that decides which keycap facts may be drawn.
// Run with tools/run-tests.sh — no compositor, no display. The helper's end
// of the same facts is pinned in daemon unit tests and the nested-session
// integration suite.
import QtQml
import "../KeyboardSession.js" as Session
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        var s0 = Session.initial()

        // ---- configure transactions: the queue this module owns ----

        T.test("a configure is queued with its identity, group and send stamp", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\tgrp:alt_shift_toggle\t\t1"
            })
            T.equal(s.queue.length, 1)
            T.equal(s.queue[0].identity,
                "configure\tevdev\tpc105\tus,ua\t\tgrp:alt_shift_toggle\t")
            T.equal(s.queue[0].group, 1)
            T.equal(s.queue[0].seq, 1)
            // Against an empty history the keymap identity counts as changed.
            T.equal(s.queue[0].changed, true)
            T.equal(s.sends, 1)
        })

        T.test("a byte-identical configure is queued as unchanged", function () {
            var payload = "configure\tevdev\tpc105\tus,ua\t\tgrp:alt_shift_toggle\t\t1"
            var s = Session.reduce(s0, { type: "configureSent", payload: payload })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            s = Session.reduce(s, { type: "configureSent", payload: payload })
            T.equal(s.queue[0].changed, false)
        })

        T.test("a group-only reconfigure keeps the identity and is unchanged", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\tgrp:alt_shift_toggle\t\t1"
            })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\tgrp:alt_shift_toggle\t\t0"
            })
            T.equal(s.queue[0].changed, false)
            T.equal(s.queue[0].group, 0)
        })

        T.test("the ack settles the OLDEST transaction and installs its world", function () {
            var first = "configure\tevdev\tpc105\tus,ua\t\t\t\t1"
            var second = "configure\tevdev\tpc104\tus,ua\t\t\t\t0"
            var s = Session.reduce(s0, { type: "configureSent", payload: first })
            s = Session.reduce(s, { type: "configureSent", payload: second })
            T.equal(s.queue.length, 2)
            // Installed identity while both are outstanding: the newest.
            T.equal(Session.installed(s),
                "configure\tevdev\tpc104\tus,ua\t\t\t")
            s = Session.reduce(s, { type: "configureAck", gen: 5 })
            T.equal(s.queue.length, 1)
            T.equal(s.acked, "configure\tevdev\tpc105\tus,ua\t\t\t")
            T.equal(s.ackedGen, 5)
            T.equal(s.group, 1)
            // And the second settle completes the queue.
            s = Session.reduce(s, { type: "configureAck", gen: 6 })
            T.equal(Session.settled(s), true)
            T.equal(s.group, 0)
            T.equal(s.ackedGen, 6)
        })

        T.test("an ack with no outstanding transaction changes nothing", function () {
            var s = Session.reduce(s0, { type: "configureAck", gen: 5 })
            T.equal(Session.settled(s), true)
            T.equal(s.ackedGen, 0)
            T.equal(s.acked, "")
        })

        T.test("a failure drops its own entry and rebases the survivors", function () {
            var good = "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            var bad = "configure\tevdev\tpc105\tus\t\t\t/bad\t0"
            var after = "configure\tevdev\tpc105\tus,ua,de\t\t\t\t1"
            var s = Session.reduce(s0, { type: "configureSent", payload: good })
            s = Session.reduce(s, { type: "configureAck", gen: 4 })
            s = Session.reduce(s, { type: "configureSent", payload: bad })
            s = Session.reduce(s, { type: "configureSent", payload: after })
            // While bad is outstanding it counts as changed against good.
            T.equal(s.queue[0].changed, true)
            s = Session.reduce(s, { type: "configureFailed" })
            T.equal(s.queue.length, 1)
            // Rebasing against the still-installed good keymap: the helper
            // refused bad, so after's drain test compares against good.
            T.equal(s.queue[0].changed, true)
            T.equal(s.queue[0].identity, "configure\tevdev\tpc105\tus,ua,de\t\t\t")
            // A no-change entry is a no-drain: hasDrainAhead says so. The
            // payload is byte-identical to the rebased keymap, so it queues
            // as unchanged.
            var s2 = Session.reduce(s, { type: "configureAck", gen: 4 })
            s2 = Session.reduce(s2, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua,de\t\t\t\t1"
            })
            T.equal(Session.hasDrainAhead(s2), false)
        })

        T.test("hasDrainAhead sees a changed configure ahead of the next lines", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t1"
            })
            T.equal(Session.hasDrainAhead(s), true)
        })

        // ---- generation correlation: which facts may be drawn ----

        T.test("facts are accepted only for the acknowledged generation and group", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t1"
            })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            // Facts from an older helper generation: superseded, refused.
            var stale = Session.reduce(s, {
                type: "capsFacts", gen: 2, group: 1, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(stale.caps, null)
            T.equal(Session.capsCurrent(stale), false)
            // Facts for another group of the SAME generation: kept, because
            // the panel asks for every group of an install up front — but not
            // drawn, because the device is not typing in that group.
            var otherGroup = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(Session.capsCurrent(otherGroup), false)
            T.equal(Session.capsMap(otherGroup), null)
            T.equal(otherGroup.caps.byGroup[0].AD01[0].text, "q")
            // The matching reply is accepted whole.
            var ok = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 1,
                byPosition: { AD01: [{ text: "й" }, { text: "Й" }] }
            })
            T.equal(Session.capsCurrent(ok), true)
            T.equal(Session.capsMap(ok).AD01[1].text, "Й")

            // The panel's accept seam: a parseable reply from a SUPERSEDED
            // generation must not report accepted, so capsFactsFailed cannot
            // be cleared by it.
            var staleApplied = Session.applyCapsReply(s, {
                gen: 2, group: 1, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(staleApplied.accepted, false)
            T.equal(staleApplied.state.caps, null)
            var okApplied = Session.applyCapsReply(s, {
                gen: 3, group: 1,
                byPosition: { AD01: [{ text: "й" }, { text: "Й" }] }
            })
            T.equal(okApplied.accepted, true)
            T.equal(Session.capsCurrent(okApplied.state), true)
            T.equal(Session.applyCapsReply(s, null).accepted, false)
        })

        T.test("a helper with no installed unit is missing, not stopped", function () {
            // Retry cannot start a unit that does not exist; the hint must
            // say what to install instead.
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: false,
                serviceIncompatible: false, capsFactsFailed: false,
                serviceMissing: true
            }), "missing")
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: false,
                serviceIncompatible: false, capsFactsFailed: false,
                serviceMissing: false
            }), "stopped")
            // A connected helper answers for itself, whatever a stale probe
            // said; an incompatible one still needs updating first.
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: true,
                serviceIncompatible: false, capsFactsFailed: false,
                serviceMissing: true
            }), "starting")
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: false,
                serviceIncompatible: true, capsFactsFailed: false,
                serviceMissing: true
            }), "incompatible")
        })

        T.test("a caps mismatch is unavailable, never the starting notice", function () {
            // Connected + failed facts is keymap-unavailable, not
            // "Starting oskar.service…".
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: true,
                serviceIncompatible: false, keycapsFailed: false,
                capsFactsFailed: true
            }), "unavailable")
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: true,
                serviceIncompatible: false, keycapsFailed: false,
                capsFactsFailed: false
            }), "starting")
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: false,
                serviceIncompatible: false, keycapsFailed: false,
                capsFactsFailed: true
            }), "stopped")
            T.equal(Session.lifecycleKind({
                inputReady: false, serviceConnected: true,
                serviceIncompatible: true, keycapsFailed: false,
                capsFactsFailed: true
            }), "incompatible")
            T.equal(Session.lifecycleKind({
                inputReady: true, serviceConnected: true,
                serviceIncompatible: false, keycapsFailed: true,
                capsFactsFailed: false
            }), "unavailable")
            T.equal(Session.lifecycleKind({
                inputReady: true, serviceConnected: true,
                serviceIncompatible: false, keycapsFailed: false,
                capsFactsFailed: false
            }), "ready")
        })

        T.test("a new acknowledged generation invalidates the drawn facts at once", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            })
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(Session.capsCurrent(s), true)
            // A changed keymap queued but not yet answered: the facts still
            // describe the INSTALLED world, so they keep drawing — but typing
            // is gated by the unsettled queue until the reply lands.
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc104\tus,ua\t\t\t\t0"
            })
            T.equal(Session.capsCurrent(s), true)
            T.equal(Session.settled(s), false)
            T.equal(Session.typingReady(s), false)
            // The reply moves the acknowledged generation: the old facts are
            // stale the moment it is processed.
            s = Session.reduce(s, { type: "configureAck", gen: 4 })
            T.equal(Session.capsCurrent(s), false)
            T.equal(Session.typingReady(s), false)
            // And the new generation's own facts reopen the gate.
            s = Session.reduce(s, {
                type: "capsFacts", gen: 4, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(Session.typingReady(s), true)
        })

        T.test("a group-only reconfigure onto current facts needs no re-request", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            })
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(Session.capsCurrent(s), true)
            // Back to group 0 with the same keymap: the acknowledged facts
            // already answer it, generation and group unchanged.
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            T.equal(Session.capsCurrent(s), true)
            T.equal(Session.typingReady(s), true)
        })

        T.test("the drawn group is requested even when the count under-reports", function () {
            // `groupCount` comes from the configured layout list, and a
            // `kb_file` keymap can carry groups that list does not name. If the
            // acknowledged group were left out of the request, capsCurrent
            // would stay false with nothing to retry it.
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\t\t\t\t/some/keymap\t1"
            })
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            s = Session.reduce(s, { type: "configureAck", gen: 2 })
            T.equal(s.group, 1)
            // The layout list looks like one group; the device is in group 1.
            T.deepEqual(Session.missingCapGroups(s, 1), [0, 1])
            s = Session.reduce(s, {
                type: "capsFacts", gen: 2, group: 1, byPosition: { AD01: [{ text: "q" }] }
            })
            T.deepEqual(Session.missingCapGroups(s, 1), [0])
            T.equal(Session.capsCurrent(s), true)
        })

        T.test("facts for every group of an install survive a group move", function () {
            // The switch flicker this closes: one group's facts went stale the
            // instant the ack moved the group, so the built-in table drew and
            // typing was gated until a round trip replaced them. The helper
            // resolves every group when it installs the keymap, so the panel
            // holds them all and a switch is a lookup.
            var payload = "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            var s = Session.reduce(s0, { type: "configureSent", payload: payload })
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            T.deepEqual(Session.missingCapGroups(s, 2), [0, 1])
            s = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            T.deepEqual(Session.missingCapGroups(s, 2), [1])
            s = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 1, byPosition: { AD01: [{ text: "й" }] }
            })
            T.deepEqual(Session.missingCapGroups(s, 2), [])
            T.equal(Session.capsMap(s).AD01[0].text, "q")
            // The language switch: same keymap, group 1. Nothing is
            // invalidated, nothing is re-requested, typing never closes.
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t1"
            })
            T.equal(Session.typingReady(s), true)
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            T.equal(Session.capsCurrent(s), true)
            T.equal(Session.typingReady(s), true)
            T.equal(Session.capsMap(s).AD01[0].text, "й")
            T.deepEqual(Session.missingCapGroups(s, 2), [])
        })

        T.test("a new generation drops every group's facts, not just one", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            })
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 3, group: 1, byPosition: { AD01: [{ text: "й" }] }
            })
            // A keymap change: every group's answer described the old install.
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc104\tus,ua\t\t\t\t0"
            })
            s = Session.reduce(s, { type: "configureAck", gen: 4 })
            T.equal(Session.capsCurrent(s), false)
            T.equal(Session.typingReady(s), false)
            T.deepEqual(Session.missingCapGroups(s, 2), [0, 1])
            // And a reply left over from the old install cannot fill them.
            var stale = Session.applyCapsReply(s, {
                gen: 3, group: 1, byPosition: { AD01: [{ text: "й" }] }
            })
            T.equal(stale.accepted, false)
            T.deepEqual(Session.missingCapGroups(stale.state, 2), [0, 1])
        })

        T.test("a group-only configure in flight keeps typing open", function () {
            // The helper's same-keymap short-circuit compiles nothing and
            // drains nothing, and the socket is ordered, so a press written
            // after the configure lands after the group move. Gating on the
            // whole queue dimmed the keyboard for that round trip.
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            })
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            s = Session.reduce(s, { type: "configureAck", gen: 2 })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 2, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 2, group: 1, byPosition: { AD01: [{ text: "й" }] }
            })
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t1"
            })
            T.equal(Session.settled(s), false)
            T.equal(Session.hasDrainAhead(s), false)
            T.equal(Session.typingReady(s), true)
            // A keymap-changing configure behind it closes the gate again.
            s = Session.reduce(s, {
                type: "configureSent",
                payload: "configure\tevdev\tpc104\tus,ua\t\t\t\t1"
            })
            T.equal(Session.hasDrainAhead(s), true)
            T.equal(Session.typingReady(s), false)
        })

        T.test("typing needs the handshake, no pending drain and current facts", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t0"
            })
            // No hello yet: never ready, whatever else is true.
            var helloed = Session.reduce(s, { type: "helloAcked", fresh: false })
            T.equal(Session.typingReady(helloed), false)
            helloed = Session.reduce(helloed, { type: "configureAck", gen: 1 })
            T.equal(Session.typingReady(helloed), false)
            helloed = Session.reduce(helloed, {
                type: "capsFacts", gen: 1, group: 0, byPosition: { AD01: [{ text: "q" }] }
            })
            T.equal(Session.typingReady(helloed), true)
            // And a connection drop closes the gate without forgetting the
            // facts: a re-hello of a live connection restores readiness.
            var down = Session.reduce(helloed, { type: "connectionDown" })
            T.equal(Session.typingReady(down), false)
            var back = Session.reduce(down, { type: "helloAcked", fresh: false })
            T.equal(Session.typingReady(back), true)
        })

        T.test("a fresh hello restarts the world; a repair re-hello keeps it", function () {
            var s = Session.reduce(s0, {
                type: "configureSent",
                payload: "configure\tevdev\tpc105\tus,ua\t\t\t\t1"
            })
            s = Session.reduce(s, { type: "configureAck", gen: 2 })
            s = Session.reduce(s, {
                type: "capsFacts", gen: 2, group: 1, byPosition: { AD01: [{ text: "й" }] }
            })
            // The repair timer re-hellos an open socket: nothing is reset.
            var repair = Session.reduce(s, { type: "helloAcked", fresh: false })
            T.equal(repair.ackedGen, 2)
            T.equal(repair.queue.length, 0)
            T.equal(Session.capsCurrent(repair), true)
            // A genuinely new connection: the helper released everything and
            // acknowledges nothing, so the queue, the generation and the
            // facts all start over.
            var fresh = Session.reduce(s, { type: "helloAcked", fresh: true })
            T.equal(fresh.ackedGen, 0)
            T.equal(fresh.acked, "")
            T.equal(fresh.queue.length, 0)
            T.equal(fresh.sends, 0)
            T.equal(fresh.caps, null)
            T.equal(fresh.helloOk, true)
        })

        // ---- the caps reply parser ----

        T.test("parseCapsReply reads all three honest level kinds", function () {
            var parsed = Session.parseCapsReply(
                "caps\t7\t1\tAD01\u001Ftй\u001FtЙ\u001EAE01\u001Ft1\u001Ft!"
                    + "\u001ETLDE\u001Fn\u001Fn\u001ERALT\u001FxISO_Level3_Shift")
            T.equal(parsed.gen, 7)
            T.equal(parsed.group, 1)
            T.deepEqual(parsed.byPosition.AD01, [{ text: "й" }, { text: "Й" }])
            T.deepEqual(parsed.byPosition.AE01, [{ text: "1" }, { text: "!" }])
            // A level with no symbol: honest, and distinct from a named
            // symbol that produces no character.
            T.deepEqual(parsed.byPosition.TLDE, [{ none: "" }, { none: "" }])
            T.deepEqual(parsed.byPosition.RALT, [{ none: "ISO_Level3_Shift" }])
        })

        T.test("parseCapsReply keeps a bare record as a position with no entry", function () {
            var parsed = Session.parseCapsReply("caps\t1\t0\tZZ09\u001EAD01\u001Ftq")
            T.deepEqual(parsed.byPosition.ZZ09, [])
            T.equal(parsed.byPosition.AD01.length, 1)
        })

        T.test("parseCapsReply refuses malformed lines and unknown tags", function () {
            T.equal(Session.parseCapsReply(""), null)
            T.equal(Session.parseCapsReply("configured\t2"), null)
            T.equal(Session.parseCapsReply("caps\tx\t0\tAD01\u001Ftq"), null)
            T.equal(Session.parseCapsReply("caps\t1\tx\tAD01\u001Ftq"), null)
            // An unknown field tag is a protocol drift signal: refuse the
            // whole reply rather than draw a guessed level.
            T.equal(Session.parseCapsReply("caps\t1\t0\tAD01\u001F?q"), null)
            T.equal(Session.parseCapsReply("caps\t1\t0\t\u001Ftq"), null)
        })


        // The compositor's kb_file is compared to the published
        // keymap by exact identity, never by substring — an unrelated user
        // path that happens to contain our suffix is the user's file.
        T.test("the published keymap path is built from the runtime dir", function () {
            T.equal(Session.publishedKeymapPath("/run/user/1000"),
                "/run/user/1000/oskar/keymap.xkb")
            T.equal(Session.publishedKeymapPath("/run/user/1000/"),
                "/run/user/1000/oskar/keymap.xkb")
            T.equal(Session.publishedKeymapPath("/run/user/1000//"),
                "/run/user/1000/oskar/keymap.xkb")
            T.equal(Session.publishedKeymapPath(""), "")
        })

        T.test("published-keymap identity is exact, never a substring", function () {
            var dir = "/run/user/1000"
            var ours = "/run/user/1000/oskar/keymap.xkb"
            T.equal(Session.isPublishedKeymap(ours, dir), true)
            T.equal(Session.isPublishedKeymap("", dir), false)
            // The audit's misclassification: a user path whose suffix
            // resembles the published path is NOT ours.
            T.equal(Session.isPublishedKeymap(
                "/home/u/backups/oskar/keymap.xkb", dir), false)
            T.equal(Session.isPublishedKeymap("/home/u/my.xkb", dir), false)
            T.equal(Session.isPublishedKeymap(ours + ".backup", dir), false)
        })

        // ---- field contracts — the state and reply shapes the
        // ---- panel binds ----
        //
        // Keyboard.qml binds session.group/ackedGen/sends/queue and draws
        // through capsMap; it reads parsed.gen/group/byPosition off every
        // caps reply. A renamed builder field here reads as `undefined`
        // with no warning — the shape is the contract, so pin it exactly.
        T.test("the initial state carries exactly the fields the panel binds", function () {
            T.deepEqual(Object.keys(Session.initial()).sort(),
                ["acked", "ackedGen", "caps", "group", "helloOk", "queue",
                 "sends"])
        })

        T.test("every event kind leaves the fields the panel reads in place", function () {
            var s = Session.reduce(s0, { type: "configureSent", payload:
                "configure\tevdev\tpc105\tus,ua\t\tgrp:alt_shift_toggle\t\t1" })
            T.deepEqual(Object.keys(s.queue[0]).sort(),
                ["changed", "group", "identity", "payload", "seq"])
            T.equal(typeof s.queue[0].seq, "number")
            T.equal(typeof s.queue[0].changed, "boolean")
            T.equal(typeof s.sends, "number")
            s = Session.reduce(s, { type: "configureAck", gen: 3 })
            T.deepEqual(Object.keys(s).sort(), Object.keys(Session.initial()).sort())
            T.equal(typeof s.acked, "string")
            T.equal(typeof s.ackedGen, "number")
            T.equal(typeof s.group, "number")
            s = Session.reduce(s, { type: "capsFacts", gen: 3, group: 1,
                byPosition: {
                    AD01: [{ text: "\u0439" }, { text: "\u0419" }],
                    RALT: [{ none: "ISO_Level3_Shift" }]
                } })
            T.deepEqual(Object.keys(s.caps).sort(), ["byGroup", "gen"])
            T.equal(s.caps.gen, 3)
            // A level entry is exactly one honest kind: text, or none.
            var levels = s.caps.byGroup[1].AD01
            for (var i = 0; i < levels.length; i++) {
                T.deepEqual(Object.keys(levels[i]), ["text"])
                T.equal(typeof levels[i].text, "string")
            }
            T.deepEqual(Object.keys(s.caps.byGroup[1].RALT[0]), ["none"])
            // applyCapsReply wraps the same event: the panel's accept seam
            // reads accepted off it and the state out of it.
            var applied = Session.applyCapsReply(s, { gen: 3, group: 0,
                byPosition: { AD01: [{ text: "q" }] } })
            T.deepEqual(Object.keys(applied).sort(), ["accepted", "state"])
            T.equal(applied.accepted, true)
            s = Session.reduce(s, { type: "helloAcked", fresh: false })
            T.equal(s.helloOk, true)
            s = Session.reduce(s, { type: "connectionDown" })
            T.equal(s.helloOk, false)
            // A failure with an empty queue changes nothing and crashes
            // nothing — the panel dispatches it from the err path.
            var failed = Session.reduce(s, { type: "configureFailed" })
            T.equal(failed.helloOk, false)
        })

        T.test("parseCapsReply carries exactly gen, group and byPosition", function () {
            var parsed = Session.parseCapsReply(
                "caps\t7\t1\tAD01\u001Ft\u0439\u001Ft\u0419")
            T.deepEqual(Object.keys(parsed).sort(),
                ["byPosition", "gen", "group"])
            T.equal(typeof parsed.gen, "number")
            T.equal(typeof parsed.group, "number")
            T.deepEqual(Object.keys(parsed.byPosition.AD01[0]), ["text"])
        })

        T.test("luaQuote seals the literal against filename injection", function () {
            // The security audit's finding 3: a crafted keymap filename
            // must not escape the hyprctl-eval Lua string it is spliced
            // into. The auditor's exact payload and friends:
            var payload = "/home/user/map'}}); print('INJECTED'); --"
            var quoted = Session.luaQuote(payload)
            // The literal contains no unescaped quote and no newline-class
            // byte: nothing inside can close it early.
            T.equal(quoted.charAt(0), "'")
            T.equal(quoted.charAt(quoted.length - 1), "'")
            // Evaluating the escapes back yields the original (the round
            // trip the compositor performs).
            var inner = quoted.slice(1, -1)
            var decoded = ""
            for (var i = 0; i < inner.length; i++) {
                if (inner.charAt(i) === "\\") {
                    var next = inner.charAt(i + 1)
                    if (next === "\\" || next === "'") { decoded += next; i += 1 }
                    else {
                        var digits = inner.slice(i + 1, i + 4)
                        if (/^[0-9][0-9][0-9]$/.test(digits)) {
                            decoded += String.fromCharCode(parseInt(digits, 10))
                            i += 3
                        } else decoded += next
                    }
                } else decoded += inner.charAt(i)
            }
            T.equal(decoded, payload)
            // The injection payload's quotes survive as DATA: every
            // single quote inside the literal is backslash-escaped (a
            // naive substring ban trips on the escape itself).
            var innerRaw = quoted.slice(1, -1)
            for (var q = 0; q < innerRaw.length; q++)
                if (innerRaw.charAt(q) === "'")
                    T.equal(innerRaw.charAt(q - 1), "\\",
                        "quote at " + q + " unescaped")
            T.equal(Session.luaQuote(""), "''")
            T.equal(Session.luaQuote("plain.xkb"), "'plain.xkb'")
            // The bash layer: a double quote in the path must arrive
            // escaped, or it closes the hyprctl eval argument.
            // Non-ASCII must round-trip: 'влад' and 'é' ride as their
            // UTF-8 bytes, each a padded \ddd — never a misread \dddD.
            var cyr = Session.luaQuote("влад")
            var cyrInner = cyr.slice(1, -1)
            var cyrBack = ""
            for (var c = 0; c < cyrInner.length; c += 4) {
                T.equal(cyrInner.charAt(c), "\\")
                cyrBack += String.fromCharCode(
                    parseInt(cyrInner.slice(c + 1, c + 4), 10))
            }
            // UTF-8 bytes decode back to the original string:
            T.equal(decodeURIComponent(
                cyrBack.split("").map(function (ch) {
                    return "%" + ("0" + ch.charCodeAt(0).toString(16)).slice(-2)
                }).join("")), "влад")
            // And a low byte pads: U+0001 rides as \001, never \1.
            T.equal(Session.luaQuote("\u0001x"), "'\\001x'")
            var dq = Session.luaQuote('a"b')
            // Expected exactly: 'a\"b' — quote, a, backslash, dquote, b, quote.
            T.equal(dq, "'a" + String.fromCharCode(92) + '"' + "b'")
            var evil = "a\nb'c}"
            T.equal(Session.luaQuote(evil).indexOf("'"), 0)
            T.equal(Session.luaQuote(evil).length > evil.length, true)
        })

        Qt.exit(T.report("keyboard session"))
    }
}
