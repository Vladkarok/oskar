// The docked relayout nudge's values and verdicts: read the user's
// general:gaps_out in any form Hyprland answers, move one number by one,
// put the exact original back. Run with tools/run-tests.sh — no
// compositor, no display.
import QtQml
import "../GapsNudge.js" as Nudge
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("the current css form nudges one number and restores the exact text", function () {
            var reply = '{"option":"general:gaps_out","css":"0 0 0 0","set":true}'
            T.deepEqual(Nudge.plan(reply), { original: "0 0 0 0", nudged: "1 0 0 0" })
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

        T.test("a full chain writes the nudge, waits, and writes the original back", function () {
            var step = Nudge.start('{"css":"3 6 9 12","set":true}')
            T.equal(step.action, "write")
            T.equal(step.value, "4 6 9 12")
            step = Nudge.written(step.state, true)
            T.equal(step.action, "wait")
            step = Nudge.restoreDue(step.state)
            T.equal(step.action, "write")
            T.equal(step.value, "3 6 9 12")
            step = Nudge.written(step.state, true)
            T.equal(step.action, "done")
            T.equal(step.log, undefined)
            T.equal(step.state.phase, "idle")
        })

        T.test("a refused nudge changed nothing and restores nothing", function () {
            var step = Nudge.start('{"css":"0 0 0 0"}')
            step = Nudge.written(step.state, false)
            T.equal(step.action, "done")
            T.equal(step.state.phase, "idle")
            T.equal(step.value, undefined)
        })

        T.test("a failed restore is retried once, then named as an error", function () {
            var step = Nudge.start('{"css":"2 2 2 2"}')
            step = Nudge.written(step.state, true)
            step = Nudge.restoreDue(step.state)
            step = Nudge.written(step.state, false)
            T.equal(step.action, "write", "one retry")
            T.equal(step.value, "2 2 2 2")
            var retried = Nudge.written(step.state, true)
            T.equal(retried.action, "done")
            T.equal(retried.log, undefined, "a landed retry is quiet")
            var stranded = Nudge.written(step.state, false)
            T.equal(stranded.action, "done")
            T.equal(stranded.log.level, "error")
            T.equal(stranded.log.text.indexOf('"3 2 2 2"') >= 0, true, stranded.log.text)
            T.equal(stranded.log.text.indexOf('"2 2 2 2"') >= 0, true, "names the original")
        })

        T.test("a write lands only on exit 0 and the compositor's own ok", function () {
            T.equal(Nudge.writeLanded(0, "ok\n"), true)
            T.equal(Nudge.writeLanded(0, "keyword can't work with non-legacy parsers. Use eval."),
                false)
            T.equal(Nudge.writeLanded(1, "ok"), false)
            T.equal(Nudge.writeLanded(0, ""), false)
        })

        T.test("a stray verdict or timer outside a chain does nothing", function () {
            T.equal(Nudge.written(Nudge.initial(), true).action, "done")
            T.equal(Nudge.restoreDue(Nudge.initial()).action, "done")
        })

        Qt.exit(T.report("gaps nudge"))
    }
}
