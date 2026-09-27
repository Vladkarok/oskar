import QtQuick
import Quickshell.Io
import "Config.js" as ConfigFile

Item {
    id: root

    // The private saves' machinery, split out of Panel.qml (the
    // structural split's step three): the 700/600 dir makers with the
    // write that rides their exits, the one umask-077 temp+rename
    // writer with its queue and retry, and the per-path failure
    // notices. What stayed in the panel is everything the saves are
    // ABOUT: the paths and the maps (bound IN below, so a dir maker's
    // exit serializes the newest exactly as the monolith did), the
    // stand-off guards (configError/stateError — a malformed external
    // edit stops the write at the same guard line it always did; the
    // panel's own save entries keep their copy of the guard), and the
    // hint line's derivation (the panel reads `saveFailedPaths` OUT and
    // derives `saveFailedNotice` itself, one home for the hint table).
    //
    // The triggers: the panel's saveOverrides/saveState flip the dir
    // makers through makeConfigDir()/makeStateDir() — a Process already
    // running ignores the flip, the coalescing the monolith's own
    // `running = true` lines carried.

    // ---- IN from the panel ----
    //
    // The four paths, bound from the panel's env-derived properties.
    property string configDir: ""
    property string configPath: ""
    property string stateDir: ""
    property string statePath: ""
    // The stand-off guards, bound from the panel's error properties:
    // while one stands, the matching dir maker's exit writes nothing —
    // the bad file is never overwritten.
    property string configError: ""
    property string stateError: ""
    // The maps, bound live: the dir makers' exits serialize whatever
    // the panel holds at that moment, never a payload captured at
    // trigger time — the monolith's own timing.
    property var userOverrides: ({})
    property var geometryState: null

    // A config/state save that could not land (dir creation failed, or
    // the private write failed twice): the in-memory controls already
    // show the new value, so the only honest panel says so on the hint
    // line until a save lands — otherwise a failed save lies silently
    // until the next shell start eats the setting. Per PATH, not one
    // boolean: config and state are two channels — a landed state write
    // must not vouch for a config write that never ran. A path leaves the
    // list only when a write of that same path succeeds.
    property var saveFailedPaths: []
    function saveFailedMark(path) {
        var paths = root.saveFailedPaths.filter(function (p) {
            return p !== path
        })
        paths.push(path)
        root.saveFailedPaths = paths
    }
    function saveFailedLanded(path) {
        root.saveFailedPaths = root.saveFailedPaths.filter(function (p) {
            return p !== path
        })
    }

    // Private at creation, never re-moded after: a directory OSKar creates
    // is made 0700 in one step (no world-readable window, umask
    // notwithstanding), and one that already exists — the user's own, a
    // dotfile manager's symlink — is left exactly as it is. Every save goes
    // through one umask-077 temp+rename, so the file itself is 0600 by
    // construction.
    Process {
        id: configDirMaker
        command: ["bash", "-c",
            "[[ -d \"$1\" ]] || mkdir -p -m 700 -- \"$1\"", "oskar-config-dir",
            root.configDir]
        onExited: (exitCode, exitStatus) => {
            if (root.configError) return
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("[oskar] could not create", root.configDir, "- configuration not saved")
                root.saveFailedMark(root.configPath)
                return
            }
            writePrivateFile(root.configPath,
                ConfigFile.serializeOverrides(root.userOverrides))
        }
    }

    Process {
        id: stateDirMaker
        command: ["bash", "-c",
            "[[ -d \"$1\" ]] || mkdir -p -m 700 -- \"$1\"", "oskar-state-dir",
            root.stateDir]
        onExited: (exitCode, exitStatus) => {
            if (root.stateError) return
            if (exitCode !== 0 || exitStatus !== 0) {
                console.warn("[oskar] could not create", root.stateDir, "- state not saved")
                root.saveFailedMark(root.statePath)
                return
            }
            writePrivateFile(root.statePath,
                ConfigFile.serializeState(root.geometryState))
        }
    }

    // The panel's two save entries flip the dir makers through these;
    // the write rides the exit, so nothing else is wanted here.
    function makeConfigDir() {
        configDirMaker.running = true
    }

    function makeStateDir() {
        stateDirMaker.running = true
    }

    // One writer, one queue: a save arriving mid-write replaces its own
    // target's queued entry (newest wins per file) and the exit drains
    // the queue — overlapping config/state saves coalesce instead of
    // racing a Process restart.
    property var privateWriteQueue: []
    // The in-flight write (path, payload, and whether a failure already
    // requeued it once — otherwise a failed write is only logged, and
    // the newest config/state is dropped until the next save happens to
    // land).
    property var privateWriteInFlight: null
    Process {
        id: privateWriter
        command: []
        // The payload rides stdin, never argv: argv is visible to every
        // local user and capped per argument, where stdin is neither.
        stdinEnabled: true
        property string payload: ""
        onStarted: {
            write(payload)
            stdinEnabled = false
        }
        onExited: (exitCode, exitStatus) => {
            root.privateWriteFinished(exitCode === 0 && exitStatus === 0,
                "exit " + exitCode)
        }
    }

    // One write's verdict: landed, or failed (a non-zero exit, or a writer
    // that could not even start) — a failure retries once and then shows
    // the saveFailed hint.
    function privateWriteFinished(ok, why) {
        if (root.privateWriteInFlight && ok) {
            // This PATH's newest save landed — the controls' shown
            // state is on disk again (and only this path is vouched
            // for; the other channel's failure stands).
            root.saveFailedLanded(root.privateWriteInFlight.path)
        }
        if (!ok && root.privateWriteInFlight) {
            console.warn("[oskar] private write failed (" + why
                + ")" + (root.privateWriteInFlight.retried ? " — again" : ", retrying"))
            if (!root.privateWriteInFlight.retried) {
                // Retry ONLY when no newer save for this path is
                // already queued — otherwise the requeue drops the
                // newer entry and pushes the failed write's STALE
                // payload, letting older data win on disk.
                var hasNewer = false
                for (var q = 0; q < root.privateWriteQueue.length; q++)
                    if (root.privateWriteQueue[q].path
                            === root.privateWriteInFlight.path)
                        hasNewer = true
                if (!hasNewer) {
                    root.privateWriteQueue.push({
                        path: root.privateWriteInFlight.path,
                        payload: root.privateWriteInFlight.payload,
                        retried: true
                    })
                }
            } else {
                // The retry failed too: the newest config/state is
                // NOT on disk and every control already shows it —
                // a failed save must not lie. This path's notice
                // stands until this path's save lands.
                root.saveFailedMark(root.privateWriteInFlight.path)
            }
        }
        root.privateWriteInFlight = null
        // The queue's HEAD runs next (FIFO).
        if (root.privateWriteQueue.length > 0) {
            var next = root.privateWriteQueue[0]
            root.privateWriteQueue = root.privateWriteQueue.slice(1)
            runPrivateWrite(next.path, next.payload, next.retried === true)
        }
    }

    // The write lands on the file the path RESOLVES to: a config.json or
    // state.json that is a symlink (a dotfile manager's) is written
    // through, and the link survives — the temp file sits beside the
    // target and is renamed over the target, never over the link. A
    // target whose directory cannot be written fails the save (the
    // saveFailed hint) with nothing touched.
    function runPrivateWrite(path, payload, retried) {
        root.privateWriteInFlight = {
            path: path, payload: payload, retried: retried === true
        }
        privateWriter.payload = payload
        privateWriter.stdinEnabled = true
        privateWriter.command = ["bash", "-c",
            "umask 077; target=$(readlink -f -- \"$1\") || exit 5; "
            + "[[ -n \"$target\" && ! -d \"$target\" ]] || exit 5; "
            + "dir=$(dirname -- \"$target\"); "
            + "[[ -d \"$dir\" && -w \"$dir\" ]] || exit 5; "
            + "t=$(mktemp -p \"$dir\" \".$(basename -- \"$target\").XXXXXX\") || exit 5; "
            + "trap 'rm -f -- \"$t\"' EXIT; "
            + "cat > \"$t\" && chmod 600 -- \"$t\" && mv -fT -- \"$t\" \"$target\"",
            "oskar-private-write", path]
        privateWriter.running = true
        // A writer that cannot start reports no exit at all: it is a failed
        // write, said the same way.
        if (!privateWriter.running)
            Qt.callLater(root.privateWriteFinished, false, "could not start")
    }

    function writePrivateFile(path, payload) {
        if (privateWriter.running) {
            var queue = root.privateWriteQueue.filter(function (entry) {
                return entry.path !== path
            })
            queue.push({ path: path, payload: payload })
            root.privateWriteQueue = queue
            return
        }
        runPrivateWrite(path, payload, false)
    }
}
