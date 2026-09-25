#!/usr/bin/env python3
"""A scripted stand-in for the helper: protocol 7 on the control socket,
with transport faults injected on command.

The panel's transport (HelperLink.qml, SocketWatch.js, ChordAcks.js) is
judged by what a peer does to it: answering late, not answering, closing
mid-command, refusing the connection. The real helper does none of those
on demand, so this peer answers the panel's verbs from captured facts
(fixtures/lab-seat.json: `keyboards`, `seat` and every group's `caps`
records, captured once from the real helper in the lab with `capture`)
and misbehaves when the leg says so. It owns no virtual keyboard: a key
line is answered `ok` and types nothing.

One reply line per command line, in order, like the real helper. The
fault commands, one per line, appended to the control file:

  delay <ms>          every reply from now on waits <ms> after its command
  mute                connections open now stop answering (they stay open;
                      later connections answer normally); `unmute` undoes
  drop                close every open connection now
  drop-after <verb>   close the connection right after the next command
                      with that verb arrives, before answering it
  err <verb>          answer the next command with that verb `err injected`
  too-many [n]        answer the next n connections `err too many clients`
                      and close them, as the real helper's fifth client
  slow-hello <ms>     the next hello's reply waits <ms> more
  not-ready <n>       answer the next n hellos `err not ready`
  clear               forget every pending fault

Every line both ways is logged with an epoch timestamp and the connection
number: `<epoch> c<n> < line` (received), `> line` (sent), `* note`
(accept, peer close, fault, drop). Usage:

  fake_helper.py serve --socket PATH --control PATH --log PATH [--fixture F]
  fake_helper.py capture --socket PATH --out F   # from a real helper
"""

import argparse
import json
import os
import socket
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_FIXTURE = os.path.join(HERE, "fixtures", "lab-seat.json")
PROTOCOL = 7
RECORD_SEP = "\x1e"
FIELD_SEP = "\x1f"


class Log:
    def __init__(self, path):
        self.handle = open(path, "a", encoding="utf-8")
        self.lock = threading.Lock()

    def write(self, conn, mark, text):
        # The caps separators are drawn visibly; tabs stay tabs.
        text = text.replace(RECORD_SEP, "\u241e").replace(FIELD_SEP, "\u241f")
        with self.lock:
            self.handle.write(f"{time.time():.3f} c{conn} {mark} {text}\n")
            self.handle.flush()


class Faults:
    def __init__(self):
        self.lock = threading.Lock()
        self.clear()

    def clear(self):
        self.delay_ms = 0
        self.drop_after = []
        self.err_once = []
        self.too_many = 0
        self.slow_hello_ms = 0
        self.not_ready = 0


class Conn:
    def __init__(self, number, sock):
        self.number = number
        self.sock = sock
        self.muted = False
        self.closed = False
        self.helloed = False
        self.queue = []
        self.cond = threading.Condition()


