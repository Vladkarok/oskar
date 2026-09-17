// Which keyboard the panel reads its layout from, and which ones the language
// button moves. Run with tools/run-tests.sh — no compositor, no display.
//
// This suite exists because the same defect arrived three times and no test
// could see any of them: the logic lived in a jq program inside a shell string.
// The fixtures below are the owner's real device zoo, copied out of
// `hyprctl devices -j` on the machine where it last broke.
import QtQml
import "../LayoutDevices.js" as Devices
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        // The three keyboards the helper positively identifies through udev.
        var safeNames = [
            "at-translated-set-2-keyboard",
            "ite-tech.-inc.-ite-device(8176)-keyboard",
            "ite-tech.-inc.-ite-device(8295)-keyboard"
        ]

        // Twelve devices, of which three can type. Groups exactly as they were
        // found: the real keyboards on `us`, every pseudo-device stuck on `ua`
        // from some earlier switch that moved a set nobody advances since.
        function zoo(realGroup, mainName) {
            var devices = [
                { name: "video-bus", idx: 1 },
                { name: "ite-tech.-inc.-ite-device(8295)-keyboard", idx: realGroup },
                { name: "ite-tech.-inc.-ite-device(8176)-wireless-radio-control", idx: 1 },
                { name: "ite-tech.-inc.-ite-device(8176)-keyboard", idx: realGroup },
                { name: "ideapad-extra-buttons", idx: 1 },
                { name: "video-bus-1", idx: 1 },
                { name: "power-button", idx: 1 },
                { name: "power-button-1", idx: 1 },
                { name: "at-translated-set-2-keyboard", idx: realGroup },
                { name: "razer-razer-deathadder-v3-keyboard", idx: 1 },
                { name: "razer-razer-deathadder-v3", idx: 1 },
                { name: "hl-virtual-keyboard-oskar-daemon", idx: 0 }
            ]
            return devices.map(function (device) {
                return {
                    name: device.name,
                    main: device.name === mainName,
                    active_layout_index: device.idx,
                    layout: "us,ua"
                }
            })
        }

        T.test("the group is never read from a device the button does not move", function () {
            // Ticket 21, and the reason this file exists. The reading used to
            // come from every non-pseudo device, the switch from the helper's
            // identified three. `ideapad-extra-buttons` and the Razer's
            // keyboard interface sit on group 1 and nothing ever advances
            // them, so the panel reported Ukrainian, told the helper group 1,
            // and the physical keyboard produced English.
            var picked = Devices.select(zoo(0, ""), "", safeNames)
            T.equal(picked.reading.active_layout_index, 0)
            T.equal(Devices.activeLayout(picked.reading), "us")
            // Everything it reads from is something it moves.
            T.equal(picked.switchSet.indexOf(picked.reading.name) !== -1, true)
            T.equal(picked.switchSet.length, 3)
            T.equal(picked.switchSet.indexOf("razer-razer-deathadder-v3-keyboard"), -1)
            T.equal(picked.switchSet.indexOf("ideapad-extra-buttons"), -1)
        })

        T.test("a switch to the second group is read back as the second group", function () {
            var picked = Devices.select(zoo(1, ""), "", safeNames)
            T.equal(picked.reading.active_layout_index, 1)
            T.equal(Devices.activeLayout(picked.reading), "ua")
        })

        T.test("the seat's current keyboard wins, then the named one", function () {
            // `main` is the seat's active keyboard — where the next physical
            // key comes from — so it outranks everything.
            var withMain = zoo(0, "at-translated-set-2-keyboard")
            withMain[8].active_layout_index = 1
            var picked = Devices.select(withMain, "ite-tech.-inc.-ite-device(8295)-keyboard", safeNames)
            T.equal(picked.reading.name, "at-translated-set-2-keyboard")
            T.equal(picked.reading.active_layout_index, 1)

            // With no `main` inside the safe set, the device the last layout
            // event named decides.
            var named = Devices.select(zoo(0, "hl-virtual-keyboard-oskar-daemon"),
                "ite-tech.-inc.-ite-device(8176)-keyboard", safeNames)
            T.equal(named.reading.name, "ite-tech.-inc.-ite-device(8176)-keyboard")
        })

        T.test("the helper's own virtual keyboard never decides anything", function () {
            // It holds `main` right after the panel types, and it is on the
            // group the panel put it on — reading from it would be the panel
            // reading its own answer back and calling it evidence. In steady
            // state the anchor names a real keyboard, and that outranks it.
            var picked = Devices.select(zoo(1, "hl-virtual-keyboard-oskar-daemon"),
                "ite-tech.-inc.-ite-device(8176)-keyboard", safeNames)
            T.equal(picked.reading.name, "ite-tech.-inc.-ite-device(8176)-keyboard")
            T.equal(picked.reading.active_layout_index, 1)
            T.equal(picked.switchSet.indexOf("hl-virtual-keyboard-oskar-daemon"), -1)
        })

        T.test("after a restart the remembered group beats a majority of sleepers", function () {
            // The owner's 2026-09-12 desync, exactly as `hyprctl devices`
            // caught it live: the seat's flag on a mouse's keyboard
            // interface (never safe), no anchor (the shell just restarted),
            // the keyboard the user actually types on flipped to group 1 by
            // alt-shift while its two sleeping siblings never receive the
            // toggle and sit on 0. Consensus read 0 — English caps while he
            // typed Ukrainian. The panel's remembered group, persisted with
            // its state, is the honest tie-breaker; the helper's own device
            // cannot serve (its reported index is the layout slot, never the
            // group — measured live).
            var desync = zoo(0, "razer-razer-deathadder-v3-keyboard")
            desync[3].active_layout_index = 1
            var picked = Devices.select(desync, "", safeNames, 1)
            // Facts come from a safe consensus device; the GROUP is the
            // remembered one, and the caller derives the code from it.
            T.equal(picked.group, 1)
            T.equal(Devices.activeLayoutForGroup(picked.reading, picked.group), "ua")
            T.equal(picked.reading.name.indexOf("hl-virtual-keyboard"), -1)
            T.equal(picked.switchSet.length, 3)
            T.equal(picked.switchSet.indexOf("hl-virtual-keyboard-oskar-daemon"), -1)
        })

        T.test("the remembered group is ignored when live evidence exists", function () {
            // A unanimous safe set is consensus evidence, and a named/main
            // device outranks memory — the fallback is only for the
            // evidence-free restart window on a diverged seat.
            T.equal(Devices.select(zoo(0, ""), "", safeNames, 1).group, 0)
            var named = Devices.select(zoo(0, ""),
                "ite-tech.-inc.-ite-device(8176)-keyboard", safeNames, 1)
            T.equal(named.reading.name, "ite-tech.-inc.-ite-device(8176)-keyboard")
            T.equal(named.group, 0)
            // A non-integer or negative memory is not evidence at all.
            var junk = Devices.select(zoo(0, ""), "", safeNames, -1)
            T.equal(junk.group, 0)
            T.equal(junk.reading.name.indexOf("hl-virtual-keyboard"), -1)
        })

        T.test("with the helper's device absent the consensus still answers", function () {
            // Helper down (first start, or it lost its seat): the old
            // consensus tier is unchanged behind the fallback.
            var noVirtual = zoo(0, "").filter(function (device) {
                return device.name.indexOf("hl-virtual-keyboard") !== 0
            })
            var picked = Devices.select(noVirtual, "", safeNames)
            T.equal(picked.reading.active_layout_index, 0)
            T.equal(picked.reading.name.indexOf("hl-virtual-keyboard"), -1)
        })

        T.test("one stuck keyboard cannot drag the reading", function () {
            // The old tie-break was the highest index any of them reached, so
            // one keyboard left behind on group 1 spoke for all three. Two of
            // three on `us` means `us`.
            var split = zoo(0, "")
            split[3].active_layout_index = 1
            var picked = Devices.select(split, "", safeNames)
            T.equal(picked.reading.active_layout_index, 0)

            // And the other way: two on `ua` and one lagging reads `ua`. The
            // helper's virtual device is modelled as synced (the panel put
            // it there) — a majority that disagrees with its own last
            // write is not a state devices reach by themselves.
            var other = zoo(1, "")
            other[3].active_layout_index = 0
            other[11].active_layout_index = 1
            T.equal(Devices.select(other, "", safeNames).reading.active_layout_index, 1)
        })

        T.test("the typing keyboard is reported only from the seat's own flag", function () {
            // The anchor used to be fed from layout events, and every
            // switchxkblayout this panel issues emits one naming the device it
            // moved — so the anchor pointed at whatever the panel touched
            // last. It read its own echo and rearranged the seat around it.
            // `typing` answers only when the seat itself says a safe keyboard
            // produced the key.
            T.equal(Devices.select(zoo(0, "at-translated-set-2-keyboard"), "", safeNames).typing,
                "at-translated-set-2-keyboard")
            // The helper's own virtual keyboard holds the flag right after the
            // panel types. That is not evidence about the user's hands.
            T.equal(Devices.select(zoo(0, "hl-virtual-keyboard-oskar-daemon"), "", safeNames).typing, "")
            // Neither is a pseudo-device holding it.
            T.equal(Devices.select(zoo(0, "ideapad-extra-buttons"), "", safeNames).typing, "")
            // With no flag the caller's remembered anchor still decides the
            // reading, which is what makes "keep what we knew" work.
            var kept = Devices.select(zoo(0, ""), "ite-tech.-inc.-ite-device(8176)-keyboard", safeNames)
            T.equal(kept.reading.name, "ite-tech.-inc.-ite-device(8176)-keyboard")
            T.equal(kept.typing, "")
        })

        T.test("no positively identified keyboard means no answer at all", function () {
            // Before the helper's snapshot arrives there is nothing safe to
            // read. Guessing a group here is what sent `group 1` off a stuck
            // pseudo-device on every panel start.
            var picked = Devices.select(zoo(0, ""), "", [])
            T.equal(picked.reading, null)
            T.equal(picked.switchSet.length, 0)
            T.equal(Devices.activeLayout(picked.reading), "")
        })

        T.test("a compositor suffix on a duplicate name is still the same keyboard", function () {
            // Two identical keyboards plugged in make `name` and `name-2`;
            // the helper's snapshot only carries the base name.
            var devices = [
                { name: "at-translated-set-2-keyboard-2", main: true,
                  active_layout_index: 1, layout: "us,ua" }
            ]
            var picked = Devices.select(devices, "", safeNames)
            T.equal(picked.reading.name, "at-translated-set-2-keyboard-2")
            T.equal(picked.switchSet.length, 1)

            // But a different device that merely starts with the same text is
            // not the same keyboard.
            var lookalike = [
                { name: "at-translated-set-2-keyboard-lookalike", main: true,
                  active_layout_index: 1, layout: "us,ua" }
            ]
            T.equal(Devices.select(lookalike, "", safeNames).reading, null)
        })

        T.test("a device with its own layout list is not switched with the others", function () {
            // An absolute group index means something different in another
            // layout space, so the switch set is the reading device's list.
            var devices = zoo(0, "at-translated-set-2-keyboard")
            devices[1].layout = "us,de,ua"
            var picked = Devices.select(devices, "", safeNames)
            T.equal(picked.switchSet.length, 2)
            T.equal(picked.switchSet.indexOf("ite-tech.-inc.-ite-device(8295)-keyboard"), -1)
        })

        T.test("the active layout is the index into the device's own list", function () {
            // `us,us` with distinct variants repeats the code, and looking the
            // code up by name always found the first twin.
            T.equal(Devices.activeLayout(
                { layout: "us,us", active_layout_index: 1 }), "us")
            T.equal(Devices.activeLayout(
                { layout: "us,ua,it", active_layout_index: 2 }), "it")
            // An index past the list falls back rather than answering blank.
            T.equal(Devices.activeLayout(
                { layout: "us,ua", active_layout_index: 7 }), "us")
        })

        T.test("power buttons and video buses are not keyboards", function () {
            T.equal(Devices.isTyped("power-button"), false)
            T.equal(Devices.isTyped("power-button-1"), false)
            T.equal(Devices.isTyped("video-bus"), false)
            T.equal(Devices.isTyped("lid-switch"), false)
            T.equal(Devices.isTyped("sleep-button"), false)
            T.equal(Devices.isTyped("hl-virtual-keyboard-oskar-daemon"), false)
            T.equal(Devices.isTyped("some-oskar-thing"), false)
            T.equal(Devices.isTyped(""), false)
            T.equal(Devices.isTyped("at-translated-set-2-keyboard"), true)
            // A name that merely CONTAINS one of them is a real device: the
            // pseudo names are anchored at the start for that reason.
            T.equal(Devices.isTyped("keychron-power-button-keyboard"), true)
        })

        // Ticket 31 (audit 2026-09-13): the remembered group is only
        // honored while the CURRENT keymap can carry it. A session whose
        // layout list shrank (four→two, two→one) must fall back to the
        // consensus path instead of requesting a group the map does not
        // have — which the caps command would refuse and typing would be
        // gated on.
        T.test("layout count: non-empty entries of the device's own list", function () {
            T.equal(Devices.layoutCount({ layout: "us,ua" }), 2)
            T.equal(Devices.layoutCount({ layout: "us,ua,de,ru" }), 4)
            T.equal(Devices.layoutCount({ layout: "us" }), 1)
            // A trailing separator is not a layout.
            T.equal(Devices.layoutCount({ layout: "us," }), 1)
            T.equal(Devices.layoutCount({ layout: "us,," }), 1)
            T.equal(Devices.layoutCount({}), 0)
            T.equal(Devices.layoutCount(null), 0)
        })

        T.test("a remembered group past a two-layout map falls back (four→two)", function () {
            var devices = [
                { name: "k1", layout: "us,ua", active_layout_index: 0 },
                { name: "k2", layout: "us,ua", active_layout_index: 1 }
            ]
            var picked = Devices.select(devices, "", ["k1", "k2"], 3)
            // The set diverges, no main/named evidence: the remembered 3
            // cannot ride a 2-layout map, so the consensus fallback answers
            // — a tie, and the lowest wins.
            T.equal(picked.group, 0)
            T.equal(picked.reading === null, false)
        })

        T.test("a remembered group past a one-layout map falls back (two→one)", function () {
            // One device still reports the previous keymap's index — the
            // divergence that arms the remembered branch — while the list
            // has shrunk to one layout.
            var devices = [
                { name: "k1", layout: "us", active_layout_index: 0 },
                { name: "k2", layout: "us", active_layout_index: 1 }
            ]
            var picked = Devices.select(devices, "", ["k1", "k2"], 1)
            T.equal(picked.group, 0)
        })

        T.test("a remembered group inside the current map is still honored", function () {
            var devices = [
                { name: "k1", layout: "us,ua,de,ru", active_layout_index: 0 },
                { name: "k2", layout: "us,ua,de,ru", active_layout_index: 2 }
            ]
            var picked = Devices.select(devices, "", ["k1", "k2"], 2)
            T.equal(picked.group, 2)
        })

        Qt.exit(T.report("layout devices"))
    }
}
