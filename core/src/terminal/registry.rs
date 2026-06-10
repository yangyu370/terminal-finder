use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use tokio::sync::mpsc;
use uuid::Uuid;

use super::session::{SessionHandle, TerminalEvent, TerminalSession};

#[derive(Clone, Default)]
pub struct TerminalRegistry {
    sessions: Arc<Mutex<HashMap<Uuid, SessionHandle>>>,
}

impl TerminalRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create_session(
        &self,
        cwd: PathBuf,
        cols: u16,
        rows: u16,
        events: mpsc::Sender<TerminalEvent>,
    ) -> anyhow::Result<Uuid> {
        let session = TerminalSession::spawn(cwd, cols, rows, events)?;
        let session_id = session.id();
        self.sessions
            .lock()
            .expect("terminal registry lock is not poisoned")
            .insert(session_id, session);
        Ok(session_id)
    }

    pub fn session(&self, session_id: Uuid) -> Option<SessionHandle> {
        self.sessions
            .lock()
            .expect("terminal registry lock is not poisoned")
            .get(&session_id)
            .cloned()
    }

    pub fn remove(&self, session_id: Uuid) -> Option<SessionHandle> {
        self.sessions
            .lock()
            .expect("terminal registry lock is not poisoned")
            .remove(&session_id)
    }

    pub fn close(&self, session_id: Uuid) -> bool {
        self.remove(session_id)
            .map(|session| {
                session.close();
                true
            })
            .unwrap_or(false)
    }

    pub fn close_many<I>(&self, session_ids: I)
    where
        I: IntoIterator<Item = Uuid>,
    {
        for session_id in session_ids {
            self.close(session_id);
        }
    }

    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.sessions
            .lock()
            .expect("terminal registry lock is not poisoned")
            .len()
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    #[cfg(test)]
    pub fn is_shared_with(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.sessions, &other.sessions)
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    #[test]
    fn empty_registry_returns_no_session() {
        let registry = TerminalRegistry::new();

        assert!(registry.session(Uuid::new_v4()).is_none());
        assert_eq!(registry.len(), 0);
    }
}
