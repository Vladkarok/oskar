.pragma library

// The smallest thing that can fail a build. Qt's own QtTest wants a test
// binary and a display; these tests want neither, so the runner is a plain
// `qml` process and this is its scoreboard.
//
// Output goes through console.warn rather than console.log: Qt's default
// logging rules drop the qml.debug category, so console.log prints nothing
// when the tests run outside a shell that has set QT_LOGGING_RULES.

var passed = 0
var failures = []
var current = ""

function test(name, body) {
    current = name
    var before = failures.length
    try {
        body()
    } catch (error) {
        failures.push(name + ": threw " + error)
        return
    }
    if (failures.length === before) passed += 1
}

function fail(detail) {
    failures.push(current + ": " + detail)
}

function equal(actual, expected, detail) {
    if (actual !== expected) {
        // The optional third argument names WHAT drifted (the ticket-52
        // arity pin passes id/language); the two-arg call sites are
        // unchanged and stay terse.
        fail((detail ? detail + ": " : "")
            + "expected " + show(expected) + ", got " + show(actual))
    }
}

function deepEqual(actual, expected) {
    if (show(actual) !== show(expected)) {
        fail("expected " + show(expected) + ", got " + show(actual))
    }
}

function show(value) {
    return JSON.stringify(value)
}

/// Prints the tally and returns the process exit code, so a runner can
/// `Qt.exit(report(...))` and let the shell see the result.
function report(suite) {
    for (var i = 0; i < failures.length; i++) {
        console.warn("FAIL  " + failures[i])
    }
    console.warn(suite + ": " + passed + " passed, " + failures.length + " failed")
    return failures.length === 0 ? 0 : 1
}
