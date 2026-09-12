#!/usr/bin/env python3
"""The control-socket integration suite — seam 1 of the two in the spec.

Every assertion in here crosses a real boundary: a protocol line goes into
the real helper over the real socket, and what comes back is either the
helper's reply, the compositor's opinion of the virtual keyboard, or the
helper's own log. Nothing mocks anything, which is why this needs a nested
Hyprland session and cannot join the host-runnable suites.

Adding a coverage: write another `@test` below. The order matters — the
tests share one helper process and each one starts where the last left off.
"""

import json
import os
import re
import signal
import subprocess
import sys
import time

from harness import (
    Clipboard,
    ElectronTarget,
    Failure,
    Helper,
    KeymapObserver,
    TypingTarget,
    focus_toward,
    published_keymap_is_live,
    run,
    share_published_keymap,
    test,
    window_addresses,
)

# The helper's stuck-key cap, injected by tools/smoke-daemon.sh so the suite
# does not have to sleep through the real fifteen seconds. Same variable the
# helper reads, so the two cannot drift apart.
HOLD_CAP = int(os.environ.get("OMARCHY_OSK_HOLD_CAP_MS", "15000")) / 1000.0

# Evdev codes, which is what the helper names in its log. AD01 is the Q
# position and LFSH the left Shift.
AD01 = 16
LFSH = 42

# Two layouts, caps-toggle, starting on the second one. The nested session's
# own config matches, so the compositor and the helper agree on the world.
CONFIGURE = "configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t1"
CONFIGURE_GROUP0 = "configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t0"

# A different model, so the same layouts still take the full compile path
# instead of short-circuiting.
CONFIGURE_SWAPPED = "configure\tevdev\tpc104\tus,ua\t\tgrp:caps_toggle\t\t1"

# Three layouts, so a cycle has a third group to reach and wrapping has
# somewhere to wrap from (ticket 10: the chooser popup is v2, but cycling
# through three groups has to be proven before the panel goes public).
THREE_GROUP = "configure\tevdev\tpc105\tus,ua,de\t\tgrp:caps_toggle\t\t0"
# Byte-identical keymap, different group: the path a `group <n>` mirrors
# takes when the panel re-sends its configure after a compositor switch.
THREE_GROUP_ON_DE = "configure\tevdev\tpc105\tus,ua,de\t\tgrp:caps_toggle\t\t2"

# `shift:both_capslock_cancel` alongside `grp:caps_toggle` is what lands
# <LFSH> in the Lock modifier map, and reading the modifier map instead of
# asking xkb is what made held Shift produce lowercase letters (a730c99).
#
# This was the owner's option string until 2026-09-03, when it was reverted to
# `compose:caps,grp:alt_shift_toggle` — `grp:caps_toggle` turned out to break
# layout switching for fcitx5 clients. The fixture stays exactly as it is: it
# is the regression guard for a730c99, and its value is that it is *not* the
# session the panel ships into. Do not "update" it to match the owner.
CONFIGURE_CAPSLOCK_CANCEL = (
    "configure\tevdev\tpc105\tus,ua\t\tshift:both_capslock_cancel,grp:caps_toggle\t\t0"
)


@test("startup inventory reports a positively identified physical keyboard")
def startup_keyboard_inventory(helper, keyboard):
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    reply = client.send("keyboards")
    if not reply.startswith("keyboards\t"):
        raise Failure(f"expected a keyboard inventory, got {reply!r}")
    names = [name for name in reply.split("\t")[1:] if name]
    if not names:
        raise Failure("the test machine has physical keyboards but inventory was empty")
    poisoned = ("hl-virtual-keyboard", "power-button", "video-bus", "omarchy-osk")
    if any(name.startswith(poisoned) for name in names):
        raise Failure(f"inventory included a pseudo keyboard: {names!r}")
    client.close()


@test("a three-group keymap cycles through every group and wraps")
def three_group_cycling(helper, keyboard):
    helper.expect_log("listening on")
    # First test on a fresh helper, deliberately: the only compiles in the
    # log are the startup default and the three-group keymap, so the count
    # taken at the end proves cycling recompiled nothing (spec-v1 §3.3: group
    # switching is never a recompile).
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(THREE_GROUP)
    keyboard.expect_group(0)
    # Both protocol paths the panel drives, in the order a cycle moves
    # through them: a byte-identical configure carrying the next group
    # (what follows every compositor switch), then the direct `group <n>`.
    # The same keymap keeps the same generation: only an install can move
    # it (decisions \u00a723).
    assert client.configure(THREE_GROUP_ON_DE) == gen
    keyboard.expect_group(2)
    client.expect("group 0", "ok")
    keyboard.expect_group(0)
    client.expect("group 1", "ok")
    keyboard.expect_group(1)
    client.expect("group 2", "ok")
    keyboard.expect_group(2)
    client.expect("group 0", "ok")
    keyboard.expect_group(0)  # and wraps back to the first
    # Two compiles: the startup default and the three-group keymap. A third
    # means a group switch recompiled, which is the churn storm in miniature.
    helper.expect_compiles(2)
    client.close()


@test("supplied keycap facts match what a focused native client receives")
def facts_match_typed_output(helper, keyboard):
    # Ticket 04's seam comparison: the facts the helper supplies for a group
    # and the characters a real client actually reads, side by side, for
    # both groups of the owner's setup. The caps the panel will draw are
    # only honest if THIS holds.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(CONFIGURE)
    keyboard.expect_group(1)
    client.expect("group 0", "ok")
    keyboard.expect_group(0)

    facts = client.caps(0, ["AD01", "AE01"])
    if facts["gen"] != gen or facts["group"] != 0:
        raise Failure(f"caps reply for the wrong world: {facts}")
    if facts["by_position"]["AD01"] != [{"text": "q"}, {"text": "Q"}]:
        raise Failure(f"group 0 AD01 facts: {facts['by_position']['AD01']}")
    # Ticket 20 keeps the position's original levels 1-4 and adds the
    # reserved-symbol block at levels 5-8 (decisions §33). This early seam
    # still checks the whole facts reply so it cannot silently regress to the
    # pre-block two-level shape before the dedicated chord test runs below.
    if facts["by_position"]["AE01"] != [
        {"text": "1"}, {"text": "!"}, {"text": "1"}, {"text": "!"},
        {"text": "!"}, {"text": "1"}, {"text": "@"}, {"text": "2"},
    ]:
        raise Failure(f"group 0 AE01 facts: {facts['by_position']['AE01']}")

    # One terminal for the whole comparison — the group switch happens under
    # it, which is exactly the product story: same client, different group,
    # different characters, facts agreeing throughout.
    target = TypingTarget()
    try:
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n")
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\n")

        # Group 1 is the Ukrainian group: the facts must switch alphabet
        # with the group, and typing must agree with what they say.
        client.expect("group 1", "ok")
        keyboard.expect_group(1)
        facts = client.caps(1, ["AD01"])
        if facts["gen"] != gen or facts["group"] != 1:
            raise Failure(f"caps reply for the wrong world: {facts}")
        # ua's AD01 is four-level: the AltGr levels carry the Serbian ј/Ј.
        # The facts answer every level the keymap defines, not just the two
        # the main page draws — and the client must receive each of them.
        if facts["by_position"]["AD01"] != [
            {"text": "й"}, {"text": "Й"}, {"text": "ј"}, {"text": "Ј"}
        ]:
            raise Failure(f"group 1 AD01 facts: {facts['by_position']['AD01']}")

        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nй\n")
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nй\nЙ\n")
        client.expect("down RALT", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up RALT", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nй\nЙ\nј\n")
        client.expect("down RALT", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up RALT", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nй\nЙ\nј\nЈ\n")
    finally:
        target.close()
    client.expect("group 0", "ok")
    keyboard.expect_group(0)
    client.close()


@test("the device group follows configure and group, around every tap")
def group_follows_protocol(helper, keyboard):
    helper.expect_log("listening on")
    # active_layout_index is the one layout fact about the helper readable
    # without a client, so every typing operation asserts it first: what is
    # proven is the group the tap actually ran under, not a final state.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(CONFIGURE)
    keyboard.expect_group(1)
    client.expect("tap AD01", "ok")
    client.expect("group 0", "ok")
    keyboard.expect_group(0)
    client.expect("tap AD01", "ok")
    # Byte-identical to the first: the helper must short-circuit rather than
    # compile again. The identical generation in the reply is the first half
    # of the proof — the compile count at the end is the rest.
    assert client.configure(CONFIGURE) == gen
    keyboard.expect_group(1)
    client.expect("tap AD01", "ok")
    client.close()


