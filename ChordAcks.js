.pragma library

// Correlating the helper's replies with the commands they answer, so a
// dispatched paste chord waits for the acknowledgement of ITS OWN final
// line — and succeeds only when the WHOLE chord was acknowledged.
//
// The helper serves each connection strictly in order and answers every
// command with exactly one line — `ok`, an `err …`, a caps fact, a
// `configured` generation. So the panel keeps a QUEUE: every command sent
// (through the one send choke point) occupies a slot, and every line the
// helper sends back pops the oldest, whatever it says. Both verdicts
// spend the slot.
//
// `chordStart` marks where the chord's region begins (the queue's length
// at dispatch entry), and every err popped inside the region poisons the
// verdict (round eight: a chord whose Insert presses ERRed on a keymap
// without that key still reported success because its LAST line's ok was
// all anyone looked at — usage recorded, the picker closed, nothing
// delivered). Pre-chord traffic is not the chord's business and does not
// count; an interleaved command after dispatch lands in the region and
// its err poisons — conservative, never falsely successful.
//
// The chord's final line is marked when the chord arms — and arming
// first strips every earlier marker, because a marker left by a timed-out
// or aborted chord is stale by definition and a late reply popping it
// would settle whatever chord waited NEXT. A reply arriving on an empty
// queue answers nothing queued (every command on the connection goes
// through the one choke point, hello and the reconnect writes included).
// A dying connection cancels the wait and drops the whole queue: replies
// owed by a dead socket never come.
//
// One chord waits at a time — the clipboard transaction serializes them.

function initial() {
    return { queue: [], chordDone: null, chordFrom: 0, chordError: false }
}

// One command went out and will be answered. Called only after a
// successful write; every kind of command queues, because every kind is
// answered.
function sent(state, line) {
    var text = String(line || "")
    if (text === "") return state
    return {
        queue: state.queue.concat([{ chordFinal: false }]),
        chordDone: state.chordDone,
        chordFrom: state.chordFrom,
        chordError: state.chordError
    }
}

// The chord's region begins here: everything already in the queue is
// pre-chord traffic, everything queued from now until the verdict is the
// chord's business. Called at dispatch entry, before the first line.
function chordStart(state) {
    return {
        queue: state.queue,
        chordDone: state.chordDone,
        chordFrom: state.queue.length,
        chordError: false
    }
}

// Arm the waiting chord: the NEWEST slot — the final line just sent —
// carries the verdict, and every OTHER marker dies first. A marker left
// by a timed-out or aborted chord is stale by definition (one chord waits
// at a time), and a late reply popping it would settle whatever chord
// waited NEXT. An empty queue at arming leaves the wait to the caller's
// guard timer.
function chordArmed(state, done) {
    var queue = state.queue.map(function () { return { chordFinal: false } })
    if (queue.length > 0)
        queue[queue.length - 1] = { chordFinal: true }
    return {
        queue: queue,
        chordDone: done || null,
        chordFrom: state.chordFrom,
        chordError: state.chordError
    }
}

// One reply line arrived. `ok` says the popped command succeeded; any
// other reply — an err, a fact, whatever — says it did not get the one
// answer success means. Inside the chord's region a non-ok poisons the
// verdict. `done` is the armed chord's callback when the popped slot was
// its final line, with `success` true only when that reply is `ok` AND
// nothing in the region failed.
function replyReceived(state, ok) {
    if (state.queue.length === 0)
        return { state: state, done: null }
    var queue = state.queue.slice(1)
    var popped = state.queue[0]
    var chordFrom = state.chordFrom
    var chordError = state.chordError
    if (chordFrom > 0) {
        chordFrom -= 1
    } else if (ok !== true) {
        chordError = true
    }
    if (!popped.chordFinal)
        return {
            state: { queue: queue, chordDone: state.chordDone,
                chordFrom: chordFrom, chordError: chordError },
            done: null
        }
    return {
        state: { queue: queue, chordDone: null,
            chordFrom: chordFrom, chordError: chordError },
        done: state.chordDone,
        success: ok === true && chordError === false
    }
}

// The verdict arrived by another path (the guard timer, a dying
// connection, a cancellation): the wait ends, the region ends with it,
// and the queue keeps draining on its own.
function chordSettled(state) {
    return {
        queue: state.queue.map(function () { return { chordFinal: false } }),
        chordDone: null,
        chordFrom: 0,
        chordError: false
    }
}

// The connection died: no reply is coming for anything sent on it, and
// the reconnect's answers address only its own writes.
function connectionLost(state) {
    return initial()
}
