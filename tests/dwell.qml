// The dwell state machine, a pure seam. Hover a cap for D milliseconds
// and it types — press+release as one click — with a second threshold
// that opens the hold-column menu for caps that carry one. Everything
// timing-shaped is decided here against an INJECTED clock, so the host
// suite can pin it (tests/dwell.qml, the HoldColumn.js discipline):
// the QML side only delivers enter/move/leave events, runs the deadline
// timer, and maps the returned action onto the same press paths a physical
// click takes. Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../Dwell.js" as Dwell
import "../HoldColumn.js" as HoldColumn
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        // ---- the delay pair's bounds ----

        T.test("the delay default sits inside its designed window", function () {
            // 400 ms is faster than a deliberate pause, 2000 ms slower than
            // anyone would wait; ~800 reads as "rest", not "brush". Off by
            // default either way — the setting is the user's opt-in.
            T.equal(Dwell.DELAY_DEFAULT_MS >= Dwell.DELAY_MIN_MS, true)
            T.equal(Dwell.DELAY_DEFAULT_MS <= Dwell.DELAY_MAX_MS, true)
            T.equal(Dwell.DELAY_MIN_MS, 400)
            T.equal(Dwell.DELAY_MAX_MS, 2000)
            T.equal(Dwell.DELAY_DEFAULT_MS, 800)
        })

        T.test("delayFor clamps a stray value into the window", function () {
            // The QML boundary hands the machine whatever the merged config
            // produced; validation owns the FILE, this owns the timer.
            T.equal(Dwell.delayFor(650), 650)
            T.equal(Dwell.delayFor(10), 400)
            T.equal(Dwell.delayFor(60000), 2000)
            T.equal(Dwell.delayFor("not a number"), 800)
            T.equal(Dwell.delayFor(undefined), 800)
            T.equal(Dwell.delayFor(812.6), 813)
        })

        T.test("the menu window rides the hold threshold, never drifts from it", function () {
            // Dwell-past opens the column menu; the window between the type
            // and the menu is hold-column's own hold window by design (one
            // hold vocabulary), and it is DERIVED, not copied — the module reads
            // HoldColumn's constant so the two cannot disagree.
            T.equal(Dwell.MENU_WINDOW_MS, HoldColumn.HOLD_THRESHOLD_MS)
            T.equal(Dwell.menuDelayFor(800), 800 + HoldColumn.HOLD_THRESHOLD_MS)
            // A clamped delay takes its menu deadline with it.
            T.equal(Dwell.menuDelayFor(10),
                400 + HoldColumn.HOLD_THRESHOLD_MS)
        })

        // ---- the machine: two thresholds, one injected clock ----
        //
        // Fixtures drive the clock by hand: t0 is whenever the caller says
        // it is, and every tick names its own now. Nothing in the module
        // reads Date.now() — that absence is what makes this a seam.

        var DELAY = 800
        var MENU = DELAY + Dwell.MENU_WINDOW_MS

        T.test("a rest under the delay types nothing", function () {
            var s = Dwell.enter(5000, DELAY, MENU, false)
            T.equal(Dwell.tick(s, 5000 + 799).action, "none")
            T.equal(s.phase, "armed")
        })

        T.test("the delay fires at exactly its boundary", function () {
            // >=, not >: the deadline the timer fires on IS the type.
            var s = Dwell.enter(0, DELAY, MENU, false)
            var at = Dwell.tick(s, DELAY)
            T.equal(at.action, "press")
            T.equal(at.state.phase, "done")
        })

        T.test("a cap without a column types once and never repeats", function () {
            // Dwell is click-shaped. Repeat belongs to a key held down
            // at the compositor, and a dwell press+release is over
            // when it is over — resting
            // on an ordinary letter must not machine-gun it. The fired
            // state is the RETURNED one; the machine never mutates in
            // place.
            var s = Dwell.enter(0, DELAY, MENU, false)
            var fired = Dwell.tick(s, DELAY)
            T.equal(fired.action, "press")
            var after = Dwell.tick(fired.state, DELAY + 1)
            T.equal(after.action, "none")
            T.equal(after.state.phase, "done")
            T.equal(Dwell.tick(fired.state, DELAY + 60000).action, "none")
        })

        T.test("a column cap's continued rest opens the menu at the second boundary", function () {
            // The 37 interplay, the dwell side: dwell-through types,
            // dwell-PAST opens the column menu rather than typing again.
            var s = Dwell.enter(0, DELAY, MENU, true)
            var typed = Dwell.tick(s, DELAY)
            T.equal(typed.action, "press")
            T.equal(typed.state.phase, "spent")
            T.equal(Dwell.tick(typed.state, MENU - 1).action, "none")
            var opened = Dwell.tick(typed.state, MENU)
            T.equal(opened.action, "menu")
            T.equal(opened.state.phase, "done")
        })

        T.test("the spent phase keeps its own deadline from the enter, not the fire", function () {
            // menuDelay is elapsed-from-enter (t0), so a tick delivered
            // late still opens the menu exactly once and never before the
            // designed window has passed.
            var s = Dwell.enter(100, DELAY, MENU, true)
            var typed = Dwell.tick(s, 100 + DELAY)
            T.equal(typed.action, "press")
            var late = Dwell.tick(typed.state, 100 + MENU + 250)
            T.equal(late.action, "menu")
            T.equal(Dwell.tick(late.state, 100 + MENU + 500).action, "none")
        })

        // ---- cancellation ----

        T.test("leaving before the delay cancels the rest", function () {
            var s = Dwell.enter(0, DELAY, MENU, true)
            var left = Dwell.leave(s)
            T.equal(left.action, "cancel")
            // And the cancelled state is inert: a late timer tick — the
            // QML side's leave stops the timer, but the machine does not
            // trust that — types nothing. The dead state is the one the
            // cancel CARRIES.
            T.equal(left.state, null)
            T.equal(Dwell.tick(left.state, DELAY).action, "none")
        })

        T.test("leaving after the type cancels the pending menu arm", function () {
            // The character is already out (it typed at the delay); what
            // dies on leave is the menu the continued rest was arming.
            var s = Dwell.enter(0, DELAY, MENU, true)
            var typed = Dwell.tick(s, DELAY)
            var left = Dwell.leave(typed.state)
            T.equal(left.action, "cancel")
            T.equal(left.state, null)
            T.equal(Dwell.tick(left.state, MENU).action, "none")
        })

        T.test("leaving an idle or finished machine is none", function () {
            T.equal(Dwell.leave(null).action, "none")
            var s = Dwell.enter(0, DELAY, MENU, false)
            var done = Dwell.tick(s, DELAY)
            T.equal(Dwell.leave(done.state).action, "none")
        })

        T.test("a move inside the cap neither cancels nor restarts the dwell", function () {
            // The decision the ticket left to design, pinned: cancel-on-
            // LEAVE, not cancel-on-move. A trembling pointer — the exact
            // user dwell is for — must be able to rest on a key while its
            // hand shakes; only leaving the cap's hit area cancels. The
            // move event stays in the API so the seam can say so.
            var s = Dwell.enter(0, DELAY, MENU, false)
            T.equal(Dwell.move(s, 100).action, "none")
            T.equal(Dwell.move(s, 400).action, "none")
            // The move did not restart the clock: the ORIGINAL deadline
            // still fires, and the fired state is the returned one.
            var fired = Dwell.tick(s, DELAY)
            T.equal(fired.action, "press")
            // Had the clock restarted at a move, a 500 ms move would push
            // the deadline to 500+DELAY; the true deadline is the enter's,
            // so the rest fires long before that.
            var moved = Dwell.enter(0, DELAY, MENU, false)
            Dwell.move(moved, 500)
            T.equal(Dwell.tick(moved, DELAY - 1).action, "none")
            var firedMoved = Dwell.tick(moved, 500 + DELAY - 1)
            T.equal(firedMoved.action, "press")
            T.equal(Dwell.tick(firedMoved.state, 500 + DELAY).action, "none")
        })

        T.test("re-entering after a fired rest arms a fresh dwell", function () {
            // Dwell typing is rest-after-rest: leave, come back, and the
            // delay starts over. The machine is one cap's current rest,
            // not a session.
            var s = Dwell.enter(0, DELAY, MENU, false)
            Dwell.tick(s, DELAY)
            var again = Dwell.enter(4000, DELAY, MENU, false)
            T.equal(again.phase, "armed")
            T.equal(Dwell.tick(again, 4000 + DELAY - 1).action, "none")
            T.equal(Dwell.tick(again, 4000 + DELAY).action, "press")
        })

        T.test("a null state is inert under every event", function () {
            T.equal(Dwell.tick(null, 99999).action, "none")
            T.equal(Dwell.move(null, 5).action, "none")
        })

        T.test("progress is the affordance's fraction, not a state", function () {
            // The underline the cap draws is progress toward the type —
            // never a second "unavailable/dim" reading. The machine states
            // that as a number: 0 at enter, half at half the delay, full
            // at the deadline, and full afterwards too (a completed rest
            // is not an error state).
            var s = Dwell.enter(0, DELAY, MENU, true)
            T.equal(Dwell.progress(s, 0), 0)
            T.equal(Dwell.progress(s, DELAY / 2), 0.5)
            T.equal(Dwell.progress(s, DELAY), 1)
            T.equal(Dwell.progress(s, MENU + 5), 1)
            T.equal(Dwell.progress(null, 100), 0)
        })

        // ---- the re-arm interval: one function for the remaining time ----
        //
        // The wiring re-arms the deadline timer for the REMAINING time
        // against the absolute deadline. Which deadline a phase waits
        // for is the machine's own fact (nextArmMs restates tick's two
        // comparisons, once, instead of duplicating the arithmetic per
        // caller), and the wiring only delivers. The fixtures use the
        // leg's own shape: an 800 delay, an 1120 menu window.

        T.test("nextArmMs answers the ms to the phase's own deadline, from the enter", function () {
            // Armed waits for the type deadline, spent for the menu
            // deadline — both anchored on the ENTER (t0), never on the
            // fire: a late delivery still waits exactly the designed
            // window. 750ms into an 800ms delay leaves 50; 1050 into the
            // 1120 menu leaves 70.
            var s = Dwell.enter(0, DELAY, MENU, true)
            T.equal(Dwell.nextArmMs(s, 750), 50)
            var typed = Dwell.tick(s, DELAY)
            T.equal(typed.action, "press")
            T.equal(Dwell.nextArmMs(typed.state, 1050), 70)
            // A nonzero enter keeps the same arithmetic — elapsed is
            // always measured from t0, not from zero.
            var late = Dwell.enter(1000, DELAY, MENU, true)
            T.equal(Dwell.nextArmMs(late, 1000 + 750), 50)
        })

        T.test("nextArmMs is floored at 1: a crossed deadline still owes one delivery", function () {
            // The answer is a timer interval, so it is never 0 and never
            // negative. A deadline already reached at the moment of asking
            // (remaining 0) or already passed (remaining negative — the
            // double-crossing case below) still owes exactly one more
            // tick to notice the crossing, and 1ms is the soonest rest.
            var s = Dwell.enter(0, DELAY, MENU, true)
            T.equal(Dwell.nextArmMs(s, DELAY), 1)
            T.equal(Dwell.nextArmMs(s, DELAY + 400), 1)
            var spent = Dwell.tick(s, DELAY).state
            T.equal(Dwell.nextArmMs(spent, MENU), 1)
            T.equal(Dwell.nextArmMs(spent, MENU + 500), 1)
        })

        T.test("dead and finished states answer null: no next arm exists", function () {
            // The wiring drops the state on leave; a stray call on the
            // dead state (or a finished one — both crossings consumed)
            // must not look like a timing value. null says "nothing to
            // arm" and cannot be confused with an interval.
            T.equal(Dwell.nextArmMs(null, 99999), null)
            var done = Dwell.tick(Dwell.enter(0, DELAY, MENU, false), DELAY)
            T.equal(done.state.phase, "done")
            T.equal(Dwell.nextArmMs(done.state, DELAY + 5), null)
            var fired = Dwell.tick(Dwell.enter(0, DELAY, MENU, true), DELAY)
            var opened = Dwell.tick(fired.state, MENU)
            T.equal(opened.state.phase, "done")
            T.equal(Dwell.nextArmMs(opened.state, MENU + 1), null)
        })

        T.test("a double-crossing delivery still converges: press then 1ms then menu", function () {
            // The wiring's one-delivery reality (`repeat: false`): a
            // single very late fire can cross the type deadline AND the
            // whole menu window before the machine has been told
            // anything. tick answers the FIRST crossing (press, spent);
            // nextArmMs answers 1 — the floor, not a negative wait — and
            // that soonest re-arm hands over the second crossing. No rest
            // is lost and none is invented.
            var s = Dwell.enter(0, DELAY, MENU, true)
            var first = Dwell.tick(s, MENU + 80)
            T.equal(first.action, "press")
            T.equal(first.state.phase, "spent")
            T.equal(Dwell.nextArmMs(first.state, MENU + 80), 1)
            var second = Dwell.tick(first.state, MENU + 81)
            T.equal(second.action, "menu")
            T.equal(second.state.phase, "done")
            T.equal(Dwell.nextArmMs(second.state, MENU + 81), null)
        })

        // ---- eligibility: which caps dwell at all ----

        T.test("a character cap dwells; a gated keyboard dwells nothing", function () {
            // inputReady is the existing disabled discipline: a cap that
            // cannot type has no press path, and a dwell is a press.
            // Readiness is checked at enter AND the wiring
            // re-checks at fire — the machine itself only guards entry.
            T.equal(Dwell.eligible({ chr: "q", xkb: "AD01" }, false, true), true)
            T.equal(Dwell.eligible({ chr: "q", xkb: "AD01" }, false, false), false)
            // Space is a character cap (its fixed label is the panel's
            // own, its chr is a real space): dwell has to type the most
            // common key on the board.
            T.equal(Dwell.eligible(
                { chr: " ", label: "", w: 4.5, xkb: "SPCE" }, false, true), true)
        })

        T.test("search never dwells: the emoji page is excluded chrome", function () {
            // The chrome decision, one edge of it: while the emoji page
            // stands, its search arm is immediate by contract (hold-column
            // refuses the defer for the same reason) and the page itself
            // — cells, categories, its pick targets — is a picker
            // surface, not a typing surface. A dwell user cannot pick an
            // emoji by dwelling either, so letting the query fill by
            // rest would promise a journey with no destination.
            T.equal(Dwell.eligible({ chr: "q", xkb: "AD01" }, true, true), false)
        })

        T.test("sticky modifiers dwell-press exactly like a click", function () {
            // A dwell on Shift latches Shift, precisely what a click
            // does — applyModifierEvent's click event, lock upgrades
            // included where the reducer allows.
            var clickable = ["ctrl", "alt", "logo", "altgr", "shift"]
            for (var i = 0; i < clickable.length; i++) {
                T.equal(Dwell.eligible(
                    { key: clickable[i], label: "mod" }, false, true), true)
            }
        })

        T.test("keysym caps dwell: they are input, not chrome", function () {
            // BackSpace, Enter, Tab, the arrows — the nav caps exist
            // because they are pointer-unreachable; for a dwell user
            // they are the whole point.
            var keysyms = ["BackSpace", "Return", "Tab", "Left", "Right",
                "Up", "Down", "Delete", "Home", "End"]
            for (var i = 0; i < keysyms.length; i++) {
                T.equal(Dwell.eligible(
                    { key: keysyms[i], label: keysyms[i] }, false, true), true)
            }
        })

        T.test("the panel's command caps and chrome never dwell", function () {
            // The chrome decision, pinned: dwell is an INPUT affordance.
            // The panel's own surfaces — the gear, the language chip, the
            // paste chip, the emoji page's cells — are not caps and never
            // route through this rule at all; the grid's own command
            // caps (close, page, emoji, fn, caps) ARE caps and are named
            // here so the exclusion is a decision, not an accident.
            // Resting the pointer while traversing the board must never
            // close the panel, flip the page, open a picker, or toggle a
            // semantic layer under the pointer's feet; those actions all
            // re-render or destroy the surface the pointer is resting
            // on. The list restates triggerSpecial's fixed cases, the
            // HoldColumn "restated, not re-derived" discipline.
            var commands = ["close", "page", "emoji", "fn", "caps"]
            for (var i = 0; i < commands.length; i++) {
                T.equal(Dwell.eligible(
                    { key: commands[i], label: commands[i] }, false, true), false)
            }
            T.equal(Dwell.eligible(null, false, true), false)
            T.equal(Dwell.eligible({ spacer: true, w: 1 }, false, true), false)
            T.equal(Dwell.eligible(
                { chr: "\u2603", unavailable: true, xkb: "AB11" }, false, true),
                false)
        })

        // ---- the 37 interplay: the defer decision ----

        function deferredCap() {
            return { chr: "3", chrShift: "\u2116", xkb: "AE03" }
        }
        function richColumn() {
            return [{ level: 3, text: "\u00a7" }, { level: 4, text: "\u20b4" }]
        }

        T.test("dwell mode suppresses the release-defer: no click is needed at all", function () {
            // In dwell mode a column cap does not defer its typing to
            // mouse-release — the dwell itself is the click, so a press
            // types immediately (repeat stays the compositor's own) and
            // the menu is reached by dwelling PAST the type, never by
            // holding a button.
            T.equal(Dwell.holdDefers(true, deferredCap(), richColumn(),
                false, true), false)
        })

        T.test("non-dwell mode keeps ticket 37 exactly as it was", function () {
            // The regression pin: with dwell off, holdDefers IS
            // HoldColumn.shouldDefer — the same caps defer, the same
            // gates gate, nothing about today's press/release/menu
            // changes because a setting exists.
            T.equal(Dwell.holdDefers(false, deferredCap(), richColumn(),
                false, true), true)
            T.equal(Dwell.holdDefers(false, deferredCap(), richColumn(),
                true, true), false)
            T.equal(Dwell.holdDefers(false, deferredCap(), richColumn(),
                false, false), false)
            T.equal(Dwell.holdDefers(false, deferredCap(), [],
                false, true), false)
            T.equal(Dwell.holdDefers(false, { key: "BackSpace" }, richColumn(),
                false, true), false)
        })

        // ---- slice two: the hold menu's entries as dwell targets ----
        //
        // A pure-dwell user can OPEN the column menu by resting PAST
        // the type, but the entries are clicks — one click still owed
        // to PICK. Slice two routes entry hover through the same
        // machine; the fire is the entry's own click semantics
        // (pickHoldEntry in the wiring), and the click path is
        // unchanged — a click still picks instantly.

        function menuEntry() {
            return { level: 3, text: "\u00a7" }
        }

        T.test("menu entries are dwell targets in dwell mode; the padding is not", function () {
            // An entry is not a cap — no position, no key, no chrome
            // exclusion — so eligibility is its own rule, not
            // `eligible`'s. The menu's padding and the gaps between
            // entries never carry an entry: the hover shield (0105888)
            // swallows a rest there whole, so only the entry hit areas
            // route into the machine.
            T.equal(Dwell.entryEligible(menuEntry(), true, false, true), true)
            // Dwell off: the click stays the only route, as before.
            T.equal(Dwell.entryEligible(menuEntry(), false, false, true), false)
            // A gated entry draws dim and refuses its click; its dwell
            // refuses identically — the rule restates pickHoldEntry's
            // own guard rather than trusting the fold that usually
            // stands behind it.
            T.equal(Dwell.entryEligible(menuEntry(), true, false, false), false)
            // Search never sees a standing menu (the page folds it),
            // but the guard is restated, not trusted to the fold.
            T.equal(Dwell.entryEligible(menuEntry(), true, true, true), false)
            // The padding and the gaps: not entries, never targets.
            T.equal(Dwell.entryEligible(null, true, false, true), false)
        })

        T.test("an entry rest rides the same machine: the delay picks it once", function () {
            // No second threshold — an entry has no column; the pick IS
            // the destination, so the rest is done at the fire and no
            // menu arm follows. enterEntry composes eligibility and the
            // arm (the holdDefers discipline: the interplay is pinned
            // in the module, not the QML) and answers null when
            // nothing armed.
            var s = Dwell.enterEntry(menuEntry(), 0, DELAY, true, false, true)
            T.equal(s.phase, "armed")
            T.equal(Dwell.tick(s, DELAY - 1).action, "none")
            var fired = Dwell.tick(s, DELAY)
            T.equal(fired.action, "press")
            T.equal(fired.state.phase, "done")
            T.equal(Dwell.tick(fired.state, DELAY + 60000).action, "none")
            // An ineligible enter arms nothing at all.
            T.equal(Dwell.enterEntry(menuEntry(), 0, DELAY, false, false, true),
                null)
        })

        T.test("moving between entries re-targets: the new enter supersedes", function () {
            // Entry A's rest dies the moment the pointer leaves it — or
            // the moment entry B's hit area is entered, which the wiring
            // orders as reset-then-enter — and B's rest counts from ITS
            // OWN enter. The gap crossing itself is the shield's:
            // nothing arms there, so a slow crossing cannot bank A's
            // progress onto B.
            var a = Dwell.enterEntry(menuEntry(), 0, DELAY, true, false, true)
            T.equal(Dwell.leave(a).action, "cancel")
            var b = Dwell.enterEntry({ level: 4, text: "\u20b4" }, 350,
                DELAY, true, false, true)
            T.equal(b.phase, "armed")
            T.equal(Dwell.tick(b, 350 + DELAY - 1).action, "none")
            T.equal(Dwell.tick(b, 350 + DELAY).action, "press")
        })

        T.test("leaving an entry before the delay cancels the pick", function () {
            // The trembling-hand rule, the entries' case: cancellation
            // is on LEAVE, and the cancel carries a dead state — a
            // stray late timer tick picks nothing after the pointer is
            // gone.
            var s = Dwell.enterEntry(menuEntry(), 0, DELAY, true, false, true)
            var left = Dwell.leave(s)
            T.equal(left.action, "cancel")
            T.equal(left.state, null)
            T.equal(Dwell.tick(left.state, DELAY).action, "none")
        })

        Qt.exit(T.report("dwell"))
    }
}
