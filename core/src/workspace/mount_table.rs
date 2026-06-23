//! Mount registry for connection-to-mountpoint reservations.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use crate::connection::ConnectionId;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reservation {
    New(String),
    Existing(String),
}

#[derive(Clone, Default)]
pub struct MountRegistry {
    inner: Arc<Mutex<HashMap<ConnectionId, String>>>,
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
            return Reservation::Existing(existing.clone());
        }

        let taken: Vec<String> = guard.values().cloned().collect();
        let mountpoint = propose(&taken);
        guard.insert(id.clone(), mountpoint.clone());
        Reservation::New(mountpoint)
    }

    pub fn release(&self, id: &ConnectionId) -> Option<String> {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard.remove(id)
    }

    pub fn is_mounted(&self, id: &ConnectionId) -> bool {
        let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard.contains_key(id)
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
        assert_eq!(first, Reservation::New("/mnt/minio".into()));

        let second = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        assert_eq!(second, Reservation::Existing("/mnt/minio".into()));
    }

    #[test]
    fn distinct_connections_with_same_name_get_unique_mountpoints() {
        let table = MountRegistry::new();
        let a = table.get_or_reserve(&id("c1"), local_propose("Minio"));
        let b = table.get_or_reserve(&id("c2"), local_propose("Minio"));
        assert_eq!(a, Reservation::New("/mnt/minio".into()));
        assert_eq!(b, Reservation::New("/mnt/minio-2".into()));
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
        assert_eq!(r, Reservation::New("sandbox://abc/data".into()));
    }

    #[test]
    fn shared_across_clones() {
        let table = MountRegistry::new();
        let cloned = table.clone();
        table.get_or_reserve(&id("c1"), local_propose("Minio"));
        assert!(cloned.is_mounted(&id("c1")));
    }
}