@test("a release sent from inside the not-ready window lifts the key immediately")
def release_crosses_the_unready_window(helper, keyboard):
    # The socket boundary under the round-2 blocker. On the panel side the
    # unready window is self-inflicted: a compositor event re-sends the
    # configure and the panel refuses to treat itself as ready until
    # `configured` is read back. A same-keymap configure keeps the helper's
    # holds alive across that window, so a key held when it opens must be
    # liftable during it — a release whose `up` the panel swallowed would
    # repeat the key until this suite's own hold cap fired, and a locked
    # Shift's lift would never go out at all. The helper sees exactly:
    # configure (reply unread), then `up`, with no readiness wait between.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE)
    client.expect("down AD01", "ok")
    # The claim is observable before the window: a tap may not lift it.
    client.expect("tap AD01", "err key held")
    # The unready window: the re-configure goes out, its reply unread, and
    # the release is written into that window — the shape of the panel's
    # transport sending the reducer's `up` while inputReady is false.
    client.write_unread(CONFIGURE)
    client.write_unread("up AD01")
    # Replies come back in order, and both arrive: the configure answered
    # and the release honoured, with nothing held waiting for readiness.
    if not client.read_reply().startswith("configured\t"):
        raise Failure("the same-keymap reconfigure did not answer configured")
    if client.read_reply() != "ok":
        raise Failure("the release sent inside the unready window was not honoured")
    # The release was immediate, not the cap's: the claim is already gone.
    client.expect("tap AD01", "ok")
    # And the stuck-key log — the signature of a release that never arrived —
    # is silent for this code.
    helper.expect_no_log(f"releasing stuck key {AD01}")
    client.close()


@test("a client dying mid-chord does not take the helper with it")
def survives_mid_chord_disconnect(helper, keyboard):
    # The keys it left pressed are its connection's problem: the helper
    # releases them and zeroes the mask on disconnect. That release has no
    # client-observable trace, so survival is what is asserted here.
    dying = helper.connect()
    dying.expect("down LCTL", "ok")
    dying.close()

    fresh = helper.connect()
    fresh.expect("hello 5", "hello 5")
    fresh.expect("tap AD01", "ok")
    fresh.close()


@test("a claim belongs to the connection that made it")
def claims_are_owned(helper, keyboard):
    # The compositor exposes no per-device modifier state to read back
    # (active_layout_index follows the asserted mask, not the keys pressed),
    # so claims are asserted through the helper's own rules. LCTL carries no
    # lock actions, so the taps below stay inert.
    a = helper.connect()
    b = helper.connect()

    a.expect("down LCTL", "ok")
    a.expect("down LCTL", "ok")            # duplicate: one claim, not two
    b.expect("up LCTL", "err not holding")  # B cannot end A's claim
    a.expect("tap LCTL", "err key held")    # a tap may not lift it either
    b.expect("down LCTL", "ok")             # one press, two claims
    a.expect("up LCTL", "ok")               # B's claim keeps the key pressed
    a.expect("tap LCTL", "err key held")
    b.expect("up LCTL", "ok")               # last claim: the release goes out
    a.expect("tap LCTL", "ok")              # nothing claimed: a tap works

    # The keymap-swap regression: a configure drains the claims but not the
    # connections' own lists, so A re-pressing after the swap must re-claim.
    # Under the earlier bookkeeping the press went out unclaimed and B could
    # end it.
    a.configure(CONFIGURE_SWAPPED)
    a.expect("down LCTL", "ok")
    b.expect("up LCTL", "err not holding")
    a.expect("tap LCTL", "err key held")
    a.expect("up LCTL", "ok")
    a.expect("tap LCTL", "ok")

    a.close()
    b.close()


@test("a held modifier reaches a focused client as a chord")
def modifiers_reach_the_client(helper, keyboard):
    # The gap that let ticket 03 ship broken: every other assertion in this
    # file is about a key going out, and a key going out is exactly what did
    # work — bare taps typed while every chord arrived modifierless, because
    # a wlroots compositor takes a virtual keyboard's modifier state from the
    # `modifiers` request and not from watching key events. Only a client
    # reading characters can tell the two apart.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    # us,ua is still installed from the claims test; group 0 is `us`, and a
    # `group` command is not a compile, so the churn count below is untouched.
    client.expect("group 0", "ok")
    keyboard.expect_group(0)

    target = TypingTarget()
    try:
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n")

        # The chord the panel emits for a latched Shift (ModifierReducer's
        # `press`): the modifier is held around the one key it applies to.
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\n")

        # And the latch really cleared: the same position after the release
        # is lower case again.
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nq\n")

        # Modifiers stack (spec-v1 §5): two held at once must both be in the
        # mask, not the last one to arrive. A terminal shows Alt as the ESC
        # prefix and Shift as the capital, so one line carries both. Super is
        # the fourth modifier and produces no character anywhere, so it stays
        # with the reducer suite and the hand check.
        client.expect("down LALT", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up LALT", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nq\n\x1bQ\n")

        # A locked modifier survives a language switch (spec-v1 §5): the group
        # rides on the same request as the mask, so a `group` command that
        # sent a zero would silently drop what is held. Ukrainian's shifted
        # AD01 is a capital Й, which is only reachable with both the switch
        # and the modifier intact.
        client.expect("down LFSH", "ok")
        client.expect("group 1", "ok")
        keyboard.expect_group(1)
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("group 0", "ok")
        keyboard.expect_group(0)
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\nq\n\x1bQ\nЙ\n")
    finally:
        target.close()
        client.close()


@test("the compositor still sees the configured layouts")
def layout_reaches_the_compositor(helper, keyboard):
    keyboard.expect_layout("us,ua")


@test("a hello in another protocol version is refused, not greeted")
def protocol_mismatch_is_refused(helper, keyboard):
    # The hello gate (decisions §23, ticket 04): version 4 moved reply
    # shapes on both sides in one change, so a mixed pairing must be named
    # before any configure is sent — the exact refusal the panel's
    # "service needs updating" state keys off. No configure rides with this
    # test: the gate exists so a mismatched panel never reaches one, and a
    # compile here would put the churn count below in a lie.
    client = helper.connect()
    client.expect("hello 3", "err protocol 5 required, helper needs reinstall")
    # The refusal names the version, not the connection: the same socket
    # speaking the current version is greeted normally.
    client.expect("hello 5", "hello 5")
    client.close()


@test("keymap churn stayed at four compiles: default, three-group, configured, swap")
def churn_held(helper, keyboard):
    # The default compiled at startup, the three-group cycling keymap, the
    # us,ua one, and the swapped model in the claims test. A fifth means the
    # byte-identical configure recompiled or a group switch did, which is
    # the churn storm in miniature.
    helper.expect_compiles(4)
    # And the helper's own rate limiter never had to save us from one.
    helper.expect_no_log("refusing excessive keymap reconfiguration")


@test("keycap facts carry the acknowledged keymap generation")
def facts_carry_generation(helper, keyboard):
    # The correlation the panel's readiness rests on: a reply names the
    # install it came from, a same-keymap reconfigure keeps that install's
    # number, a changed keymap moves it, and a group past the keymap's own
    # count is refused rather than silently wrapped to another group.
    #
    # This test needs two real uploads of its own (a same-keymap configure
    # and a changed one), and the four compiles the tests above performed
    # land inside the helper's ten-second churn-guard window when the
    # session is quick. Wait the guard out instead of raising the cap: the
    # cap is the thing that keeps a compile loop from freezing a desktop.
    time.sleep(11)
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(THREE_GROUP)
    if client.caps(0, ["AD01"])["gen"] != gen:
        raise Failure("caps reply did not carry the acknowledged generation")
    assert client.configure(THREE_GROUP_ON_DE) == gen
    # A changed keymap bumps the generation; the new facts answer under it.
    gen_next = client.configure(CONFIGURE)
    assert gen_next != gen
    if client.caps(1, ["AD01"])["gen"] != gen_next:
        raise Failure("caps reply did not carry the new generation")
    client.expect("caps 9 AD01", "err bad group")
    bare = client.caps(0, ["QQ77"])
    if bare["by_position"]["QQ77"] != []:
        raise Failure("an unknown position must answer bare, not with facts")
    client.close()


# A variant the owner's setup could carry: the second copy of `us` is
# `euro`, whose AltGr level puts the euro sign on 5. Same layout code for
# both groups — the case where guessing a group from the code is wrong.
CONFIGURE_VARIANT = "configure\tevdev\tpc105\tus,us\t,euro\t\t\t0"


