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

import json
import os
import socket
import subprocess
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
        self._stream = self._socket.makefile("rw")

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

    def close(self):
        """Drop the connection, delivering the EOF the helper waits for.

        Both handles have to go: the buffered stream keeps the socket open,
        so closing the socket alone would never reach the helper's read loop
        and the mid-chord disconnect tests would assert nothing.
        """
        self._stream.close()
        self._socket.close()


class Helper:
    """The helper under test: where to reach it, and what it wrote down."""

    def __init__(self, socket_path, log_path):
        self.socket_path = socket_path
        self.log_path = log_path

    def connect(self):
        return Client(self.socket_path)

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
                return
            time.sleep(0.05)
        raise Failure(f"device group never became {wanted} (saw: {self.group()})")

    def expect_layout(self, wanted):
        actual = self.layout()
        if actual != wanted:
            raise Failure(f"device layout is {actual!r}, expected {wanted!r}")


class TypingTarget:
    """A real client with keyboard focus, and the text it actually received.

    The fourth source of truth, and the only one that can see a *modified*
    keystroke: a protocol reply says a key went out, `hyprctl devices` says
    which group the device is in, and neither says what character arrived.
    So a foot terminal runs `cat` into a file and the assertion is on what
    a focused client read — the same thing a human reads off the screen,
    which is where the missing-modifier bug was found by hand.

    Canonical mode is the flush: the terminal hands `cat` a line when RTRN
    is typed, so every expectation below ends with one.
    """

    def __init__(self):
        runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        self.path = os.path.join(runtime, "osk-typed.txt")
        if os.path.exists(self.path):
            os.unlink(self.path)
        self._errors = open(os.path.join(runtime, "osk-typing-target.log"), "w+")
        self._process = subprocess.Popen(
            ["foot", "sh", "-c", f"cat > {self.path}"],
            stdout=subprocess.DEVNULL,
            stderr=self._errors,
        )
        self._wait_for_focus()

    def _wait_for_focus(self):
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
            if window.get("class") == "foot":
                # The window is mapped and focused; the keyboard enter it is
                # about to get is what makes the first keystroke land.
                time.sleep(0.5)
                return
            if self._process.poll() is not None:
                raise Failure(
                    f"foot exited with {self._process.returncode} instead of taking "
                    f"focus: {self._diagnosis()}"
                )
            time.sleep(0.1)
        raise Failure("no focused foot window to type into")

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
        for _ in range(40):
            if self.text() == wanted:
                return
            time.sleep(0.1)
        raise Failure(f"focused client read {self.text()!r}, expected {wanted!r}")

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


def run(socket_path, log_path):
    """Run every registered test in order; return a process exit code.

    The tests share one long-lived helper and build on each other's state —
    the compile count at the end only means anything if everything before it
    ran — so the first failure stops the run.
    """
    helper = Helper(socket_path, log_path)
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
