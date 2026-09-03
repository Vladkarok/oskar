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

import sys
import time

from harness import TypingTarget, run, test

# Two layouts, caps-toggle, starting on the second one. The nested session's
# own config matches, so the compositor and the helper agree on the world.
CONFIGURE = "configure\tevdev\tpc105\tus,ua\t\tgrp:caps_toggle\t\t1"

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

# The owner's own option string. `shift:both_capslock_cancel` alongside
# `grp:caps_toggle` is what lands <LFSH> in the Lock modifier map, which is
# the difference between this suite's world and the session the panel
# actually shipped into.
CONFIGURE_CAPSLOCK_CANCEL = (
    "configure\tevdev\tpc105\tus,ua\t\tshift:both_capslock_cancel,grp:caps_toggle\t\t0"
)


@test("a three-group keymap cycles through every group and wraps")
def three_group_cycling(helper, keyboard):
    helper.expect_log("listening on")
    # First test on a fresh helper, deliberately: the only compiles in the
    # log are the startup default and the three-group keymap, so the count
    # taken at the end proves cycling recompiled nothing (spec-v1 §3.3: group
    # switching is never a recompile).
    client = helper.connect()
    client.expect("hello 2", "hello 2")
    client.expect(THREE_GROUP, "configured")
    keyboard.expect_group(0)
    # Both protocol paths the panel drives, in the order a cycle moves
    # through them: a byte-identical configure carrying the next group
    # (what follows every compositor switch), then the direct `group <n>`.
    client.expect(THREE_GROUP_ON_DE, "configured")
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


@test("the device group follows configure and group, around every tap")
def group_follows_protocol(helper, keyboard):
    helper.expect_log("listening on")
    # active_layout_index is the one layout fact about the helper readable
    # without a client, so every typing operation asserts it first: what is
    # proven is the group the tap actually ran under, not a final state.
    client = helper.connect()
    client.expect("hello 2", "hello 2")
    client.expect(CONFIGURE, "configured")
    keyboard.expect_group(1)
    client.expect("tap AD01", "ok")
    client.expect("group 0", "ok")
    keyboard.expect_group(0)
    client.expect("tap AD01", "ok")
    # Byte-identical to the first: the helper must short-circuit rather than
    # compile again. Both paths answer "configured", so the reply proves
    # nothing — the compile count at the end is what proves it.
    client.expect(CONFIGURE, "configured")
    keyboard.expect_group(1)
    client.expect("tap AD01", "ok")
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
    fresh.expect("hello 2", "hello 2")
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
    a.expect(CONFIGURE_SWAPPED, "configured")
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
    client.expect("hello 2", "hello 2")
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


@test("keymap churn stayed at four compiles: default, three-group, configured, swap")
def churn_held(helper, keyboard):
    # The default compiled at startup, the three-group cycling keymap, the
    # us,ua one, and the swapped model in the claims test. A fifth means the
    # byte-identical configure recompiled or a group switch did, which is
    # the churn storm in miniature.
    helper.expect_compiles(4)
    # And the helper's own rate limiter never had to save us from one.
    helper.expect_no_log("refusing excessive keymap reconfiguration")


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
    # the churn guard doing its job rather than a fault — the four the tests
    # above compiled all land inside that window when the session is quick.
    # Wait it out instead of raising the cap: the cap is the thing that keeps
    # a compile loop from freezing a desktop.
    time.sleep(11)

    client = helper.connect()
    client.expect("hello 2", "hello 2")
    client.expect(CONFIGURE_CAPSLOCK_CANCEL, "configured")
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


if __name__ == "__main__":
    sys.exit(run(sys.argv[1], sys.argv[2]))
