//! The control socket: accepting clients, framing lines, and the handshake
//! and write bounds every connection lives under.

use std::io::{BufReader, Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use wayland_client::Connection;

use crate::apply::{apply, expire_stuck_keys, hold_deadline, release_all};
use crate::protocol::{parse, parse_hello, PROTOCOL_VERSION};
use crate::seat::startup_keyboard_reply;
use crate::state::SharedRef;

pub(crate) fn serve(listener: UnixListener, shared: SharedRef, connection: Connection) {
    const MAX_CLIENTS: usize = 4;
    let clients = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for stream in listener.incoming().flatten() {
        if clients.fetch_add(1, Ordering::AcqRel) >= MAX_CLIENTS {
            clients.fetch_sub(1, Ordering::AcqRel);
            // Refuse loudly: a silent drop leaves the panel believing the
            // helper healthy while it cannot get in. The panel's rebuild
            // path treats any error line alike.
            let _ = writeln!(&mut { stream }, "err too many clients");
            continue;
        }
        let shared = Arc::clone(&shared);
        let connection = connection.clone();
        let spawned = {
            let clients = Arc::clone(&clients);
            thread::Builder::new()
                .name("osk-client".into())
                .spawn(move || {
                    handle_client(stream, shared, connection);
                    clients.fetch_sub(1, Ordering::AcqRel);
                })
                .is_err()
        };
        if spawned {
            // The client is dropped, never the helper: exiting would skip
            // the release paths live connections' keys depend on. The slot
            // must be returned, or four failed spawns lock everyone out.
            eprintln!("cannot spawn socket client worker; dropping the client");
            clients.fetch_sub(1, Ordering::AcqRel);
        }
    }
}

/// The pre-handshake window and the write bound are both absolute: neither
/// a client that streams frames without pausing nor one that stops reading
/// may extend them.
const HANDSHAKE_WINDOW: Duration = Duration::from_secs(5);
const WRITE_BOUND: Duration = Duration::from_secs(5);

/// Whether a connection that never completed its `hello` has worn the
/// pre-handshake window out. Evaluated per iteration, not only when a read
/// times out — continuous traffic must not extend the window.
fn handshake_expired(handshaked: bool, connected_for: Duration) -> bool {
    !handshaked && connected_for >= HANDSHAKE_WINDOW
}

/// One bounded reply. `bound` is the caller's remaining time: while the handshake window is open, a write may not
/// outlive it — a parked write would let a late hello complete long past
/// the window. `false` means the bound is spent or the client is not
/// draining its pipe; the connection is dropped either way.
fn write_reply(out: &mut UnixStream, text: &str, bound: Duration) -> bool {
    if bound.is_zero() {
        return false;
    }
    if out.set_write_timeout(Some(bound)).is_err() {
        return false;
    }
    match writeln!(out, "{text}") {
        Ok(()) => true,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) =>
        {
            false
        }
        // EPIPE and friends: the read side notices the disconnect on its
        // own; an idle writer gains nothing by tearing the loop down here.
        Err(_) => true,
    }
}

/// The bound on the NEXT reply write: never more than `WRITE_BOUND`, and
/// while the handshake window is open, never past its end.
fn reply_bound(handshaked: bool, connected_for: Duration) -> Duration {
    if handshaked {
        WRITE_BOUND
    } else {
        HANDSHAKE_WINDOW
            .saturating_sub(connected_for)
            .min(WRITE_BOUND)
    }
}

