.pragma library

// Correlating the helper's replies with the commands they answer, so a
// dispatched paste chord can wait for the acknowledgement of ITS OWN
// final line.
//
// The helper serves each connection strictly in order and answers every
// command with exactly one line — `ok`, an `err …`, a caps fact, a
// `configured` generation. So the panel keeps a QUEUE: every command sent
// (through the one send choke point) occupies a slot, and every line the
// helper sends back pops the oldest, whatever it says. Both verdicts
// spend the slot (round four's blocker: an err'd plain command used to
// sit in a bare counter forever, and every later chord "failed" its guard
// timeout while the pastes themselves worked).
//
// The chord's final line is marked when the chord arms — and arming first
// strips every earlier marker, because a marker left by a timed-out or
// aborted chord is stale by definition and a late reply popping it would
// settle whatever chord waited NEXT. A reply arriving on an empty queue
// answers nothing queued (every command on the connection goes through
// the one choke point, hello and the reconnect writes included). A dying
// connection cancels the wait and drops the whole queue: replies owed by
// a dead socket never come.
//
// One chord waits at a time — the clipboard transaction serializes them.

function initial() {
    return { queue: [], chordDone: null }
}

// One command went out and will be answered. Called only after a
// successful write; every kind of command queues, because every kind is
// answered.
function sent(state, line) {
    var text = String(line || "")
    if (text === "") return state
    return {
        queue: state.queue.concat([{ chordFinal: false }]),
        chordDone: state.chordDone
    }
}

// Arm the waiting chord: the NEWEST slot — the final line just sent —
// carries the verdict, and every OTHER marker dies first. A marker left
// by a timed-out or aborted chord is stale by definition (one chord waits
// at a time), and a late reply popping it would settle whatever chord
// waited NEXT — the reviewer reproduced exactly that. An empty queue at
// arming leaves the wait to the caller's guard timer.
function chordArmed(state, done) {
    var queue = state.queue.map(function () { return { chordFinal: false } })
    if (queue.length > 0)
        queue[queue.length - 1] = { chordFinal: true }
    return { queue: queue, chordDone: done || null }
}

// One reply line arrived. `ok` says the popped command succeeded; any
// other reply — an err, a fact, whatever — says it did not get the one
// answer success means. `done` is the armed chord's callback when the
// popped slot was its final line, with `success` as the verdict.
function replyReceived(state, ok) {
    if (state.queue.length === 0)
        return { state: state, done: null }
    var queue = state.queue.slice(1)
    var popped = state.queue[0]
    if (!popped.chordFinal)
        return { state: { queue: queue, chordDone: state.chordDone }, done: null }
    return { state: { queue: queue, chordDone: null },
        done: state.chordDone, success: ok === true }
}

// The verdict arrived by another path (the guard timer, a dying
// connection): the wait ends, the queue keeps draining — and the marker
// dies with the wait. A late reply to the timed-out chord pops an unmarked
// slot and settles nothing; it must not reach whatever chord waits next.
function chordSettled(state) {
    return {
        queue: state.queue.map(function () { return { chordFinal: false } }),
        chordDone: null
    }
}

// The connection died: no reply is coming for anything sent on it, and
// the reconnect's answers address only its own writes.
function connectionLost(state) {
    return initial()
}
