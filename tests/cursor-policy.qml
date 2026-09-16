// Pure cursor-policy lifecycle logic, beside the existing panel reducer
// tests. This is not a product seam: it drives the same pure state machine
// the panel's CursorPolicy.qml hosts, with no processes, compositor or
// filesystem behind it (spec-v1.1 §8). The machine's contract is the whole
// point: every event returns the actions to execute, and a stale generation's
// answer can never produce one.
import QtQml
import "../CursorPolicy.js" as Machine
import "harness.js" as T

QtObject {
    // Test helpers over the action lists the machine returns.
    function writes(actions) {
        var out = []
        for (var i = 0; i < actions.length; i++)
            if (actions[i].op === "write") out.push(actions[i])
        return out
    }
    function reads(actions) {
        var out = []
        for (var i = 0; i < actions.length; i++)
            if (actions[i].op === "read") out.push(actions[i])
        return out
    }
    // Drive a full "open, measured enabled, applied" lifecycle; returns the
    // state with the suspension write already confirmed.
    function suspended() {
        var m = Machine.create()
        Machine.open(m)
        Machine.readResult(m, "probe", 1, true)
        Machine.writeResult(m, 1, true)
        return m
    }

    Component.onCompleted: {
        T.test("the option parse accepts bool and legacy int, nothing else", function () {
            T.equal(Machine.parseHideOption('{"bool": true}'), true)
            T.equal(Machine.parseHideOption('{"bool": false}'), false)
            T.equal(Machine.parseHideOption('{"int": 1}'), true)
            T.equal(Machine.parseHideOption('{"int": 0}'), false)
            // Anything else is a failed read, not an answer: null means the
            // policy must keep its hands off.
            T.equal(Machine.parseHideOption(""), null)
            T.equal(Machine.parseHideOption("garbage"), null)
            T.equal(Machine.parseHideOption("{}"), null)
            T.equal(Machine.parseHideOption('{"bool": 1}'), null)
            T.equal(Machine.parseHideOption('{"int": 2}'), null)
        })

        T.test("open probes, and a measured enabled option is suspended exactly once", function () {
            var m = Machine.create()
            var actions = Machine.open(m)
            T.deepEqual(reads(actions), [{ op: "read", kind: "probe", seq: 1 }])
            T.equal(writes(actions).length, 0)
            var applied = Machine.readResult(m, "probe", 1, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 1 }])
            T.equal(m.overrideLive, true)
            T.equal(m.recorded, "true")
            // Confirming the write settles the lifecycle: nothing pending.
            T.deepEqual(Machine.writeResult(m, 1, true), [])
            T.equal(m.writeSeq, 0)
        })

        T.test("originally disabled cursor hiding suspends and restores nothing", function () {
            var m = Machine.create()
            Machine.open(m)
            var actions = Machine.readResult(m, "probe", 1, false)
            T.equal(actions.length, 0)
            T.equal(m.overrideLive, false)
            T.equal(m.outcome, "cursor hiding already off; nothing to suspend")
            // And the close has nothing to undo — no restore read, no write.
            T.deepEqual(Machine.close(m), [])
        })

        T.test("a failed probe overrides nothing and close is a plain no-op", function () {
            var m = Machine.create()
            Machine.open(m)
            var actions = Machine.readResult(m, "probe", 1, null)
            T.equal(actions.length, 0)
            T.equal(m.overrideLive, false)
            T.equal(m.outcome, "probe failed; cursor hiding left as the user set it")
            T.deepEqual(Machine.close(m), [])
        })

        T.test("close before the probe answers leaves the late result powerless", function () {
            // The R6 shape: the panel closes while the probe is still in
            // flight; the old wiring then disabled hiding after close and
            // outlived the panel. The machine must drop the answer.
            var m = Machine.create()
            T.equal(Machine.open(m).length, 1) // probe in flight
            T.deepEqual(Machine.close(m), []) // no override existed to restore
            var late = Machine.readResult(m, "probe", 1, true)
            T.equal(late.length, 0)
            T.equal(m.overrideLive, false)
            T.equal(m.recorded, "")
            T.equal(m.outcome, "stale probe result dropped")
        })

        T.test("a stale generation cannot apply after a newer open either", function () {
            var m = Machine.create()
            Machine.open(m) // seq 1, probe in flight
            Machine.close(m)
            var reopen = Machine.open(m)
            T.deepEqual(reads(reopen), [{ op: "read", kind: "probe", seq: 2 }])
            // The first lifecycle's answer lands late: dropped.
            T.equal(Machine.readResult(m, "probe", 1, true).length, 0)
            // The live lifecycle's answer applies.
            var applied = Machine.readResult(m, "probe", 2, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 2 }])
        })

        T.test("close restores exactly what this lifecycle applied", function () {
            var m = suspended()
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 2 }])
            // The verify read finds our override still live: undo it. The
            // override stays live until the write CONFIRMS — a failed undo
            // write must not forget the obligation.
            var restore = Machine.readResult(m, "restore", 2, false)
            T.deepEqual(writes(restore), [{ op: "write", value: "true", seq: 2 }])
            T.equal(m.overrideLive, true)
            T.deepEqual(Machine.writeResult(m, 2, true), [])
            T.equal(m.overrideLive, false)
            T.equal(m.recorded, "")
        })

        T.test("restore skips the write when the value moved to the user's mid-lifecycle", function () {
            // A config reload (or an external change) already put the user's
            // value back: it is not ours to undo, and writing over it would
            // restore a guess.
            var m = suspended()
            Machine.close(m)
            var restore = Machine.readResult(m, "restore", 2, true)
            T.equal(restore.length, 0)
            T.equal(m.overrideLive, false)
            T.equal(m.outcome, "restore skipped; the value no longer ours")
        })

        T.test("a failed verify read still restores the recorded measurement", function () {
            // Skipping here would risk the exact leak this policy exists to
            // close; the recorded value was measured, not guessed.
            var m = suspended()
            Machine.close(m)
            var restore = Machine.readResult(m, "restore", 2, null)
            T.deepEqual(writes(restore), [{ op: "write", value: "true", seq: 2 }])
            T.deepEqual(Machine.writeResult(m, 2, true), [])
            T.equal(m.overrideLive, false)
        })

        T.test("close behind an in-flight suspension write waits for it", function () {
            // Restoring before the suspension write lands could read the
            // pre-write value, skip the undo, and leave our false live after
            // close — the leak wearing a different hat.
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true) // write seq 1 in flight
            T.deepEqual(Machine.close(m), [])
            var settled = Machine.writeResult(m, 1, true)
            T.deepEqual(reads(settled), [{ op: "read", kind: "restore", seq: 2 }])
            T.deepEqual(Machine.readResult(m, "restore", 2, false).length, 1)
        })

        T.test("reopening behind a suspension write rides the live override", function () {
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true) // write seq 1 in flight
            Machine.close(m) // restore queued behind the write
            // The reopen: the suspension is already in effect, so no new
            // probe and no second write — this lifecycle inherits it.
            T.deepEqual(Machine.open(m), [])
            T.equal(m.outcome, "open rode the still-live override")
            T.deepEqual(Machine.writeResult(m, 1, true), [])
            // And the inherited override is undone by this lifecycle's close.
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 2 }])
            T.deepEqual(writes(Machine.readResult(m, "restore", 2, false)),
                [{ op: "write", value: "true", seq: 2 }])
        })

        T.test("reopen behind a settling restore rides the live override", function () {
            var m = suspended()
            Machine.close(m) // restore read seq 2 in flight
            Machine.open(m) // deferred — the previous lifecycle is mid-handoff
            // The verify finds our override still live and the panel already
            // open again: the override continues as-is. Undoing it and
            // re-probing would flap the compositor setting twice for nothing.
            var verify = Machine.readResult(m, "restore", 2, false)
            T.equal(verify.length, 0)
            T.equal(m.overrideLive, true)
            T.equal(m.recorded, "true")
            T.equal(m.outcome, "verify superseded by reopen; the override continues")
            // And this lifecycle's close restores it once.
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 3 }])
            T.deepEqual(writes(Machine.readResult(m, "restore", 3, false)),
                [{ op: "write", value: "true", seq: 3 }])
        })

        T.test("a verify reading true while reopened re-establishes the suspension", function () {
            var m = suspended()
            Machine.close(m)
            Machine.open(m)
            // The override is gone; riding it would leave the panel open
            // unsuspended. Re-measure and suspend if the config still says so.
            var verify = Machine.readResult(m, "restore", 2, true)
            T.deepEqual(reads(verify), [{ op: "read", kind: "probe", seq: 3 }])
            T.equal(m.overrideLive, false)
            var applied = Machine.readResult(m, "probe", 3, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 3 }])
        })

        T.test("a failed verify during reopen keeps ownership", function () {
            // Re-probing after a failed verify can read the still-live
            // override's false and assume hiding was originally disabled —
            // then the next close restores nothing.
            var m = suspended()
            Machine.close(m)
            Machine.open(m)
            var verify = Machine.readResult(m, "restore", 2, null)
            T.equal(verify.length, 0)
            T.equal(m.overrideLive, true)
            T.equal(m.recorded, "true")
            T.equal(m.probeSeq, 0)
            T.equal(m.outcome, "verify failed during reopen; the override obligation stands")
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 3 }])
            T.deepEqual(writes(Machine.readResult(m, "restore", 3, false)),
                [{ op: "write", value: "true", seq: 3 }])
        })

        T.test("a closed-panel verify that finds the value moved writes nothing", function () {
            var m = suspended()
            Machine.close(m)
            var verify = Machine.readResult(m, "restore", 2, true)
            T.equal(verify.length, 0)
            T.equal(m.overrideLive, false)
            T.equal(m.outcome, "restore skipped; the value no longer ours")
        })


        T.test("an unconfirmed suspension write keeps the restore obligation", function () {
            // A watchdog timeout is not settlement: the write may still land.
            // Verifying now can read the pre-write true, drop the obligation,
            // and let the late false land after close.
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true)
            Machine.close(m)
            var unconfirmed = Machine.writeResult(m, 1, null)
            T.equal(unconfirmed.length, 0)
            T.equal(m.writeSeq, 1)
            T.equal(m.writeValue, "false")
            T.equal(m.overrideLive, true)
            T.equal(m.recorded, "true")
            T.equal(m.outcome, "suspension write unconfirmed; restore obligation stands")
            // Physical completion, not the timeout, starts the queued restore.
            var settled = Machine.writeResult(m, 1, true)
            T.equal(m.writeSeq, 0)
            T.deepEqual(reads(settled), [{ op: "read", kind: "restore", seq: 2 }])
            T.deepEqual(writes(Machine.destroyed(m)),
                [{ op: "write", value: "true", seq: 0 }])
        })

        T.test("an unconfirmed undo write stays in flight until it completes", function () {
            var m = suspended()
            Machine.close(m)
            Machine.readResult(m, "restore", 2, false)
            T.deepEqual(Machine.writeResult(m, 2, null), [])
            T.equal(m.writeSeq, 2)
            T.equal(m.writeValue, "true")
            T.equal(m.overrideLive, true)
            T.deepEqual(Machine.writeResult(m, 2, true), [])
            T.equal(m.overrideLive, false)
            T.equal(m.writeSeq, 0)
        })

        T.test("a reload during an unconfirmed write waits for physical completion", function () {
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true)
            T.deepEqual(Machine.configReloaded(m), [])
            T.deepEqual(Machine.writeResult(m, 1, null), [])
            T.equal(m.writeSeq, 1)
            T.equal(m.reloadDuringWrite, true)
            T.equal(m.overrideLive, true)
            var settled = Machine.writeResult(m, 1, true)
            T.equal(m.overrideLive, false)
            T.equal(m.reloadDuringWrite, false)
            T.deepEqual(reads(settled), [{ op: "read", kind: "probe", seq: 2 }])
        })

        T.test("a failed suspension write leaves hiding as the user set it", function () {
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true) // suspension write seq 1
            // The write never landed: hiding was never disabled, so there is
            // nothing to undo and the close must not "restore" anything.
            T.deepEqual(Machine.writeResult(m, 1, false), [])
            T.equal(m.overrideLive, false)
            T.equal(m.recorded, "")
            T.equal(m.outcome, "suspension write failed; hiding left as the user set it")
            T.deepEqual(Machine.close(m), [])
        })

        T.test("a failed undo write keeps the obligation and the next close retries", function () {
            var m = suspended()
            Machine.close(m)
            var undo = Machine.readResult(m, "restore", 2, false)
            T.deepEqual(writes(undo), [{ op: "write", value: "true", seq: 2 }])
            // The undo write failed: the override must not be forgotten, or
            // hiding stays disabled with nothing owed — the leak by another
            // route.
            T.deepEqual(Machine.writeResult(m, 2, false), [])
            T.equal(m.overrideLive, true)
            T.equal(m.recorded, "true")
            T.equal(m.outcome, "restore write failed; the undo obligation stands")
            // A reopen rides the still-live obligation; its close verifies
            // and retries the undo.
            T.deepEqual(Machine.open(m), [])
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 3 }])
            T.deepEqual(writes(Machine.readResult(m, "restore", 3, false)),
                [{ op: "write", value: "true", seq: 3 }])
            T.deepEqual(Machine.writeResult(m, 3, true), [])
            T.equal(m.overrideLive, false)
        })

        T.test("a config reload during the probe retires it and reissues", function () {
            // A pre-reload true sample must not suspend after the reload
            // configured false — that would restore obsolete true on close.
            var m = Machine.create()
            Machine.open(m) // probe seq 1 in flight
            var actions = Machine.configReloaded(m)
            T.deepEqual(reads(actions), [{ op: "read", kind: "probe", seq: 2 }])
            T.equal(m.probeSeq, 2)
            T.equal(Machine.readResult(m, "probe", 1, true).length, 0)
            T.equal(m.overrideLive, false)
            T.deepEqual(Machine.readResult(m, "probe", 2, false), [])
            T.equal(m.overrideLive, false)
            T.deepEqual(Machine.close(m), [])
        })

        T.test("open behind an in-flight undo write defers and re-probes fresh", function () {
            // The undo write is REMOVING the override; riding it would leave
            // the panel open, unsuspended, with nothing re-measuring (the
            // mirror of the reopen-during-suspension-write case).
            var m = suspended()
            Machine.close(m) // verify read seq 2
            var undo = Machine.readResult(m, "restore", 2, false)
            T.deepEqual(writes(undo), [{ op: "write", value: "true", seq: 2 }])
            var opening = Machine.open(m)
            T.equal(opening.length, 0)
            T.equal(m.outcome, "open deferred behind the settling previous lifecycle")
            // The undo lands: the fresh probe measures the user's true and
            // re-establishes the suspension for this open.
            var resumed = Machine.writeResult(m, 2, true)
            T.deepEqual(reads(resumed), [{ op: "read", kind: "probe", seq: 3 }])
            var applied = Machine.readResult(m, "probe", 3, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 3 }])
            T.deepEqual(Machine.writeResult(m, 3, true), [])
            T.equal(m.overrideLive, true)
            // And this lifecycle's close restores once.
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 4 }])
            T.deepEqual(writes(Machine.readResult(m, "restore", 4, false)),
                [{ op: "write", value: "true", seq: 4 }])
            T.deepEqual(Machine.writeResult(m, 4, true), [])
        })

        T.test("a failed suspension write drops a queued restore as pointless", function () {
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true) // suspension write seq 1
            Machine.close(m) // restore queued behind the write
            // Nothing was ever suspended: the failed write's settle returns
            // no follow-up at all — no verify read, no restore write.
            T.deepEqual(Machine.writeResult(m, 1, false), [])
            T.equal(m.restoreSeq, 0)
            T.equal(m.overrideLive, false)
            T.deepEqual(Machine.close(m), [])
        })

        T.test("a probe deferred behind an undo write survives a close-open burst", function () {
            // open deferred behind the undo, closed again (queueing a
            // restore), opened again — all before the undo write settles.
            // The restoreQueued path used to drop the queued probe here,
            // leaving the panel open with the suspension unestablished.
            var m = suspended()
            Machine.close(m) // verify read seq 2
            Machine.readResult(m, "restore", 2, false) // undo write seq 2
            Machine.open(m) // deferred behind the undo write
            Machine.close(m) // restore queued behind it too
            Machine.open(m) // deferred again
            var settled = Machine.writeResult(m, 2, true)
            T.deepEqual(reads(settled), [{ op: "read", kind: "probe", seq: 3 }])
            // The override is gone (the undo landed), so the fresh probe
            // re-establishes the suspension for this open.
            var applied = Machine.readResult(m, "probe", 3, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 3 }])
            T.deepEqual(Machine.writeResult(m, 3, true), [])
            T.equal(m.overrideLive, true)
            T.equal(m.opened, true)
        })

        T.test("a config reload while closed, nothing pending, is a no-op", function () {
            var m = suspended()
            Machine.close(m)
            T.deepEqual(writes(Machine.readResult(m, "restore", 2, false)),
                [{ op: "write", value: "true", seq: 2 }])
            T.deepEqual(Machine.writeResult(m, 2, true), [])
            T.deepEqual(Machine.configReloaded(m), [])
            T.equal(m.outcome, "config reload; no override in place")
        })

        T.test("a config reload while the panel is open re-suspends", function () {
            // A reload re-applies the config file and wipes running-session
            // eval changes. Spec-v1 §9 holds for the WHOLE open: the policy
            // must re-measure and re-establish the suspension (or honestly
            // stand down if the config itself now says false), not leave the
            // cursor hiding under the finger until the next close.
            var m = suspended()
            var actions = Machine.configReloaded(m)
            T.equal(m.overrideLive, false)
            T.deepEqual(reads(actions), [{ op: "read", kind: "probe", seq: 2 }])
            // The config's own value is true: suspend anew.
            var applied = Machine.readResult(m, "probe", 2, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 2 }])
            T.deepEqual(Machine.writeResult(m, 2, true), [])
            // And the close still restores exactly once.
            var closing = Machine.close(m)
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 3 }])
            T.deepEqual(writes(Machine.readResult(m, "restore", 3, false)),
                [{ op: "write", value: "true", seq: 3 }])
        })

        T.test("a config reload naming false stops the suspension honestly", function () {
            var m = suspended()
            var actions = Machine.configReloaded(m)
            T.deepEqual(reads(actions), [{ op: "read", kind: "probe", seq: 2 }])
            // The user's config now says false: nothing to suspend, and the
            // later close must not "restore" anything.
            T.deepEqual(Machine.readResult(m, "probe", 2, false), [])
            T.equal(m.overrideLive, false)
            T.deepEqual(Machine.close(m), [])
        })

        T.test("close during a deferred probe replaces the dying verify cleanly", function () {
            var m = suspended()
            Machine.close(m) // restore read seq 2 in flight
            Machine.open(m) // deferred
            var closing = Machine.close(m) // closed again before anything settles
            T.deepEqual(reads(closing), [{ op: "read", kind: "restore", seq: 3 }])
            // The first verify's late answer drops under its retired
            // generation; the fresh one settles the restore.
            T.equal(Machine.readResult(m, "restore", 2, false).length, 0)
            T.deepEqual(writes(Machine.readResult(m, "restore", 3, false)),
                [{ op: "write", value: "true", seq: 3 }])
        })

        T.test("a config reload invalidates a restore read already in flight", function () {
            var m = suspended()
            Machine.close(m) // restore read seq 2 in flight
            Machine.configReloaded(m)
            // The late answer must not write: the reload owns the value now.
            T.equal(Machine.readResult(m, "restore", 2, false).length, 0)
            T.equal(m.overrideLive, false)
        })

        T.test("a config reload during a write re-probes if the panel is still open", function () {
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true) // suspension write in flight
            T.deepEqual(Machine.configReloaded(m), [])
            var settled = Machine.writeResult(m, 1, true)
            T.equal(m.overrideLive, false)
            T.deepEqual(reads(settled), [{ op: "read", kind: "probe", seq: 2 }])
            var applied = Machine.readResult(m, "probe", 2, true)
            T.deepEqual(writes(applied), [{ op: "write", value: "false", seq: 2 }])
        })

        T.test("a config reload during a write is reconciled after settlement", function () {
            // The write may already have applied before the reload wiped it.
            // Restoring recorded true would overwrite a config that now says
            // false. After settlement, the reload owns the value.
            var m = Machine.create()
            Machine.open(m)
            Machine.readResult(m, "probe", 1, true) // write in flight
            T.deepEqual(Machine.configReloaded(m), [])
            T.equal(m.writeSeq, 1)
            Machine.close(m)
            var settled = Machine.writeResult(m, 1, true)
            T.equal(settled.length, 0)
            T.equal(m.overrideLive, false)
            T.equal(m.restoreSeq, 0)
        })

        T.test("a config reload resumes a probe deferred behind a dying restore", function () {
            var m = suspended()
            Machine.close(m)
            Machine.open(m) // probe deferred behind restore read seq 2
            var actions = Machine.configReloaded(m)
            T.deepEqual(reads(actions), [{ op: "read", kind: "probe", seq: 3 }])
            // The superseded restore's late answer drops.
            T.equal(Machine.readResult(m, "restore", 2, false).length, 0)
        })

        T.test("destruction with the override live makes one best-effort restore", function () {
            var m = suspended()
            var actions = Machine.destroyed(m)
            T.deepEqual(writes(actions), [{ op: "write", value: "true", seq: 0 }])
            T.equal(m.overrideLive, false)
            // All pending bookkeeping is dropped with the object.
            T.equal(m.probeSeq, 0)
            T.equal(m.restoreSeq, 0)
            T.equal(m.writeSeq, 0)
        })

        T.test("destruction without a live override writes nothing", function () {
            var m = Machine.create()
            Machine.open(m) // probe still in flight — nothing was applied
            T.deepEqual(Machine.destroyed(m), [])
            var idle = Machine.create()
            T.deepEqual(Machine.destroyed(idle), [])
        })

        T.test("open and close are idempotent transitions", function () {
            var m = Machine.create()
            T.equal(Machine.open(m).length, 1)
            T.equal(Machine.open(m).length, 0) // already open: no second probe
            T.equal(Machine.close(m).length, 0)
            T.equal(Machine.close(m).length, 0) // already closed
        })

        Qt.exit(T.report("cursor policy"))
    }
}
