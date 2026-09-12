#!/usr/bin/env python3
"""Levels 5-8 probe driver (ticket 20, first task).

Runs one leg against a focused client inside the nested session:

  wayland  Chromium on Ozone/Wayland — the stack Electron ships, the one
           whose DomCode table dropped the reserved block's keycodes.
  x11      Chromium on Ozone/X11 through the nested XWayland.
  foot     a native Wayland terminal that resolves keysyms itself — the
           discriminator: if foot receives a glyph the chromium leg does
           not, the failure is inside the client, not on the way in.

Chromium legs read keydowns off the window title (probe-way.html /
probe-x11.html): every keydown appends one token `key·code`. foot reads
what `cat` flushes to a file, one newline per step. Every leg starts with a
control key — an ordinary letter whose arrival proves the probe is actually
receiving — and gives NO verdict if it does not land, so an unfocused
window cannot read as a finding (the trap that produced fourteen false
negatives on 2026-09-08).

The chords press positions, exactly the way the panel does: LVL5 for the
level-5 modifier, LVL3 for level three, LFSH for Shift, around a tap of the
key under test. The negative step taps I219 — a keycode ticket 20 measured
as dropped by Chromium's DomCode table; on chromium it must type nothing,
while on foot it is EXPECTED to type a character, because foot resolves
keysyms itself and is exactly the kind of test that cannot catch a drop.
"""

import json
import os
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
PROBE_DIR = f"{HOME}/lvl5-probe"
KEYMAP = f"{PROBE_DIR}/lvl5-probe.keymap"
LEG = sys.argv[1] if len(sys.argv) > 1 else "wayland"

MARKERS = {"wayland": "PROBE-WAY|", "x11": "PROBE-X11|"}
# the page files; the wayland tag does not spell its file name
PAGES = {"wayland": "probe-way.html", "x11": "probe-x11.html"}

# position -> (level 1, level 2, level 5, level 6, level 7, level 8),
# mirrored from make_keymap.py.
CHARS = {
    "AD01": ("q", "Q", "£", "¡", "á", "â"),
    "AD10": ("p", "P", "≠", "²", "å", "ù"),
    "AE01": ("1", "!", "¤", "¦", "§", "¨"),
}


def say(msg):
    print(msg, flush=True)


def hyprctl_json(*args):
    proc = subprocess.run(["hyprctl", *args], capture_output=True, text=True)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}


def wait_monitor(timeout=30):
    for _ in range(int(timeout / 0.5)):
        if hyprctl_json("monitors", "-j"):
            return True
        time.sleep(0.5)
    return False


def kill_old_probes(tag):
    subprocess.run(["pkill", "-f", f"user-data-dir=/tmp/chromeprobe-{tag}"],
                   capture_output=True)
    time.sleep(1.0)
    # a killed chromium leaves the profile's process-singleton lock behind;
    # a new chromium against a live lock hands off and exits instead of
    # opening the probe page
    for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        try:
            os.unlink(f"/tmp/chromeprobe-{tag}/{name}")
        except FileNotFoundError:
            pass


def launch_chromium(tag):
    """Maps one probe window; returns a probe handle, or None to skip.

    The wayland leg runs Electron 43 (`electron43`, the same content shell
    the ticket's consumer is built on) — plain Chromium 152 cannot composite
    a frame in the nested VM session under any flag combination tried (maps
    its window, runs the page JS, rejects every input event), while Electron
    is what ticket 20 actually has to satisfy. Launches through
    `setsid nohup … & disown`, the shape the handoff's probe recipe
    prescribes; the plain Popen shape left a focused chromium-class window
    that never published the probe title, twice.
    """
    if tag == "wayland":
        argv = ("electron43 --no-sandbox --disable-gpu "
                "--ozone-platform=wayland "
                f"{PROBE_DIR}/electron")
        # Electron derives its wm_class from the app name
        want = "lvl5-probe"
    else:
        argv = (f"chromium --user-data-dir=/tmp/chromeprobe-{tag} --no-first-run "
                "--no-default-browser-check --ozone-platform=x11")
        want = "chrom"
        xdisplay = os.environ.get("OSK_NEST_XDISPLAY", "")
        if not xdisplay:
            say("SKIP  x11 leg: no nested XWayland display was identified")
            return None
        argv = f"env DISPLAY={xdisplay} WAYLAND_DISPLAY= {argv} 'file://{PROBE_DIR}/{PAGES[tag]}'"
    inner = (f"setsid nohup {argv} >/tmp/probe-{tag}.log 2>&1 & disown")
    subprocess.Popen(["bash", "-c", inner], start_new_session=True)
    return want


def wait_focus(want, timeout=90):
    for _ in range(int(timeout / 0.25)):
        window = hyprctl_json("activewindow", "-j")
        if want.lower() in str(window.get("class", "")).lower():
            time.sleep(2)  # keyboard-enter settle, the suite's pacing
            return True
        time.sleep(0.25)
    return False


