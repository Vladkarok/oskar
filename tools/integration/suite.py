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
    EventClient,
    Failure,
    Helper,
    KeymapObserver,
    TypingTarget,
    compositor_kb_file,
    compositor_keyboards,
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
HOLD_CAP = int(os.environ.get("OSKAR_HOLD_CAP_MS", "15000")) / 1000.0

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
# somewhere to wrap from.
THREE_GROUP = "configure\tevdev\tpc105\tus,ua,de\t\tgrp:caps_toggle\t\t0"
# Byte-identical keymap, different group: the path a `group <n>` mirrors
# takes when the panel re-sends its configure after a compositor switch.
THREE_GROUP_ON_DE = "configure\tevdev\tpc105\tus,ua,de\t\tgrp:caps_toggle\t\t2"

# `shift:both_capslock_cancel` alongside `grp:caps_toggle` is what lands
# <LFSH> in the Lock modifier map, and reading the modifier map instead of
# asking xkb is what made held Shift produce lowercase letters (a730c99).
#
# `grp:caps_toggle` breaks layout switching for fcitx5 clients, which is
# why the shipped session uses `compose:caps,grp:alt_shift_toggle`
# instead. The fixture stays exactly as it is: it
# is the regression guard for a730c99, and its value is that it is *not* the
# session the panel ships into. Do not "update" it to match the shipped session.
CONFIGURE_CAPSLOCK_CANCEL = (
    "configure\tevdev\tpc105\tus,ua\t\tshift:both_capslock_cancel,grp:caps_toggle\t\t0"
)


@test("startup inventory reports a positively identified physical keyboard")
def startup_keyboard_inventory(helper, keyboard):
    client = helper.connect()
    client.expect("hello 6", "hello 6")
    reply = client.send("keyboards")
    if not reply.startswith("keyboards\t"):
        raise Failure(f"expected a keyboard inventory, got {reply!r}")
    names = [name for name in reply.split("\t")[1:] if name]
    if not names:
        raise Failure("the test machine has physical keyboards but inventory was empty")
    poisoned = ("hl-virtual-keyboard", "power-button", "video-bus", "oskar")
    if any(name.startswith(poisoned) for name in names):
        raise Failure(f"inventory included a pseudo keyboard: {names!r}")
    client.close()


@test("a three-group keymap cycles through every group and wraps")
def three_group_cycling(helper, keyboard):
    helper.expect_log("listening on")
    # First test on a fresh helper, deliberately: the only compiles in the
    # log are the startup default and the three-group keymap, so the count
    # taken at the end proves cycling recompiled nothing (group
    # switching is never a recompile).
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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
    # The seam comparison: the facts the helper supplies for a group
    # and the characters a real client actually reads, side by side, for
    # both groups. The caps the panel will draw are
    # only honest if THIS holds.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
    gen = client.configure(CONFIGURE)
    keyboard.expect_group(1)
    client.expect("group 0", "ok")
    keyboard.expect_group(0)

    facts = client.caps(0, ["AD01", "AE01"])
    if facts["gen"] != gen or facts["group"] != 0:
        raise Failure(f"caps reply for the wrong world: {facts}")
    if facts["by_position"]["AD01"] != [{"text": "q"}, {"text": "Q"}]:
        raise Failure(f"group 0 AD01 facts: {facts['by_position']['AD01']}")
    # The position keeps its original levels 1-4 and adds the
    # reserved-symbol block at levels 5-8. This early seam
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
    client.expect("hello 6", "hello 6")
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


@test("out-of-range groups are refused without touching the installed map")
def out_of_range_groups_fail_closed(helper, keyboard):
    # Daemon defence in depth: `caps` already refuses a group
    # the keymap does not carry; configure and `group` —
    # the two commands that MOVE the group — refuse it the same way, with
    # no device state change, no recompile, and the previously installed
    # generation intact.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
    gen = client.configure(CONFIGURE)  # us,ua — two groups, group 1
    keyboard.expect_group(1)
    # A configure naming a group the map cannot carry. A different model,
    # so a buggy acceptance would take the full compile path.
    client.expect(CONFIGURE_SWAPPED[:-1] + "9", "err bad group")
    keyboard.expect_group(1)
    # The refusal installed nothing: the same configure short-circuits
    # with the identical generation afterwards.
    assert client.configure(CONFIGURE) == gen
    client.expect("group 9", "err bad group")
    keyboard.expect_group(1)
    client.expect("group 0", "ok")
    keyboard.expect_group(0)
    client.close()


