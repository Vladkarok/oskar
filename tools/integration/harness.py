"""Plumbing for the control-socket integration seam.

The suite next door says what must be true; this says how to find out. It
holds everything that talks to something real — the helper's socket, the
helper's log, the compositor's view of the virtual keyboard — so that
adding an assertion means adding a function to the suite and nothing else.

Three sources of truth, in descending order of how much they prove:

  * the compositor, via `hyprctl devices` — what the helper actually did
  * the protocol replies — what the helper says it did
  * the helper's log — the only window onto work that has no
    client-observable trace, such as whether a keymap was recompiled

Nothing here inspects the helper's internals; that is what the Rust unit
tests are for.
"""

import hashlib
import json
import os
import signal
import shutil
import socket
import subprocess
import sys
import time

# Hyprland names virtual keyboards hl-virtual-keyboard[-<binary>] depending on
# misc:name_vk_after_proc, so match the protocol prefix rather than the process
# name. The nested session has no other virtual keyboard to collide with.
DEVICE_PREFIX = "hl-virtual-keyboard"

# Each compile the helper performs writes one of these.
COMPILE_MARK = "keymap compiled for"


class Failure(Exception):
    """An assertion the run cannot continue past."""


class Client:
    """One connection to the control socket, the way the panel keeps one.

    A claim on a key code belongs to the connection that made it, so tests
    about claims open more than one of these.
    """

    def __init__(self, path):
        self._socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._socket.settimeout(10)
        for attempt in range(50):
            try:
                self._socket.connect(path)
                break
            except ConnectionRefusedError:
                if attempt == 49:
                    raise
                time.sleep(0.05)
        # UTF-8 on purpose, independent of the guest's locale: the `text`
        # command's payload is the user's string (ticket 24), and a TextIOWrapper
        # left at the locale default would encode emoji as ASCII or die trying
        # on a C-locale guest.
        self._stream = self._socket.makefile("rw", encoding="utf-8")

    def send(self, command):
        """Write one protocol line, return the helper's reply."""
        self._stream.write(command + "\n")
        self._stream.flush()
        return self._stream.readline().strip()

    def expect(self, command, reply):
        """Send a line and require an exact reply."""
        actual = self.send(command)
        if actual != reply:
            raise Failure(f"{command!r}: expected {reply!r}, got {actual!r}")

    def configure(self, payload):
        """Send a configure, return the keymap generation it installed.

        Since protocol 4 the reply names the helper's install generation —
        the fact the panel correlates keycap replies against, so most tests
        capture and compare it rather than assert a literal.
        """
        reply = self.send(payload)
        if not reply.startswith("configured\t"):
            raise Failure(f"{payload!r}: expected configured<TAB><gen>, got {reply!r}")
        try:
            return int(reply.split("\t")[1])
        except (IndexError, ValueError):
            raise Failure(f"configured reply without a generation: {reply!r}")

    def caps(self, group, positions=()):
        """Request keycap facts for one group, decoded (decisions \u00a723)."""
        line = f"caps {group}"
        if positions:
            line += " " + " ".join(positions)
        return parse_caps_reply(self.send(line))

    def write_unread(self, command):
        """Write one protocol line without waiting for its reply.

        The panel's unready window in its raw socket shape: a configure has
        gone out and the panel treats itself as not ready until it has read
        `configured`. A test that models a release sent from inside that
        window needs the write to not consume the reply first — the replies
        stay queued in order for read_reply.
        """
        self._stream.write(command + "\n")
        self._stream.flush()

    def read_reply(self):
        """Read one reply the helper already owes this connection."""
        return self._stream.readline().strip()

    def close(self):
        """Drop the connection, delivering the EOF the helper waits for.

        Both handles have to go: the buffered stream keeps the socket open,
        so closing the socket alone would never reach the helper's read loop
        and the mid-chord disconnect tests would assert nothing.
        """
        self._stream.close()
        self._socket.close()


