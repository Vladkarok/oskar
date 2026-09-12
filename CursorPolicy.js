.pragma library

// Cursor-hiding policy (spec-v1 §9): while the panel is open, Hyprland's
// `cursor:hide_on_key_press` is suspended and restored on close, because the
// keys the panel sends are real ones and the cursor vanished under the very
// finger aiming it.
//
// This module is that policy as a pure state machine. It owns the whole
// lifecycle — probe, override, restore — and never touches a process
// itself: every event returns a list of actions ({op: "read"|"write", ...})
// for the host (CursorPolicy.qml) to execute, and every asynchronous answer
// carries the generation (seq) that asked for it, so an answer can only ever
// act on the lifecycle that is still current.
//
// Why this exists — review finding R6: the previous wiring lived in
// Panel.qml as a free callback. Closing before the probe completed ran the
// restore first (nothing recorded yet, so a no-op) and the probe's callback
// landed afterwards, disabling hiding with the panel closed. Worse, the
// stale override survived: the next open probed the already-disabled value,
// recorded nothing, and had nothing to restore. One lifecycle owner that
// serializes probe, override and restore closes that class.
//
// Explicit outcomes the policy commits to:
//
// - Close before the probe answers: the answer is stale (its generation was
//   retired by close or a newer open) and cannot apply — no late override.
// - Probe failure (hyprctl missing, non-zero, unparseable): hands off; the
//   user's setting stays exactly as it was, and there is nothing to restore.
// - Originally disabled hiding: nothing to suspend, nothing to restore.
// - An unconfirmed write (watchdog timeout of a still-running process)
//   stays in flight until physical completion or destruction: writeSeq
//   is kept, so a queued restore cannot verify against the still-running
//   write. The restore obligation stands. A confirmed startup failure
//   is a real failure and releases the host's process slot.
// - Restore only an override this lifecycle measured and applied. Before the
//   undo write, one fresh read verifies the override is still what the
//   compositor holds: a config reload or an external change mid-lifecycle
//   may have moved the value, and this must not write over it — that would
//   be restoring a guess.
// - A config reload supersedes a live override (a reload re-applies the
//   config file and wipes running-session `eval` changes), so the override
//   is dropped and close restores nothing. A reload landing while a write
//   is in flight is recorded and reconciled after that write settles —
//   the write is not assumed to land after the reload. A reload landing
//   while a probe is in flight retires that sample and reissues.
// - A reopen mid-verify rides a confirmed still-live override (`false`)
//   or a failed verify (ownership is kept; re-probing a still-live
//   `false` would assume hiding was originally disabled). A true verify
//   re-establishes the suspension.
// - Panel destruction with the override live: one best-effort restore of the
//   recorded measurement (the host sends it detached, since tracked
//   processes die with the object). If the whole shell dies with the panel
//   open, nothing can run — a later config reload is the documented escape
//   hatch, because the override only ever changed the running session.
//
// Residuals, documented rather than pretended away: a direct external
// `hyprctl eval` disabling hiding mid-lifecycle is indistinguishable at
// verify time from our own override (both read false), so the restore
// undoes it; a write that actually lands after a racing reload may leave
// hiding disabled until the next reload (the recorded value is not
// restored, because the write may equally have applied before the reload
// wiped it); a still-running write that never exits leaves restore queued
// until destruction's best-effort write; a failed reopen verify that
// actually meant the override was gone leaves the panel open unsuspended
// until the next close restores the recorded value; a failed suspension
// write stands down honestly for that open — hiding was never disabled,
// and the next open re-probes; a failed undo write keeps the obligation
// and is retried at the next open+close, but if the panel is never
// reopened and the shell dies uncleanly, hiding stays disabled until a
// config reload, with the journal line as the only signal; a reload
// landing while the probe is in flight retires that sample and reissues
// the probe; and a destruction while the suspension write is still in
// flight races it, so the best-effort restore write cannot be ordered
// after the destruction's own detached send.

// A fresh model. `seq` is a monotonic generation counter bumped on every
// async operation issued; `probeSeq`/`restoreSeq`/`writeSeq` hold the
// generation of the one operation currently in flight of each kind (0 =
// none), which is what makes every late answer droppable. The host executes
// at most one read and one write at a time and never overlaps a read of one
// kind with a write — the deferral rules below are what keep that true.
function create() {
    return {
        seq: 0,
        opened: false,
        probeSeq: 0,
        restoreSeq: 0,
        writeSeq: 0,
        probeQueued: false,   // an open is waiting for the previous lifecycle to settle
        restoreQueued: false, // a close is waiting for the suspension write to land
        writeValue: "",       // the value of the write in flight ("false"=suspension, "true"=undo)
        overrideLive: false,  // our `false` is applied and believed current
        recorded: "",         // the measured pre-open value, kept for the undo
        reloadDuringWrite: false, // a reload landed while a write was in flight
        outcome: "idle"
    }
}

