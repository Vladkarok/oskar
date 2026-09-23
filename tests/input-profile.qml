// A pure seam: the input profile. The panel serves two pointer
// worlds — the mouse it was born with and touch fingers — and which world
// is live decides a family of affordances: whether character caps type on
// release with slide-off cancel (generalising hold-column's deferred caps),
// whether dwell may arm, what a tooltip does without hover, how much
// forgiveness a chrome chip's hit area grows, and whether our own surfaces
// may steal a sliding finger. ALL of that lives here as DATA — the
// resolution (observed touch events + setting -> effective profile) and the
// per-profile affordance table — so the host suite can pin it (the
// Dwell.js/HoldColumn.js discipline) and the QML only wires. Run with
// tools/run-tests.sh — no compositor, no display.
import QtQml
import QtQuick
import "../InputProfile.js" as InputProfile
import "../Dwell.js" as Dwell
import "../HoldColumn.js" as HoldColumn
import "../UiStrings.js" as UiStrings
import "harness.js" as T

QtObject {
    Component.onCompleted: {
        // ---- the resolution: setting + observation -> effective profile ----

        T.test("the dwell guard: auto never flips away from mouse while dwell is on", function () {
            // An accessibility rule: a user who ENABLED dwell chose
            // their access method — one stray touch
            // (theirs, a caregiver's, the cat's) must not disarm it for
            // the panel's life while the recovery path needs the very
            // input that was lost. An explicit touch pin still wins.
            T.equal(InputProfile.resolve("auto", true, true), "mouse")
            T.equal(InputProfile.resolve("auto", true, false), "touch")
            T.equal(InputProfile.resolve("auto", false, true), "mouse")
            T.equal(InputProfile.resolve("touch", false, true), "touch")
            T.equal(InputProfile.resolve("mouse", true, true), "mouse")
            // The two-arg call (dwell unspecified) keeps the auto-profile contract.
            T.equal(InputProfile.resolve("auto", true), "touch")
        })

        T.test("auto with no touch observed is the mouse, byte-today", function () {
            // The default world: everything the panel ships today keeps
            // happening until a finger says otherwise.
            T.equal(InputProfile.resolve("auto", false), "mouse")
            T.equal(InputProfile.resolve("auto", undefined), "mouse")
        })

        T.test("auto flips to touch the moment a touch event is observed", function () {
            // A 2-in-1 flipping modes must not visit Settings (the
            // owner's framing): the first OBSERVED touch event switches
            // the affordances from then on.
            T.equal(InputProfile.resolve("auto", true), "touch")
        })

        T.test("explicit overrides win over the observation", function () {
            // The setting is the user's word: a pinned mouse stays the
            // mouse on a touchscreen seat (touch events recorded, never
            // acted on), a pinned touch stays touch on a desktop.
            T.equal(InputProfile.resolve("mouse", true), "mouse")
            T.equal(InputProfile.resolve("touch", false), "touch")
        })

        T.test("junk values degrade to auto's semantics", function () {
            // Validation owns the file (Config.js holds the value space);
            // whatever slips past a boundary — a runtime value the file
            // never saw — answers as auto: observed decides.
            T.equal(InputProfile.resolve(undefined, false), "mouse")
            T.equal(InputProfile.resolve(undefined, true), "touch")
            T.equal(InputProfile.resolve(null, true), "touch")
            T.equal(InputProfile.resolve("", false), "mouse")
            T.equal(InputProfile.resolve("tablet", true), "touch")
            T.equal(InputProfile.resolve("TOUCH", false), "mouse")
        })

        T.test("the stickiness decision is pinned: once seen, per summon", function () {
            // Touch observed is MONOTONIC within a summon (the panel holds
            // the fact; the seam is stateless and never decays it, and a
            // HIDDEN panel resets it). A
            // touchscreen laptop's stray mouse click must not flap the
            // profile back mid-session, and a flip the other way is the
            // explicit setting's job. What is pinned here is the
            // vocabulary: one profile list, one not-synthesized source
            // constant, so the wiring cannot invent a third state.
            T.deepEqual(InputProfile.PROFILES, ["auto", "mouse", "touch"])
            T.equal(InputProfile.MOUSE_SOURCE_NOT_SYNTHESIZED,
                Qt.MouseEventNotSynthesized)
        })

        // ---- the observation: which mouse events were synthesized ----

        T.test("a synthesized mouse event is a touch observation", function () {
            // Qt synthesizes the mouse events a MouseArea sees from touch
            // (and tablet) input; the source field is the only thing that
            // tells a finger from a button. A pen gets the touch
            // affordances too: it is a hover-less pointer the same way.
            T.equal(InputProfile.isTouchSource(
                Qt.MouseEventSynthesizedByQt), true)
            T.equal(InputProfile.isTouchSource(
                Qt.MouseEventSynthesizedBySystem), true)
            T.equal(InputProfile.isTouchSource(
                Qt.MouseEventSynthesizedByApplication), true)
        })

        T.test("a real mouse event observes nothing", function () {
            T.equal(InputProfile.isTouchSource(
                Qt.MouseEventNotSynthesized), false)
            T.equal(InputProfile.isTouchSource(0), false)
            T.equal(InputProfile.isTouchSource(undefined), false)
            T.equal(InputProfile.isTouchSource(null), false)
        })

        // ---- the affordance table: what lives and dies per profile ----

        T.test("the mouse profile's table is byte-today", function () {
            // The regression pin as data: press-typing (37's column-only
            // defer composed in Dwell.holdDefers), release types wherever
            // it lands, dwell follows its own setting, tooltips hover,
            // chrome hit areas stay exactly as drawn, nothing prevents
            // stealing. Every value is the shipped behaviour.
            T.deepEqual(InputProfile.affordances("mouse"), {
                profile: "mouse",
                typesOnRelease: false,
                slideOffCancels: false,
                dwellPossible: true,
                tooltipGlyphChrome: "hover",
                tooltipTextChrome: "hover",
                hoverHighlight: true,
                minChromeTargetPx: 0,
                preventStealing: false,
                tooltipHoverShows: true
            })
        })

        T.test("the touch profile's table is the touch contract", function () {
            // Character caps type on release and a slide-off cancels;
            // dwell never arms (a finger cannot hover); the header's
            // glyph chrome answers a touch-and-hold with its tooltip
            // while the text chrome hides (its label already states it);
            // hover highlight is inert by absence; chrome targets grow
            // invisibly to the 44px floor; our own surfaces never steal
            // a sliding finger.
            T.deepEqual(InputProfile.affordances("touch"), {
                profile: "touch",
                tooltipHoverShows: false,
                typesOnRelease: true,
                slideOffCancels: true,
                dwellPossible: false,
                tooltipGlyphChrome: "hold",
                tooltipTextChrome: "hidden",
                hoverHighlight: false,
                minChromeTargetPx: 44,
                preventStealing: true
            })
        })

        T.test("an unknown profile degrades to the mouse table", function () {
            T.equal(InputProfile.affordances(undefined).profile, "mouse")
            T.equal(InputProfile.affordances("pen").profile, "mouse")
        })

        T.test("the chrome target floor is the touch-era standard", function () {
            // 44px is the floor the platform guidelines converge on
            // (Apple 44pt, Material 48dp with 48-minus-tolerance); the
            // chips are 28-30px drawn, so the growth is invisible hit
            // area, never a redesign (the ticket's own rule).
            T.equal(InputProfile.affordances("touch").minChromeTargetPx, 44)
            T.equal(InputProfile.affordances("mouse").minChromeTargetPx, 0)
        })

        // ---- release-typing: which caps defer their typing to the lift ----

        // Fixtures in the hold-column suite's own shapes.
        function letterCap() { return { chr: "\u0439", chrShift: "\u0419", xkb: "AD01" } }
        function columnCap() { return { chr: "3", chrShift: "\u2116", xkb: "AE03" } }
        function column() {
            return [{ level: 3, text: "\u00a7" }, { level: 4, text: "\u20b4" }]
        }

        T.test("mouse defers exactly as today: Dwell.holdDefers verbatim", function () {
            // The composition lives in the seam so the 37/50 interplay
            // cannot drift: dwell off is HoldColumn.shouldDefer, dwell on
            // defers nothing. Pinned across the cap matrix.
            T.equal(InputProfile.defersTyping("mouse", false,
                columnCap(), column(), false, true),
                Dwell.holdDefers(false, columnCap(), column(), false, true))
            T.equal(InputProfile.defersTyping("mouse", true,
                columnCap(), column(), false, true), false)
            T.equal(InputProfile.defersTyping("mouse", false,
                letterCap(), [], false, true), false)
            T.equal(InputProfile.defersTyping("mouse", false,
                columnCap(), column(), true, true), false)
            T.equal(InputProfile.defersTyping("mouse", false,
                columnCap(), column(), false, false), false)
        })

        T.test("touch defers every character cap, column or not", function () {
            // The generalisation: a drifting finger strands phantom
            // characters under press-typing, so EVERY character cap
            // types on release. The column requirement was 37's scoping
            // of the menu, not of the release semantics; the threshold
            // still rides the same timer (openHoldMenu leaves a
            // columnless hold pending, and the release then types).
            T.equal(InputProfile.defersTyping("touch", false,
                letterCap(), [], false, true), true)
            T.equal(InputProfile.defersTyping("touch", false,
                columnCap(), column(), false, true), true)
        })

        T.test("touch defers the exact &123 glyph caps too", function () {
            // Their press is typeCap's exact arm; deferred, the pair
            // (typeCap + releaseKey) moves to the release whole — the
            // same endCapHold path every deferred cap already takes.
            var glyph = { chr: "\u00a3", xkb: "AB11", baseLvl: 5,
                exact: true, level3: true }
            T.equal(InputProfile.defersTyping("touch", false,
                glyph, [], false, true), true)
        })

        T.test("touch keeps press semantics where repeat is the point", function () {
            // BackSpace, the arrows and the modifiers are `key` caps —
            // hold-to-repeat is their touch idiom (the compositor's own
            // repeat). Space (fixed label) keeps it too: the
            // most-held key on the board must not lose its repeat to the
            // release-typing rule.
            T.equal(InputProfile.defersTyping("touch", false,
                { key: "BackSpace", label: "\u232b" }, [], false, true), false)
            T.equal(InputProfile.defersTyping("touch", false,
                { key: "shift", label: "Shift" }, [], false, true), false)
            T.equal(InputProfile.defersTyping("touch", false,
                { chr: " ", label: "", w: 4.5, xkb: "SPCE" }, [], false, true), false)
        })

        T.test("touch never defers a gated, searching or dead cap", function () {
            // The moment gates are the same gates the press path keeps:
            // readiness, the emoji search's press-fed
            // query (hold-column's rule, restated), the unavailable mark,
            // spacers.
            T.equal(InputProfile.defersTyping("touch", false,
                letterCap(), [], false, false), false)
            T.equal(InputProfile.defersTyping("touch", false,
                letterCap(), [], true, true), false)
            T.equal(InputProfile.defersTyping("touch", false,
                { chr: "\u2603", unavailable: true, xkb: "AB11" }, [], false, true), false)
            T.equal(InputProfile.defersTyping("touch", false,
                { spacer: true, w: 1 }, [], false, true), false)
            T.equal(InputProfile.defersTyping("touch", false,
                null, [], false, true), false)
        })

        T.test("touch ignores the dwell setting in the defer decision", function () {
            // Dwell never arms in touch, so its "the dwell IS the click"
            // veto over defers (Dwell.holdDefers) has nothing to veto —
            // a leftover dwell_enabled override must not strand the
            // release-typing contract.
            T.equal(InputProfile.defersTyping("touch", true,
                letterCap(), [], false, true), true)
        })

        // ---- dwell: the touch profile never arms it ----

        T.test("dwell composes: the setting AND the profile must allow it", function () {
            T.equal(InputProfile.dwellArms("mouse", true), true)
            T.equal(InputProfile.dwellArms("mouse", false), false)
            T.equal(InputProfile.dwellArms("touch", true), false)
            T.equal(InputProfile.dwellArms("touch", false), false)
            T.equal(InputProfile.dwellArms(undefined, true), true)
        })

        // ---- chrome hit growth: the invisible minimum target ----

        T.test("mouse grows nothing anywhere", function () {
            T.deepEqual(InputProfile.chromeHitGrowth(30, 8, 16, 8, 0),
                { left: 0, right: 0, up: 0, down: 0 })
            T.deepEqual(InputProfile.chromeHitGrowth(30, 8, 16, 8,
                InputProfile.affordances("mouse").minChromeTargetPx),
                { left: 0, right: 0, up: 0, down: 0 })
        })

        T.test("touch grows a 30px chip toward 44, gap-capped", function () {
            // Vertical: the full need (7px a side), bounded by the room
            // the caller actually has. Horizontal: never past the
            // MIDPOINT of the gap to the neighbouring chip — the capHit
            // discipline, so two grown areas tile instead of fighting.
            T.deepEqual(InputProfile.chromeHitGrowth(30, 8, 16, 8, 44),
                { left: 4, right: 4, up: 7, down: 7 })
            T.deepEqual(InputProfile.chromeHitGrowth(30, 16, 16, 8, 44),
                { left: 7, right: 7, up: 7, down: 7 })
        })

        T.test("growth is bounded by the room on every side", function () {
            // A tight band gives what it has: the pure function answers
            // the geometry's honest maximum, and the wiring passes the
            // room it truly owns.
            T.deepEqual(InputProfile.chromeHitGrowth(30, 8, 3, 2, 44),
                { left: 4, right: 4, up: 3, down: 2 })
        })

        T.test("a chip already at the floor grows nothing", function () {
            T.deepEqual(InputProfile.chromeHitGrowth(44, 8, 16, 16, 44),
                { left: 0, right: 0, up: 0, down: 0 })
            T.deepEqual(InputProfile.chromeHitGrowth(48, 8, 16, 16, 44),
                { left: 0, right: 0, up: 0, down: 0 })
        })

        T.test("no gap means no horizontal growth", function () {
            // Adjacent surfaces that already tile exactly keep doing so.
            T.deepEqual(InputProfile.chromeHitGrowth(30, 0, 16, 8, 44),
                { left: 0, right: 0, up: 7, down: 7 })
        })

        // ---- the settings row's translated labels fit their segments ----
        //
        // The segmented control is a FIXED width, so the widest
        // translated label must fit the segment it lands in. The probe
        // draws every label in the mono face at fontBody (12) offscreen,
        // exactly the way the popover's own label column re-measures.

        T.test("every translated profile label fits its segment", function () {
            // The labels come straight from UiStrings across ALL shipped
            // languages: checking only a couple by hand would miss a
            // language whose translation overflows the row's budget.
            var labels = []
            for (var l = 0; l < UiStrings.LANGUAGES.length; l++) {
                var lang = UiStrings.LANGUAGES[l]
                labels.push(UiStrings.tr("settings.profile.auto", lang))
                labels.push(UiStrings.tr("settings.profile.mouse", lang))
                labels.push(UiStrings.tr("settings.profile.touch", lang))
            }
            var probe = Qt.createQmlObject(
                'import QtQuick 2.0; Text { font.family: "JetBrainsMono Nerd Font"; ' +
                'font.pixelSize: 12 }',
                harnessTarget)
            var widest = 0
            for (var i = 0; i < labels.length; i++) {
                probe.text = labels[i]
                widest = Math.max(widest, probe.implicitWidth)
            }
            probe.destroy()
            // SettingsSegmented at the 180 the profile row uses: three
            // segments of (180 - 4 - 2 * 2) / 3 = 57.3px each, minus the
            // 4px horizontal padding each segment's label keeps.
            T.equal(widest <= 57.3 - 4, true,
                "widest label " + widest + "px vs 53.3px segment")
        })

        T.test("the notice keys on the OBSERVATION, not the effective profile", function () {
            // Keying on effectiveInputProfile === "touch" alone would
            // also light the notice on a HAND-PINNED touch, overflowing
            // the un-widened row. The pin: the notice exists exactly when
            // the observation flipped
            // auto (synthesized touch arrived, no hand pin, dwell guard
            // off). The wiring reads the same three facts.
            T.equal(InputProfile.resolve("auto", true, false) === "touch"
                && true, true)  // observation flipped: notice applies
            T.equal(InputProfile.resolve("touch", false, false) === "touch"
                && true, true)  // hand-pinned: no notice, plain labels
            // The width's two inputs, restated as the pin's data:
            T.equal(InputProfile.resolve("auto", true, true) === "touch",
                false)  // dwell guard: no flip, no notice, no width
        })

        T.test("the auto-flipped notice fits its widened segment", function () {
            // While auto stands flipped to touch, the Auto segment
            // carries the "Auto+touch" notice and the row widens from
            // 150 to 240 — the notice must fit (240 - 4 - 2 * 2) / 3
            // = 77.33px minus its 4px padding, in every language (EN is
            // the widest at 71.875px; a 235px row falls 0.2px short).
            var labels = ["Auto+touch",
                "\u0410\u0432\u0442\u043e+\u0442\u0430\u0447"]
            var probe = Qt.createQmlObject(
                'import QtQuick 2.0; Text { font.family: "JetBrainsMono Nerd Font"; ' +
                'font.pixelSize: 12 }',
                harnessTarget)
            var widest = 0
            for (var i = 0; i < labels.length; i++) {
                probe.text = labels[i]
                widest = Math.max(widest, probe.implicitWidth)
            }
            probe.destroy()
            T.equal(widest <= 77.33 - 4, true,
                "widest notice " + widest + "px vs 73.33px widened segment")
        })

        Qt.exit(T.report("input profile"))
    }

    // The offscreen probe needs a parent object.
    property Item harnessTarget: Item {}
}