def title_of(marker):
    for client in hyprctl_json("clients", "-j"):
        if str(client.get("title", "")).startswith(marker):
            return str(client["title"])
    return ""


def dump_windows():
    """Every mapped window's class and title — what an abort sees instead of
    the window it expected."""
    for client in hyprctl_json("clients", "-j"):
        say(f".... window class={client.get('class')!r} "
            f"title={client.get('title')!r}")


class Helper:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.stream = self.sock.makefile("rw")

    def send(self, line):
        self.stream.write(line + "\n")
        self.stream.flush()
        return self.stream.readline().strip()


def configure(helper):
    reply = helper.send(f"configure\tevdev\tpc105\tus\t\t\t{KEYMAP}\t0")
    if not reply.startswith("configured\t"):
        say(f"ABORT configure: {reply!r}")
        sys.exit(2)
    say(f".... configure: {reply}")

    positions = " ".join(CHARS)
    caps = helper.send(f"caps 1 {positions}")
    if caps.startswith("err"):
        caps = helper.send(f"caps 0 {positions}")
    if not caps.startswith("caps\t"):
        say(f"WARN caps unavailable: {caps!r} — typing evidence still rules")
        return
    problems = []
    for record in "\t".join(caps.split("\t")[3:]).split("\x1e"):
        if not record:
            continue
        fields = record.split("\x1f")
        pos = fields[0]
        want = CHARS.get(pos)
        if want is None:
            continue
        texts = [f[1:] for f in fields[1:] if f[:1] == "t"]
        # fields[1..8] are levels 1..8; levels 5-8 are the last four
        got = (texts + [""] * 8)[4:8]
        if got != list(want[2:]):
            problems.append(f"{pos}: levels 5-8 are {got}, "
                            f"expected {list(want[2:])}")
    if problems:
        say("WARN keymap facts disagree with the probe design "
            "(typing evidence below still rules):")
        for p in problems:
            say(f"      {p}")
    else:
        say(".... caps: levels 5-8 of every probed position carry the probe glyphs")


def needle_for(char):
    return f"{char}\u00b7" if LEG in MARKERS else char


def build_steps():
    """(name, commands, needle-or-None, kind) — kind: char | nochar | info."""
    steps = [
        ("control z (AB01)", ["tap AB01"], needle_for("z"), "char"),
        ("negative: I219", ["tap I219"], None, "nochar"),
        ("level 5  LVL5 + AD01", ["down LVL5", "tap AD01", "up LVL5"],
         needle_for("£"), "char"),
        ("level 6  Shift+LVL5 + AD01", ["down LVL5", "down LFSH", "tap AD01",
                                        "up LFSH", "up LVL5"],
         needle_for("¡"), "char"),
        ("level 7  LVL3+LVL5 + AD01", ["down LVL5", "down LVL3", "tap AD01",
                                       "up LVL3", "up LVL5"],
         needle_for("á"), "char"),
        ("level 8  Shift+LVL3+LVL5 + AD01", ["down LVL5", "down LVL3", "down LFSH",
                                             "tap AD01", "up LFSH", "up LVL3",
                                             "up LVL5"],
         needle_for("â"), "char"),
        ("level 5  LVL5 + AD10", ["down LVL5", "tap AD10", "up LVL5"],
         needle_for("≠"), "char"),
        ("level 5  LVL5 + AE01", ["down LVL5", "tap AE01", "up LVL5"],
         needle_for("¤"), "char"),
        ("stock 1  AD01", ["tap AD01"], needle_for("q"), "char"),
        ("stock 2  Shift + AD01", ["down LFSH", "tap AD01", "up LFSH"],
         needle_for("Q"), "char"),
        ("stock 3  LVL3 + AD01 stays q", ["down LVL3", "tap AD01", "up LVL3"],
         needle_for("q"), "char"),
        ("stock 4  Shift+LVL3 + AD01 stays Q", ["down LVL3", "down LFSH",
                                                "tap AD01", "up LFSH", "up LVL3"],
         needle_for("Q"), "char"),
    ]
    return steps


def run_steps(helper, reader):
    """Runs the battery; returns (verdicts, control_ok). reader() -> delta."""
    verdicts = []
    control_ok = None
    for name, commands, needle, kind in build_steps():
        aborted = False
        for command in commands:
            reply = helper.send(command)
            if reply != "ok":
                say(f"ABORT {command!r}: {reply!r}")
                aborted = True
                break
            time.sleep(0.06)
        if aborted:
            return verdicts, False
        delta = reader()
        if kind == "char":
            ok = needle in delta
        elif kind == "nochar" and LEG not in MARKERS:
            # foot resolves keysyms itself: I219 typing there is the known
            # blind spot ticket 20 records, not a finding — record, don't fail
            ok, kind = True, "info"
        else:
            singles = [tok.split("\u00b7")[0] for tok in delta.split()
                       if "\u00b7" in tok and len(tok.split("\u00b7")[0]) == 1]
            ok = not singles
        if name.startswith("control"):
            control_ok = ok
        mark = "PASS" if ok else "FAIL"
        say(f"{mark}  [{LEG}] {name} — got {delta.strip()!r}")
        verdicts.append((name, ok, delta.strip()))
    return verdicts, bool(control_ok)


