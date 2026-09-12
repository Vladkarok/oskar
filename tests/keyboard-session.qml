// The keyboard session's half of ticket 04, driven as a pure module: the
// configure transaction queue it inherited from the panel, and the
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

        // ---- configure transactions: the queue the panel used to own ----

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

        T.test("a caps mismatch is unavailable, never the starting notice", function () {
            // decisions §23 / spec-v1.1 §6: connected + failed facts is
            // keymap-unavailable, not "Starting omarchy-osk.service…".
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

        // ---- text delivery: the command's one wire shape (ticket 24) ----

        T.test("a text line is the verb, one space, the payload verbatim", function () {
            T.equal(Session.textLine("👍"), "text 👍")
            // Spaces ride in the payload: the helper takes the whole rest
            // of the line, it does not split a word list.
            T.equal(Session.textLine("a b"), "text a b")
            // Multi-codepoint sequences — ZWJ joiners, variation selectors,
            // tag characters — pass through untouched, which is the whole
            // point of carrying a catalogue entry's emoji string.
            var zwj = "🙂‍↔️"
            T.equal(Session.textLine(zwj), "text " + zwj)
            T.equal(Session.textLine("🇺🇦"), "text 🇺🇦")
        })

        T.test("a payload the line protocol cannot carry is refused", function () {
            // Empty: the helper would read a bare "text", which its parse
            // does not recognize as a command at all.
            T.equal(Session.textLine(""), "")
            T.equal(Session.textLine(null), "")
            T.equal(Session.textLine(undefined), "")
            // A newline is the frame separator: one command per line, so a
            // payload carrying one is not one delivery. Nothing the
            // catalogue holds can be these; the guard is the protocol's.
            T.equal(Session.textLine("a\nb"), "")
            T.equal(Session.textLine("\n"), "")
        })

        Qt.exit(T.report("keyboard session"))
    }
}
