// The paste chip's panel-local branch (the colour fields, the emoji
// search): which clipboard kinds it reads, and what a finished read
// inserts. Pure ClipboardPaste.js logic; the Process wiring stays in
// Panel.qml.
import QtQml
import "../ClipboardPaste.js" as ClipboardPaste
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        T.test("only plain text is read into a panel-local input", function () {
            T.equal(ClipboardPaste.localPasteAllowed("text"), true)
            // Content a password manager marked secret is pasted by the
            // chord only, never read into the panel.
            T.equal(ClipboardPaste.localPasteAllowed("hidden"), false)
            // An image (or any offer without text) has no text to give.
            T.equal(ClipboardPaste.localPasteAllowed("other"), false)
            T.equal(ClipboardPaste.localPasteAllowed("empty"), false)
            T.equal(ClipboardPaste.localPasteAllowed(undefined), false)
        })

        T.test("a finished local read inserts text or nothing, never a silent blank", function () {
            T.equal(ClipboardPaste.localReadText(0, "hello"), "hello")
            // The one trailing newline a copy carries is not pasted.
            T.equal(ClipboardPaste.localReadText(0, "hello\n"), "hello")
            T.equal(ClipboardPaste.localReadText(0, "a\nb"), "a\nb")
            // A secret that landed mid-read, a failed read, an empty one:
            // nothing to insert, which the caller shows as a refusal.
            T.equal(ClipboardPaste.localReadText(ClipboardPaste.READ_SECRET_EXIT, ""), null)
            T.equal(ClipboardPaste.localReadText(1, "partial"), null)
            T.equal(ClipboardPaste.localReadText(0, ""), null)
            T.equal(ClipboardPaste.localReadText(0, "\n"), null)
            T.equal(ClipboardPaste.localReadText(0, null), null)
            // Bytes that are not text (an image served anyway) are refused.
            T.equal(ClipboardPaste.localReadText(0, "\u0089PNG\u0000\r\n"), null)
        })

        T.test("every payload read asks wl-paste for text", function () {
            // Without --type, wl-paste serves an image-only offer's bytes.
            var scripts = { read: ClipboardPaste.READ_SCRIPT, count: ClipboardPaste.COUNT_SCRIPT }
            for (var name in scripts) {
                var reads = scripts[name].match(/wl-paste --no-newline[^|]*/g) || []
                T.equal(reads.length, 1, name + " has one payload read")
                for (var r = 0; r < reads.length; r++)
                    T.equal(/--type text\b/.test(reads[r]), true, name + ": " + reads[r])
            }
        })

        Qt.exit(T.report("local paste"))
    }
}