@test("a release sent from inside the not-ready window lifts the key immediately")
def release_crosses_the_unready_window(helper, keyboard):
    # The socket boundary under the unready window. On the panel side the
    # unready window is self-inflicted: a compositor event re-sends the
    # configure and the panel refuses to treat itself as ready until
    # `configured` is read back. A same-keymap configure keeps the helper's
    # holds alive across that window, so a key held when it opens must be
    # liftable during it — a release whose `up` the panel swallowed would
    # repeat the key until this suite's own hold cap fired, and a locked
    # Shift's lift would never go out at all. The helper sees exactly:
    # configure (reply unread), then `up`, with no readiness wait between.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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
    fresh.expect("hello 6", "hello 6")
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
    # Every other assertion in this file is about a key going out, but a
    # bare tap typing is not enough proof: a chord can arrive
    # modifierless even though the tap works, because
    # a wlroots compositor takes a virtual keyboard's modifier state from the
    # `modifiers` request and not from watching key events. Only a client
    # reading characters can tell the two apart.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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

        # Modifiers stack: two held at once must both be in the
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

        # A locked modifier survives a language switch: the group
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
    # The hello gate: a protocol version bump moves reply
    # shapes on both sides in one change, so a mixed pairing must be named
    # before any configure is sent — the exact refusal the panel's
    # "service needs updating" state keys off. No configure rides with this
    # test: the gate exists so a mismatched panel never reaches one, and a
    # compile here would put the churn count below in a lie.
    client = helper.connect()
    client.expect("hello 3", "err protocol 7 required, helper needs reinstall")
    # The refusal names the version, not the connection: the same socket
    # speaking the current version is greeted normally.
    client.expect("hello 6", "hello 6")
    client.close()


# ---- the overlap contract, against the REAL
# helper: the host suites exercise the machines alone; these pin the seams
# where one operation overlaps another on the same socket.


@test("even an empty line answers exactly one reply")
def empty_line_answers(suite_helper, keyboard):
    client = suite_helper.connect()
    client.write_unread("\n")
    if client.read_line() != "err empty":
        raise Failure("a bare empty line did not answer err empty")
    client.expect("ping", "pong")
    client.close()


@test("nothing executes before a completed hello, and a refused version never opens the door")
def pre_handshake_gate(helper, keyboard):
    raw = helper.connect(negotiate=False)
    raw.expect("ping", "err hello first")
    raw.expect("keyboards", "err hello first")
    # A wrong version is REFUSED, not negotiated: the door stays shut.
    reply = raw.send("hello 4")
    if reply != "err protocol 7 required, helper needs reinstall":
        raise Failure(f"hello 4: {reply!r}")
    raw.expect("ping", "err hello first")
    # The matching hello opens it, on the same connection.
    raw.expect("hello 6", "hello 6")
    raw.expect("ping", "pong")
    raw.close()


@test("coalesced commands in one write are each answered, in order, whatever they answer")
def coalesced_batch_is_fully_served(helper, keyboard):
    client = helper.connect()
    # One write, three commands — an err among them spends its own slot
    # (the panel's correlation queue relies on exactly this FIFO).
    client.write_unread("ping\ngroup 9\nping\n")
    if client.read_line() != "pong":
        raise Failure("first coalesced reply was not pong")
    if client.read_line() != "err bad group":
        raise Failure("the err'd group did not spend exactly its own slot")
    if client.read_line() != "pong":
        raise Failure("the reply after the err was not pong")
    # Valid coalesced commands totalling
    # far past the 4 KiB frame cap are ALL served — the cap is per line.
    client.write_unread("ping\n" * 1500)
    for i in range(1500):
        if client.read_line() != "pong":
            raise Failure(f"reply {i} of the oversized batch went missing")
    client.close()


@test("a single line past the frame cap is refused and the connection closed")
def oversized_line_is_refused(helper, keyboard):
    client = helper.connect()
    # Complete (newline-terminated): refused before parsing.
    client.write_unread("ping" * 1300 + "\n")
    if client.read_line() != "err line too long":
        raise Failure("a complete 5 KiB line was served instead of refused")
    if client.read_line() != "":
        raise Failure("the connection stayed open past the refused line")
    client.close()
    # Incomplete (no newline): the growing tail trips the same cap.
    tail = helper.connect()
    tail.write_unread("ping" * 1300)
    if tail.read_line() != "err line too long":
        raise Failure("a newline-free 5 KiB tail was not refused")
    if tail.read_line() != "":
        raise Failure("the connection stayed open past the refused tail")
    tail.close()


