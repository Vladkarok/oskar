#!/usr/bin/env python3
"""A keyboard toggled by itself is followed; the panel's own click is not.

The owner's seat (captured 2026-09-27): fcitx5's virtual keyboard
re-emits every key and holds the seat's `main` flag for good, so the flag
never names the keyboard typed on. Alt+Shift moves that one keyboard and
nothing else. The panel must follow it — the keyboard that moved alone,
uncommanded, becomes the anchor and its live group the reading — while
the layout events its own language click produces, one per keyboard it
moves, never re-anchor it or flip it.

The lab cannot press physical keys, but `hyprctl switchxkblayout <device>
next` on ONE keyboard produces the same lone layout event a physical
toggle does, and the lab runs fcitx5, so `main` stays off the keyboard
that moves exactly as on the owner's seat. The leg:

1. hosts the real panel (the settle leg's isolated venue: a private
   runtime, its own helper, the packaged service stopped), brings the
   switch set to group 0 with the panel's own click, and waits out the
   post-reconnect settle window so every follow is a first-sight follow;
2. seeds a diverged seat: one keyboard of the set moved alone to group 1,
   so the anchor is a keyboard that is NOT the one about to move;
3. toggles the mover four times with `switchxkblayout <mover> next`
   (four layouts: every step is a new group), asserting after each that
   no safe keyboard holds `main`, the panel's group is the mover's live
   group, and the mover is the anchor;
4. drives the panel's own click to the next group and asserts the seat
   reunites on it, the panel's group holds on it through the echoes, the
   anchor stays the mover, and the helper logged exactly one group move.

Run inside the VM's lab session:

  cd ~/oskar && OSK_LONE_TOGGLE_LIVE=1 python3 tools/integration/lone_toggle.py
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hold_column import Failure, wait_for  # noqa: E402
from restart_settle import (LabSession, LegDaemon, Panel,  # noqa: E402
                            PrivateRuntime, STATE_FILE, group_names_in_keymap,
                            hyprctl, kb_file_option, keyboard_groups,
                            read_state, restore_compositor_kb_file,
                            restore_service, sane_restore_target,
                            wait_seat_carries_groups)

LAB_HOSTNAME = "testprod"
RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "")
# SettleGuard.WINDOW_MS plus a margin: past it, every uncommanded flip is
# followed at first sight, which is what the toggles below assert.
SETTLE_WINDOW_S = 11.0


def guard():
    # Live-only by explicit opt-in, and the lab's hostname as positive
    # proof: this leg stops the osk service and moves the seat's groups.
    if os.environ.get("OSK_LONE_TOGGLE_LIVE", "") != "1":
        raise Failure("this leg stops the osk service and drives the live "
                      "session — run it only in the omarchy-vm lab, with "
                      "OSK_LONE_TOGGLE_LIVE=1 (docs/vm-handoff.md)")
    if os.uname().nodename != LAB_HOSTNAME:
        raise Failure(f"OSK_LONE_TOGGLE_LIVE=1 is set, but this host is "
                      f"{os.uname().nodename!r}, not the lab "
                      f"({LAB_HOSTNAME!r}); refusing (docs/vm-handoff.md)")


def main_holders():
    try:
        keyboards = json.loads(hyprctl("devices", "-j"))["keyboards"]
    except (json.JSONDecodeError, KeyError):
        return []
    return [k.get("name", "") for k in keyboards if k.get("main")]


def converge(panel, group, switch_set, note):
    panel.command(f"group {group}", "grouped")
    wait_for(lambda: all(keyboard_groups().get(n) == group
                         for n in switch_set), 10,
             f"every switch-set keyboard on group {group} ({note})")
    wait_for(lambda: panel.state()["group"] == group, 10,
             f"the panel on group {group} ({note})")


def run(repo, rt):
    daemon = LegDaemon(repo, "lone", rt.env)
    panel = None
    try:
        daemon.wait_socket()
        panel = Panel(repo, rt.env, tag="lone")
        wait_for(lambda: any(l == "alive" for l in panel.marker_lines()),
                 120, "the hosted panel to start")
        panel.command("open", "opened")
        wait_for(lambda: panel.state()["ready"] is True, 90,
                 "the keyboard to become ready to type")
        ready_at = time.monotonic()
        state = panel.state()
        codes = state["codes"]
        switch_set = state["switchSet"]
        if len(codes) < 3:
            raise Failure(f"the lab's layout list is {codes}; the leg needs "
                          "at least three layouts so every toggle is a new "
                          "group")
        if len(switch_set) < 3:
            raise Failure(f"the switch set is {switch_set}; the leg needs "
                          "three keyboards (a mover, a seeded anchor, one "
                          "that stays put)")
        wait_seat_carries_groups(len(codes), "before the seed")
        print(f"ok    hosted panel ready: codes {codes}, switch set "
              f"{switch_set}, anchor {state['anchor']!r}")

        converge(panel, 0, switch_set, "the seed")
        wait_for(lambda: panel.state()["ready"] is True, 30,
                 "readiness after the seed")
        # Past the post-reconnect window, a flip is followed at first
        # sight; inside it the guard would hold each toggle for a quiesce.
        remaining = SETTLE_WINDOW_S - (time.monotonic() - ready_at)
        if remaining > 0:
            time.sleep(remaining)

        holders = main_holders()
        if any(name in switch_set for name in holders):
            raise Failure(f"`main` sits on {holders}, a safe keyboard; the "
                          "leg needs it off the set (the lab's fcitx5 "
                          "holds it) or it proves nothing about the mover")

        # The diverged seed: one keyboard moved alone becomes the anchor.
        # The mover is another one, and a third stays put.
        seeded, mover = switch_set[0], switch_set[1]
        hyprctl("switchxkblayout", seeded, "1")
        wait_for(lambda: panel.state()["group"] == 1
                 and panel.state()["anchor"] == seeded, 10,
                 f"the panel to follow {seeded} moved alone to 1")
        print(f"ok    diverged seat seeded: {keyboard_groups_of(switch_set)}, "
              f"anchor {seeded!r}, main on {main_holders()}")

        followed = []
        for step in range(4):
            hyprctl("switchxkblayout", mover, "next")
            live = keyboard_groups().get(mover)
            try:
                wait_for(lambda: (lambda s: s["group"] == live
                                  and s["anchor"] == mover)(panel.state()),
                         10, f"toggle {step + 1}")
            except Failure:
                raise Failure(f"toggle {step + 1}: {mover} moved alone to "
                              f"{live}, the panel stayed on "
                              f"{panel.state()['group']} with anchor "
                              f"{panel.state()['anchor']!r} (seat "
                              f"{keyboard_groups_of(switch_set)}, main on "
                              f"{main_holders()})")
            holders = main_holders()
            if mover in holders or any(n in switch_set for n in holders):
                raise Failure(f"toggle {step + 1}: `main` landed on "
                              f"{holders}; the follow is not the lone "
                              "mover's")
            followed.append(live)
            print(f"ok    toggle {step + 1}: {mover} alone -> {live}; panel "
                  f"on {live}, anchor {mover!r}, main on {holders}, seat "
                  f"{keyboard_groups_of(switch_set)}")
        if len(panel.holds()) != 0:
            raise Failure(f"the settle guard held a toggle outside its "
                          f"window: {panel.holds()[:3]}")

        # The panel's own click: the seat reunites, the echoes neither
        # flip the panel nor re-anchor it.
        wait_for(lambda: panel.state()["ready"] is True, 30,
                 "readiness before the click")
        moves_before = len(daemon.group_moves())
        target = (panel.state()["group"] + 1) % len(codes)
        panel.command(f"group {target}", "grouped")
        wait_for(lambda: all(keyboard_groups().get(n) == target
                             for n in switch_set), 10,
                 f"the seat to reunite on {target}")
        seen = set()
        anchors = set()
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            s = panel.state()
            seen.add(s["group"])
            anchors.add(s["anchor"])
            time.sleep(0.1)
        after = daemon.group_moves()[moves_before:]
        if seen != {target}:
            raise Failure(f"after the click the panel showed groups "
                          f"{sorted(seen)}, expected only {target}")
        if anchors != {mover}:
            raise Failure(f"the click's echoes re-anchored the panel: "
                          f"{sorted(anchors)}, expected {mover!r}")
        if after != [str(target)]:
            raise Failure(f"the helper logged group moves {after} for the "
                          f"click, expected exactly ['{target}']")
        print(f"ok    the panel's click to {target}: seat reunited "
              f"{keyboard_groups_of(switch_set)}, panel held {target} "
              f"through the echoes, anchor still {mover!r}, one helper "
              "group move")
        print(f"ok    LONE TOGGLE LEG GREEN: four lone toggles followed "
              f"{followed}, the click reunited the seat without a flip")
    finally:
        if panel:
            try:
                panel.command("close", "closed", timeout=10)
            except Failure:
                pass
            panel.close()
        daemon.close()


def keyboard_groups_of(names):
    groups = keyboard_groups()
    return {name: groups.get(name) for name in names}


def main():
    guard()
    repo = os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))
    state_backup = read_state()
    kb_file_was = kb_file_option()
    with LabSession(), PrivateRuntime() as rt:
        packaged_keymap = os.path.join(RUNTIME, "oskar/keymap.xkb")
        packaged_backup = None
        try:
            # The lab's packaged panel stays alive and re-asserts the
            # compositor's kb_file at its own published file; a stale
            # one-group file there would leave the seat unable to carry
            # the groups the toggles move through (the settle leg's
            # reasoning, restart_settle.py). Healed for the leg's lifetime
            # and put back after.
            try:
                with open(packaged_keymap, "rb") as handle:
                    packaged_backup = handle.read()
            except OSError:
                packaged_backup = None
            healed = subprocess.run(
                ["bash", "-c", "xkbcli compile-keymap --layout us,ua,it,ru"
                 f" > {packaged_keymap}"], capture_output=True)
            if healed.returncode != 0 \
                    or len(group_names_in_keymap(packaged_keymap)) < 4:
                raise Failure("could not heal the packaged panel's published "
                              "keymap to the seat's four groups: "
                              + healed.stderr.decode()[:200])
            run(repo, rt)
        finally:
            if state_backup is not None:
                with open(STATE_FILE, "w", encoding="utf-8") as handle:
                    json.dump(state_backup, handle, indent=2)
            if packaged_backup is not None:
                with open(packaged_keymap, "wb") as handle:
                    handle.write(packaged_backup)
            restore_compositor_kb_file(sane_restore_target(kb_file_was),
                                       "the lone toggle leg's teardown")
    restore_service()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as failure:
        print(f"FAIL  lone toggle leg: {failure}")
        sys.exit(1)