class FakeHelper:
    def __init__(self, socket_path, control_path, log_path, fixture):
        with open(fixture, encoding="utf-8") as handle:
            self.fixture = json.load(handle)
        self.socket_path = socket_path
        self.control_path = control_path
        self.log = Log(log_path)
        self.faults = Faults()
        self.conns = []
        self.conns_lock = threading.Lock()
        self.count = 0
        self.gen = 0
        self.identity = None
        self.state_lock = threading.Lock()

    # ---- the verbs ----

    def caps(self, words):
        try:
            group = int(words[1])
        except (IndexError, ValueError):
            return "err unknown command"
        groups = self.fixture["caps"]
        if group < 0 or group >= len(groups):
            return "err bad group"
        records = [r for r in groups[group].split(RECORD_SEP) if r]
        by_name = {r.split(FIELD_SEP)[0]: r for r in records}
        wanted = words[2:]
        body = RECORD_SEP.join(records) if not wanted else \
            RECORD_SEP.join(by_name.get(p, p) for p in wanted)
        with self.state_lock:
            gen = self.gen
        return f"caps\t{gen}\t{group}\t{body}"

    def configure(self, line):
        # A changed keymap bumps the generation; a group move (the last
        # field) or a byte-identical refresh keeps it, as the helper does.
        fields = line.split("\t")
        identity = "\t".join(fields[1:-1])
        with self.state_lock:
            if identity != self.identity:
                self.identity = identity
                self.gen += 1
            return f"configured\t{self.gen}"

    def answer(self, conn, line):
        words = line.split()
        verb = words[0] if words else ""
        if verb == "hello":
            conn.helloed = True
            with self.faults.lock:
                if self.faults.not_ready > 0:
                    self.faults.not_ready -= 1
                    return "err not ready"
            if len(words) == 2 and words[1] in ("6", str(PROTOCOL)):
                return f"hello {words[1]}"
            return f"err protocol {PROTOCOL}"
        if not conn.helloed:
            return "err hello first"
        if verb == "configure":
            return self.configure(line)
        if verb == "caps":
            return self.caps(words)
        if verb == "keyboards":
            return self.fixture["keyboards"]
        if verb == "seat":
            return "seat\t" + json.dumps(self.fixture["seat"],
                                         separators=(",", ":"))
        if verb == "ping":
            return "pong"
        if verb in ("switch", "share", "events", "group", "mods", "down",
                    "up", "tap"):
            return "ok"
        return "err unknown command"

    # ---- connections ----

    def close_conn(self, conn, why):
        with conn.cond:
            if conn.closed:
                return
            conn.closed = True
            conn.cond.notify_all()
        self.log.write(conn.number, "*", f"closed-by-fake {why}")
        try:
            # shutdown first: it wakes the reader blocked in recv.
            conn.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            conn.sock.close()
        except OSError:
            pass

    def writer(self, conn):
        while True:
            with conn.cond:
                while not conn.queue and not conn.closed:
                    conn.cond.wait()
                if conn.closed:
                    return
                due, line = conn.queue[0]
                wait = due - time.monotonic()
                if wait > 0:
                    conn.cond.wait(wait)
                    continue
                conn.queue.pop(0)
            try:
                conn.sock.sendall((line + "\n").encode())
                self.log.write(conn.number, ">", line)
            except OSError as error:
                self.log.write(conn.number, "*", f"write-failed {error}")
                return

    def reader(self, conn):
        buffer = b""
        while True:
            try:
                chunk = conn.sock.recv(65536)
            except OSError:
                chunk = b""
            if not chunk:
                if not conn.closed:
                    self.log.write(conn.number, "*", "peer-closed")
                    with conn.cond:
                        conn.closed = True
                        conn.cond.notify_all()
                    try:
                        conn.sock.close()
                    except OSError:
                        pass
                return
            buffer += chunk
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                line = raw.decode("utf-8", "replace").rstrip("\r")
                if line == "":
                    continue
                self.command(conn, line)
                if conn.closed:
                    return

    def command(self, conn, line):
        self.log.write(conn.number, "<", line)
        verb = line.split()[0] if line.split() else ""
        with self.faults.lock:
            drop = verb in self.faults.drop_after
            if drop:
                self.faults.drop_after.remove(verb)
            inject = verb in self.faults.err_once
            if inject:
                self.faults.err_once.remove(verb)
            delay = self.faults.delay_ms
            if verb == "hello" and self.faults.slow_hello_ms:
                delay += self.faults.slow_hello_ms
                self.faults.slow_hello_ms = 0
        if drop:
            self.close_conn(conn, f"drop-after {verb}")
            return
        if conn.muted:
            self.log.write(conn.number, "*", "muted: no reply")
            return
        reply = "err injected" if inject else self.answer(conn, line)
        with conn.cond:
            conn.queue.append((time.monotonic() + delay / 1000.0, reply))
            conn.cond.notify_all()

    def accept(self, sock):
        self.count += 1
        conn = Conn(self.count, sock)
        try:
            cred = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                                   struct.calcsize("3i"))
            pid = struct.unpack("3i", cred)[0]
        except OSError:
            pid = -1
        self.log.write(conn.number, "*", f"accept pid={pid}")
        with self.faults.lock:
            refuse = self.faults.too_many > 0
            if refuse:
                self.faults.too_many -= 1
        if refuse:
            try:
                sock.sendall(b"err too many clients\n")
                self.log.write(conn.number, ">", "err too many clients")
            except OSError:
                pass
            self.close_conn(conn, "too-many")
            return
        with self.conns_lock:
            self.conns = [c for c in self.conns if not c.closed] + [conn]
        threading.Thread(target=self.writer, args=(conn,), daemon=True).start()
        threading.Thread(target=self.reader, args=(conn,), daemon=True).start()

    # ---- the control file ----

    def open_conns(self):
        with self.conns_lock:
            return [c for c in self.conns if not c.closed]

    def fault(self, line):
        words = line.split()
        if not words:
            return
        self.log.write(0, "*", f"fault {line}")
        verb, args = words[0], words[1:]
        faults = self.faults
        with faults.lock:
            if verb == "delay":
                faults.delay_ms = int(args[0])
            elif verb == "drop-after":
                faults.drop_after.append(args[0])
            elif verb == "err":
                faults.err_once.append(args[0])
            elif verb == "too-many":
                faults.too_many = int(args[0]) if args else 1
            elif verb == "slow-hello":
                faults.slow_hello_ms = int(args[0])
            elif verb == "not-ready":
                faults.not_ready = int(args[0])
            elif verb == "clear":
                faults.clear()
        if verb in ("mute", "unmute"):
            for conn in self.open_conns():
                conn.muted = verb == "mute"
        elif verb == "drop":
            for conn in self.open_conns():
                self.close_conn(conn, "drop")

    def watch_control(self):
        offset = 0
        pending = ""
        while True:
            try:
                with open(self.control_path, encoding="utf-8") as handle:
                    handle.seek(offset)
                    data = handle.read()
                    offset = handle.tell()
            except FileNotFoundError:
                data = ""
            pending += data
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                try:
                    self.fault(line.strip())
                except (ValueError, IndexError) as error:
                    self.log.write(0, "*", f"bad fault {line!r}: {error}")
            time.sleep(0.02)

    def serve(self):
        os.makedirs(os.path.dirname(self.socket_path), exist_ok=True)
        if os.path.exists(self.socket_path):
            os.unlink(self.socket_path)
        if not os.path.exists(self.control_path):
            open(self.control_path, "w").close()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(self.socket_path)
        listener.listen(8)
        threading.Thread(target=self.watch_control, daemon=True).start()
        self.log.write(0, "*", f"listening {self.socket_path}")
        while True:
            sock, _ = listener.accept()
            self.accept(sock)