@test("the pre-handshake window is absolute under continuous traffic")
def handshake_window_survives_traffic(helper, keyboard):
    raw = helper.connect(negotiate=False)
    started = time.monotonic()
    dropped = None
    # Stream frames without a hello for longer than the five-second
    # window: the daemon must drop the connection at the window, however
    # busy the read side keeps it.
    while time.monotonic() - started < 9:
        try:
            raw.write_unread("ping\n" * 64)
        except (BrokenPipeError, ConnectionResetError, OSError):
            dropped = time.monotonic()
            break
        # Drain the refusals so the client's own buffer never blocks us.
        # A reset is the drop just as an EOF is — closed-with-queued-data
        # reads that way.
        for _ in range(64):
            try:
                line = raw.read_line()
            except (ConnectionResetError, BrokenPipeError):
                line = ""
            if line == "":
                dropped = time.monotonic()
                break
        if dropped is not None:
            break
        if time.monotonic() - started < 5.5:
            time.sleep(0.05)
    if dropped is None:
        # The daemon may also simply stop reading: a final drain proves it.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if raw.read_line() == "":
                dropped = time.monotonic()
                break
        if dropped is None:
            raise Failure("a hello-less connection survived 9s of traffic")
    elapsed = dropped - started
    if elapsed < 4.5:
        raise Failure(f"the connection was dropped at {elapsed:.1f}s, before the window")
    if elapsed > 8.0:
        raise Failure(f"the connection was dropped at {elapsed:.1f}s, past the window's purpose")
    raw.close()
    # And the helper still serves the next client.
    fresh = helper.connect()
    fresh.expect("ping", "pong")
    fresh.close()


@test("a stalled reader is dropped by the write bound, not allowed to wedge the helper")
def write_bound_drops_stalled_reader(helper, keyboard):
    client = helper.connect()
    # Flood kilobyte-scale replies without reading a single one: the
    # daemon's socket buffers fill, its bounded write times out, and the
    # connection is dropped rather than parked.
    try:
        for _ in range(300):
            client.write_unread("caps 0\n")
    except OSError:
        pass  # our own send buffer filling is fine — the point is the daemon's

    def _read_or_eof():
        """A reply line, or None when the daemon dropped us.

        A socket closed with data still queued reads as a reset rather
        than an EOF — both are the drop, exactly what this test wants.
        """
        try:
            return client.read_line()
        except (ConnectionResetError, BrokenPipeError):
            return None

    saw_eof = False
    lines = 0
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        line = _read_or_eof()
        if line is None or line == "":
            saw_eof = True
            break
        lines += 1
    if not saw_eof:
        raise Failure(
            f"the stalled connection was still being served after 15s ({lines} replies)"
        )
    client.close()
    # The helper itself must be untouched.
    fresh = helper.connect()
    fresh.expect("ping", "pong")
    fresh.close()


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
    client.expect("hello 6", "hello 6")
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


# A variant a real seat could carry: the second copy of `us` is
# `euro`, whose AltGr level puts the euro sign on 5. Same layout code for
# both groups — the case where guessing a group from the code is wrong.
CONFIGURE_VARIANT = "configure\tevdev\tpc105\tus,us\t,euro\t\t\t0"


@test("a repeated layout with distinct variants answers per-variant facts")
def variant_facts(helper, keyboard):
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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
    client.expect("hello 6", "hello 6")
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
    # The wedged-panel case. Nothing arrives on the socket after
    # the `down`, which is exactly the shape a panel that is alive but stuck
    # has — so the release cannot come from the panel and cannot come from a
    # heartbeat, because there is none.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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
    # A locked Shift is deliberately held for minutes, so the cap
    # must not touch a modifier code. "The lock indicator still matches
    # reality" is a panel-side statement, but the fact underneath it is
    # visible here: after twice the cap the modifier is still claimed, and a
    # client still reads a capital.
    client = helper.connect()
    client.expect("hello 6", "hello 6")

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
    dying.expect("hello 6", "hello 6")
    dying.expect("down AD01", "ok")
    dying.close()
    # The release happens on the dying connection's own thread when its read
    # returns EOF. Well under the cap, and the point of the assertion below is
    # that the cap is not what did it.
    time.sleep(0.5)

    fresh = helper.connect()
    fresh.expect("hello 6", "hello 6")
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
    client.expect("hello 6", "hello 6")
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
    # The never-drained ordering, at the socket. A failed
    # configure (a kb_file that cannot compile) is answered by install_config
    # BEFORE it would drain anything, so the connection's holds and the mask
    # they imply survive intact — the fact the panel's failure settle counts
    # on when it lifts the lock it had and zeroes the mask. The
    # drain-before-failure ordering (an upload failure) is not reachable from
    # outside the compositor and is covered by the reducer seam instead.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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
    client.expect("hello 6", "hello 6")
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
    client.expect("hello 6", "hello 6")
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
    # The helper adds a block of symbols no
    # configured layout carries to every keymap it installs. The claim is that
    # they are not a layout's business: the same cap produces the same
    # character in `us` and in `ua`.
    #
    # The block rides on levels five to eight of the digit
    # row rather than on free keycodes of its own — Chromium's Ozone/Wayland
    # DomCode table drops those, so they would not type in Chromium-based
    # clients. `<LVL5>` opens the levels; Shift and `<LVL3>` choose among them.
    #
    # Nothing here installs a fixture keymap. The configure is the ordinary
    # one every other test uses, so what is asserted is what ships.
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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
    # And what the layout itself put on levels 1-4 is still there: the
    # block is an addition, never an edit.
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
        # group switch — `@` must not silently depend on a `us` group
        # being present.
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
    restore.expect("hello 6", "hello 6")
    restore.configure(CONFIGURE)
    keyboard.expect_group(1)
    restore.close()


