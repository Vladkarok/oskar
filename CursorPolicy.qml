import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick
import "CursorPolicy.js" as Machine

Item {
    id: policy

    // Hyprland hides the pointer while keys are being pressed, and the keys
    // this panel sends are real ones, so the cursor vanished under the very
    // finger aiming it. While the panel is open that behaviour is suspended
    // (spec-v1 §9), and on close it is restored.
    //
    // This component owns that whole lifecycle — probe, override, restore —
    // out of the panel's presentation code (the R6 review finding): the
    // previous wiring lived as a free property plus callback on Panel.qml,
    // and a close that landed before the probe answered ran the restore
    // first (nothing recorded, so a no-op) and then let the late probe
    // disable hiding with the panel closed, outliving it. CursorPolicy.js
    // is the serialized state machine; every asynchronous answer carries the
    // generation that asked for it and a stale generation can never apply.
    // The host below only executes the actions the machine returns.
    //
    // Applied with `hyprctl eval` and Hyprland's Lua config call: `hyprctl
    // keyword` refuses outright under the Lua parser ("keyword can't work
    // with non-legacy parsers. Use eval."). It only changes the running
    // session, so a config reload restores the user's setting even if the
    // shell dies with the panel open and never runs the restore — the
    // documented escape hatch behind the machine's best-effort destruction
    // restore.
    //
    // Driven by a binding, so every writer of the panel's state — the bar
    // toggle, close(), the shell itself — goes through the same owner.
    property bool targetOpened: false
    onTargetOpenedChanged: dispatch(targetOpened ? Machine.open(policyState)
                                                 : Machine.close(policyState))

    // Set during destruction so the final write goes out detached: a tracked
    // process cannot outlive the object that would report its exit.
    property bool destructing: false
    Component.onDestruction: {
        destructing = true
        dispatch(Machine.destroyed(policyState))
    }

    // A config reload wipes running-session eval changes; the machine treats
    // that as the user's configuration taking the value back, and re-measures
    // while the panel is still open so the suspension survives the reload.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!event || String(event.name) !== "configreloaded") return
            policy.dispatch(Machine.configReloaded(policy.policyState))
        }
    }

    readonly property var policyState: Machine.create()

    Process {
        id: optionRead
        // The generation requested, mirrored onto the collector at the same
        // point. Keyboard.qml's keycap pipeline captures its generation in
        // onStarted because it retags slots while a process is alive; here
        // readPending makes that impossible — the slot cannot be retagged
        // until the previous run has fully exited — so the request-time
        // assignment is the captured generation, and it exists even for a
        // read that never managed to start (which the watchdog must be able
        // to settle by name).
        property int seq: 0
        property string kind: ""
        command: ["hyprctl", "getoption", "cursor:hide_on_key_press", "-j"]
        stdout: StdioCollector {
            id: readCollector
            property int rseq: 0
            property string rkind: ""
            waitForEnd: true
            onStreamFinished: policy.readAnswered(rkind, rseq,
                Machine.parseHideOption(text))
        }
        onExited: {
            // A read that exits without the collector ever delivering (or
            // after it delivered under a guard that dropped) must still free
            // its machine slot — the seq guard makes this a no-op whenever
            // the real answer already landed.
            policy.readAnswered(readCollector.rkind, readCollector.rseq, null)
            readPending = false
            flushQueued()
        }
    }

    Process {
        id: optionWrite
        property int seq: 0
        property string value: "true"
        command: ["hyprctl", "eval",
            "hl.config({ cursor = { hide_on_key_press = " + value + " } })"]
        onExited: function (exitCode) {
            // A non-zero exit is a failed write: the machine must hear it,
            // or a failed undo would be recorded as landed.
            writeSettled(seq, exitCode === 0)
            writePending = false
            flushQueued()
        }
    }

    // A read that never started is a failed read, and a write that could not
    // start leaves the compositor untouched — either way the machine must
    // hear a settle or its generation would wait forever. Quickshell 0.3.1's
    // Process reports no spawn error and no exit for a hung command, so a
    // one-shot watchdog settles an op that is still unanswered after 10 s.
    //
    // The settle is MACHINE-side only: the pending flag stays true until the
    // process itself exits, because a still-running Process ignores
    // `running = true` — clearing the flag early would turn the next op into
    // a silent no-op and strand its generation. Until exit, new ops queue
    // (queuedActions) and run the moment the hung command gives up.
    Timer {
        id: settleWatchdog
        interval: 10000
        onTriggered: {
            // Settle, machine-side only, an op the machine is STILL waiting
            // for, under the generation the physically running op captured.
            // Branching on the machine slots (not on the flags) is what
            // keeps a stuck read process from starving a write settle: the
            // read branch is skipped once its generation was retired, and
            // the next firing reaches the write. A QUEUED generation owns
            // no process and cannot be settled — it starts (and arms its
            // own window) when the slot frees, so it must not keep this
            // timer spinning. (A queued generation starts — and arms — when the slot
// frees; a command that never exits strands it, per the limitation above.)
            var canSettleRead = readPending
                && (readCollector.rkind === "probe"
                    && readCollector.rseq === policyState.probeSeq
                    || readCollector.rkind === "restore"
                    && readCollector.rseq === policyState.restoreSeq)
            var canSettleWrite = writePending
                && optionWrite.seq === policyState.writeSeq
            if (canSettleRead)
                policy.readAnswered(readCollector.rkind, readCollector.rseq, null)
            else if (canSettleWrite)
                policy.writeSettled(optionWrite.seq, false)
            if (canSettleRead || canSettleWrite)
                settleWatchdog.restart()
        }
    }

    // One op at a time per kind, tracked explicitly rather than through
    // `running`: the flag is what stops a second read starting before the
    // first run's answer has been delivered and accounted. Load-bearing
    // ordering: StdioCollector with waitForEnd delivers streamFinished
    // BEFORE the Process's exited — the answer reaches the machine under the
    // generation captured at start, and only then does onExited free the
    // slot. If that order ever inverted, a queued read could start before
    // the previous answer landed and inherit its slot mid-flight.
    property bool readPending: false
    property bool writePending: false

    // The machine serializes the lifecycle logically, but its retirement of
    // an in-flight op (a close racing the probe, a reload racing a verify)
    // can leave the physically running process superseded. Rather than
    // killing it — its late answer would be indistinguishable from a real
    // one — a new action waits here; onExited flushes the queue. Also holds
    // ops that arrive while a watchdog-settled command is still hung: they
    // run when the hung command finally exits.
    property var queuedActions: []

    // Answers are reported under the generation captured at start
    // (readCollector.rseq / optionWrite.seq); the guard drops everything
    // else. Neither function frees the pending slot — that is onExited's
    // job, so a hung process can never let a second op overlap it.
    function readAnswered(kind, seq, enabled) {
        var pending = kind === "probe" ? policyState.probeSeq : policyState.restoreSeq
        if (seq === pending)
            dispatch(Machine.readResult(policyState, kind, seq, enabled))
    }

    function writeSettled(seq, ok) {
        if (seq === policyState.writeSeq)
            dispatch(Machine.writeResult(policyState, seq, ok))
    }

    function queueAction(action) {
        // Prune generations the machine retired while queued, so a hung
        // process cannot accumulate dead entries behind it.
        for (var i = queuedActions.length - 1; i >= 0; i--) {
            var queued = queuedActions[i]
            var retired = queued.op === "read"
                ? (queued.seq !== policyState.probeSeq
                   && queued.seq !== policyState.restoreSeq)
                : queued.seq !== policyState.writeSeq
            if (retired) queuedActions.splice(i, 1)
        }
        queuedActions.push(action)
    }

    function flushQueued() {
        // Walk in order: drop generations the machine retired while queued,
        // skip entries whose slot is still busy, and start the first runnable
        // one — one per flush; the rest start at that run's own exit.
        for (var i = 0; i < queuedActions.length; ) {
            var action = queuedActions[i]
            var retired = action.op === "read"
                ? (action.seq !== policyState.probeSeq
                   && action.seq !== policyState.restoreSeq)
                : action.seq !== policyState.writeSeq
            if (retired) {
                queuedActions.splice(i, 1)
                continue
            }
            var busy = action.op === "read" ? readPending : writePending
            if (busy) {
                i += 1
                continue
            }
            queuedActions.splice(i, 1)
            dispatch([action])
            return // it owns its slot now; the rest flush at its exit
        }
    }

    property string lastOutcome: ""

    function dispatch(actions) {
        for (var i = 0; i < actions.length; i++) {
            var action = actions[i]
            if (action.op === "read") {
                if (readPending) {
                    if (queuedActions.length === 0)
                        console.log("[osk] cursor policy: read queued behind the run in flight")
                    queueAction(action)
                    continue
                }
                readPending = true
                optionRead.seq = action.seq
                optionRead.kind = action.kind
                readCollector.rseq = action.seq
                readCollector.rkind = action.kind
                optionRead.running = true
                settleWatchdog.restart()
            } else if (action.op === "write") {
                if (destructing || action.seq === 0) {
                    // Best-effort: the destruction restore, or any write with
                    // no lifecycle left to confirm it.
                    Quickshell.execDetached(["hyprctl", "eval",
                        "hl.config({ cursor = { hide_on_key_press = "
                            + action.value + " } })"])
                } else if (writePending) {
                    if (queuedActions.length === 0)
                        console.log("[osk] cursor policy: write queued behind the run in flight")
                    queueAction(action)
                    continue
                } else {
                    writePending = true
                    optionWrite.seq = action.seq
                    optionWrite.value = action.value
                    optionWrite.running = true
                    settleWatchdog.restart()
                }
            }
        }
        // The journal is the diagnostic channel for the races this policy
        // arbitrates; log only what changed, so a quiet session stays quiet.
        if (policyState.outcome !== lastOutcome) {
            console.log("[osk] cursor policy:", policyState.outcome)
            lastOutcome = policyState.outcome
        }
    }
}
