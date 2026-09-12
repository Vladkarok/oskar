.pragma library

// Picker-session lifecycle (tickets 09/10, spec-v1.1 §1, decisions §24).
// Pure: events in, next session + actions out. Geometry stays in PickerFit.js.
// The host (Panel.qml) runs processes; this module never launches, closes,
// or writes a window rule itself.
//
// Managed toggle is Emote or the Omarchy shell overlay. A second `emote`
// exec destroy/recreates the picker (live guest: same pid, new address,
// class "emote"); dismissal is closewindow of the identified address. The
// shell overlay (`omarchy-menu-emoji`) uses open/hide/state IPC, never a
// client move or a second paste. A cancelled opening keeps cancelMap until
// that window is gone or timeout closewindows the late launch address
// (Emote) / hides the overlay (shell). Closing retries dismiss; failed()
// settles. queueHandoff refuses to kill an in-flight close and will not
// retarget that close onto a later map. A closing session with no pin does
// not rearm the 6s closer. stay_focused is applied only to an Emote
// address while the session is open and unset on settle — it is a
// pointer/follow_mouse lock, not the keyboard-target path.

function isManagedEmote(app) {
    return String(app || "").toLowerCase() === "emote"
}

function isManagedShell(app) {
    return String(app || "").toLowerCase() === "omarchy-menu-emoji"
}

function sessionKind(app) {
    if (isManagedShell(app)) return "shell"
    if (isManagedEmote(app)) return "emote"
    return "client"
}

function snapshotTarget(target) {
    if (!target || !target.address) return null
    return { address: String(target.address), className: String(target.className || "") }
}

function create(app, target) {
    return {
        app: String(app || ""),
        managed: isManagedEmote(app) || isManagedShell(app),
        kind: sessionKind(app),
        phase: "opening",
        target: snapshotTarget(target),
        address: "",
        stayApplied: false,
        cancelMap: false
    }
}

function sameAddr(a, b) {
    var left = String(a || "").toLowerCase()
    var right = String(b || "").toLowerCase()
    if (left.indexOf("0x") === 0) left = left.slice(2)
    if (right.indexOf("0x") === 0) right = right.slice(2)
    return left !== "" && left === right
}

function restoreAction(session) {
    if (!session || !session.target || !session.target.address) return null
    return { op: "focus", address: session.target.address }
}

function shouldRestore(session, currentAddress) {
    if (!session || !session.target || !session.target.address) return false
    if (!currentAddress) return true
    if (session.address && sameAddr(currentAddress, session.address)) return true
    if (sameAddr(currentAddress, session.target.address)) return true
    return false
}

function dismissShell(session, currentAddress) {
    var actions = [{ op: "shellHide" }]
    if (shouldRestore(session, currentAddress)) {
        var restore = restoreAction(session)
        if (restore) actions.push(restore)
    }
    session.phase = "closing"
    return actions
}

function dismissActions(session, currentAddress) {
    if (session && session.kind === "shell")
        return dismissShell(session, currentAddress)
    var actions = []
    if (session.stayApplied && session.address) {
        actions.push({ op: "setStayFocused", address: session.address, value: "unset" })
        session.stayApplied = false
    }
    if (session.address)
        actions.push({ op: "closeWindow", address: session.address })
    if (shouldRestore(session, currentAddress)) {
        var restore = restoreAction(session)
        if (restore) actions.push(restore)
    }
    session.phase = "closing"
    return actions
}

function rearmCloser(session) {
    if (!session || session.phase !== "closing") return false
    if (session.kind === "shell") return true
    return !!session.address
}