def parse_caps_reply(reply):
    """Decode a `caps` reply into {gen, group, by_position}, or raise.

    Each record is a position name plus one field per level: `t<text>` for
    drawable text, `x<keysym>` for a symbol that produces no character, `n`
    for no symbol at all. A bare record (no level fields) is a position the
    keymap does not carry.
    """
    parts = reply.split("\t")
    if len(parts) < 4 or parts[0] != "caps":
        raise Failure(f"not a caps reply: {reply!r}")
    try:
        gen, group = int(parts[1]), int(parts[2])
    except ValueError:
        raise Failure(f"bad generation/group in caps reply: {reply!r}")
    by_position = {}
    for record in "\t".join(parts[3:]).split("\x1e"):
        if not record:
            continue
        fields = record.split("\x1f")
        levels = []
        for field in fields[1:]:
            tag, rest = field[:1], field[1:]
            if tag == "t":
                levels.append({"text": rest})
            elif tag == "n":
                levels.append({"none": ""})
            elif tag == "x":
                levels.append({"none": rest})
            else:
                raise Failure(f"unknown caps field tag {field!r} in {reply!r}")
        by_position[fields[0]] = levels
    return {"gen": gen, "group": group, "by_position": by_position}


class Helper:
    """The helper under test: where to reach it, and what it wrote down."""

    def __init__(self, socket_path, log_path, pid=None):
        self.socket_path = socket_path
        self.log_path = log_path
        self.pid = pid

    def connect(self):
        return Client(self.socket_path)

    def terminate(self, timeout=5.0):
        """Stop the helper the way `systemctl stop` does, and wait for it.

        SIGTERM rather than SIGKILL on purpose: the shutdown release is what
        is under test, and SIGKILL is by definition unhandleable — a helper
        killed outright still strands whatever it holds, and no code can
        change that.
        """
        if self.pid is None:
            raise Failure("the helper's pid was not passed to the suite")
        os.kill(self.pid, signal.SIGTERM)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                os.kill(self.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        raise Failure(f"helper {self.pid} did not exit within {timeout}s of SIGTERM")

    def log(self):
        with open(self.log_path, encoding="utf-8", errors="replace") as handle:
            return handle.read()

    def expect_log(self, needle):
        if needle not in self.log():
            raise Failure(f"helper log never mentioned {needle!r}")

    def expect_no_log(self, needle):
        if needle in self.log():
            raise Failure(f"helper log mentioned {needle!r} and should not have")

    def compiles(self):
        """How many keymaps the helper has compiled since it started."""
        return self.log().count(COMPILE_MARK)

    def expect_compiles(self, wanted):
        actual = self.compiles()
        if actual != wanted:
            raise Failure(f"expected {wanted} keymap compiles, saw {actual}")


class VirtualKeyboard:
    """The compositor's view of the device the helper owns."""

    def _device(self):
        out = subprocess.run(
            ["hyprctl", "devices", "-j"], capture_output=True, text=True
        ).stdout
        for keyboard in json.loads(out)["keyboards"]:
            if DEVICE_PREFIX in keyboard["name"]:
                return keyboard
        raise Failure(f"no keyboard named {DEVICE_PREFIX}* on the compositor")

    def group(self):
        return self._device()["active_layout_index"]

    def layout(self):
        return self._device()["layout"]

    def expect_group(self, wanted):
        """Wait for the device to reach a group, then require it.

        The modifiers event crosses the compositor asynchronously, so this
        retries rather than reading once.
        """
        for _ in range(40):
            if str(self.group()) == str(wanted):
                if os.environ.get("OSK_DEBUG_LAYOUT"):
                    print(
                        f".... group {wanted} ok; device layout now "
                        f"{self.layout()!r}",
                        flush=True,
                    )
                return
            time.sleep(0.05)
        raise Failure(f"device group never became {wanted} (saw: {self.group()})")

    def expect_layout(self, wanted):
        actual = self.layout()
        if actual != wanted:
            # The whole devices list, not just the verdict: which keymap the
            # device last received is exactly the question here.
            import json as _json
            raise Failure(
                f"device layout is {actual!r}, expected {wanted!r}; devices: "
                + _json.dumps(
                    [k | {"keymap": k.get("keymap", "")} for k in self._all_keyboards()],
                    default=str,
                )[:600]
            )

    def _all_keyboards(self):
        out = subprocess.run(
            ["hyprctl", "devices", "-j"], capture_output=True, text=True
        ).stdout
        return [
            {k: kb.get(k) for k in ("name", "layout", "active_layout_index", "main")}
            for kb in json.loads(out)["keyboards"]
        ]


def share_published_keymap():
    """Point the nested compositor at the helper's published keymap (§35).

    The real panel performs these two public compositor calls after each new
    helper generation.  There is no panel in this suite, so the consumer
    regressions cross that same boundary themselves rather than inspecting
    either implementation's state.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    path = os.path.join(runtime, "omarchy-osk", "keymap.xkb")
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        raise Failure(f"helper did not publish a keymap at {path!r}")
    for value in ("", path):
        expression = f"hl.config({{input = {{kb_file = '{value}'}}}})"
        proc = subprocess.run(
            ["hyprctl", "eval", expression], capture_output=True, text=True
        )
        if proc.returncode != 0 or "error" in proc.stdout.lower():
            raise Failure(
                f"compositor refused input:kb_file = {value!r}: "
                f"{(proc.stdout + proc.stderr).strip()!r}"
            )
    for _ in range(80):
        proc = subprocess.run(
            ["hyprctl", "getoption", "input:kb_file", "-j"],
            capture_output=True,
            text=True,
        )
        try:
            if json.loads(proc.stdout).get("str") == path:
                return path
        except json.JSONDecodeError:
            pass
        time.sleep(0.05)
    raise Failure(f"compositor never selected the published keymap {path!r}")


def published_keymap_is_live():
    """The compositor still names the helper's published keymap (§35).

    A leg that only READS the seat must not re-point it: every clear/set of
    `input:kb_file` costs the compositor a keymap identity change, which is
    the nested-session churn ceiling's currency. Legs that need it set call
    `share_published_keymap`; legs that only need it to still be set assert
    through here.
    """
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    path = os.path.join(runtime, "omarchy-osk", "keymap.xkb")
    proc = subprocess.run(
        ["hyprctl", "getoption", "input:kb_file", "-j"],
        capture_output=True,
        text=True,
    )
    try:
        if json.loads(proc.stdout).get("str") == path:
            return path
    except json.JSONDecodeError:
        pass
    raise Failure(
        f"input:kb_file no longer names the published keymap {path!r}: "
        f"{proc.stdout.strip()[:200]!r}"
    )


def focus_toward(wanted, before, x_by_address):
    """One verified focus move, the §35 leg's method.

    Hyprland's directional focus dispatch between two known windows, with
    the move confirmed against `activewindow` before the caller proceeds —
    an unverified dispatch would leave the next assertion reading whatever
    window happened to be focused.
    """
    direction = (
        "left" if x_by_address[wanted] < x_by_address.get(before, 0) else "right"
    )
    dispatched = subprocess.run(
        ["hyprctl", "dispatch", f"hl.dsp.focus({{ direction = '{direction}' }})"],
        capture_output=True,
        text=True,
    )
    if dispatched.returncode != 0 or "ok" not in dispatched.stdout.lower():
        raise Failure(
            f"focus dispatch {direction} toward {wanted} was refused: "
            f"{(dispatched.stdout + dispatched.stderr).strip()!r}"
        )
    for _ in range(60):
        now_raw = subprocess.run(
            ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
        ).stdout
        try:
            now = json.loads(now_raw)
        except json.JSONDecodeError:
            now = {}
        if now.get("address") == wanted and wanted != before:
            return now
        time.sleep(0.05)
    raise Failure(
        f"focus never moved {direction} from {before} to {wanted}; "
        f"compositor last answered: {now_raw.strip()[:200]!r}"
    )


def window_addresses():
    """{address: x} for every mapped window, for focus_toward's directions."""
    raw = subprocess.run(
        ["hyprctl", "clients", "-j"], capture_output=True, text=True
    ).stdout
    try:
        windows = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    return {
        window.get("address"): (window.get("at") or [0])[0] for window in windows
    }


def _active_window():
    proc = subprocess.run(
        ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
    )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {}


class ElectronTarget:
    """Native-Wayland Electron recorder for the Chromium DomCode path."""

    marker = "OSK-ELECTRON|"

    def __init__(self, debug_log=None):
        fixture = os.path.join(os.path.dirname(__file__), "electron")
        if not shutil.which("electron43"):
            raise Failure("electron43 is required for the native-Wayland regression")
        env = dict(os.environ)
        if debug_log:
            env["WAYLAND_DEBUG"] = "client"
        self._errors = open(
            debug_log or os.path.join(env["XDG_RUNTIME_DIR"], "osk-electron.log"),
            "w+",
        )
        self._process = subprocess.Popen(
            [
                "electron43",
                "--no-sandbox",
                "--disable-gpu",
                "--ozone-platform=wayland",
                fixture,
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=self._errors,
        )
        self._wait_ready()
        self.last = self.title()

    def _wait_ready(self):
        for _ in range(360):
            if self.title().startswith(self.marker + "ready"):
                time.sleep(1)
                return
            if self._process.poll() is not None:
                self._errors.flush()
                self._errors.seek(0)
                raise Failure(
                    f"Electron exited with {self._process.returncode}: "
                    f"{self._errors.read().strip()[-1000:]!r}"
                )
            time.sleep(0.25)
        raise Failure(f"Electron never published its ready title; active={_active_window()}")

    def title(self):
        proc = subprocess.run(
            ["hyprctl", "clients", "-j"], capture_output=True, text=True
        )
        try:
            clients = json.loads(proc.stdout)
        except json.JSONDecodeError:
            return ""
        for client in clients:
            title = str(client.get("title", ""))
            if title.startswith(self.marker):
                return title
        return ""

    def delta(self, expect_event=True):
        deadline = time.monotonic() + (4 if expect_event else 1)
        while time.monotonic() < deadline:
            current = self.title()
            if len(current) > len(self.last):
                delta = current[len(self.last):]
                self.last = current
                return delta
            time.sleep(0.05)
        return ""

    def close(self):
        self._process.terminate()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()
        self._errors.close()


class KeymapObserver:
    """Focused Wayland client exposing keymap payload IDs and xkb state."""

    def __init__(self):
        binary = os.environ.get("OSK_KEYMAP_OBSERVER", "")
        if not binary or not os.path.isfile(binary):
            raise Failure("OSK_KEYMAP_OBSERVER is not a built observer binary")
        self.path = os.path.join(
            os.environ["XDG_RUNTIME_DIR"], "osk-keymap-observer.log"
        )
        self._log = open(self.path, "w+")
        env = dict(os.environ, WAYLAND_DEBUG="client")
        self._process = subprocess.Popen(
            [binary], env=env, stdout=self._log, stderr=self._log
        )
        self.expect("READY", timeout=20)

    def text(self):
        self._log.flush()
        with open(self.path, encoding="utf-8", errors="replace") as handle:
            return handle.read()

    def expect(self, needle, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if needle in self.text():
                return
            if self._process.poll() is not None:
                raise Failure(
                    f"keymap observer exited with {self._process.returncode}: "
                    f"{self.text()[-1200:]!r}"
                )
            time.sleep(0.05)
        raise Failure(
            f"keymap observer never reported {needle!r}: {self.text()[-1200:]!r}"
        )

    def close(self):
        self._process.terminate()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()
        self._log.close()


class Clipboard:
    """The nested seat's clipboard, observed through wl-clipboard.

    Ticket 24's negative half: a pick must type, never paste (decisions §26
    and the reverse clause the ticket adds). The seat is seeded on purpose —
    an empty clipboard cannot distinguish "unchanged" from "there was
    nothing to read" — and the seeded offer is held by a foreground wl-copy
    this class owns, so the observation has exactly one lifecycle to clean
    up and cannot be mistaken for the live session's clipboard: it binds to
    whatever WAYLAND_DISPLAY the suite runs under, which is the nested
    compositor's.
    """

    def __init__(self, seed):
        if not (shutil.which("wl-copy") and shutil.which("wl-paste")):
            raise Failure(
                "wl-copy and wl-paste are required to observe the seat "
                "clipboard; without them a pick's clipboard behaviour "
                "cannot be asserted and must not be faked"
            )
        self._process = subprocess.Popen(
            ["wl-copy", "--foreground", seed],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # wl-copy turns its command-line text into a line — this guest serves
        # the seed with a trailing newline whatever --trim-newline claims —
        # so the seeding check accepts the seed as served, and the digest
        # that the pick must not move is over the bytes wl-paste actually
        # serves, never over the seed string.
        deadline = time.monotonic() + 5
        served = b""
        while time.monotonic() < deadline:
            try:
                served = self.read()
            except Failure:
                # wl-paste exits nonzero while nothing has been copied yet,
                # so the first reads race the seeding; keep polling rather
                # than declaring the seat unreadable.
                served = b""
            if served in (seed.encode(), seed.encode() + b"\n"):
                self.seed_digest = hashlib.sha256(served).hexdigest()
                return
            time.sleep(0.05)
        alive = self._process.poll() is None
        self.close()
        raise Failure(
            "the seeded clipboard never became readable via wl-paste; "
            f"wl-copy alive={alive}, wl-paste served {served!r}"
        )

    def read(self):
        """What wl-paste currently serves, or raise."""
        proc = subprocess.run(["wl-paste"], capture_output=True)
        if proc.returncode != 0:
            raise Failure(
                "wl-paste could not read the seat clipboard: "
                f"{proc.stderr.decode(errors='replace').strip()!r}"
            )
        return proc.stdout

    def digest(self):
        return hashlib.sha256(self.read()).hexdigest()

    def expect_unchanged(self, note):
        """Require the seat clipboard still to serve exactly the seed."""
        current = self.digest()
        if current != self.seed_digest:
            raise Failure(
                f"the seat clipboard changed {note}: sha256 "
                f"{self.seed_digest} -> {current}"
            )
        return current

    def close(self):
        self._process.terminate()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()


class TypingTarget:
    """A real client with keyboard focus, and the text it actually received.

    The fourth source of truth, and the only one that can see a *modified*
    keystroke: a protocol reply says a key went out, `hyprctl devices` says
    which group the device is in, and neither says what character arrived.
    So a terminal runs `cat` into a file and the assertion is on what a
    focused client read — the same thing a human reads off the screen,
    which is where the missing-modifier bug was found by hand.

    Canonical mode is the flush: the terminal hands `cat` a line when RTRN
    is typed, so every expectation below ends with one.

    `cls` picks the client: `foot` is native Wayland; `x11cat` is the
    bundled GTK fixture (x11cat.py) mapped through XWayland, so typing into
    it exercises the X11 path end to end — the path that dropped
    per-keystroke helper processes entirely (decisions \u00a71). A real
    X11 window with real WM_CLASS and real core key events, only smaller
    than a terminal.
    """

    def __init__(self, cls="foot"):
        self.cls = cls
        runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        self.path = os.path.join(runtime, "osk-typed.txt")
        if os.path.exists(self.path):
            os.unlink(self.path)
        self._errors = open(os.path.join(runtime, "osk-typing-target.log"), "w+")
        # The nested compositor publishes its output some time after it
        # accepts clients, and foot refuses to start without one ("no monitors
        # available"). Every test before this one talks to the helper alone
        # and never noticed. Wait for the monitor, then retry the terminal a
        # few times anyway, so a compositor still settling does not read as a
        # modifier regression.
        self._wait_for_monitor()
        self._process = None
        for attempt in range(5):
            if attempt:
                time.sleep(2)
            if cls == "x11cat":
                # GDK_BACKEND=x11 is the whole point: the same GTK would
                # otherwise take the Wayland path and prove nothing here.
                # The display comes from nested-session.sh, which identifies
                # the X socket ITS compositor created — guessing :0 would map
                # the client onto the live session's XWayland instead.
                xdisplay = os.environ.get("OSK_NEST_XDISPLAY", "")
                if not xdisplay:
                    raise Failure(
                        "no nested XWayland display was identified; refusing "
                        "to guess an X display (a guess lands on the live "
                        "session)"
                    )
                env = dict(os.environ, GDK_BACKEND="x11", DISPLAY=xdisplay)
                env.pop("WAYLAND_DISPLAY", None)
                self._process = subprocess.Popen(
                    [sys.executable,
                     os.path.join(os.path.dirname(__file__), "x11cat.py"),
                     self.path],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=self._errors,
                )
            else:
                self._process = subprocess.Popen(
                    ["foot", "sh", "-c", f"cat > {self.path}"],
                    stdout=subprocess.DEVNULL,
                    stderr=self._errors,
                )
            if self._wait_for_focus(last=attempt == 4):
                return

    def _wait_for_monitor(self):
        for _ in range(150):
            out = subprocess.run(
                ["hyprctl", "monitors", "-j"], capture_output=True, text=True
            ).stdout
            try:
                if json.loads(out):
                    return
            except json.JSONDecodeError:
                pass
            time.sleep(0.2)
        raise Failure("the nested compositor never published a monitor")

    def _wait_for_focus(self, last):
        """True once a foot window has focus; False if this attempt died."""
        # Generous: a cold foot in a nested compositor has been seen taking
        # several seconds to map, and a timeout here reads as a failure of
        # whatever was being typed.
        for _ in range(300):
            out = subprocess.run(
                ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
            ).stdout
            try:
                window = json.loads(out)
            except json.JSONDecodeError:
                window = {}
            if window.get("class") == self.cls:
                # The window is mapped and focused; the keyboard enter it is
                # about to get is what makes the first keystroke land. The
                # settle is generous because the host this runs on is shared
                # and busy: a mapped-and-named foot has been seen taking
                # seconds to actually receive its keyboard enter, and a
                # keystroke sent before it is dropped on the compositor
                # floor — an empty client file that reads as a product bug.
                time.sleep(2)
                return True
            if self._process.poll() is not None:
                if not last:
                    return False
                raise Failure(
                    f"foot exited with {self._process.returncode} instead of taking "
                    f"focus: {self._diagnosis()}"
                )
            time.sleep(0.1)
        raise Failure(
            "no focused foot window to type into; the compositor last "
            f"answered: {out.strip()[:200]!r}"
        )

    def _diagnosis(self):
        self._errors.flush()
        self._errors.seek(0)
        return self._errors.read().strip() or "it printed nothing"

    def text(self):
        try:
            with open(self.path, encoding="utf-8", errors="replace") as handle:
                return handle.read()
        except FileNotFoundError:
            return ""

    def expect_text(self, wanted):
        """Wait for the client's text to reach `wanted`, then require it."""
        for _ in range(120):
            if self.text() == wanted:
                return
            time.sleep(0.25)
        # Evidence with the verdict: what the compositor thought was focused
        # and what keymaps its keyboards carry at that moment.
        active = subprocess.run(
            ["hyprctl", "activewindow", "-j"], capture_output=True, text=True
        ).stdout
        devs = subprocess.run(
            ["hyprctl", "devices", "-j"], capture_output=True, text=True
        ).stdout
        keymaps = []
        try:
            keymaps = [
                {k: kb.get(k) for k in ("name", "layout", "active_layout_index", "active_keymap", "main")}
                for kb in json.loads(devs)["keyboards"]
            ]
        except (json.JSONDecodeError, KeyError):
            pass
        raise Failure(
            f"focused client read {self.text()!r}, expected {wanted!r}; "
            f"activewindow: {active.strip()[:300]!r}; keyboards: {keymaps}"
        )

    def close(self):
        self._process.terminate()
        try:
            self._process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._process.kill()
        self._errors.close()
        if os.path.exists(self.path):
            os.unlink(self.path)


_TESTS = []


def test(name):
    """Register a suite entry. Order is significant — see run()."""

    def register(body):
        _TESTS.append((name, body))
        return body

    return register


def run(socket_path, log_path, pid=None):
    """Run every registered test in order; return a process exit code.

    The tests share one long-lived helper and build on each other's state —
    the compile count at the end only means anything if everything before it
    ran — so the first failure stops the run.
    """
    helper = Helper(socket_path, log_path, pid)
    keyboard = VirtualKeyboard()
    for name, body in _TESTS:
        try:
            body(helper, keyboard)
        except Failure as failure:
            print(f"FAIL  {name}: {failure}")
            return 1
        print(f"ok    {name}")
    print(f"{len(_TESTS)} passed")
    return 0