// `hyprctl getoption cursor:hide_on_key_press -j` reports {"bool": ...};
// older builds used "int". Anything else — including empty output from a
// failed run — is a failed read (null), never an answer.
function parseHideOption(text) {
    try {
        var parsed = JSON.parse(text)
        if (parsed.bool === true || parsed.int === 1) return true
        if (parsed.bool === false || parsed.int === 0) return false
    } catch (error) {
    }
    return null
}

function startProbe(m) {
    m.seq += 1
    m.probeSeq = m.seq
    m.outcome = "probing cursor hiding"
    return [{ op: "read", kind: "probe", seq: m.probeSeq }]
}

function startRestore(m) {
    m.seq += 1
    m.restoreSeq = m.seq
    m.outcome = "verifying before restore"
    return [{ op: "read", kind: "restore", seq: m.restoreSeq }]
}

// A deferred open starts its probe only once the operation it deferred
// behind has settled.
function resumeProbeIfQueued(m) {
    if (!m.probeQueued || !m.opened) return []
    m.probeQueued = false
    return startProbe(m)
}

function open(m) {
    if (m.opened) return []
    m.opened = true
    if (m.overrideLive && m.restoreSeq === 0 && m.writeValue !== "true") {
        // A closing lifecycle's suspension is still in effect (its restore
        // lost the race with this reopen, or never started): ride it rather
        // than probing our own `false` and mistaking it for the user's
        // setting. This lifecycle's close will restore it. An UNDO write in
        // flight is the exception — the override is being removed right now,
        // so defer and probe fresh once it settles.
        m.outcome = "open rode the still-live override"
        return []
    }
    if (m.restoreSeq !== 0 || m.writeSeq !== 0) {
        // The previous lifecycle is mid-handoff (a restore read, or a
        // suspension write with a queued restore). Probing now could read
        // our own override as the user's value; wait for the settle.
        m.probeQueued = true
        m.outcome = "open deferred behind the settling previous lifecycle"
        return []
    }
    return startProbe(m)
}

function close(m) {
    if (!m.opened) return []
    m.opened = false
    // Retiring the generation is the R6 fix: an in-flight or deferred probe
    // of this lifecycle can no longer apply, whatever it answers.
    m.probeSeq = 0
    m.probeQueued = false
    if (!m.overrideLive) {
        m.outcome = "closed; nothing was suspended"
        return []
    }
    if (m.writeSeq !== 0) {
        // The suspension write is still in flight; restoring before it
        // lands could verify the pre-write value and skip the undo, leaving
        // our `false` live after close. Settle first, then restore.
        m.restoreQueued = true
        m.outcome = "restore queued behind the suspension write"
        return []
    }
    return startRestore(m)
}

function readResult(m, kind, seq, enabled) {
    if (kind === "probe") {
        if (seq !== m.probeSeq) {
            m.outcome = "stale probe result dropped"
            return []
        }
        m.probeSeq = 0
        if (enabled !== true) {
            m.outcome = enabled === null
                ? "probe failed; cursor hiding left as the user set it"
                : "cursor hiding already off; nothing to suspend"
            return []
        }
        m.overrideLive = true
        m.recorded = "true"
        m.outcome = "cursor hiding suspended"
        // The write inherits the read's generation: the pair is one
        // lifecycle step, and a stale read can therefore never trigger a
        // live write.
        m.writeSeq = seq
        m.writeValue = "false"
        return [{ op: "write", value: "false", seq: m.writeSeq }]
    }

    // A restore read whose generation was retired (only a config reload
    // retires one) must not write.
    if (seq !== m.restoreSeq) {
        m.outcome = "stale restore result dropped"
        return resumeProbeIfQueued(m)
    }
    m.restoreSeq = 0
    if (m.opened) {
        m.probeQueued = false
        if (enabled === false) {
            // Confirmed still live: ride it rather than flapping the
            // compositor setting. This lifecycle's close will restore.
            m.outcome = "verify superseded by reopen; the override continues"
            return []
        }
        if (enabled === null) {
            // Unknown is not gone. Re-probing can read our still-live
            // false and assume hiding was originally disabled.
            m.outcome = "verify failed during reopen; the override obligation stands"
            return []
        }
        // The override is gone (true): re-establish.
        m.overrideLive = false
        m.recorded = ""
        m.outcome = "verify showed the override gone; re-establishing"
        return startProbe(m)
    }
    var actions = []
    var undo = m.recorded
    if (enabled === false) {
        // Our override is still what the compositor holds: undo exactly it.
        m.outcome = "verifying before restore settled; undo write going out"
    } else if (enabled === true) {
        // The value moved mid-lifecycle — a config reload or an external
        // change already put the user's own choice back. Not ours to undo.
        undo = ""
        m.overrideLive = false
        m.recorded = ""
        m.outcome = "restore skipped; the value no longer ours"
    } else {
        // The verify read failed. The recorded value was measured at
        // suspension time, so restoring it is not a guess — and skipping
        // would risk leaving hiding disabled after close.
        m.outcome = "restore read failed; restoring the recorded value"
    }
    if (undo !== "") {
        // The override stays `live` until the write CONFIRMS: a failed undo
        // write keeps the obligation (the next close verifies and retries,
        // a reload drops it, destruction still makes the best-effort write)
        // instead of forgetting hiding was left disabled.
        m.writeSeq = seq
        m.writeValue = undo
        actions.push({ op: "write", value: undo, seq: m.writeSeq })
    }
    return actions
}