@test("a repeated layout with distinct variants answers per-variant facts")
def variant_facts(helper, keyboard):
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(CONFIGURE_VARIANT)
    keyboard.expect_group(0)
    plain = client.caps(0, ["AE05"])["by_position"]["AE05"]
    euro = client.caps(1, ["AE05"])["by_position"]["AE05"]
    # AE05 now also hosts reserved levels 5-8. This test owns the original
    # per-variant levels; the dedicated reserved-block test owns the tail.
    if plain[:2] != [{"text": "5"}, {"text": "%"}]:
        raise Failure(f"group 0 AE05 facts: {plain}")
    if euro[:4] != [{"text": "5"}, {"text": "%"}, {"text": "\u20ac"}, {"none": ""}]:
        raise Failure(f"group 1 AE05 facts: {euro}")
    if client.caps(1, ["AE05"])["gen"] != gen:
        raise Failure("caps reply did not carry the acknowledged generation")
    # Facts for a repeated layout with distinct variants are only honest if
    # the focused client actually receives them: group 0 types a plain 5,
    # group 1's AltGr level types the euro the facts named.
    target = TypingTarget()
    try:
        client.expect("tap AE05", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("5\n")
        client.expect("group 1", "ok")
        keyboard.expect_group(1)
        client.expect("down RALT", "ok")
        client.expect("tap AE05", "ok")
        client.expect("up RALT", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("5\n\u20ac\n")
    finally:
        target.close()
    client.close()


@test("a held Shift capitalises under options that put Shift in the Lock modmap")
def shift_capitalises_under_capslock_cancel(helper, keyboard):
    # The gap that let the modifier fix ship still broken. Every case above
    # runs on `grp:caps_toggle` alone, and on that keymap the modifier map
    # says a held Shift means Shift. The owner's session adds
    # `shift:both_capslock_cancel`, which puts Caps_Lock on the Shift keys'
    # second level; with CAPS already out of Lock the compiled keymap reads
    # `modifier_map Lock { <LFSH> }`, and a mask taken from that union told
    # the compositor Shift+Lock. Shift+Lock on an ALPHABETIC key is level 1,
    # so letters came out lowercase while the TWO_LEVEL number row, which
    # ignores Lock, shifted correctly. Only a client reading both a letter
    # and a digit can see that split.
    #
    # Last in the file on purpose: it is the only case that needs a keymap
    # nothing else uses, and compiling one here rather than earlier keeps the
    # churn count above a statement about the paths that matter.
    #
    # The helper refuses a fifth keymap upload inside ten seconds, which is
    # the churn guard doing its job rather than a fault — the compiles the
    # tests above performed all land inside that window when the session is
    # quick. Wait it out instead of raising the cap: the cap is the thing
    # that keeps a compile loop from freezing a desktop.
    time.sleep(11)

    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE_CAPSLOCK_CANCEL)
    keyboard.expect_group(0)

    target = TypingTarget()
    try:
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("Q!\n")
    finally:
        target.close()
        client.close()


@test("a non-modifier held past the cap is released by the helper and logged")
def cap_releases_a_stuck_key(helper, keyboard):
    # The wedged-panel case (spec-v1 §6). Nothing arrives on the socket after
    # the `down`, which is exactly the shape a panel that is alive but stuck
    # has — so the release cannot come from the panel and cannot come from a
    # heartbeat, because there is none.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.expect("down AD01", "ok")
    # `tap` on a held code is refused, which is how the claim is observable
    # from out here without reading the helper's internals.
    client.expect("tap AD01", "err key held")
    time.sleep(HOLD_CAP + 1.0)
    helper.expect_log(f"releasing stuck key {AD01}")
    # And the claim really went with it: the same position taps again.
    client.expect("tap AD01", "ok")
    client.close()


@test("a modifier held past the cap is left alone and still modifies")
def cap_exempts_modifiers(helper, keyboard):
    # A locked Shift is deliberately held for minutes (spec-v1 §5), so the cap
    # must not touch a modifier code. "The lock indicator still matches
    # reality" is a panel-side statement, but the fact underneath it is
    # visible here: after twice the cap the modifier is still claimed, and a
    # client still reads a capital.
    client = helper.connect()
    client.expect("hello 5", "hello 5")

    target = TypingTarget()
    try:
        # Unshifted first, so a later capital means the modifier and not a
        # terminal that was never listening.
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n")

        client.expect("down LFSH", "ok")
        time.sleep(HOLD_CAP * 2 + 1.0)
        helper.expect_no_log(f"releasing stuck key {LFSH}")
        client.expect("tap LFSH", "err key held")  # the claim survived
        client.expect("tap AD01", "ok")            # and so did the mask
        # Shift comes off before the flush: a terminal reads Shift+Return as
        # the kitty protocol's CSI 13;2u rather than a newline, so `cat` would
        # sit on the line and the assertion would read an empty file.
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\nQ\n")
    finally:
        target.close()
        client.close()


@test("a client dying mid-hold releases the non-modifier it was holding")
def disconnect_releases_a_hold(helper, keyboard):
    # Layer one of the protection, and the common case: the per-connection
    # claim rules already lift everything a connection holds when its socket
    # closes, well before the cap would.
    dying = helper.connect()
    dying.expect("hello 5", "hello 5")
    dying.expect("down AD01", "ok")
    dying.close()
    # The release happens on the dying connection's own thread when its read
    # returns EOF. Well under the cap, and the point of the assertion below is
    # that the cap is not what did it.
    time.sleep(0.5)

    fresh = helper.connect()
    fresh.expect("hello 5", "hello 5")
    # Free immediately, not fifteen seconds later: the disconnect did it.
    fresh.expect("tap AD01", "ok")
    fresh.close()


def _set_repeat(delay, rate):
    """Change the compositor's repeat settings the way a user would.

    Edit the config and reload — which is the whole point of the test, since
    the claim is that the panel follows the user's settings with nothing
    rebuilt and no code changed. `hyprctl keyword` is no use here: the Lua
    parser refuses it ("keyword can't work with non-legacy parsers") on
    stdout with a zero exit status, and `hyprctl eval` updates the value
    without pushing new `repeat_info` to anyone.
    """
    path = os.environ.get("OSK_NEST_CONFIG")
    if not path:
        raise Failure("OSK_NEST_CONFIG is unset; run under tools/nested-session.sh")
    text = re.sub(r"\n *repeat_(delay|rate) = \d+,", "", open(path).read())
    text = text.replace(
        'kb_layout = "us,ua",',
        f'kb_layout = "us,ua",\n    repeat_delay = {delay},\n    repeat_rate = {rate},',
    )
    with open(path, "w") as handle:
        handle.write(text)
    subprocess.run(["hyprctl", "reload"], capture_output=True, text=True)
    out = subprocess.run(
        ["hyprctl", "getoption", "input:repeat_rate"], capture_output=True, text=True
    ).stdout
    if f"int: {rate}" not in out:
        raise Failure(f"compositor did not take input:repeat_rate = {rate}: {out!r}")


def _repeats_while_held(client, target, seconds):
    """How many characters a held position produced at the focused client."""
    baseline = target.text()
    client.expect("down AD01", "ok")
    time.sleep(seconds)
    client.expect("up AD01", "ok")
    # `cat` is line buffered, so the whole burst arrives with the newline —
    # and the wait is for the text to *change*, since it already ended with
    # one from the burst before.
    client.expect("tap RTRN", "ok")
    for _ in range(50):
        time.sleep(0.1)
        text = target.text()
        if text != baseline and text.endswith("\n"):
            break
    return target.text().count("q") - baseline.count("q")


@test("a held key repeats, at the compositor's rate rather than a constant")
def repeat_belongs_to_the_compositor(helper, keyboard):
    # The point of sending `down`/`up` instead of `tap`, and the reason the
    # panel has no repeat timer: everything between the two is the
    # compositor's, at the delay and rate the user configured. Asserted by
    # changing those settings and nothing else — no rebuild, no restart, no
    # code change — and requiring the observed count to follow.
    #
    # Last in the file: it is the only test that writes to the compositor's
    # config, so whatever that provokes cannot disturb the compile counts
    # above.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    keyboard.expect_group(0)

    held = 1.2
    try:
        # A 300 ms delay leaves 0.9 s of repeating, so the expected counts are
        # about 1 + 0.9 * rate. Generous bands rather than exact numbers: the
        # point is that the count tracks the setting, and a VM under load
        # drops repeats without that being a defect. Nothing in between could
        # produce both numbers from one constant.
        for rate, low, high in ((8, 4, 13), (30, 18, 45)):
            _set_repeat(300, rate)
            # Key repeat in Wayland is the *client's* timer: the compositor
            # sends `repeat_info` and the client runs it, which is about as
            # far from a panel-side timer as the design gets. A client already
            # running has been seen keeping its old values, so each rate gets
            # a client that saw the new ones on its keyboard enter.
            target = TypingTarget()
            try:
                typed = _repeats_while_held(client, target, held)
            finally:
                target.close()
            if not low <= typed <= high:
                raise Failure(
                    f"at repeat_rate {rate} a {held}s hold typed {typed}, "
                    f"expected between {low} and {high}"
                )
    finally:
        _set_repeat(600, 25)  # Hyprland's defaults, for anything after this
        client.close()


@test("a configure the helper refuses never drains a held key")
def refused_configure_never_drains(helper, keyboard):
    # The round-6 blocker's never-drained ordering, at the socket. A failed
    # configure (a kb_file that cannot compile) is answered by install_config
    # BEFORE it would drain anything, so the connection's holds and the mask
    # they imply survive intact — the fact the panel's failure settle counts
    # on when it lifts the lock it had and zeroes the mask. The
    # drain-before-failure ordering (an upload failure) is not reachable from
    # outside the compositor and is covered by the reducer seam instead.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    # A configure whose kb_file cannot be read fails to compile, and
    # install_config refuses BEFORE it would drain anything — the
    # deterministic never-drained ordering.
    client.expect("down LFSH", "ok")
    client.expect("configure\tevdev\tpc105\tus\t\t\t/nonexistent-keymap\t0",
                  "err cannot configure keymap")
    client.expect("tap LFSH", "err key held")
    # And the mask still carries the hold: a tapped letter lands capital.
    # The hold comes off before the Return tap — a held Shift makes the
    # terminal encode Return as the kitty CSI string, which never flushes
    # the canonical line the assertion reads.
    target = TypingTarget()
    try:
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("Q\n")
    finally:
        target.close()
        client.close()
    # The refusal-before-release ordering, helper-side: locked Shift → held
    # key → refused configure → release. (Release-before-refusal lives in the
    # reducer test, where the settle is the panel's to make.) The refusal
    # never drains, so the lock and its mask survive the release too — the
    # facts the panel's failure settle (up + mods 0) reconciles. Fresh
    # connection: the helper released the old one's holds at its close, which
    # is exactly the world the ordering re-establishes.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.expect("down LFSH", "ok")
    client.expect("down AD01", "ok")
    client.expect("configure\tevdev\tpc105\tus\t\t\t/nonexistent-keymap\t0",
                  "err cannot configure keymap")
    client.expect("up AD01", "ok")
    # And the mask the hold implies still shifts: a tapped letter under the
    # surviving lock answers through its claim, which is the fact the
    # panel's failure settle (up + mods 0) reconciles. The client-visible
    # half — the letter arriving capital — is part 1's receiver.
    client.expect("tap LFSH", "err key held")
    client.expect("tap AD01", "ok")
    client.expect("up LFSH", "ok")
    client.close()


@test("supplied keycap facts match what an XWayland client receives")
def facts_match_xwayland_output(helper, keyboard):
    # The other half of the seam comparison: the XWayland path, which is
    # what no per-keystroke helper process ever reached (decisions \u00a71).
    # x11cat is a real X11 client — GTK mapped with GDK_BACKEND=x11, real
    # WM_CLASS, real core key events; the nested compositor starts
    # XWayland for it. Last in the file: it configures one more keymap, so
    # everything above asserts on its own compile counts.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(CONFIGURE)
    keyboard.expect_group(1)
    facts = client.caps(1, ["AD01"])
    if facts["gen"] != gen or facts["group"] != 1:
        raise Failure(f"caps reply for the wrong world: {facts}")
    if facts["by_position"]["AD01"] != [
        {"text": "й"}, {"text": "Й"}, {"text": "ј"}, {"text": "Ј"}
    ]:
        raise Failure(f"group 1 AD01 facts: {facts['by_position']['AD01']}")

    target = TypingTarget(cls="x11cat")
    try:
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("й\n")
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("й\nЙ\n")
        client.expect("down RALT", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up RALT", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("й\nЙ\nј\n")
        client.expect("down RALT", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AD01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up RALT", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("й\nЙ\nј\nЈ\n")
    finally:
        target.close()
    client.close()


@test("reserved symbols type the same characters in every group")
def reserved_symbols_are_layout_independent(helper, keyboard):
    # Ticket 18, moved by ticket 20. The helper adds a block of symbols no
    # configured layout carries to every keymap it installs. The claim is that
    # they are not a layout's business: the same cap produces the same
    # character in `us` and in `ua`.
    #
    # Since decisions §33 the block rides on levels five to eight of the digit
    # row rather than on free keycodes of its own — Chromium's Ozone/Wayland
    # DomCode table drops those, so they typed here and nowhere the owner
    # works. `<LVL5>` opens the levels; Shift and `<LVL3>` choose among them.
    #
    # Nothing here installs a fixture keymap. The configure is the ordinary
    # one every other test uses, so what is asserted is what ships.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    gen = client.configure(CONFIGURE)
    keyboard.expect_group(1)

    # Discovery goes through the facts the panel already requests — the block
    # needs no protocol of its own. AE01 is the first host; the helper puts the
    # first two symbol/digit pairs from the direct page on its levels 5-8.
    facts = client.caps(1, ["AE01"])
    if facts["gen"] != gen:
        raise Failure(f"caps reply for the wrong generation: {facts}")
    levels = facts["by_position"].get("AE01")
    if not isinstance(levels, list) or len(levels) != 8:
        raise Failure(f"AE01 does not carry the reserved block: {levels}")
    block = levels[4:]
    if block != [{"text": "!"}, {"text": "1"},
                 {"text": "@"}, {"text": "2"}]:
        raise Failure(f"AE01 levels 5-8 are not the block: {block}")
    # And what the layout itself put on levels 1-4 is still there. This is
    # ticket 20's other half: the block is an addition, never an edit.
    below = levels[:4]
    if below[0] != {"text": "1"} or below[1] != {"text": "!"}:
        raise Failure(f"AE01 lost its own levels 1-2: {below}")

    target = TypingTarget()
    try:
        # Levels 1 and 2 first, because they are what must not have moved.
        client.expect("tap AE01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n")
        client.expect("down LFSH", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n")

        # Then the block, one chord per level. <LVL5> is ISO_Level5_Shift in
        # every compiled keymap, as <LVL3> is ISO_Level3_Shift — the block
        # reserves no modifier of its own.
        client.expect("down LVL5", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LVL5", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n!\n")
        client.expect("down LVL5", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up LVL5", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n!\n1\n")
        client.expect("down LVL5", "ok")
        client.expect("down LVL3", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LVL3", "ok")
        client.expect("up LVL5", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n!\n1\n@\n")
        client.expect("down LVL5", "ok")
        client.expect("down LVL3", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up LVL3", "ok")
        client.expect("up LVL5", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n!\n1\n@\n2\n")

        # The whole point: group 0 is the other alphabet's neighbour — `us`
        # here, where `ua` was — and the same four characters come out. A
        # group move installs no keymap, so this also shows the block
        # survives one.
        before = helper.compiles()
        client.configure("configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t0")
        keyboard.expect_group(0)
        helper.expect_compiles(before)
        client.expect("down LVL5", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LVL5", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n!\n1\n@\n2\n!\n")

        # No `us` group at all: the direct punctuation remains the same
        # because it comes from the reserved block rather than a temporary
        # group switch. This is ticket 19's formerly dishonest `@` case.
        client.configure("configure\tevdev\tpc105\tua,ru\t\tgrp:caps_toggle\t\t1")
        keyboard.expect_group(1)
        no_us = client.caps(1, ["AE01"])["by_position"].get("AE01")
        if not isinstance(no_us, list) or no_us[4:] != block:
            raise Failure(f"reserved punctuation changed without us: {no_us}")
        client.expect("down LVL5", "ok")
        client.expect("down LVL3", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LVL3", "ok")
        client.expect("up LVL5", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("1\n!\n!\n1\n@\n2\n!\n@\n")
    finally:
        target.close()
    client.close()
    # Left on the group the tests after this one expect.
    restore = helper.connect()
    restore.expect("hello 5", "hello 5")
    restore.configure(CONFIGURE)
    keyboard.expect_group(1)
    restore.close()


@test("reserved symbols reach an XWayland client too")
def reserved_symbols_reach_xwayland(helper, keyboard):
    # The block's whole point is characters no layout carries, and XWayland is
    # where that has bitten: the scratch gate found two keysyms that reach a
    # native client and produce NOTHING in an X11 one (`approximate`,
    # `permille`), which is why the catalogue spells those two in Unicode
    # notation. A native-only test would not have caught it, and would not
    # catch the next one either.
    #
    # This leg cannot catch a DomCode-table drop, which is what ticket 20 was:
    # x11cat resolves the keysym itself. That gap is the ticket's own open
    # acceptance item, a native-Wayland leg, and it is not this test.
    #
    # One position, all four block levels, through the real GTK/X11 fixture.
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE)
    keyboard.expect_group(1)
    client.expect("text " + "a" * 17, "text-err text too long")

    target = TypingTarget(cls="x11cat")
    try:
        # x11cat flushes per key, so no newline is needed between levels.
        client.expect("down LVL5", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LVL5", "ok")
        target.expect_text("!")
        client.expect("down LVL5", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up LVL5", "ok")
        target.expect_text("!1")
        client.expect("down LVL5", "ok")
        client.expect("down LVL3", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LVL3", "ok")
        client.expect("up LVL5", "ok")
        target.expect_text("!1@")
        client.expect("down LVL5", "ok")
        client.expect("down LVL3", "ok")
        client.expect("down LFSH", "ok")
        client.expect("tap AE01", "ok")
        client.expect("up LFSH", "ok")
        client.expect("up LVL3", "ok")
        client.expect("up LVL5", "ok")
        target.expect_text("!1@2")
    finally:
        target.close()
    client.close()


@test("the published symbol keymap reaches native-Wayland Electron")
def reserved_symbols_reach_electron(helper, keyboard):
    """Ticket 20's missing consumer: Chromium's DomCode-gated path.

    The symbol position is discovered from the helper's product-generated
    facts.  On the old implementation that resolves to I219 and the positive
    assertion fails; on the shipped implementation it resolves to an ordinary
    position and Electron reports both the glyph and a real DomCode.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE_GROUP0)
    published = share_published_keymap()
    if not published.endswith("/omarchy-osk/keymap.xkb"):
        raise Failure(f"unexpected published keymap path: {published!r}")
    client.expect("group 0", "ok")
    keyboard.expect_group(0)

    positions = (
        [f"AE{i:02d}" for i in range(1, 14)]
        + ["AB11"]
        + ["JPCM", "I120", "I149", "I154", "I168", "I178", "I183",
           "I184", "I219", "I222", "I230", "I248"]
    )
    facts = client.caps(0, positions)["by_position"]
    found = None
    for position in positions:
        for level, fact in enumerate(facts.get(position, []), start=1):
            if fact == {"text": "£"}:
                found = (position, level)
                break
        if found:
            break
    if found is None:
        raise Failure("the product keymap advertised no position for £")
    position, level = found
    chords = {
        1: (), 2: ("LFSH",), 3: ("LVL3",), 4: ("LVL3", "LFSH"),
        5: ("LVL5",), 6: ("LVL5", "LFSH"),
        7: ("LVL5", "LVL3"), 8: ("LVL5", "LVL3", "LFSH"),
    }
    if level not in chords:
        raise Failure(f"£ was advertised at unsupported level {level} on {position}")

    target = ElectronTarget()
    try:
        client.expect("tap AB01", "ok")
        control = target.delta()
        if "z·KeyZ" not in control:
            raise Failure(f"Electron control key did not arrive: {control!r}")

        # The known discriminator. A keysym-resolving terminal accepts I219;
        # Electron's fixed evdev->DomCode table must not expose a keyboard
        # event for it. The now-focused editable may still emit an input
        # event from the keysym; that is not a DomCode and is deliberately
        # ignored here.
        client.expect("tap I219", "ok")
        negative = target.delta(expect_event=False)
        if "·" in negative:
            raise Failure(f"Electron unexpectedly gave exotic I219 a DomCode: {negative!r}")

        for modifier in chords[level]:
            client.expect(f"down {modifier}", "ok")
        client.expect(f"tap {position}", "ok")
        for modifier in reversed(chords[level]):
            client.expect(f"up {modifier}", "ok")
        received = target.delta()
        if "£·" not in received:
            raise Failure(
                f"Electron dropped product £ from {position} level {level}: {received!r}"
            )
        glyph_token = next((token for token in received.split() if token.startswith("£·")), "")
        if glyph_token.endswith("·-"):
            raise Failure(f"Electron received £ without a DomCode: {received!r}")
        print(
            f".... Electron: control KeyZ, I219 dropped, £ arrived from "
            f"{position} level {level} as {glyph_token}",
            flush=True,
        )
    finally:
        target.close()
        client.close()


@test("six focus changes keep one published keymap and the selected group")
def focus_keeps_one_keymap_and_group(helper, keyboard):
    """Decisions §35 at the public Wayland/compositor boundary."""
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE)
    share_published_keymap()
    client.expect("group 1", "ok")
    keyboard.expect_group(1)

    observer = KeymapObserver()
    other = None
    try:
        # Snapshot the one initial map before the focus sequence. The generic
        # wire logger proves the event happened; the listener hashes the fd's
        # bytes and proves which payload it carried.
        initial_trace = observer.text()
        initial_raw_events = re.findall(
            r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", initial_trace
        )
        initial_payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            initial_trace,
            re.MULTILINE,
        )
        if len(initial_raw_events) != 1 or len(initial_payloads) != 1:
            raise Failure(
                "observer did not start with exactly one keymap event/payload: "
                f"wire={len(initial_raw_events)}, payloads={initial_payloads}"
            )
        if initial_payloads[0][2] != "1":
            raise Failure(f"initial seat keymap lacks the catalogue: {initial_payloads}")

        initial_windows_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            initial_windows = json.loads(initial_windows_raw)
        except json.JSONDecodeError:
            initial_windows = []
        observer_address = next(
            (window.get("address") for window in initial_windows
             if window.get("class") == "osk-keymap-observer"), None
        )
        initial_active_raw = subprocess.run(
            ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
        ).stdout
        try:
            initial_active = json.loads(initial_active_raw)
        except json.JSONDecodeError:
            initial_active = {}
        if not observer_address or initial_active.get("address") != observer_address:
            raise Failure(
                f"observer did not own focus before the sequence: {initial_active!r}"
            )

        # Mapping foot moves focus observer -> foot: transition 1 of exactly
        # six. Five verified directional moves below end back on the observer.
        other = TypingTarget()
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            windows = json.loads(clients_raw)
        except json.JSONDecodeError:
            windows = []
        foot_address = next(
            (window.get("address") for window in windows
             if window.get("class") == "foot"), None
        )
        if not observer_address or not foot_address:
            raise Failure(f"focus fixtures did not both map: {windows!r}")
        x_by_address = {
            window.get("address"): (window.get("at") or [0])[0]
            for window in windows
        }
        first_raw = subprocess.run(
            ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
        ).stdout
        try:
            first_active = json.loads(first_raw)
        except json.JSONDecodeError:
            first_active = {}
        if first_active.get("address") != foot_address:
            raise Failure(
                f"focus transition 1/6 did not land on foot: {first_active!r}"
            )

        for transition in range(2, 7):
            before = subprocess.run(
                ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
            ).stdout
            try:
                before_address = json.loads(before).get("address")
            except json.JSONDecodeError:
                before_address = None
            wanted = observer_address if transition % 2 == 0 else foot_address
            direction = (
                "left" if x_by_address[wanted] < x_by_address.get(before_address, 0)
                else "right"
            )
            dispatched = subprocess.run(
                ["hyprctl", "dispatch",
                 f"hl.dsp.focus({{ direction = '{direction}' }})"],
                capture_output=True,
                text=True,
            )
            if dispatched.returncode != 0 or "ok" not in dispatched.stdout.lower():
                raise Failure(
                    f"focus transition {transition}/6 was refused: "
                    f"{(dispatched.stdout + dispatched.stderr).strip()!r}"
                )
            for _ in range(60):
                now_raw = subprocess.run(
                    ["hyprctl", "activewindow", "-j"],
                    capture_output=True,
                    text=True,
                ).stdout
                try:
                    now = json.loads(now_raw)
                except json.JSONDecodeError:
                    now = {}
                if now.get("address") == wanted and wanted != before_address:
                    break
                time.sleep(0.05)
            else:
                raise Failure(f"focus transition {transition}/6 never occurred")

        if now.get("address") != observer_address:
            raise Failure(f"six transitions did not end on the observer: {now!r}")
        time.sleep(0.3)

        # No group command after the sequence: this is the regression. The
        # focused client must still have the group selected before it began.
        keyboard.expect_group(1)
        before_key = observer.text()
        client.expect("tap AD01", "ok")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            after_key = observer.text()
            key_tail = after_key[len(before_key):]
            if "KEY evdev=16 group=1 text=й" in key_tail:
                break
            time.sleep(0.05)
        else:
            raise Failure(
                "the retained group did not resolve AD01 as й after focus: "
                f"{observer.text()[len(before_key):]!r}"
            )

        trace = observer.text()
        raw_events = re.findall(r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", trace)
        payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            trace,
            re.MULTILINE,
        )
        sequence_trace = trace[len(initial_trace):]
        sequence_raw_events = re.findall(
            r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", sequence_trace
        )
        sequence_payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            sequence_trace,
            re.MULTILINE,
        )
        if sequence_raw_events or sequence_payloads:
            raise Failure(
                "six focus transitions swapped the client's keymap: "
                f"wire={len(sequence_raw_events)}, payloads={sequence_payloads}"
            )
        if len(raw_events) != 1 or len(payloads) != 1:
            raise Failure(
                f"trace changed outside the sequence accounting: "
                f"wire={len(raw_events)}, payloads={payloads}"
            )
        identities = {identity for _, identity, _ in payloads}
        if len(identities) != 1 or payloads[0][2] != "1":
            raise Failure(
                f"seat did not keep one extended keymap identity: {payloads}"
            )
        print(
            f".... §35: {len(raw_events)} wl_keyboard.keymap event, "
            f"payload {payloads[0][1]} ({payloads[0][0]} bytes), "
            "no events during exactly six focus transitions, retained group 1 typed й",
            flush=True,
        )
    finally:
        if other is not None:
            other.close()
        observer.close()
        client.close()


@test("a text pick delivers its payload once and leaves the clipboard alone")
def text_pick_delivers_once_without_clipboard(helper, keyboard):
    """Ticket 24's delivery half, end to end through the helper socket.

    One `text` line while a real client is focused is exactly what a click
    on the emoji page drives, so the leg is the pick itself, not a mock of
    one. The focused client's `cat` capture is the whole assertion, the same
    evidence every typing leg here reads: the payload byte-exact, and once —
    a doubled delivery fails the equality the same way a dropped one does.
    The family is five scalars (two ZWJ joins inside), so the pick must
    plan, chord and restore five level-5-8 slots, not one.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    # The keymap the §35 leg installed, so this configure short-circuits
    # and compiles nothing: the churn bookkeeping this suite does stays
    # about the tests that earned it.
    client.configure(CONFIGURE)
    keyboard.expect_group(1)

    # Ticket 24's negative half (decisions §26 and its reverse): a pick
    # types, it never pastes. The clipboard is seeded so "unchanged" cannot
    # be confused with "there was nothing to read", then hashed around the
    # picks. The offer lives on the nested seat — the WAYLAND_DISPLAY this
    # suite runs under — never on the host session's.
    clipboard = Clipboard("osk text-pick canary")
    try:
        target = TypingTarget()
        try:
            # Distinct reply shapes keep the panel's text callback FIFO from
            # consuming a generic key-event `ok` queued immediately before it.
            client.write_unread("group 1")
            client.write_unread("text 🙂")
            if client.read_reply() != "ok" or client.read_reply() != "text-ok":
                raise Failure("tap/text replies were not distinctly FIFO-tagged")
            helper.expect_log("text: delivered 1 scalar(s)")
            client.expect("tap RTRN", "ok")
            target.expect_text("🙂\n")

            client.expect("text 👨‍👩‍👧", "text-ok")
            helper.expect_log("text: delivered 5 scalar(s)")
            client.expect("tap RTRN", "ok")
            target.expect_text("🙂\n👨‍👩‍👧\n")
        finally:
            target.close()
        served = clipboard.expect_unchanged("after two text picks")
    finally:
        clipboard.close()
    client.close()
    print(
        ".... text: focused foot read 🙂 then 👨‍👩‍👧, each exactly once; "
        f"nested-seat clipboard sha256 {served} unchanged",
        flush=True,
    )


@test("a text pick preserves supplementary Unicode in native-Wayland Electron")
def text_pick_reaches_electron(helper, keyboard):
    """Ticket 26's exact missing consumer boundary.

    Electron's native Ozone/Wayland path translates the compositor keymap
    through Chromium before the renderer sees ``KeyboardEvent.key``.  A
    keysym-only/unit assertion cannot catch its historical 16-bit character
    truncation, so the real renderer records every key here and the suite
    rebuilds the exact string it received.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    # No Latin group at all: the route must supply its own ASCII hex alphabet,
    # not assume group zero is US-like.
    client.configure("configure\tevdev\tpc105\tua,ru\t\tgrp:caps_toggle\t\t1")
    keyboard.expect_group(1)

    target = ElectronTarget()
    payloads = ["😁😛", "👍🏽", "🇺🇦", "👨‍👩‍👧"]
    clipboard = Clipboard("osk Electron text-pick canary")
    expected = ""
    try:
        for payload in payloads:
            client.expect(f"text-unicode {payload}", "text-ok")
            expected += payload
            delta = target.delta_until_value(expected)
            snapshots = re.findall(r"V([^;]*);", delta)
            received = "" if not snapshots else "".join(
                chr(int(codepoint, 16))
                for codepoint in snapshots[-1].split(",") if codepoint
            )
            if received != expected:
                got = " ".join(f"U+{ord(c):04X}" for c in received)
                wanted = " ".join(f"U+{ord(c):04X}" for c in expected)
                raise Failure(
                    f"Electron changed text payload {wanted} into {got}: {delta!r}"
                )
        # The temporary ASCII entry map must be gone and the selected Russian
        # group restored before text-ok: AD01 is й there.
        client.expect("tap AD01", "ok")
        expected += "й"
        restored = target.delta_until_value(expected)
        if not re.findall(r"V([^;]*);", restored):
            raise Failure("Electron did not receive й from the restored ru group")
        served = clipboard.expect_unchanged("after Electron text picks")
    finally:
        clipboard.close()
        target.close()
        client.close()
    print(
        ".... text/Electron: grin+tongue, skin tone, flag and ZWJ family "
        f"arrived byte-exact; clipboard sha256 {served} unchanged",
        flush=True,
    )


@test("a text pick delivers its payload to an XWayland client too")
def text_pick_reaches_xwayland(helper, keyboard):
    """Ticket 24's third consumer (decisions §33's X11 path).

    x11cat is a real X11 client — GDK on the core key-events path, no input
    method — and it flushes per key press, so each pick's scalars arrive
    one write at a time and the assertion needs no newline: the same exact
    equality as the foot leg, on a client that resolves the keysyms itself
    rather than through a DomCode table.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    # Same keymap the delivery leg before this left installed: this
    # configure short-circuits and compiles nothing.
    client.configure(CONFIGURE)
    keyboard.expect_group(1)

    target = TypingTarget(cls="x11cat")
    try:
        client.expect("text 🙂", "text-ok")
        target.expect_text("🙂")
        client.expect("text 👨‍👩‍👧", "text-ok")
        target.expect_text("🙂👨‍👩‍👧")
    finally:
        target.close()
    client.close()
    print(
        ".... text/x11cat: the XWayland client read 🙂 then 👨‍👩‍👧, "
        "each exactly once",
        flush=True,
    )


@test("a text pick costs two keymap events and the §35 invariant survives it")
def text_pick_keeps_one_keymap_and_group(helper, keyboard):
    """Ticket 24's cost, measured where §35 measured its defect.

    The design spends exactly two `wl_keyboard.keymap` events per pick on
    the focused client — the transient map out, the installed map back —
    and compensates each event's group reset by re-sending modifiers
    (§35). So with the observer focused: exactly two events, the second
    carrying the very payload the client started with; the emoji itself
    among the events' keys; and then six focus changes with no keymap
    event at all and the pre-pick group still resolving letters — the
    stable single-keymap behaviour §35 automated, surviving a pick.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE)
    # Left live by the §35 leg, and a pick must not need it re-pointed:
    # the transient swap happens on the helper's own device, and touching
    # kb_file is what costs the compositor an identity change.
    published_keymap_is_live()
    client.expect("group 1", "ok")
    keyboard.expect_group(1)

    observer = KeymapObserver()
    other = None
    try:
        # The one initial map, before anything is picked.
        initial_trace = observer.text()
        initial_raw_events = re.findall(
            r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", initial_trace
        )
        initial_payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            initial_trace,
            re.MULTILINE,
        )
        if len(initial_raw_events) != 1 or len(initial_payloads) != 1:
            raise Failure(
                "observer did not start with exactly one keymap event/payload: "
                f"wire={len(initial_raw_events)}, payloads={initial_payloads}"
            )
        if initial_payloads[0][2] != "1":
            raise Failure(f"initial seat keymap lacks the catalogue: {initial_payloads}")
        initial_id = initial_payloads[0][1]

        # The observer owns focus; map foot and take focus back, so the
        # pick runs focused on the observer. Both windows stay for the six
        # transitions after the pick.
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            client_list = json.loads(clients_raw)
        except json.JSONDecodeError:
            client_list = []
        observer_address = next(
            (window.get("address") for window in client_list
             if window.get("class") == "osk-keymap-observer"), None
        )
        initial_active_raw = subprocess.run(
            ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
        ).stdout
        try:
            initial_active = json.loads(initial_active_raw)
        except json.JSONDecodeError:
            initial_active = {}
        if not observer_address or initial_active.get("address") != observer_address:
            raise Failure(
                f"observer did not own focus before the pick: {initial_active!r}"
            )

        other = TypingTarget()
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            client_list = json.loads(clients_raw)
        except json.JSONDecodeError:
            client_list = []
        foot_address = next(
            (window.get("address") for window in client_list
             if window.get("class") == "foot"), None
        )
        if not foot_address:
            raise Failure(f"foot did not map for the focus sequence: {client_list!r}")
        x_by_address = window_addresses()
        focus_toward(observer_address, foot_address, x_by_address)

        # The pick. The reply is the helper's word; the trace is the fact.
        before_pick = observer.text()
        client.expect("text 🙂", "text-ok")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if len(re.findall(
                    r"^KEYMAP event=\d+ bytes=\d+ id=[0-9a-f]+ catalogue=\d$",
                    observer.text(),
                    re.MULTILINE)) >= 3:
                break
            time.sleep(0.05)
        else:
            raise Failure(
                "a text pick never produced its two keymap events; "
                f"trace tail: {observer.text()[len(before_pick):][-600:]!r}"
            )
        time.sleep(0.3)  # the pick's trailing modifiers, past the second event
        pick_trace = observer.text()[len(before_pick):]
        pick_raw = re.findall(
            r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", pick_trace
        )
        pick_payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            pick_trace,
            re.MULTILINE,
        )
        if len(pick_raw) != 2 or len(pick_payloads) != 2:
            raise Failure(
                f"a text pick must cost exactly two keymap events: "
                f"wire={len(pick_raw)}, payloads={pick_payloads}"
            )
        if pick_payloads[0][1] == initial_id or pick_payloads[1][1] != initial_id:
            raise Failure(
                f"the installed keymap did not go back last: pick {pick_payloads}, "
                f"initial {initial_id}"
            )
        if any(catalogue != "1" for *_, catalogue in pick_payloads):
            raise Failure(f"a pick keymap lacked the catalogue: {pick_payloads}")
        if "text=🙂" not in pick_trace:
            raise Failure(
                "the focused observer never read the emoji back: "
                f"{pick_trace[-600:]!r}"
            )
        groups = re.findall(r"^MODIFIERS group=(\d+)", pick_trace, re.MULTILINE)
        if not groups or groups[-1] != "1":
            raise Failure(
                f"the pick did not end with the group re-sent: {groups}"
            )
        keyboard.expect_group(1)

        # Six verified focus changes after the pick, ending on the observer:
        # §35's sequence, none of which may carry a keymap event.
        before_sequence = observer.text()
        current = observer_address
        for transition in range(6):
            wanted = foot_address if transition % 2 == 0 else observer_address
            focus_toward(wanted, current, x_by_address)
            current = wanted
        if current != observer_address:
            raise Failure(f"six transitions did not end on the observer: {current}")
        time.sleep(0.3)
        sequence_trace = observer.text()[len(before_sequence):]
        sequence_raw = re.findall(
            r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", sequence_trace
        )
        sequence_payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            sequence_trace,
            re.MULTILINE,
        )
        if sequence_raw or sequence_payloads:
            raise Failure(
                "focus changes after a pick swapped the client's keymap: "
                f"wire={len(sequence_raw)}, payloads={sequence_payloads}"
            )

        # The retained group, with nothing corrective between the pick and
        # this tap: the observer still resolves AD01 as й at group 1.
        keyboard.expect_group(1)
        before_key = observer.text()
        client.expect("tap AD01", "ok")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            key_tail = observer.text()[len(before_key):]
            if "KEY evdev=16 group=1 text=й" in key_tail:
                break
            time.sleep(0.05)
        else:
            raise Failure(
                "the group retained through the pick did not resolve AD01 as й: "
                f"{key_tail!r}"
            )

        # Whole-trace accounting: initial + the pick's two, two distinct
        # payloads, the seat back on the extended map it started with.
        trace = observer.text()
        raw_events = re.findall(r"wl_keyboard[@#][^.]*(?:\.|::)keymap\(", trace)
        payloads = re.findall(
            r"^KEYMAP event=\d+ bytes=(\d+) id=([0-9a-f]+) catalogue=(\d)$",
            trace,
            re.MULTILINE,
        )
        if len(raw_events) != 3 or len(payloads) != 3:
            raise Failure(
                f"trace accounting broke: wire={len(raw_events)}, "
                f"payloads={payloads}"
            )
        identities = {payload[1] for payload in payloads}
        if identities != {initial_id, pick_payloads[0][1]}:
            raise Failure(
                f"unexpected keymap identities on the seat: {payloads}, "
                f"initial {initial_id}"
            )
        print(
            f".... §35 after a pick: {len(raw_events)} keymap events total "
            f"(transient {pick_payloads[0][1][:8]}, installed {initial_id[:8]} "
            "back), six focus changes carried none, group 1 still typed й",
            flush=True,
        )
    finally:
        if other is not None:
            other.close()
        observer.close()
        client.close()


@test("text keeps a held modifier while text-unicode suspends and restores it")
def routes_isolate_modifiers_differently(helper, keyboard):
    """The two text routes' modifier policies, pinned on a named consumer (F4).

    The witness is the observer's serialized modifier mask, not a terminal:
    a canonical-mode `cat` cannot see a Ctrl-held delivery at all — the
    pty eats ^Q/^S as flow control, and Ctrl+Return does not flush the
    line (measured; that trap cost this test its first cut). What the mask
    shows: `text` plans its slots around what a connection already holds,
    so a held Ctrl rides straight through a pick and is still depressed
    after the reply; `text-unicode` cannot compose under foreign
    modifiers, lifts every held key for the ASCII entry map's reign and
    puts them back before the reply — the mask dips during the delivery
    and is whole again at text-ok. Only the release drops it. The
    divergence is by design (decisions §39/§40); this pin keeps it
    visible until a shared transaction interface (§9) decides otherwise.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE)
    keyboard.expect_group(1)
    holder = helper.connect()
    holder.expect("hello 5", "hello 5")

    observer = KeymapObserver()
    other = None
    try:
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            client_list = json.loads(clients_raw)
        except json.JSONDecodeError:
            client_list = []
        observer_address = next(
            (window.get("address") for window in client_list
             if window.get("class") == "osk-keymap-observer"), None
        )
        if not observer_address:
            raise Failure(f"observer did not map: {client_list!r}")
        other = TypingTarget()
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            client_list = json.loads(clients_raw)
        except json.JSONDecodeError:
            client_list = []
        foot_address = next(
            (window.get("address") for window in client_list
             if window.get("class") == "foot"), None
        )
        if not foot_address:
            raise Failure(f"foot did not map for the focus dance: {client_list!r}")
        x_by_address = window_addresses()
        focus_toward(observer_address, foot_address, x_by_address)

        def depressed_masks():
            trace = observer.text()
            return [int(mask) for mask in
                    re.findall(r"^MODIFIERS .*depressed=(\d+)", trace, re.MULTILINE)]

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if depressed_masks():
                break
            time.sleep(0.05)
        else:
            raise Failure("the observer never reported a modifier mask")
        base = depressed_masks()[-1]

        def wait_for_ctrl_bit(before, note):
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                masks = depressed_masks()
                if masks and masks[-1] != before:
                    return before ^ masks[-1], masks[-1]
                time.sleep(0.05)
            raise Failure(f"{note}: the observer never saw the modifier move")

        holder.expect("down LCTL", "ok")
        ctrl_bit, held_mask = wait_for_ctrl_bit(base, "down LCTL never reached the seat")
        # From here on, a mask without the ctrl bit can only be a route's
        # own doing — the dip assertion below slices the trace here, not
        # from the file's beginning (pre-LCTL masks would make it vacuous).

        # The text route preserves the hold across a pick.
        client.expect("text \U0001f642", "text-ok")

        def last_mask():
            masks = depressed_masks()
            return masks[-1] if masks else None

        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            mask = last_mask()
            if mask is not None and mask & ctrl_bit:
                break
            time.sleep(0.05)
        else:
            raise Failure(
                f"the text route dropped a held modifier: {depressed_masks()[-3:]!r}"
            )

        # The Unicode route dips for its entry map and is whole again at
        # the reply: the restore broadcast can lag the reply by a compositor
        # pass, so poll for it — the dip in the middle is the contrast.
        client.expect("text-unicode \U0001f601", "text-ok")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            mask = last_mask()
            if mask is not None and mask & ctrl_bit:
                break
            time.sleep(0.05)
        else:
            raise Failure(
                f"text-unicode did not restore the held modifier: {depressed_masks()[-3:]!r}"
            )
        masks = depressed_masks()
        # Everything from the LCTL press onward: within this window a mask
        # without the ctrl bit is a route suspending the hold, not history.
        held_from = next(i for i, mask in enumerate(masks)
                         if mask & ctrl_bit)
        dips = [mask for mask in masks[held_from:] if not mask & ctrl_bit]
        if not dips:
            raise Failure(
                "text-unicode never suspended the held modifier — the pin "
                "lost its contrast"
            )
        holder.expect("up LCTL", "ok")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            masks = depressed_masks()
            if masks and not masks[-1] & ctrl_bit:
                break
            time.sleep(0.05)
        else:
            raise Failure(f"up LCTL never lifted the seat mask: {masks[-3:]!r}")
    finally:
        if other is not None:
            other.close()
        observer.close()
        client.close()
    print(
        ".... modifier isolation: text rode a held Ctrl through the pick, "
        "text-unicode dipped and restored it, the release dropped it",
        flush=True,
    )


@test("a focus change mid Unicode delivery splits it but leaves nothing held")
def focus_change_mid_unicode(helper, keyboard):
    """Focus follows the seat, not the delivery (F4 measurement).

    Composition keys go to whoever has keyboard focus when each event
    lands, so moving focus mid-delivery splits the sequence across two
    clients — inherent to focus-following delivery, recorded here rather
    than judged. What must NOT be inherent: the device's own state after
    the reply. The installed keymap and group return, and the next plain
    tap types the group's letter, byte-exact, at whichever client is
    focused by then.
    """
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    client.configure(CONFIGURE)
    keyboard.expect_group(1)

    observer = KeymapObserver()
    other = None
    try:
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            client_list = json.loads(clients_raw)
        except json.JSONDecodeError:
            client_list = []
        observer_address = next(
            (window.get("address") for window in client_list
             if window.get("class") == "osk-keymap-observer"), None
        )
        if not observer_address:
            raise Failure(f"observer did not map: {client_list!r}")
        other = TypingTarget()
        clients_raw = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        ).stdout
        try:
            client_list = json.loads(clients_raw)
        except json.JSONDecodeError:
            client_list = []
        foot_address = next(
            (window.get("address") for window in client_list
             if window.get("class") == "foot"), None
        )
        if not foot_address:
            raise Failure(f"foot did not map for the focus split: {client_list!r}")
        x_by_address = window_addresses()
        focus_toward(observer_address, foot_address, x_by_address)

        # A seven-scalar family (~750 ms of pacing), focus leaves mid-way.
        before = observer.text()
        client.write_unread(
            "text-unicode \U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466"
        )
        time.sleep(0.15)
        focus_toward(foot_address, observer_address, x_by_address)
        if client.read_reply() != "text-ok":
            raise Failure("the interrupted delivery did not complete")

        # The device after the split: the selected group restored, the next
        # tap the group's own letter at the newly focused client. A tail,
        # not whole-capture equality — the half of the composition foot
        # inherited lands as bytes ahead of it.
        keyboard.expect_group(1)
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if other.text().endswith("й\n"):
                break
            time.sleep(0.25)
        else:
            raise Failure(
                f"the post-split tap did not type й at the new focus: {other.text()!r}"
            )
        # The observer held focus long enough to see the delivery begin:
        # the transient entry map's upload is in its trace. Everything the
        # helper sends after the focus move is foot's, not the observer's —
        # the compositor broadcasts to the focused client only — so the
        # observer's trace legitimately ends mid-composition; the device's
        # own state is what keyboard.expect_group and the й tap assert.
        trace = observer.text()[len(before):]
        keymaps = re.findall(
            r"^KEYMAP event=\d+ bytes=\d+ id=[0-9a-f]+ catalogue=\d$",
            trace, re.MULTILINE,
        )
        if not keymaps:
            raise Failure(
                "the observer never saw the transient entry map — the "
                f"delivery had not started when focus moved: {trace[-300:]!r}"
            )
    finally:
        if other is not None:
            other.close()
        observer.close()
        client.close()
    print(
        ".... focus split: composition divided across two clients, group 1 "
        "restored, next tap typed й at the new focus",
        flush=True,
    )


@test("a custom keymap edited at its own path installs, unchanged does not")
def custom_keymap_content_refresh(helper, keyboard):
    # Ticket 06. A configure carries the PATH of a custom keymap; the user
    # edits the FILE. Comparing configure fields alone reports "same keymap"
    # for a map whose every key may have changed, and the helper goes on
    # typing yesterday's while the panel draws caps for it — the two agreeing
    # with each other and with nothing on screen.
    #
    # Under $HOME on purpose: the unit sets PrivateTmp, so /tmp is the
    # helper's own and a file written there is one the helper cannot see.
    path = os.path.join(os.path.expanduser("~"), "osk-custom-keymap.xkb")

    def write(layouts):
        compiled = subprocess.run(
            ["xkbcli", "compile-keymap", "--layout", layouts],
            capture_output=True, text=True, check=True,
        ).stdout
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(compiled)

    line = f"configure\tevdev\tpc105\t\t\t\t{path}\t0"
    client = helper.connect()
    client.expect("hello 5", "hello 5")
    target = TypingTarget()
    try:
        write("us")
        first = client.configure(line)
        keyboard.expect_group(0)
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n")

        # Same path, same line, different bytes: a new keymap and a new
        # generation, and the typing follows the file rather than the path.
        before = helper.compiles()
        write("ru")
        second = client.configure(line)
        if second == first:
            raise Failure(f"an edited keymap kept generation {first}")
        helper.expect_compiles(before + 1)
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n\u0439\n")

        # And unchanged bytes are unchanged: no compile, no upload, and the
        # generation the panel's facts are correlated against stands.
        again = client.configure(line)
        if again != second:
            raise Failure(f"an unchanged file bumped the generation to {again}")
        helper.expect_compiles(before + 1)

        # A replacement that cannot compile is refused outright, and what was
        # installed keeps typing — the panel is told, and nothing advertises
        # caps for a keymap that is not in use.
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("this is not a keymap\n")
        refused = client.send(line)
        if not refused.startswith("err "):
            raise Failure(f"an invalid keymap was accepted: {refused!r}")
        helper.expect_compiles(before + 1)
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n\u0439\n\u0439\n")

        # Recoverable: fixing the file installs it, so a bad edit costs the
        # edit and not the session.
        write("us")
        recovered = client.configure(line)
        if recovered == second:
            raise Failure("a repaired keymap did not install")
        client.expect("tap AD01", "ok")
        client.expect("tap RTRN", "ok")
        target.expect_text("q\n\u0439\n\u0439\nq\n")
    finally:
        target.close()
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    client.close()
    # The only following test holds Enter and stops the helper; the repaired
    # custom US map already carries it. Avoid a fifth distinct install inside
    # the production ten-second churn window merely to restore an unused
    # layout after this test.


@test("a helper stopped mid-hold releases the key before it exits")
def shutdown_releases_a_hold(helper, keyboard):
    # Last in the file because it stops the helper: nothing can run after it.
    #
    # The defect (ticket 17, found by the owner): SIGTERM killed the process
    # with `shared.held` still full, so the virtual keyboard was destroyed
    # holding the key. The compositor left it down and the focused client
    # repeated it for the rest of the session; `Retry` could not clear it,
    # because a restarted helper gets a NEW keyboard object and cannot lift
    # another one's press.
    #
    # Two things make this test prove the shutdown path specifically:
    #
    #  * the client stays CONNECTED across the stop, so the per-connection
    #    release in `release_all` — which the test above already covers —
    #    cannot be what lifts the key;
    #  * the hold is RTRN, so every repeat is a newline. `cat` is canonical,
    #    a newline is its flush, and the captured text therefore grows in
    #    real time instead of sitting in the terminal's line buffer. Holding
    #    a letter here would look "clean" whatever the helper did, which is
    #    the trap that made a first cut of this fix read as working.
    target = TypingTarget()
    try:
        client = helper.connect()
        client.expect("hello 5", "hello 5")
        client.expect("down RTRN", "ok")
        # Long enough for the compositor's repeat delay to elapse, so the key
        # really is repeating when the helper is stopped. Without this the
        # test would pass against a helper that strands the key, having only
        # ever proven that one keystroke arrived.
        time.sleep(1.0)
        repeating = target.text()
        if "\n" not in repeating:
            raise Failure(
                "the held RTRN never reached the focused client, so this test "
                f"would prove nothing; it read {repeating!r}"
            )

        helper.terminate()

        # Everything in flight has landed by now; whatever the client reads
        # after this point came from a key the compositor still believes is
        # down.
        time.sleep(0.5)
        settled = target.text()
        time.sleep(1.5)
        after = target.text()
        if after != settled:
            raise Failure(
                "the key kept repeating after the helper stopped: "
                f"{len(settled)} then {len(after)} bytes at the client — the "
                "virtual keyboard was destroyed still holding it"
            )
        # The mechanism, not just the symptom: the shutdown path ran AND had
        # something to release. The message names the codes for that reason —
        # an unconditional "released" line cannot tell the fixed helper apart
        # from one that found nothing held.
        helper.expect_log("released held keys")
    finally:
        target.close()


@test("a SIGTERM mid Unicode delivery aborts with the release intact")
def sigterm_mid_unicode_aborts_clean(helper, keyboard):
    # Last in the file because it stops the helper — a fresh one it spawns
    # itself, because the mid-hold test above already stopped the suite's.
    #
    # F4's own scenario: the Chromium route paces (6 + hex digits) x 10 ms
    # per scalar under the command lock, and a four-person family is ~750 ms
    # of that. The shutdown release waits on the lock for at most 500 ms and
    # then leaves anyway — destroying the virtual keyboard mid-chord, which
    # Hyprland does not lift (ticket 17): the composition's Ctrl would sit
    # on the seat for the rest of the session. The delivery must notice the
    # shutdown request within one scalar, leave, and let the ordinary
    # release-and-roundtrip answer for the device. The helper's own log is
    # the mechanism's proof: "released held keys" means the release got the
    # lock and ran; "leaving anyway" means the 500 ms guard fired first and
    # the abort never happened.
    daemon = os.environ.get("OSK_DAEMON")
    if not daemon:
        raise Failure(
            "OSK_DAEMON is not set; this test respawns the helper the suite "
            "stopped and needs its binary path"
        )
    target = TypingTarget()
    fresh = None
    try:
        # A helper of the suite's own, on the same socket: the dead one's
        # socket file fails the connect probe, so the newcomer unlinks and
        # binds it — the refusal in main() is for a LIVE owner only.
        log_path = os.path.join(os.environ["XDG_RUNTIME_DIR"],
            "osk-mid-delivery.log")
        log_handle = open(log_path, "w")
        proc = subprocess.Popen([daemon], stdout=log_handle,
            stderr=log_handle)
        log_handle.close()  # Popen dup'd the fd; the parent's copy is spare
        fresh = Helper(helper.socket_path, log_path, proc.pid)
        # The dead helper's socket file lingers on disk (exit runs no
        # unlink), so existence proves nothing — readiness is a successful
        # connect, which only the newcomer's bind can satisfy.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                probe = fresh.connect()
                probe.close()
                break
            except (ConnectionRefusedError, FileNotFoundError):
                if proc.poll() is not None:
                    raise Failure(
                        f"the respawned helper exited with {proc.returncode}: "
                        f"{fresh.log()[-600:]!r}"
                    )
                time.sleep(0.05)
        else:
            raise Failure(
                f"the respawned helper never bound its socket: {fresh.log()[-600:]!r}"
            )

        client = fresh.connect()
        client.expect("hello 5", "hello 5")
        client.configure(CONFIGURE)
        keyboard.expect_group(1)
        # A held key across the stop, so the release has something real to
        # answer for (the Unicode route lifts it at the device for the entry
        # map's reign; the claim survives in shared state).
        holder = fresh.connect()
        holder.expect("hello 5", "hello 5")
        holder.expect("down RTRN", "ok")
        time.sleep(1.0)
        repeating = target.text()
        if "\n" not in repeating:
            raise Failure(
                "the held RTRN never repeated, so this test would prove "
                f"nothing; it read {repeating!r}"
            )

        client.write_unread(
            "text-unicode \U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466"
        )
        # Deterministic mid-delivery landing: each committed scalar inserts
        # its emoji into the terminal, so the first non-newline byte in the
        # capture (the holder's RTRN contributes only newlines) is scalar
        # one done and scalar two in flight. Timing the stop from here
        # cannot miss the delivery, on either side of the fix.
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if any(ch != "\n" for ch in target.text()):
                break
            time.sleep(0.05)
        else:
            raise Failure(
                f"the Unicode composition never committed a scalar at the "
                f"focused client: {target.text()!r}"
            )
        os.kill(proc.pid, signal.SIGTERM)
        # Not Helper.terminate(): the respawned helper is this process's
        # child, and an exited child is a zombie until waited —
        # os.kill(pid, 0) answers a zombie, so the shared helper would read
        # "did not exit". poll() is the wait.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        else:
            raise Failure(
                f"the respawned helper did not exit within 5s of SIGTERM: "
                f"{fresh.log()[-400:]!r}"
            )

        time.sleep(0.5)
        settled = target.text()
        time.sleep(1.5)
        after = target.text()
        if after != settled:
            raise Failure(
                "something kept arriving after the helper stopped: "
                f"{len(settled)} then {len(after)} bytes — the mid-delivery "
                "stop stranded a key the compositor still believes is down"
            )
        fresh.expect_log("released held keys")
        fresh.expect_no_log("leaving anyway")
    finally:
        if fresh is not None and fresh.pid is not None:
            try:
                os.kill(fresh.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        target.close()


if __name__ == "__main__":
    pid = int(sys.argv[3]) if len(sys.argv) > 3 else None
    sys.exit(run(sys.argv[1], sys.argv[2], pid))
