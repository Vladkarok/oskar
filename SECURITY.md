# Security policy

## Report

Open a GitHub issue marked `[security]`, or contact the maintainer
directly. There is no bug bounty — there is gratitude and fast fixes.

## Posture (audited 2026-09-18, v0.1.0)

Two independent adversarial audits (different labs, both with tree
access) converged: **needs-hardening, core sound**. The full findings
and their fixes live in the commits of 2026-09-18; the shape:

**What held up under audit** — no XKB injection (configure payloads
are compiled under keycode and cleanliness gates and re-proved against
the compiled map; the typed-payload keysym engine is gone with §91); no
shell interpolation on any clipboard path (argv arrays throughout); a
strict allowlist config parser with prototype-pollution defense; an
offline, checksum-gated emoji generator; no root, setuid, udev rules,
or network listener anywhere; a systemd sandbox (`ProtectSystem=
strict`, `ProtectHome=read-only`, `PrivateTmp`) that contains the
daemon's own sloppy writes.

**What the audits found and 2026-09-18 fixed:**

- **Lua injection through the keymap path** — a crafted filename
  escaped the `hyprctl eval` string literal; both auditors flagged it,
  one proved it in a stub. Fixed: `Session.luaQuote` seals every
  interpolation into Lua literals (quotes, backslashes, control bytes
  escaped; double quotes covered for the bash layer), and the share
  path rides positional arguments instead of spliced strings.
- **Five writes could kill the keyboard permanently** — an unbounded
  line plus `MemoryMax` plus `StartLimitBurst` meant a same-user
  client could OOM-loop the unit into `failed`, and a user who types
  through OSKar cannot type their way out. Fixed with a manual
  chunked read loop (the first cut's post-hoc length check missed an
  active newline-free stream — the cross-round caught it): every
  read is capped at one 8 KiB buffer, the frame cap is enforced per
  chunk, overflow answers `err line too long` and closes.
- **Slot starvation** — four idle connections held every slot forever
  while the socket stayed alive (the panel reported the helper
  healthy). Fixed with an ABSOLUTE 5-second connect-to-`hello`
  deadline (a renewable timeout evicted no one — the cross-round's
  catch) and a loud `err too many clients` on refusal. A post-handshake
  connection silent for 60 s is dropped through the ordinary release
  path (§107): the panel's never-stopping probe speaks every 15 s and
  never trips it; a hung same-user client cannot park a slot for the
  process lifetime.
- **Socket-directory pre-bind impersonation** — the daemon refuses to
  serve from any runtime directory it does not solely own (uid +
  0700 asserted at start; explicit mode on create). Residual, stated
  plainly: a same-user attacker who binds their own socket before the
  daemon's first start still races it — the panel does not yet verify
  the peer; the same-user boundary is the actual wall.
- **Clipboard preview rich text** — a text/plain payload with a
  remote image tag could make the preview issue a network request.
  Fixed: `Text.PlainText`, always; `wl-copy` gains `--`; every
  `wl-paste` reader is stream-capped at 64 KiB so a malicious
  clipboard owner cannot balloon the shell's memory through the
  collector.
- **Dev-tool surfaces** — the nested-lab harness used a predictable
  `/tmp` path (now `mktemp -d` exclusive); the wall's logs are
  private; CI pins its action by commit SHA, declares
  `permissions: contents: read`, and persists no credentials; the
  panel no longer falls back to a predictable `/tmp` sound file.

**The honest boundary**: OSKar is a same-user tool. The control socket
is reachable by anything running as you — that is the design, and the
0700 runtime directory is the wall other users cannot cross. Root sees
everything, as root always does.