function writeResult(m, seq, ok) {
    if (seq !== m.writeSeq) return []
    if (ok !== true && ok !== false) {
        // Still running: keep writeSeq so a queued restore cannot verify
        // concurrently, and so a later exit still matches this generation.
        m.outcome = m.writeValue === "false"
            ? "suspension write unconfirmed; restore obligation stands"
            : "restore write unconfirmed; the undo obligation stands"
        return []
    }
    m.writeSeq = 0
    var value = m.writeValue
    m.writeValue = ""
    if (m.reloadDuringWrite) {
        // The write may have applied before the reload wiped it, or after.
        // Either way the reload owns the configured value; do not restore
        // a recorded guess. Re-measure if the panel is still open.
        m.reloadDuringWrite = false
        m.restoreQueued = false
        m.overrideLive = false
        m.recorded = ""
        m.outcome = "write settled after a config reload; reconciling"
        if (m.opened) {
            m.probeQueued = false
            return startProbe(m)
        }
        return []
    }
    if (ok === false) {
        if (value === "false") {
            // The suspension write failed: hiding was never disabled, so
            // there is nothing to undo and nothing to restore later.
            m.overrideLive = false
            m.recorded = ""
            m.outcome = "suspension write failed; hiding left as the user set it"
        } else {
            // The undo write failed: the obligation stands — the next
            // open+close verifies and retries, a reload supersedes it, and
            // destruction still sends the best-effort restore.
            m.outcome = "restore write failed; the undo obligation stands"
        }
    } else if (value === "true") {
        // The undo landed: the override is gone.
        m.overrideLive = false
        m.recorded = ""
        m.outcome = "cursor hiding restored"
    }
    if (m.restoreQueued) {
        m.restoreQueued = false
        if (!m.opened) {
            // A failed suspension write left nothing to undo (the override
            // was already dropped), so skip the pointless verify.
            if (!m.overrideLive) {
                m.outcome = "queued restore dropped; nothing was suspended"
                return []
            }
            return startRestore(m)
        }
        // Reopened before the write landed: this lifecycle either rode the
        // suspension write or deferred behind an undo write — a probe it
        // deferred must resume now, or the panel would sit open with the
        // suspension unestablished and nothing pending.
    }
    return resumeProbeIfQueued(m)
}

function configReloaded(m) {
    if (m.writeSeq !== 0) {
        // The write may already have applied, or it may land after this
        // reload. Record the race and reconcile when the write settles.
        m.reloadDuringWrite = true
        m.outcome = "config reload during a write; will reconcile after it settles"
        return []
    }
    if (m.restoreSeq !== 0) {
        // The reload already answered the restore question; a late verify
        // result must not write over the config's own value.
        m.restoreSeq = 0
    }
    if (m.probeSeq !== 0) {
        // A pre-reload sample is obsolete: the reload may have changed the
        // configured value, and applying it would restore a guess on close.
        m.probeSeq = 0
    }
    var superseded = m.overrideLive
    m.overrideLive = false
    m.recorded = ""
    m.outcome = superseded ? "override superseded by config reload"
                          : "config reload; no override in place"
    if (m.opened && m.probeSeq === 0 && !m.probeQueued) {
        // Spec-v1 §9 holds for the whole open, not just until the first
        // reload: the reload put the config's own value back, so re-measure.
        // If the config itself now says false, the probe honestly answers
        // "nothing to suspend"; otherwise the suspension is re-established.
        return startProbe(m)
    }
    return resumeProbeIfQueued(m)
}

function destroyed(m) {
    var value = m.overrideLive ? m.recorded : ""
    m.opened = false
    m.probeSeq = 0
    m.restoreSeq = 0
    m.writeSeq = 0
    m.writeValue = ""
    m.probeQueued = false
    m.restoreQueued = false
    m.reloadDuringWrite = false
    m.overrideLive = false
    m.recorded = ""
    m.outcome = value !== ""
        ? "destroyed with the override live; best-effort restore"
        : "destroyed with nothing applied"
    // seq 0 marks this write untracked: the host sends it detached, since a
    // tracked process could not outlive the destruction that asked for it.
    return value !== "" ? [{ op: "write", value: value, seq: 0 }] : []
}