function queueHandoff(inFlight, actions) {
    var launches = []
    var handoff = { addr: "", stay: "", closeWin: false, focusAddr: "" }
    for (var i = 0; i < (actions || []).length; i++) {
        var action = actions[i]
        if (action.op === "launch") {
            launches.push(action)
            continue
        }
        if (action.op === "setStayFocused") {
            handoff.addr = action.address
            handoff.stay = action.value
        } else if (action.op === "closeWindow") {
            handoff.addr = action.address
            handoff.closeWin = true
        } else if (action.op === "focus") {
            handoff.focusAddr = action.address
        }
    }
    var hasHandoff = !!(handoff.stay || handoff.closeWin || handoff.focusAddr)
    var blocking = inFlight && inFlight.running && inFlight.closeWin
    if (blocking && hasHandoff) {
        var pending = inFlight.pending
            ? {
                addr: inFlight.pending.addr || "",
                stay: inFlight.pending.stay || "",
                closeWin: !!inFlight.pending.closeWin,
                focusAddr: inFlight.pending.focusAddr || ""
            }
            : { addr: "", stay: "", closeWin: false, focusAddr: "" }
        if (handoff.closeWin) {
            if (!pending.closeWin || !pending.addr)
                pending.addr = handoff.addr
            pending.closeWin = true
        }
        if (handoff.stay) {
            pending.stay = handoff.stay
            if (handoff.addr && !pending.closeWin)
                pending.addr = handoff.addr
        }
        if (handoff.focusAddr) pending.focusAddr = handoff.focusAddr
        return { launches: launches, start: false, pending: pending, handoff: null }
    }
    return {
        launches: launches,
        start: hasHandoff,
        pending: null,
        handoff: hasHandoff ? handoff : null
    }
}

function handoffActions(handoff) {
    if (!handoff) return []
    var actions = []
    if (handoff.stay)
        actions.push({ op: "setStayFocused", address: handoff.addr, value: handoff.stay })
    if (handoff.closeWin)
        actions.push({ op: "closeWindow", address: handoff.addr })
    if (handoff.focusAddr)
        actions.push({ op: "focus", address: handoff.focusAddr })
    return actions
}

function capPressed(session, app, target, currentAddress) {
    if (isManagedShell(app)) {
        if (!session || session.phase === "closed") {
            return {
                session: create(app, target),
                actions: [{ op: "shellSummon" }]
            }
        }
        if (session.phase === "closing")
            return { session: session, actions: dismissShell(session, currentAddress) }
        if (session.phase === "opening") {
            session.phase = "closing"
            session.cancelMap = true
            return { session: session, actions: [{ op: "shellHide" }] }
        }
        if (session.phase === "open")
            return { session: session, actions: dismissShell(session, currentAddress) }
        return { session: session, actions: [] }
    }
    if (!isManagedEmote(app)) {
        return {
            session: create(app, target),
            actions: [{ op: "launch", app: String(app || "") }]
        }
    }
    if (!session || session.phase === "closed") {
        return {
            session: create(app, target),
            actions: [{ op: "launch", app: "emote" }]
        }
    }
    if (session.phase === "closing") {
        if (!session.address)
            return { session: session, actions: [] }
        return { session: session, actions: dismissActions(session, currentAddress) }
    }
    if (session.phase === "opening") {
        session.phase = "closing"
        session.cancelMap = true
        var actions = []
        if (session.address)
            actions.push({ op: "closeWindow", address: session.address })
        return { session: session, actions: actions }
    }
    if (session.phase === "open")
        return { session: session, actions: dismissActions(session, currentAddress) }
    return { session: session, actions: [] }
}

function mapped(session, address) {
    if (!session) return { session: session, actions: [] }
    if (session.cancelMap) {
        var actions = [{ op: "closeWindow", address: address }]
        if (shouldRestore(session, "")) {
            var restore = restoreAction(session)
            if (restore) actions.push(restore)
        }
        // Keep the closer until this window is gone or timeout closewindows
        // it. Settling here would drop a failed/slow closewindow.
        session.phase = "closing"
        session.address = address
        return { session: session, actions: actions }
    }
    session.address = address
    session.phase = "open"
    var actions = []
    if (session.managed && address && !session.stayApplied) {
        // stay_focused=true wins pointer hit-testing before overlays, so
        // OSK clicks (including ☺ dismiss) never land. Unset it on the
        // identified address only; a class-wide host rule is not touched.
        actions.push({ op: "setStayFocused", address: address, value: "unset" })
        session.stayApplied = true
    }
    return { session: session, actions: actions }
}

