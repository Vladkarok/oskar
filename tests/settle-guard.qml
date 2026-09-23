// The settle guard, driven as a pure module: after a
// daemon (re)connect, which observed group readings may the panel FOLLOW —
// move the helper's group and `remembered` with — and which are the
// compositor's own re-application churn echoed back at a panel that just
// re-registered its virtual keyboard. Without the guard: a language click
// moves all three keyboards to group 1 and the panel follows — then a
// devices read returns the reading keyboard at 0 (Hyprland churn), the
// panel FOLLOWS the flip, and the seat stays split with the label lying
// until converged by hand.
//
// Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../SettleGuard.js" as SettleGuard
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        // The clock is injected: every decision below names its own time so
        // the window and the quiesce are exercised exactly, not by sleeping.

        T.test("the establishing configure is followed and arms the window", function () {
            var v = SettleGuard.decide(SettleGuard.initial(), 0, 0)
            T.equal(v.follow, true)
            T.equal(v.state.followed, 0)
            T.equal(v.state.armed, true)
            T.equal(v.state.openedAt, 0)
        })

        T.test("a commanded switch is followed immediately inside the window", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            s = SettleGuard.commanded(s, 1, 500)
            var v = SettleGuard.decide(s, 1, 600)
            T.equal(v.follow, true)
            T.equal(v.state.followed, 1)
            T.equal(v.state.armed, true)
        })

        T.test("an uncommanded flip inside the window is ignored", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            s = SettleGuard.commanded(s, 1, 500)
            s = SettleGuard.decide(s, 1, 600).state
            s = SettleGuard.decide(s, 1, 700).state
            // The churn flip: 0 again, inside the window, commanded nothing.
            var v = SettleGuard.decide(s, 0, 800)
            T.equal(v.follow, false)
            // What the panel keeps is the group it followed last — the
            // clicked one. `remembered` is persisted from the configure the
            // panel sends, and the panel sends `held`, never the flip.
            T.equal(v.held, 1)
            T.equal(v.state.followed, 1)
        })

        T.test("an early second sighting of the flip is still ignored", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            s = SettleGuard.decide(s, 0, 900).state
            var first = SettleGuard.decide(s, 1, 1000)
            T.equal(first.follow, false)
            // The churn's own follow-up read lands inside the quiesce
            // interval; the incident's flip-and-echo was sub-second.
            var second = SettleGuard.decide(first.state, 1,
                1000 + SettleGuard.QUIESCE_MS - 1)
            T.equal(second.follow, false)
            T.equal(second.held, 0)
        })

        T.test("a flip that persists past the quiesce is followed and closes the window", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            var first = SettleGuard.decide(s, 1, 1000)
            T.equal(first.follow, false)
            var second = SettleGuard.decide(first.state, 1,
                1000 + SettleGuard.QUIESCE_MS)
            T.equal(second.follow, true)
            T.equal(second.state.followed, 1)
            T.equal(second.state.armed, false)
            // The window is closed: the NEXT uncommanded flip is today's
            // behavior — followed at first sight.
            var after = SettleGuard.decide(second.state, 0, 1000
                + SettleGuard.QUIESCE_MS + 50)
            T.equal(after.follow, true)
        })

        T.test("a reading that returns to the followed group retires the candidate", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            var flip = SettleGuard.decide(s, 1, 1000)
            T.equal(flip.follow, false)
            // The flip was transient: the next reading is back on the
            // followed group — today the panel would have bounced to 1 and
            // back; here nothing moved at all.
            var back = SettleGuard.decide(flip.state, 0, 1500)
            T.equal(back.follow, true)
            T.equal(back.state.candidate, -1)
            // And a fresh single sighting after it is held again.
            var again = SettleGuard.decide(back.state, 1, 1600)
            T.equal(again.follow, false)
        })

        T.test("a new command retires the held candidate and its echo is followed", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            var flip = SettleGuard.decide(s, 1, 1000)
            T.equal(flip.follow, false)
            // The user clicks THROUGH the churn: the loop moves the seat to
            // 1 — the same group the churn was showing — and the echo must
            // be followed even though 1 was the held candidate.
            var s2 = SettleGuard.commanded(flip.state, 1, 1200)
            T.equal(s2.candidate, -1)
            var echo = SettleGuard.decide(s2, 1, 1300)
            T.equal(echo.follow, true)
            T.equal(echo.state.followed, 1)
        })

        T.test("the same flip outside the window is followed — today's behavior", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            var v = SettleGuard.decide(s, 1, SettleGuard.WINDOW_MS + 100)
            T.equal(v.follow, true)
            T.equal(v.state.followed, 1)
            T.equal(v.state.armed, false)
        })

        T.test("a command inside the window re-anchors it around the click", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            // The incident's own timing: click three seconds after the
            // first configure, churn flip a fraction later.
            s = SettleGuard.commanded(s, 1, 3000)
            T.equal(s.openedAt, 3000)
            s = SettleGuard.decide(s, 1, 3100).state
            var v = SettleGuard.decide(s, 0, 3200)
            T.equal(v.follow, false)
            T.equal(v.held, 1)
        })

        T.test("a command outside the window does not re-arm it", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            // Steady state: the window expired, the user clicks. Today's
            // world — no churn to race, the echo is followed on the general
            // not-armed path and a later flip is too.
            s = SettleGuard.decide(s, 1, SettleGuard.WINDOW_MS + 100).state
            var s2 = SettleGuard.commanded(s, 0, SettleGuard.WINDOW_MS + 500)
            T.equal(s2.armed, false)
            T.equal(s2.openedAt, 0)
            var echo = SettleGuard.decide(s2, 0, SettleGuard.WINDOW_MS + 600)
            T.equal(echo.follow, true)
        })

        T.test("the incident, end to end: one commanded follow, no bounce, remembered kept", function () {
            // The journal's exact shape. 18:53:19 first configure after the
            // daemon restart; 18:53:22 the click; all inside one second.
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            s = SettleGuard.commanded(s, 1, 3000)
            var commands = 0
            var remembered = 0
            var readings = [
                { group: 1, at: 3100 },   // click moved all three to 1
                { group: 1, at: 3150 },   // stable
                { group: 0, at: 3200 },   // a read returned 0 — churn
                { group: 0, at: 3250 },   // churn's own echo, sub-second
                { group: 0, at: 3300 }
            ]
            for (var i = 0; i < readings.length; i++) {
                var v = SettleGuard.decide(s, readings[i].group, readings[i].at)
                if (v.follow && v.state.followed !== remembered) {
                    commands += 1
                    remembered = v.state.followed
                }
                s = v.state
            }
            // Exactly the commanded move: the click's echo. The churn never
            // moved the helper's group or `remembered` off the clicked 1.
            T.equal(commands, 1)
            T.equal(remembered, 1)
        })

        // ---- the cold-start constraint ----

        T.test("cold start with diverged sleepers: the remembered answer is followed", function () {
            // A fresh panel over a live daemon: no daemon-restart window
            // exists at all, the seat's sleepers genuinely disagree and the
            // remembered group is the honest tie-breaker LayoutDevices
            // answers with. That answer is the ESTABLISHING configure — the
            // first reading the new world has — and it must be followed
            // exactly as today, window or no window.
            var s = SettleGuard.connected(SettleGuard.initial())
            var v = SettleGuard.decide(s, 1, 0)
            T.equal(v.follow, true)
            T.equal(v.state.followed, 1)
            // The cold-start branch answers the same remembered group on
            // every refresh; nothing about it is a flip, so nothing is held.
            v = SettleGuard.decide(v.state, 1, 400)
            T.equal(v.follow, true)
        })

        T.test("connected forgets the old world and disarms until the next establishing configure", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            s = SettleGuard.commanded(s, 1, 500)
            s = SettleGuard.decide(s, 1, 600).state
            var s2 = SettleGuard.connected(s)
            T.equal(s2.followed, -1)
            T.equal(s2.commanded, -1)
            T.equal(s2.candidate, -1)
            T.equal(s2.armed, false)
            // The stale command from before the reconnect must not
            // auto-adopt a matching reading: it is followed as the
            // establishing configure (the only configure there is), and the
            // window is armed fresh from THIS moment.
            var v = SettleGuard.decide(s2, 1, 5000)
            T.equal(v.follow, true)
            T.equal(v.state.armed, true)
            T.equal(v.state.openedAt, 5000)
        })

        T.test("decide never follows a negative or non-numeric observation", function () {
            var s = SettleGuard.decide(SettleGuard.initial(), 0, 0).state
            var v = SettleGuard.decide(s, -1, 100)
            T.equal(v.follow, false)
            var junk = SettleGuard.decide(s, "1", 100)
            T.equal(junk.follow, false)
        })

        Qt.exit(T.report("settle guard"))
    }
}