def capture(socket_path, out):
    """The fixture, from a real helper: hello, keyboards, seat, and the
    bare caps (every record) of each group the seat's layout list names.
    kb_file is blanked: the fake's panel must configure from the RMLVO,
    never adopt the lab's published keymap path."""
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    client.connect(socket_path)
    reader = client.makefile("r", encoding="utf-8", newline="\n")

    def ask(line):
        client.sendall((line + "\n").encode())
        while True:
            reply = reader.readline().rstrip("\n")
            if not reply.startswith("event\t"):
                return reply

    hello = ask(f"hello {PROTOCOL}")
    if hello != f"hello {PROTOCOL}":
        raise SystemExit(f"helper answered {hello!r}")
    keyboards = ask("keyboards")
    seat_reply = ask("seat")
    if not seat_reply.startswith("seat\t"):
        raise SystemExit(f"seat answered {seat_reply!r}")
    seat = json.loads(seat_reply.split("\t", 1)[1])
    seat["kb_file"] = ""
    caps = []
    group = 0
    while True:
        reply = ask(f"caps {group}")
        if not reply.startswith("caps\t"):
            break
        caps.append(reply.split("\t", 3)[3])
        group += 1
    client.close()
    with open(out, "w", encoding="utf-8") as handle:
        json.dump({"keyboards": keyboards, "seat": seat, "caps": caps},
                  handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    print(f"captured {len(caps)} groups, "
          f"{len(seat.get('keyboards', []))} keyboards -> {out}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--socket", required=True)
    serve.add_argument("--control", required=True)
    serve.add_argument("--log", required=True)
    serve.add_argument("--fixture", default=DEFAULT_FIXTURE)
    cap = sub.add_parser("capture")
    cap.add_argument("--socket", required=True)
    cap.add_argument("--out", default=DEFAULT_FIXTURE)
    args = parser.parse_args()
    if args.mode == "capture":
        capture(args.socket, args.out)
        return
    FakeHelper(args.socket, args.control, args.log, args.fixture).serve()


if __name__ == "__main__":
    sys.exit(main())
