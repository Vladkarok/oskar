#!/usr/bin/env python3
"""A minimal real X11 client for the XWayland leg of the keycap seam.

The native leg types into `foot` running `cat`; an X11 terminal the lab
does not have would be needed for the other half. This maps an ordinary
top-level GTK window through XWayland (GDK_BACKEND=x11) and appends every
key press's translated text to a file, flushing per key — the same
core-protocol key-events path any X11 terminal exercises, with no input
method and no shortcuts between the compositor's keymap and the text.

Run by tools/integration/harness.py's TypingTarget(cls="x11cat").
"""
import locale
import sys

import gi

gi.require_version("Gtk", "3.0")
# Pin Gdk before anything imports it: unpinned, the importer resolves the
# newest Gdk (4.0), and Gtk 3.0's dependency then fails to load.
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402

locale.setlocale(locale.LC_ALL, "")

out_path = sys.argv[1]
out = open(out_path, "w")

# One name everywhere Hyprland looks: WM_CLASS is what `hyprctl clients`
# reports as `class`, and the harness's focus wait matches on it.
Gtk.Window.set_default_icon_name("utilities-terminal")


def on_key_press(_widget, event):
    text = event.string
    if text:
        out.write(text)
        out.flush()
    return False


def on_destroy(_widget):
    Gtk.main_quit()


win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
# Deprecated on purpose: WM_CLASS is the X11 identity, and only the X11
# backend honours it — which is the backend this fixture exists for.
win.set_wmclass("x11cat", "x11cat")
win.set_title("x11cat")
win.set_default_size(400, 120)
win.add_events(Gdk.EventMask.KEY_PRESS_MASK)
win.connect("key-press-event", on_key_press)
win.connect("destroy", on_destroy)
win.show_all()
win.present()

Gtk.main()