fn handle_client(stream: UnixStream, shared: SharedRef, connection: Connection) {
    let Ok(mut out) = stream.try_clone() else {
        return;
    };
    // A client that stops reading while its pipe is full would park a
    // reply forever: every write on this connection is bounded, and one
    // that times out drops the connection — its read side would only ever
    // notice at an EOF that client never sends.
    if out.set_write_timeout(Some(WRITE_BOUND)).is_err() {
        return;
    }
    // Keys this connection pressed and has not released. If the shell restarts
    // mid-chord the compositor would otherwise keep Ctrl logically down for the
    // rest of the session, which looks like a broken machine rather than a
    // broken plugin.
    let mut held: Vec<u32> = Vec::new();
    static CONNECTION: AtomicU64 = AtomicU64::new(1);
    let conn_id = CONNECTION.fetch_add(1, Ordering::Relaxed);

    let mut reader = BufReader::with_capacity(8 * 1024, match stream.try_clone() {
        Ok(handle) => handle,
        Err(_) => return,
    });
    // Bytes of the line in flight. A raw byte buffer, not a String: the
    // manual chunk loop below enforces the frame cap per read, because
    // read_line accumulates without bound inside one call while a sender
    // streams newline-free bytes.
    let mut pending: Vec<u8> = Vec::new();
    let mut handshaked = false;
    let connected_at = Instant::now();
    // A negotiated client also owes traffic: otherwise a client that
    // hello'd and went silent would park one of the four slots for the
    // process lifetime. 60 s of post-handshake silence drops the connection
    // through the ordinary release path. The real panel's health probe
    // speaks every 15 s, and a held key arms its own tighter deadline.
    let mut last_activity = Instant::now();
    const NEGOTIATED_IDLE: Duration = Duration::from_secs(60);
    loop {
        // The only thing this connection ever waits on is its own next line.
        // Arming that wait with the cap's deadline is what enforces the cap
        // without a timer thread: no hold means no deadline and the read
        // blocks, and a hold means exactly one wakeup, at the moment the key
        // is due to be lifted.
        // The pre-handshake window is absolute: 5 s from connect to a
        // completed `hello`, measured from `connected_at` rather than
        // renewed per read, so idle connections cannot hold the four slots
        // forever. A hold's deadline still wins when it is sooner.
        let handshake = if handshaked {
            None
        } else {
            Some(
                connected_at
                    .checked_add(HANDSHAKE_WINDOW)
                    .map(|deadline| {
                        deadline
                            .saturating_duration_since(Instant::now())
                            .max(Duration::from_millis(1))
                    })
                    .unwrap_or(Duration::from_millis(1)),
            )
        };
        let hold = hold_deadline(&shared, conn_id).map(|deadline| {
            deadline
                .saturating_duration_since(Instant::now())
                .max(Duration::from_millis(1))
        });
        let idle = if handshaked && hold.is_none() {
            Some(
                last_activity
                    .checked_add(NEGOTIATED_IDLE)
                    .map(|deadline| {
                        deadline
                            .saturating_duration_since(Instant::now())
                            .max(Duration::from_millis(1))
                    })
                    .unwrap_or(Duration::from_millis(1)),
            )
        } else {
            None
        };
        let timeout = [handshake, hold, idle].into_iter().flatten().min();
        if stream.set_read_timeout(timeout).is_err() {
            break;
        }
        // Deadline enforcement must not depend on the traffic going quiet:
        // a client that streams frames keeps the read succeeding forever,
        // so the deadlines are evaluated here every turn, not only in the
        // timeout arm.
        if handshake_expired(handshaked, connected_at.elapsed()) {
            break;
        }
        if hold_deadline(&shared, conn_id).is_some_and(|deadline| deadline <= Instant::now()) {
            for code in expire_stuck_keys(&shared, &connection) {
                held.retain(|entry| *entry != code);
            }
        }
        // The idle window is traffic-gated like the others (a client
        // streaming frames keeps the reads succeeding; only silence
        // closes it).
        if handshaked
            && hold_deadline(&shared, conn_id).is_none()
            && last_activity.elapsed() >= NEGOTIATED_IDLE
        {
            break;
        }
        // The frame cap, enforced per chunk: a newline-free stream must not
        // grow `pending` without bound (under MemoryMax that becomes a
        // restart loop and then a lockout). 4 KiB is generous — the longest
        // real line, a configure with a kb_file path, is a few hundred
        // bytes. One chunk is one buffer fill, so `pending` is bounded by
        // cap + 8 KiB whatever the sender's pace. Overflow answers once and
        // closes.
        const MAX_LINE: usize = 4096;
        let mut chunk = [0u8; 8192];
        let read = match reader.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => n,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                // The deadline came due. Pre-handshake past the window:
                // this connection never said hello — drop it, freeing
                // the slot. Post-handshake with no hold, it may be the
                // negotiated-idle window closing — same release path.
                // Otherwise this is the hold cap's wakeup: lift what is
                // due and keep waiting for the rest of the line.
                if handshake_expired(handshaked, connected_at.elapsed()) {
                    break;
                }
                // Being handshaked and holdless is not enough: the read
                // deadline was computed before the loop-top hold expiry,
                // so a claim that vanished in between (cap, or another
                // client's install draining it) leaves a stale past-due
                // timeout. Only the real idle window closes the connection.
                if handshaked
                    && hold_deadline(&shared, conn_id).is_none()
                    && last_activity.elapsed() >= NEGOTIATED_IDLE
                {
                    break;
                }
                for code in expire_stuck_keys(&shared, &connection) {
                    held.retain(|entry| *entry != code);
                }
                continue;
            }
            Err(_) => break,
        };
        last_activity = Instant::now();
        pending.extend_from_slice(&chunk[..read]);
        // Dispatch every complete line the buffer now holds; the tail
        // without its newline stays for the next chunk.
        let mut poisoned = false;
        let mut write_dead = false;
        while let Some(nl) = pending.iter().position(|byte| *byte == b'\n') {
            // A complete line is capped here, before it is parsed. Breaking
            // without draining leaves the oversized bytes in `pending` for
            // the tail check below, which answers and closes.
            if nl + 1 > MAX_LINE {
                break;
            }
            // Deadlines between commands, not only between reads: one chunk
            // can carry a whole burst,
            // paced slow enough to cross the window, and its late hello
            // must not complete. Breaking here drops the rest of the
            // buffer; the loop-top check finishes dropping the connection.
            if handshake_expired(handshaked, connected_at.elapsed()) {
                break;
            }
            if hold_deadline(&shared, conn_id).is_some_and(|deadline| deadline <= Instant::now()) {
                for code in expire_stuck_keys(&shared, &connection) {
                    held.retain(|entry| *entry != code);
                }
            }
            let mut line_bytes = pending.drain(..=nl).collect::<Vec<u8>>();
            line_bytes.pop(); // the newline itself
            let Ok(line_str) = String::from_utf8(line_bytes) else {
                // Invalid UTF-8 disconnects rather than guesses, through
                // the release path: a bare `return` would skip release_all
                // and strand every key this client holds.
                poisoned = true;
                break;
            };
            let line = line_str.trim();
            if line.is_empty() {
                // Even this answers one line: the reply-per-command
                // invariant has no silent case, and the panel's correlation
                // queue pops on it.
                if !write_reply(&mut out, "err empty",
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            // `hello` reports more than "the process is up": a keyboard without a
            // keymap accepts commands and drops every key, so the client must not
            // enable keys until one is loaded. `ping` stays a plain liveness check.
            // The grammar is exactly `hello <u32>`: the handshake is a
            // version gate, not a default, so an old or broken client fails
            // closed instead of negotiating the current version by omission.
            if let Some(hello) = parse_hello(line) {
                let reply = match hello {
                    Ok(wanted) if wanted == PROTOCOL_VERSION => {
                        if shared.lock().unwrap().is_ready() {
                            format!("hello {PROTOCOL_VERSION}")
                        } else {
                            "err not ready".to_string()
                        }
                    }
                    _ => {
                        format!("err protocol {PROTOCOL_VERSION} required, helper needs reinstall")
                    }
                };
                if !write_reply(&mut out, &reply,
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                // Set, never cleared: a post-handshake wrong-version hello is a protocol
                // confusion, not a de-negotiation.
                handshaked |= matches!(hello, Ok(wanted) if wanted == PROTOCOL_VERSION);
                continue;
            }
            // Protocol negotiation is a gate, not a suggestion: until this
            // connection has completed a `hello` the
            // version it speaks for is unknown, and nothing — not ping,
            // not keyboards, and above all not a command that moves keys
            // or keymaps — executes. A client that never negotiates gets
            // its slot's five seconds and one refusal per line.
            if !handshaked {
                if !write_reply(&mut out, "err hello first",
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            if line == "ping" {
                if !write_reply(&mut out, "pong",
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            if line == "keyboards" {
                if !write_reply(&mut out, &startup_keyboard_reply(),
                    reply_bound(handshaked, connected_at.elapsed()))
                {
                    write_dead = true;
                    break;
                }
                continue;
            }
            let reply = match parse(line) {
                Some(command) => apply(&shared, &connection, command, Some(&mut held), conn_id),
                None => "err unknown command".to_string(),
            };
            if !write_reply(&mut out, &reply,
                reply_bound(handshaked, connected_at.elapsed()))
            {
                write_dead = true;
                break;
            }
        }
        if poisoned || write_dead {
            break;
        }
        // The frame cap is per line, not per batch: coalesced complete
        // commands share this chunk legally, so the cap is measured on what
        // remains — the tail without its newline, the one line still
        // growing.
        if pending.len() > MAX_LINE {
            let _ = writeln!(out, "err line too long");
            break;
        }
    }

    release_all(&shared, &connection, held, conn_id);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_handshake_window_is_absolute_under_traffic() {
        // Continuous frames never pause the read, so the window is checked
        // per iteration — a connection that streams without a hello is
        // dropped once the window wears out, not only when it goes quiet.
        assert!(handshake_expired(false, Duration::from_secs(5)));
        assert!(handshake_expired(false, Duration::from_secs(600)));
        assert!(!handshake_expired(false, Duration::from_secs(4)));
        assert!(!handshake_expired(true, Duration::from_secs(600)));
    }

    #[test]
    fn reply_writes_are_bounded_by_the_remaining_handshake_window() {
        // Handshaked, the fixed write bound stands. Inside the window the
        // write gets only what is left of it; past the window, nothing —
        // a parked write must not carry a late hello home.
        assert_eq!(reply_bound(true, Duration::from_secs(600)), WRITE_BOUND);
        assert_eq!(reply_bound(false, Duration::from_secs(1)), Duration::from_secs(4));
        assert!(reply_bound(false, Duration::from_secs(6)).is_zero());
        assert_eq!(reply_bound(false, Duration::ZERO), HANDSHAKE_WINDOW);
    }
}