class TitleReader:
    """Diffs the probe window's title between calls.

    Init waits for the title to appear and then to stay unchanged for a
    moment, so the browser's ` - Chromium` suffix and any early keydowns are
    inside the baseline rather than the first delta. A cold chromium in this
    VM has taken well over ten seconds to publish its first title, so the
    appearance wait is generous.
    """

    def __init__(self, marker):
        self.marker = marker
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            self.last = title_of(marker)
            if self.last:
                break
            time.sleep(0.25)
        else:
            dump_windows()
            raise SystemExit(f"ABORT: no window titled {marker!r} is mapped")
        # stabilise: the suffix and page load land after the first title
        stable_since = time.monotonic()
        while time.monotonic() < deadline:
            current = title_of(self.marker)
            now = time.monotonic()
            if current != self.last:
                self.last = current
                stable_since = now
            elif now - stable_since > 0.8:
                return
            time.sleep(0.1)

    def __call__(self):
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            current = title_of(self.marker)
            if len(current) > len(self.last):
                delta = current[len(self.last):]
                self.last = current
                return delta
            time.sleep(0.1)
        return ""


class FootReader:
    """Reads what foot's `cat` flushed; a newline per step."""

    def __init__(self, path, helper):
        self.path = path
        self.helper = helper
        self.last = self._read()

    def _read(self):
        try:
            with open(self.path, encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except FileNotFoundError:
            return ""

    def __call__(self):
        self.helper.send("tap RTRN")  # flush the step's line through cat
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            current = self._read()
            if len(current) > len(self.last):
                delta = current[len(self.last):]
                self.last = current
                return delta
            time.sleep(0.1)
        return ""


def main():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    if os.environ.get("OSK_NESTED_SESSION", "") != "1" or not runtime:
        sys.exit("Run this under tools/nested-session.sh inside omarchy-vm.")
    if not wait_monitor():
        say("ABORT: nested compositor never published a monitor (known VM "
            "flake — re-run before believing a failure)")
        sys.exit(42)

    helper = Helper(os.path.join(runtime, "omarchy-osk/control.sock"))
    say(f".... helper: {helper.send('hello 5')}")
    configure(helper)

    if LEG == "foot":
        path = os.path.join(runtime, "osk-lvl5-foot.txt")
        if os.path.exists(path):
            os.unlink(path)
        proc = subprocess.Popen(["foot", "sh", "-c", f"cat > {path}"],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL)
        if not wait_focus("foot", timeout=60):
            proc.kill()
            say("ABORT  [foot] foot never took focus")
            sys.exit(4)
        verdicts, control_ok = run_steps(helper, FootReader(path, helper))
        proc.terminate()
    else:
        kill_old_probes(LEG)
        if LEG == "wayland":
            subprocess.run(["pkill", "-f", "lvl5-probe/electron"],
                           capture_output=True)
        launched = launch_chromium(LEG)
        if launched is None:
            sys.exit(3)
        if not wait_focus(launched):
            dump_windows()
            say(f"ABORT  [{LEG}] chromium never took focus; "
                f"/tmp/chromeprobe-{LEG}.log follows")
            sys.exit(4)
        # the owner's hand-run probe clicked into the page; a synthetic run
        # has no click, and a focused window whose web contents were never
        # activated swallows every keydown — wake it with a Tab and verify
        # the page is actually receiving before the battery starts
        subprocess.run(["hyprctl", "dispatch", "focuswindow",
                        f"class:{launched}"], capture_output=True)
        time.sleep(1)
        helper.send("tap TAB")
        time.sleep(0.5)
        reader = TitleReader(MARKERS[LEG])
        verdicts, control_ok = run_steps(helper, reader)
        # owner-facing evidence: what the probe window looked like afterwards
        subprocess.run(["grim", f"{PROBE_DIR}/shot-{LEG}.png"],
                       capture_output=True)
        kill_old_probes(LEG)

    lines = []
    if not control_ok:
        lines.append(f"NO VERDICT — the control key never arrived; the probe "
                     f"was not receiving ({LEG})")
    else:
        passed = sum(1 for _, ok, _ in verdicts if ok)
        for name, ok, note in verdicts:
            lines.append(f"{'PASS' if ok else 'FAIL'}  {name} — {note!r}")
        lines.append(f"{passed}/{len(verdicts)} steps passed ({LEG})")
    result = f"{PROBE_DIR}/result-{LEG}.txt"
    with open(result, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    sys.exit(0 if (control_ok and all(ok for _, ok, _ in verdicts)) else 1)


if __name__ == "__main__":
    main()
