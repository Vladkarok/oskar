// Pure Emote picker-session lifecycle (ticket 09). Not a product seam:
// drives PickerSession.js the way the panel hosts it, with no compositor.
import QtQml
import "../PickerSession.js" as Session
import "harness.js" as T

QtObject {
    function ops(actions) {
        var out = []
        for (var i = 0; i < actions.length; i++) out.push(actions[i].op)
        return out
    }

    Component.onCompleted: {
        var target = { address: "0x56513709a1a0", className: "omawrite" }

        T.test("a first Emote cap press launches once and records the target", function () {
            var r = Session.capPressed(null, "emote", target)
            T.equal(r.session.phase, "opening")
            T.equal(r.session.managed, true)
            T.equal(r.session.target.address, "0x56513709a1a0")
            T.deepEqual(ops(r.actions), ["launch"])
            T.equal(r.actions[0].app, "emote")
        })

        T.test("an open Emote session dismisses the identified window instead of exec", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0x565136a243a0")
            T.equal(r.session.phase, "open")
            T.deepEqual(ops(r.actions), ["setStayFocused"])
            T.equal(r.actions[0].value, "unset")
            r = Session.capPressed(r.session, "emote", target, "0x565136a243a0")
            T.equal(r.session.phase, "closing")
            T.deepEqual(ops(r.actions), ["setStayFocused", "closeWindow", "focus"])
            T.equal(r.actions[0].value, "unset")
            T.equal(r.actions[1].address, "0x565136a243a0")
            T.equal(r.actions[2].address, "0x56513709a1a0")
        })

        T.test("a second press while opening cancels a late map", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.capPressed(r.session, "emote", target)
            T.equal(r.session.phase, "closing")
            T.equal(r.session.cancelMap, true)
            T.deepEqual(ops(r.actions), [])
            r = Session.capPressed(r.session, "emote", target)
            T.deepEqual(ops(r.actions), [])
            T.equal(Session.rearmCloser(r.session), false)
            r = Session.mapped(r.session, "0x55a20b2fac00")
            T.equal(r.session.phase, "closing")
            T.deepEqual(ops(r.actions), ["closeWindow", "focus"])
            T.equal(r.actions[0].address, "0x55a20b2fac00")
            r = Session.closed(r.session, "0x55a20b2fac00", "0x55a20b2fac00")
            T.equal(r.session.phase, "closed")
            r = Session.capPressed(r.session, "emote", target)
            T.deepEqual(ops(r.actions), ["launch"])
        })

        T.test("mashing the emoji cap while closing with no pin does not rearm the closer", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.capPressed(r.session, "emote", target)
            T.equal(r.session.phase, "closing")
            T.equal(r.session.address, "")
            T.equal(Session.rearmCloser(r.session), false)
            r = Session.capPressed(r.session, "emote", target)
            T.deepEqual(ops(r.actions), [])
            T.equal(Session.rearmCloser(r.session), false)
            r = Session.capPressed(r.session, "emote", target)
            T.equal(Session.rearmCloser(r.session), false)
        })

        T.test("close of the pin while open restores the target before Emote's paste", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0xaaa")
            r = Session.closed(r.session, "0xaaa", "0xaaa")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["setStayFocused", "focus"])
            T.equal(r.actions[1].address, "0x56513709a1a0")
        })

        T.test("an opening timeout that never maps restores the recorded target", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.timeout(r.session, "")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["focus"])
            T.equal(r.actions[0].address, "0x56513709a1a0")
        })

        T.test("an opening timeout closewindows a late launch address", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.panelClosed(r.session, "")
            T.equal(r.session.cancelMap, true)
            r = Session.timeout(r.session, "", "0x55a20b2fac00")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["closeWindow", "focus"])
            T.equal(r.actions[0].address, "0x55a20b2fac00")
        })

        T.test("a closing timeout retries closewindow of the identified appearance", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0xaaa")
            r = Session.capPressed(r.session, "emote", target, "0xaaa")
            T.equal(r.session.phase, "closing")
            r = Session.timeout(r.session, "0xaaa")
            T.equal(r.session.phase, "closed")
            T.equal(ops(r.actions).indexOf("closeWindow") >= 0, true)
            T.equal(r.actions[ops(r.actions).indexOf("closeWindow")].address, "0xaaa")
        })

        T.test("a second press while closing retries dismiss", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0xaaa")
            r = Session.capPressed(r.session, "emote", target, "0xaaa")
            T.equal(r.session.phase, "closing")
            r = Session.capPressed(r.session, "emote", target, "0xaaa")
            T.equal(r.session.phase, "closing")
            T.deepEqual(ops(r.actions), ["closeWindow", "focus"])
            T.equal(r.actions[0].address, "0xaaa")
            T.equal(Session.rearmCloser(r.session), true)
        })

        T.test("a failed handoff while a cancelled opening has no pin keeps the closer", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.panelClosed(r.session, "")
            r = Session.failed(r.session, "")
            T.equal(r.session.phase, "closing")
            T.equal(r.session.cancelMap, true)
            T.deepEqual(ops(r.actions), [])
            r = Session.mapped(r.session, "0x55a20b2fac00")
            T.equal(ops(r.actions).indexOf("closeWindow") >= 0, true)
        })

        T.test("a failed closewindow settles a closing session", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0xaaa")
            r = Session.capPressed(r.session, "emote", target, "0xaaa")
            T.equal(r.session.phase, "closing")
            r = Session.failed(r.session, "0xaaa")
            T.equal(r.session.phase, "closed")
            T.equal(ops(r.actions).indexOf("closeWindow") >= 0, true)
            T.equal(r.actions[ops(r.actions).indexOf("closeWindow")].address, "0xaaa")
            r = Session.capPressed(r.session, "emote", target)
            T.deepEqual(ops(r.actions), ["launch"])
        })

        T.test("an in-flight close is not replaced by a later stay or focus handoff", function () {
            var inFlight = { running: true, closeWin: true, pending: null }
            var plan = Session.queueHandoff(inFlight, [
                { op: "setStayFocused", address: "0xaaa", value: "unset" },
                { op: "focus", address: "0x56513709a1a0" }
            ])
            T.equal(plan.start, false)
            T.equal(plan.pending.closeWin, false)
            T.equal(plan.pending.focusAddr, "0x56513709a1a0")
            T.equal(plan.pending.stay, "unset")
        })

        T.test("a pending close is not retargeted by a later stay", function () {
            var inFlight = {
                running: true,
                closeWin: true,
                pending: { addr: "0xaaa", stay: "", closeWin: true, focusAddr: "" }
            }
            var plan = Session.queueHandoff(inFlight, [
                { op: "setStayFocused", address: "0xbbb", value: "unset" }
            ])
            T.equal(plan.start, false)
            T.equal(plan.pending.closeWin, true)
            T.equal(plan.pending.addr, "0xaaa")
        })

        T.test("an in-flight close is not killed by another close", function () {
            var inFlight = { running: true, closeWin: true, pending: null }
            var plan = Session.queueHandoff(inFlight, [
                { op: "closeWindow", address: "0xaaa" }
            ])
            T.equal(plan.start, false)
            T.equal(plan.pending.closeWin, true)
            T.equal(plan.pending.addr, "0xaaa")
        })

        T.test("a handoff starts when no close is in flight", function () {
            var plan = Session.queueHandoff({ running: false, closeWin: false }, [
                { op: "closeWindow", address: "0xaaa" },
                { op: "focus", address: "0x56513709a1a0" }
            ])
            T.equal(plan.start, true)
            T.equal(plan.handoff.closeWin, true)
            T.equal(plan.handoff.addr, "0xaaa")
            T.equal(plan.handoff.focusAddr, "0x56513709a1a0")
            T.equal(plan.pending, null)
        })

        T.test("a user-focused other client is not stolen back on dismiss", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0xaaa")
            r = Session.capPressed(r.session, "emote", target, "0xfoot")
            T.equal(ops(r.actions).indexOf("focus") >= 0, false)
            T.deepEqual(ops(r.actions), ["setStayFocused", "closeWindow"])
        })

        T.test("unmanaged apps still launch; they do not get stay_focused", function () {
            var r = Session.capPressed(null, "xmoji", target)
            T.equal(r.session.managed, false)
            T.deepEqual(ops(r.actions), ["launch"])
            r = Session.mapped(r.session, "0xccc")
            T.equal(r.session.phase, "open")
            T.deepEqual(ops(r.actions), [])
        })

        T.test("closing the panel dismisses the identified Emote appearance", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.mapped(r.session, "0xaaa")
            r = Session.panelClosed(r.session, "0xaaa")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["setStayFocused", "closeWindow", "focus"])
        })

        T.test("closing the panel while opening still closewindows a late map", function () {
            var r = Session.capPressed(null, "emote", target)
            r = Session.panelClosed(r.session, "")
            T.equal(r.session.phase, "closing")
            T.equal(r.session.cancelMap, true)
            T.equal(ops(r.actions).indexOf("closeWindow") >= 0, false)
            r = Session.mapped(r.session, "0x55a20b2fac00")
            T.equal(r.session.phase, "closing")
            T.equal(r.session.address, "0x55a20b2fac00")
            T.deepEqual(ops(r.actions), ["closeWindow", "focus"])
            T.equal(r.actions[0].address, "0x55a20b2fac00")
            r = Session.closed(r.session, "0x55a20b2fac00", "0x55a20b2fac00")
            T.equal(r.session.phase, "closed")
            r = Session.capPressed(r.session, "emote", target)
            T.deepEqual(ops(r.actions), ["launch"])
        })

        T.test("a first shell overlay cap press summons and records the target", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            T.equal(r.session.phase, "opening")
            T.equal(r.session.kind, "shell")
            T.equal(r.session.managed, true)
            T.equal(r.session.target.address, "0x56513709a1a0")
            T.deepEqual(ops(r.actions), ["shellSummon"])
            T.equal(ops(r.actions).indexOf("launch") >= 0, false)
            T.equal(ops(r.actions).indexOf("paste") >= 0, false)
        })

        T.test("an open shell overlay hides through the shell instead of closewindow", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.overlayOpened(r.session)
            T.equal(r.session.phase, "open")
            T.deepEqual(ops(r.actions), [])
            r = Session.capPressed(r.session, "omarchy-menu-emoji", target, "0x56513709a1a0")
            T.equal(r.session.phase, "closing")
            T.deepEqual(ops(r.actions), ["shellHide", "focus"])
            T.equal(r.actions[1].address, "0x56513709a1a0")
            T.equal(ops(r.actions).indexOf("closeWindow") >= 0, false)
            T.equal(ops(r.actions).indexOf("paste") >= 0, false)
        })

        T.test("a second press while the shell overlay is opening cancels with hide", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.capPressed(r.session, "omarchy-menu-emoji", target)
            T.equal(r.session.phase, "closing")
            T.equal(r.session.cancelMap, true)
            T.deepEqual(ops(r.actions), ["shellHide"])
            r = Session.overlayOpened(r.session)
            T.equal(r.session.phase, "closing")
            T.deepEqual(ops(r.actions), ["shellHide", "focus"])
        })

        T.test("shell overlay close restores the target and never pastes", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.overlayOpened(r.session)
            r = Session.overlayClosed(r.session, "")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["focus"])
            T.equal(r.actions[0].address, "0x56513709a1a0")
            T.equal(ops(r.actions).indexOf("paste") >= 0, false)
        })

        T.test("a user-focused other client is not stolen back when the overlay closes", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.overlayOpened(r.session)
            r = Session.overlayClosed(r.session, "0xfoot")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), [])
        })

        T.test("closing the panel hides an open shell overlay", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.overlayOpened(r.session)
            r = Session.panelClosed(r.session, "")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["shellHide", "focus"])
        })

        T.test("an open shell overlay refits through the shell, not a client move", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.overlayOpened(r.session)
            var fit = Session.fitActions(r.session)
            T.deepEqual(ops(fit), ["shellFit"])
        })

        T.test("a shell overlay timeout hides instead of closewindow", function () {
            var r = Session.capPressed(null, "omarchy-menu-emoji", target)
            r = Session.timeout(r.session, "")
            T.equal(r.session.phase, "closed")
            T.deepEqual(ops(r.actions), ["shellHide", "focus"])
            T.equal(ops(r.actions).indexOf("closeWindow") >= 0, false)
        })

        Qt.exit(T.report("picker session"))
    }
}