@test("the published symbol keymap reaches native-Wayland Electron")
def reserved_symbols_reach_electron(helper, keyboard):
    """Ticket 20's missing consumer: Chromium's DomCode-gated path.

    The symbol position is discovered from the helper's product-generated
    facts.  On the old implementation that resolves to I219 and the positive
    assertion fails; on the shipped implementation it resolves to an ordinary
    position and Electron reports both the glyph and a real DomCode.
    """
    client = helper.connect()
    client.expect("hello 6", "hello 6")
    client.configure(CONFIGURE_GROUP0)
    published = share_published_keymap()
    if not published.endswith("/oskar/keymap.xkb"):
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
    client.expect("hello 6", "hello 6")
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


@test("a custom keymap edited at its own path installs, unchanged does not")
def custom_keymap_content_refresh(helper, keyboard):
    # A configure carries the PATH of a custom keymap; the user
    # edits the FILE. Comparing configure fields alone reports "same keymap"
    # for a map whose every key may have changed, and the helper goes on
    # typing yesterday's while the panel draws caps for it — the two agreeing
    # with each other and with nothing on screen.
    #
    # Under $HOME on purpose: the unit sets PrivateTmp, so /tmp is the
    # helper's own and a file written there is one the helper cannot see.
    path = os.path.join(os.path.expanduser("~"), "osk-custom-keymap.xkb")

    # The custom-map configures share the churn window with the
    # preceding tests' compiles; without draining it first the honest
    # budget refuses. Drain the window first — the budget is the
    # product's, not the fixture's.
    time.sleep(10.5)

    def write(layouts):
        compiled = subprocess.run(
            ["xkbcli", "compile-keymap", "--layout", layouts],
            capture_output=True, text=True, check=True,
        ).stdout
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(compiled)

    line = f"configure\tevdev\tpc105\t\t\t\t{path}\t0"
    client = helper.connect()
    client.expect("hello 6", "hello 6")
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


def _seat_facts(client):
    """One `seat` reply, decoded."""
    reply = client.send("seat")
    if not reply.startswith("seat\t"):
        raise Failure(f"expected seat<TAB><json>, got {reply[:200]!r}")
    try:
        return json.loads(reply[len("seat\t"):])
    except json.JSONDecodeError as error:
        raise Failure(f"the seat reply is not JSON ({error}): {reply[:200]!r}")


def _physical_keyboard():
    """A keyboard of the nested compositor's own, never the helper's."""
    for name in compositor_keyboards():
        if not name.startswith("hl-virtual-keyboard"):
            return name
    raise Failure("the nested compositor lists no keyboard of its own")


@test("a protocol-6 peer keeps the v6 world: seat verbs unknown, no events")
def seat_verbs_need_protocol_seven(helper, keyboard):
    client = helper.connect()
    if client.hello_reply != "hello 6":
        raise Failure(f"hello 6 was refused: {client.hello_reply!r}")
    for line in ("seat", "events on", "switch\twl_keyboard\t1", "share\t-"):
        client.expect(line, "err unknown command")
    # A layout move the compositor announces must not reach this
    # connection: the ping's reply is the very next line it reads.
    device = _physical_keyboard()
    subprocess.run(["hyprctl", "switchxkblayout", device, "1"], capture_output=True)
    time.sleep(0.5)
    subprocess.run(["hyprctl", "switchxkblayout", device, "0"], capture_output=True)
    time.sleep(0.5)
    client.expect("ping", "pong")
    client.close()


