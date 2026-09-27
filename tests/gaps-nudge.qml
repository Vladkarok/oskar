// The docked relayout nudge's values and verdicts: read the user's
// general:gaps_out in any form Hyprland answers, move one number by one,
// judge every write by reading the value back, put the exact original
// back. Run with tools/run-tests.sh — no compositor, no display.
import QtQml
import "../GapsNudge.js" as Nudge
import "harness.js" as T

QtObject {
    function css(value) { return '{"option":"general:gaps_out","css":"' + value + '","set":true}' }

    Component.onCompleted: {
        T.test("the current css form nudges one number and restores the exact text", function () {
            T.deepEqual(Nudge.plan(css("0 0 0 0")), { original: "0 0 0 0", nudged: "1 0 0 0" })
            T.deepEqual(Nudge.plan('{"css":"10 20 30 40"}'),
                { original: "10 20 30 40", nudged: "11 20 30 40" })
            T.deepEqual(Nudge.plan('{"css":"5"}'), { original: "5", nudged: "6" })
            T.deepEqual(Nudge.plan('{"custom":"8 12"}'), { original: "8 12", nudged: "9 12" })
        })

        T.test("the older int form still works", function () {
            T.deepEqual(Nudge.plan('{"option":"general:gaps_out","int":10,"set":true}'),
                { original: "10", nudged: "11" })
            T.deepEqual(Nudge.plan('{"int":0}'), { original: "0", nudged: "1" })
        })

        T.test("an answer the code does not understand writes nothing", function () {
            var unknown = ["", "not json", "{}", '{"set":true}', '{"css":"1 2 3 4 5"}',
                '{"css":"1px 2px"}', '{"css":""}', '{"int":1.5}', '{"css":5}', "null", "[]"]
            for (var i = 0; i < unknown.length; i++) {
                T.equal(Nudge.plan(unknown[i]), null, unknown[i])
                var step = Nudge.start(unknown[i])
                T.equal(step.action, "done", unknown[i])
                T.equal(step.value, undefined, "no value to write")
                T.equal(step.log.level, "warn")
            }
        })

        T.test("a full chain: nudge, read back, wait, restore, read back", function () {
            var step = Nudge.start(css("3 6 9 12"))
            T.equal(step.action, "write")
            T.equal(step.value, "4 6 9 12")
            step = Nudge.written(step.state)
            T.equal(step.action, "read")
            step = Nudge.readBack(step.state, css("4 6 9 12"))
            T.equal(step.action, "wait")
            step = Nudge.restoreDue(step.state)
            T.equal(step.action, "write")
            T.equal(step.value, "3 6 9 12")
            step = Nudge.written(step.state)
            T.equal(step.action, "read")
            step = Nudge.readBack(step.state, css("3 6 9 12"))
            T.equal(step.action, "done")
            T.equal(step.log, undefined)
            T.equal(step.state.phase, "idle")
        })

        T.test("a nudge that landed whatever hyprctl answered is still restored", function () {
            // The verdict is the read-back, never the write's reply: the
            // write is followed by a read in every case.
            var step = Nudge.written(Nudge.start(css("0 0 0 0")).state)
            T.equal(step.action, "read")
            step = Nudge.readBack(step.state, css("1 0 0 0"))
            T.equal(step.action, "wait", "the value moved, so it goes back")
            // An unreadable read-back is not proof nothing changed.
            var blind = Nudge.readBack(Nudge.written(Nudge.start(css("0 0 0 0")).state).state, "")
            T.equal(blind.action, "wait")
        })

        T.test("a nudge that changed nothing restores nothing", function () {
            var step = Nudge.written(Nudge.start(css("0 0 0 0")).state)
            step = Nudge.readBack(step.state, css("0 0 0 0"))
            T.equal(step.action, "done")
            T.equal(step.value, undefined)
            T.equal(step.log.level, "log")
        })

        T.test("a restore that does not read back is retried once, then named as an error", function () {
            var step = Nudge.start(css("2 2 2 2"))
            step = Nudge.readBack(Nudge.written(step.state).state, css("3 2 2 2"))
            step = Nudge.written(Nudge.restoreDue(step.state).state)
            step = Nudge.readBack(step.state, css("3 2 2 2"))
            T.equal(step.action, "write", "one retry")
            T.equal(step.value, "2 2 2 2")
            var check = Nudge.written(step.state)
            var retried = Nudge.readBack(check.state, css("2 2 2 2"))
            T.equal(retried.action, "done")
            T.equal(retried.log, undefined, "a landed retry is quiet")
            var stranded = Nudge.readBack(check.state, css("3 2 2 2"))
            T.equal(stranded.action, "done")
            T.equal(stranded.log.level, "error")
            T.equal(stranded.log.text.indexOf('"3 2 2 2"') >= 0, true, stranded.log.text)
            T.equal(stranded.log.text.indexOf('"2 2 2 2"') >= 0, true, "names the original")
        })

        T.test("a stray verdict or timer outside a chain does nothing", function () {
            T.equal(Nudge.written(Nudge.initial()).action, "done")
            T.equal(Nudge.readBack(Nudge.initial(), css("0 0 0 0")).action, "done")
            T.equal(Nudge.restoreDue(Nudge.initial()).action, "done")
        })

        Qt.exit(T.report("gaps nudge"))
    }
}
