//! One connection's write side, shared between its replies and the seat's
//! pushed events, and the registry of connections that asked for events.
//!
//! The framing invariant lives here: every line — a reply or an event — is
//! written whole under the connection's writer lock, so an event can land
//! between two replies but never inside one.

use std::io::Write;
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use crate::seat::{EventSink, SeatEvent};

/// Locks without inheriting a panic: a writer that panicked mid-line took
/// its own connection down, and the lock must not take the others with it.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The write half of one client connection.
#[derive(Clone)]
pub(crate) struct Outbox {
    stream: Arc<Mutex<UnixStream>>,
}

impl Outbox {
    pub(crate) fn new(stream: UnixStream) -> Self {
        Outbox {
            stream: Arc::new(Mutex::new(stream)),
        }
    }

    /// Writes `text` and its newline as one unit, bounded by `bound`.
    /// `false` means the bound is spent or the peer is not draining its
    /// pipe; the connection is to be dropped. A peer that already hung up
    /// (EPIPE) answers `true`: its read side notices on its own.
    pub(crate) fn write_line(&self, text: &str, bound: Duration) -> bool {
        if bound.is_zero() {
            return false;
        }
        let mut line = String::with_capacity(text.len() + 1);
        line.push_str(text);
        line.push('\n');
        let mut stream = lock(&self.stream);
        // The socket's send timeout is shared by every handle on it, so it
        // is set under the same lock as the write it bounds.
        if stream.set_write_timeout(Some(bound)).is_err() {
            return false;
        }
        match stream.write_all(line.as_bytes()) {
            Ok(()) => true,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                false
            }
            Err(_) => true,
        }
    }

    /// Ends the connection from outside its own thread: the thread's
    /// pending read returns and it leaves through its release path.
    fn hang_up(&self) {
        let _ = lock(&self.stream).shutdown(Shutdown::Both);
    }

    fn same(&self, other: &Outbox) -> bool {
        Arc::ptr_eq(&self.stream, &other.stream)
    }
}

/// Connections that sent `events on`, keyed by connection id.
pub(crate) struct Subscribers {
    list: Mutex<Vec<(u64, Outbox)>>,
    bound: Duration,
}

/// The helper's one registry: the seat backend's event threads send here.
pub(crate) static SUBSCRIBERS: Subscribers = Subscribers::new(Duration::from_secs(5));

impl Subscribers {
    pub(crate) const fn new(bound: Duration) -> Self {
        Subscribers {
            list: Mutex::new(Vec::new()),
            bound,
        }
    }

    pub(crate) fn subscribe(&self, id: u64, outbox: &Outbox) {
        let mut list = lock(&self.list);
        if !list.iter().any(|(known, _)| *known == id) {
            list.push((id, outbox.clone()));
        }
    }

    pub(crate) fn unsubscribe(&self, id: u64) {
        lock(&self.list).retain(|(known, _)| *known != id);
    }

    /// Writes one event line to every subscriber. The list is copied out
    /// first, so a slow peer holds up this broadcast and nobody's
    /// subscribe or unsubscribe. A peer whose write fails its bound is
    /// dropped the way a stalled reply drops it: removed and hung up.
    pub(crate) fn broadcast(&self, line: &str) {
        let targets: Vec<(u64, Outbox)> = lock(&self.list).clone();
        for (id, outbox) in targets {
            if !outbox.write_line(line, self.bound) {
                lock(&self.list).retain(|(known, other)| !(*known == id && other.same(&outbox)));
                outbox.hang_up();
            }
        }
    }
}

impl EventSink for Subscribers {
    fn listening(&self) -> bool {
        !lock(&self.list).is_empty()
    }

    fn send(&self, event: SeatEvent) {
        self.broadcast(&event.line());
    }
}

impl EventSink for &'static Subscribers {
    fn listening(&self) -> bool {
        (**self).listening()
    }

    fn send(&self, event: SeatEvent) {
        (**self).send(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::thread;

    #[test]
    fn events_interleave_between_replies_but_never_inside_one() {
        // Replies long enough that an unguarded write would split, from one
        // thread, and events from another, onto one connection.
        let (ours, theirs) = UnixStream::pair().unwrap();
        let outbox = Outbox::new(ours);
        let subscribers = Arc::new(Subscribers::new(Duration::from_secs(5)));
        subscribers.subscribe(1, &outbox);
        let reply = format!("caps\t1\t0\t{}", "r".repeat(60_000));
        let replies = {
            let outbox = outbox.clone();
            let reply = reply.clone();
            thread::spawn(move || {
                for _ in 0..40 {
                    assert!(outbox.write_line(&reply, Duration::from_secs(5)));
                }
            })
        };
        let events = {
            let subscribers = Arc::clone(&subscribers);
            thread::spawn(move || {
                for group in 0..200 {
                    subscribers.send(SeatEvent::Layout {
                        device: "kbd".into(),
                        group,
                    });
                }
                subscribers.send(SeatEvent::Devices);
            })
        };
        let mut reader = BufReader::new(theirs);
        let (mut seen_replies, mut seen_events) = (0, 0);
        let mut line = String::new();
        while seen_replies < 40 || seen_events < 201 {
            line.clear();
            assert!(reader.read_line(&mut line).unwrap() > 0);
            let line = line.trim_end_matches('\n');
            if line == reply {
                seen_replies += 1;
            } else if line.starts_with("event\tlayout\tkbd\t") || line == "event\tdevices" {
                seen_events += 1;
            } else {
                panic!("a torn line: {:?}…", &line[..line.len().min(80)]);
            }
        }
        replies.join().unwrap();
        events.join().unwrap();
    }

    #[test]
    fn only_subscribers_hear_events_and_a_stalled_one_is_dropped() {
        let subscribers = Subscribers::new(Duration::from_millis(200));
        assert!(!subscribers.listening());
        let (listening, mut listening_peer) = UnixStream::pair().unwrap();
        let (_quiet, mut quiet_peer) = UnixStream::pair().unwrap();
        subscribers.subscribe(1, &Outbox::new(listening));
        assert!(subscribers.listening());
        subscribers.send(SeatEvent::Devices);
        quiet_peer.set_nonblocking(true).unwrap();
        let mut buf = [0u8; 64];
        assert!(std::io::Read::read(&mut quiet_peer, &mut buf).is_err(), "not subscribed");
        let n = std::io::Read::read(&mut listening_peer, &mut buf).unwrap();
        assert_eq!(&buf[..n], b"event\tdevices\n");
        subscribers.unsubscribe(1);
        assert!(!subscribers.listening());

        // A peer that never reads fills its pipe; the broadcast gives up on
        // it inside the bound, drops it and hangs it up.
        let (stalled, stalled_peer) = UnixStream::pair().unwrap();
        subscribers.subscribe(2, &Outbox::new(stalled));
        for _ in 0..100_000 {
            subscribers.send(SeatEvent::Devices);
            if lock(&subscribers.list).iter().all(|(id, _)| *id != 2) {
                break;
            }
        }
        assert!(lock(&subscribers.list).iter().all(|(id, _)| *id != 2));
        drop(stalled_peer);
        assert!(!subscribers.listening());
    }
}
