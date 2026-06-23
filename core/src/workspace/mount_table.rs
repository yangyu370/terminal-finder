//! Mount registry for connection-to-mountpoint reservations.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::connection::ConnectionId;
use tokio::sync::Notify;

#[derive(Clone)]
pub enum Reservation {
    New(String),
    Existing(String),
    Pending(PendingMount),
}

#[derive(Clone)]
pub struct PendingMount {
    id: ConnectionId,
    inner: Arc<Mutex<HashMap<ConnectionId, MountEntry>>>,
}

#[derive(Clone)]
struct MountEntry {
    mountpoint: String,
    status: MountStatus,
    notify: Arc<Notify>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum MountStatus {
    Pending,
    Ready,
}

#[derive(Clone, Default)]
pub struct MountRegistry {
    inner: Arc<Mutex<HashMap<ConnectionId, MountEntry>>>,
}

impl MountRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn get_or_reserve<F>(&self, id: &ConnectionId, propose: F) -> Reservation
    where
        F: FnOnce(&[String]) -> String,
    {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(existing) = guard.get(id) {
            if existing.status == MountStatus::Ready {
                return Reservation::Existing(existing.mountpoint.clone());
            }
            return Reservation::Pending(PendingMount {
                id: id.clone(),
                inner: Arc::clone(&self.inner),
            });
        }

        let taken: Vec<String> = guard
            .values()
            .map(|entry| entry.mountpoint.clone())
            .collect();
        let mountpoint = propose(&taken);
        guard.insert(
            id.clone(),
            MountEntry {
                mountpoint: mountpoint.clone(),
                status: MountStatus::Pending,
                notify: Arc::new(Notify::new()),
            },
        );
        Reservation::New(mountpoint)
    }

    pub fn mark_ready(&self, id: &ConnectionId) -> Option<String> {
        let notify = {
            let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            let entry = guard.get_mut(id)?;
            entry.status = MountStatus::Ready;
            Arc::clone(&entry.notify)
        };
        notify.notify_waiters();
        self.mountpoint(id)
    }

    pub fn release(&self, id: &ConnectionId) -> Option<String> {
        let entry = {
            let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            guard.remove(id)
        }?;
        entry.notify.notify_waiters();
        Some(entry.mountpoint)
    }

    pub fn clear(&self) {
        let entries = {
            let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
            guard.drain().map(|(_id, entry)| entry).collect::<Vec<_>>()
        };
        for entry in entries {
            entry.notify.notify_waiters();
        }
    }

    pub fn is_mounted(&self, id: &ConnectionId) -> bool {
        let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard
            .get(id)
            .map(|entry| entry.status == MountStatus::Ready)
            .unwrap_or(false)
    }

    fn mountpoint(&self, id: &ConnectionId) -> Option<String> {
        let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard.get(id).map(|entry| entry.mountpoint.clone())
    }
}

impl PendingMount {
    pub async fn wait(self) -> Option<String> {
        loop {
            let notified = {
                let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
                match guard.get(&self.id) {
                    Some(entry) if entry.status == MountStatus::Ready => {
                        return Some(entry.mountpoint.clone());
                    }
                    Some(entry) => Arc::clone(&entry.notify).notified_owned(),
                    None => return None,
                }
            };
            notified.await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::naming::mountpoint_for;
    use super::*;
    use crate::connection::ConnectionId;

    fn id(s: &str) -> ConnectionId {
        ConnectionId(s.into())
    }

    fn local_propose(display_name: &str) -> impl FnOnce(&[String]) -> String + '_ {
        move |taken| mountpoint_for("/mnt", display_name, taken)
    }

    #[test]
    fn reserve_returns_new_mountpoint_then_reuses_for_same_connection() {
        let table = MountRegistry::new();
        let first = table.get_or_reserve(&id("c1"), local_propose("Minio"));

        assert!(matches!(first, Reservation::New(ref path) if path == "/mnt/minio"));
        assert!(!table.is_mounted(&id("c1")));

        table.mark_ready(&id("c1"));
        let second = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        assert!(matches!(second, Reservation::Existing(ref path) if path == "/mnt/minio"));
    }

    #[test]
    fn distinct_connections_with_same_name_get_unique_mountpoints() {
        let table = MountRegistry::new();
        let a = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let b = table.get_or_reserve(&id("c2"), local_propose("Minio"));
        assert!(matches!(a, Reservation::New(ref path) if path == "/mnt/minio"));
        assert!(matches!(b, Reservation::New(ref path) if path == "/mnt/minio-2"));
    }

    #[test]
    fn release_removes_mapping_and_returns_mountpoint() {
        let table = MountRegistry::new();
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        assert_eq!(table.release(&id("c1")), Some("/mnt/minio".into()));
        assert_eq!(table.release(&id("c1")), None);
    }

    #[test]
    fn registry_is_root_agnostic() {
        let table = MountRegistry::new();
        let r = table.get_or_reserve(&id("c1"), |_taken| "sandbox://abc/data".into());
        assert!(matches!(r, Reservation::New(ref path) if path == "sandbox://abc/data"));
    }

    #[test]
    fn shared_across_clones() {
        let table = MountRegistry::new();
        let cloned = table.clone();
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        table.mark_ready(&id("c1"));
        assert!(cloned.is_mounted(&id("c1")));
    }

    #[tokio::test]
    async fn pending_reservation_waits_until_ready_or_release() {
        let table = MountRegistry::new();
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let pending = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let Reservation::Pending(pending) = pending else {
            panic!("expected pending reservation");
        };

        table.mark_ready(&id("c1"));

        assert_eq!(pending.wait().await, Some("/mnt/minio".into()));
    }

    #[tokio::test]
    async fn pending_reservation_returns_none_after_release() {
        let table = MountRegistry::new();
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let pending = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let Reservation::Pending(pending) = pending else {
            panic!("expected pending reservation");
        };

        table.release(&id("c1"));

        assert_eq!(pending.wait().await, None);
    }

    #[tokio::test]
    async fn pending_reservation_waits_on_current_entry_after_rereserve() {
        let table = MountRegistry::new();
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let pending = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let Reservation::Pending(pending) = pending else {
            panic!("expected pending reservation");
        };

        table.release(&id("c1"));
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        table.mark_ready(&id("c1"));

        assert_eq!(pending.wait().await, Some("/mnt/minio".into()));
    }
}