function closed(session, address, currentAddress) {
    if (!session) return { session: null, actions: [] }
    var pin = String(session.address || "")
    if (!sameAddr(pin, address)) return { session: session, actions: [] }
    var actions = []
    if (session.stayApplied) {
        actions.push({ op: "setStayFocused", address: pin, value: "unset" })
        session.stayApplied = false
    }
    if (shouldRestore(session, currentAddress)) {
        var restore = restoreAction(session)
        if (restore) actions.push(restore)
    }
    session.phase = "closed"
    session.address = ""
    return { session: session, actions: actions }
}

function settleClosed(session, currentAddress, pin) {
    var actions = []
    if (session.stayApplied && session.address) {
        actions.push({ op: "setStayFocused", address: session.address, value: "unset" })
        session.stayApplied = false
    }
    if (pin)
        actions.push({ op: "closeWindow", address: pin })
    if (shouldRestore(session, currentAddress)) {
        var restore = restoreAction(session)
        if (restore) actions.push(restore)
    }
    session.phase = "closed"
    session.address = ""
    return { session: session, actions: actions }
}

function timeout(session, currentAddress, lateAddress) {
    if (!session) return { session: null, actions: [] }
    if (session.phase === "open")
        return { session: session, actions: [] }
    if (session.kind === "shell") {
        var actions = [{ op: "shellHide" }]
        if (shouldRestore(session, currentAddress)) {
            var restore = restoreAction(session)
            if (restore) actions.push(restore)
        }
        session.phase = "closed"
        session.address = ""
        return { session: session, actions: actions }
    }
    return settleClosed(session, currentAddress, session.address || lateAddress || "")
}

function overlayOpened(session) {
    if (!session || session.kind !== "shell")
        return { session: session, actions: [] }
    if (session.phase === "open" || session.phase === "closed")
        return { session: session, actions: [] }
    if (session.cancelMap) {
        var actions = [{ op: "shellHide" }]
        if (shouldRestore(session, "")) {
            var restore = restoreAction(session)
            if (restore) actions.push(restore)
        }
        session.phase = "closing"
        return { session: session, actions: actions }
    }
    session.phase = "open"
    return { session: session, actions: [] }
}

function overlayClosed(session, currentAddress) {
    if (!session || session.phase === "closed" || session.kind !== "shell")
        return { session: session, actions: [] }
    var actions = []
    if (shouldRestore(session, currentAddress)) {
        var restore = restoreAction(session)
        if (restore) actions.push(restore)
    }
    session.phase = "closed"
    session.address = ""
    return { session: session, actions: actions }
}

function fitActions(session) {
    if (session && session.kind === "shell" && session.phase === "open")
        return [{ op: "shellFit" }]
    return []
}

function failed(session, currentAddress) {
    if (!session || session.phase === "closed")
        return { session: session, actions: [] }
    if (session.kind === "shell") {
        var actions = [{ op: "shellHide" }]
        if (shouldRestore(session, currentAddress)) {
            var restore = restoreAction(session)
            if (restore) actions.push(restore)
        }
        session.phase = "closed"
        session.address = ""
        return { session: session, actions: actions }
    }
    if (session.cancelMap && !session.address)
        return { session: session, actions: [] }
    return settleClosed(session, currentAddress, session.address || "")
}

function panelClosed(session, currentAddress) {
    if (!session || session.phase === "closed")
        return { session: session, actions: [] }
    if (session.kind === "shell") {
        if (session.phase === "opening" || session.phase === "closing") {
            session.phase = "closing"
            session.cancelMap = true
            return { session: session, actions: [{ op: "shellHide" }] }
        }
        var shellActions = dismissShell(session, currentAddress)
        session.phase = "closed"
        session.cancelMap = true
        return { session: session, actions: shellActions }
    }
    if (session.phase === "opening" || (session.phase === "closing" && !session.address)) {
        session.phase = "closing"
        session.cancelMap = true
        var pending = []
        if (shouldRestore(session, currentAddress)) {
            var restore = restoreAction(session)
            if (restore) pending.push(restore)
        }
        return { session: session, actions: pending }
    }
    var actions = dismissActions(session, currentAddress)
    session.phase = "closed"
    session.address = ""
    session.cancelMap = true
    return { session: session, actions: actions }
}
