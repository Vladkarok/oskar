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
// The chord's final line is marked when the chord arms; its pop is the
// verdict — success only when that reply is a bare `ok`. A reply that
// pops an unmarked slot settles nothing; a reply arriving on an empty
// queue answers one of the few writes that bypass the choke point (the
// reconnect's hello/keyboards/mods 0), sent only when the queue is known
// empty. A dying connection cancels the wait and drops the whole queue:
// replies owed by a dead socket never come.
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
// carries the verdict. An empty queue at arming leaves the wait to the
// caller's guard timer (nothing sent can be waiting for an answer).
function chordArmed(state, done) {
    if (state.queue.length === 0)
        return { queue: state.queue, chordDone: done || null }
    var queue = state.queue.slice(0, state.queue.length - 1)
        .concat([{ chordFinal: true }])
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
// connection): the wait ends, the queue keeps draining.
function chordSettled(state) {
    return { queue: state.queue, chordDone: null }
}

// The connection died: no reply is coming for anything sent on it, and
// the reconnect's answers address only its own writes.
function connectionLost(state) {
    return initial()
}
