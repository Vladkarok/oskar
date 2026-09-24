#!/usr/bin/env python3
"""Ticket 50's lab leg: dwell-to-type through the real compositor pointer.

Host-side, like the canary's QMP legs: the pointer only exists as virsh QMP
absolute motion, the panel is the ticket-48 guest frame, and the oracle is
the strace count of protocol `down` lines the helper receives. No button is
ever pressed — every character here comes from a rest.

With dwell on (dwell_enabled true, dwell_delay_ms 800, written into the
lab user's config BEFORE the frame boots — FileView does not see a file
created after load):
  1. a rest on a plain cap types exactly once, and keeps not repeating;
  2. leaving a cap before the delay types nothing;
  3. a rest on a cap with a hold column types once, then opens the column
     menu instead of a second character (grim keeps the proof);
and with dwell off:
  4. the same rest types nothing.

The cap points are per lab output size, like the canary's Q cap.

  OSK_DWELL_LIVE=1 python3 tools/integration/dwell_leg.py
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import panel_canary as pc  # noqa: E402

CONFIG = "~/.config/oskar/config.json"
# Docked, default size preset. PARK is empty band beside the key grid.
POINTS_BY_OUTPUT = {
    (1920, 1080): {"park": (200, 1000), "q": (643, 902), "w": (696, 902),
                   "three": (774, 853)},
}
DELAY_S = 0.8


def move(x, y):
    width, height = pc._screen_size()
    pc._qmp('{"execute":"input-send-event","arguments":{"events":['
            f'{{"type":"abs","data":{{"axis":"x","value":{x * 32767 // width}}}}},'
            f'{{"type":"abs","data":{{"axis":"y","value":{y * 32767 // height}}}}}]}}}}')


def write_config(text):
    subprocess.run(["ssh", pc.GUEST, f"command cat > {CONFIG}"], input=text,
                   text=True, capture_output=True, timeout=30)


def with_dwell(base, enabled):
    import json
    try:
        config = json.loads(base) if base.strip() else {}
    except json.JSONDecodeError:
        raise pc.Failure("the lab's config.json is not JSON; fix it first")
    config.update({"dwell_enabled": enabled, "dwell_delay_ms": 800})
    return json.dumps(config, indent=2) + "\n"


def framed(points, body):
    pc._start_frame(os.environ.get("OSK_CANARY_TREE", "~/oskar"))
    try:
        pc._strace_on(pc._daemon_pid())
        move(*points["park"])
        time.sleep(1.5)
        body()
    finally:
        pc._stop_frame()


def expect(label, got, want):
    if got != want:
        raise pc.Failure(f"{label}: {got} protocol down(s), expected {want}")
    print(f"ok    {label}: {got} down(s)")


def main():
    if os.environ.get("OSK_DWELL_LIVE") != "1":
        raise pc.Failure("set OSK_DWELL_LIVE=1 to drive the lab")
    os.environ["OSK_CANARY_QMP"] = "1"
    if not pc._host_guard():
        return 1
    size = pc._screen_size()
    points = POINTS_BY_OUTPUT.get(size)
    if points is None:
        raise pc.Failure(f"no dwell calibration for a {size[0]}x{size[1]} "
                         "lab output — add one to POINTS_BY_OUTPUT")
    base = pc._guest(f"command cat {CONFIG} 2>/dev/null").stdout
    try:
        write_config(with_dwell(base, True))

        def dwell_on():
            before = pc._strace_presses()
            move(*points["q"])
            time.sleep(DELAY_S + 0.6)
            expect("1 a rest types once", pc._strace_presses() - before, 1)
            time.sleep(1.6)
            expect("1 and does not repeat", pc._strace_presses() - before, 1)
            move(*points["park"])
            time.sleep(1.2)

            before = pc._strace_presses()
            move(*points["w"])
            time.sleep(DELAY_S / 2)
            move(*points["park"])
            time.sleep(1.4)
            expect("2 leaving before the delay types nothing",
                   pc._strace_presses() - before, 0)

            before = pc._strace_presses()
            move(*points["three"])
            time.sleep(DELAY_S + 1.0)
            pc._guest("grim -g '0,779 1892x301' /tmp/osk-dwell-menu.png")
            time.sleep(1.5)
            expect("3 a column cap types once, then opens its menu "
                   "(screenshot: /tmp/osk-dwell-menu.png in the guest)",
                   pc._strace_presses() - before, 1)
            move(*points["park"])

        framed(points, dwell_on)
        write_config(with_dwell(base, False))

        def dwell_off():
            before = pc._strace_presses()
            move(*points["q"])
            time.sleep(2.5)
            expect("4 dwell off: a rest types nothing",
                   pc._strace_presses() - before, 0)
            move(*points["park"])

        framed(points, dwell_off)
        print("ok    DWELL LEG GREEN")
    finally:
        # Back exactly as found: a config that did not exist stays absent.
        if base:
            write_config(base)
        else:
            pc._guest(f"rm -f {CONFIG}")
        pc._guest("sudo -n pkill strace; true")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except pc.Failure as failure:
        print(f"FAIL  dwell leg: {failure}")
        sys.exit(1)