@test("protocol 7: seat reports the compositor's keyboards and kb_file")
def seat_reports_the_compositor(helper, keyboard):
    client = EventClient(helper.socket_path)
    client.expect("hello 7", "hello 7")
    client.expect("events on", "ok")
    facts = _seat_facts(client)
    compositor = compositor_keyboards()
    names = [entry["name"] for entry in facts["keyboards"]]
    if sorted(names) != sorted(compositor):
        raise Failure(f"seat names {names!r}, the compositor {sorted(compositor)!r}")
    for entry in facts["keyboards"]:
        truth = compositor[entry["name"]]
        for key in ("main", "active_layout_index", "layout", "variant", "rules",
                    "model", "options"):
            if entry[key] != truth[key]:
                raise Failure(
                    f"{entry['name']}.{key}: seat {entry[key]!r}, "
                    f"compositor {truth[key]!r}"
                )
    if facts["kb_file"] != compositor_kb_file():
        raise Failure(f"seat kb_file {facts['kb_file']!r}, compositor {compositor_kb_file()!r}")
    inventory = [name for name in client.send("keyboards").split("\t")[1:] if name]
    if facts["safe"] != inventory:
        raise Failure(f"seat safe {facts['safe']!r}, keyboards verb {inventory!r}")
    if facts["titles"].get("ua") != "Ukrainian":
        raise Failure(f"no human name for ua: {facts['titles']!r}")
    print(f".... seat: {len(names)} keyboards {names!r}, kb_file "
          f"{facts['kb_file']!r}", flush=True)
    client.close()


@test("protocol 7: switch moves a keyboard; an outside switch arrives as an event")
def seat_switch_and_layout_events(helper, keyboard):
    client = EventClient(helper.socket_path)
    client.expect("hello 7", "hello 7")
    client.expect("events on", "ok")
    device = _physical_keyboard()
    client.expect(f"switch\t{device}\t1", "ok")
    for _ in range(40):
        if compositor_keyboards()[device]["active_layout_index"] == 1:
            break
        time.sleep(0.05)
    else:
        raise Failure(f"{device} never reached group 1 after switch")
    reply = client.send("switch\tno-such-keyboard\t1")
    if not reply.startswith("err seat refused"):
        raise Failure(f"a switch of an unknown device answered {reply!r}")
    # The move made OUTSIDE the helper — Caps Lock, the bar, a keybind —
    # is what the panel has to follow.
    client.events.clear()
    moved = subprocess.run(
        ["hyprctl", "switchxkblayout", device, "0"], capture_output=True, text=True
    )
    if moved.stdout.strip() != "ok":
        raise Failure(f"hyprctl switchxkblayout refused: {moved.stdout!r}")
    seen = client.wait_event(f"event\tlayout\t{device}\t0")
    # Replies still pair with commands while events flow.
    client.expect("ping", "pong")
    print(f".... events: {seen!r}", flush=True)
    client.expect("events off", "ok")
    client.close()


@test("protocol 7: share points kb_file at a keymap and share - clears it")
def seat_share_and_clear(helper, keyboard):
    client = EventClient(helper.socket_path)
    client.expect("hello 7", "hello 7")
    # Refused before the compositor is touched, like the panel's own
    # "not published yet" exit.
    client.expect("share\t/nonexistent/oskar/keymap.xkb", "err keymap missing")
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    published = os.path.join(runtime, "oskar", "keymap.xkb")
    client.expect(f"share\t{published}", "ok")
    if compositor_kb_file() != published:
        raise Failure(f"after share the compositor has {compositor_kb_file()!r}")
    client.expect("share\t-", "ok")
    if compositor_kb_file() != "":
        raise Failure(f"after share - the compositor has {compositor_kb_file()!r}")
    facts = _seat_facts(client)
    if facts["kb_file"] != "":
        raise Failure(f"seat still reports kb_file {facts['kb_file']!r}")
    client.close()


@test("a helper stopped mid-hold releases the key before it exits")
def shutdown_releases_a_hold(helper, keyboard):
    # Last in the file because it stops the helper: nothing can run after it.
    #
    # SIGTERM must not kill the process with `shared.held` still full:
    # that would destroy the virtual keyboard while holding the key,
    # leaving it down for the focused client to repeat for the rest of
    # the session — and `Retry` cannot clear it, because a restarted
    # helper gets a NEW keyboard object and cannot lift another one's
    # press.
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
        client.expect("hello 6", "hello 6")
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




if __name__ == "__main__":
    pid = int(sys.argv[3]) if len(sys.argv) > 3 else None
    sys.exit(run(sys.argv[1], sys.argv[2], pid))
