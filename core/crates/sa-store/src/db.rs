//! The database handle: one dedicated writer thread, a pool of read-only connections (WAL mode).
//!
//! Callers never hold a `Connection` across an `await`: both [`Db::read`] and [`Db::write`] are blocking calls
//! that run a closure, and the async layer above wraps them in `spawn_blocking`.

use crate::error::DbResultExt;
use crate::migrate;
use crossbeam_channel::{Receiver, Sender, bounded, unbounded};
use parking_lot::Mutex;
use rusqlite::{Connection, OpenFlags, Transaction, TransactionBehavior};
use sa_core::{Error, Result};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::JoinHandle;

type WriteJob = Box<dyn FnOnce(&mut Connection) + Send + 'static>;

const READER_COUNT: usize = 4;
const CLEAN_EXIT_KEY: &str = "session.clean_exit";

/// `Ok(())` when SQLite reports the database healthy, otherwise the problems it found.
pub type CheckOutcome = std::result::Result<(), String>;

/// What happened while opening the database.
#[derive(Debug, Clone)]
pub struct OpenReport {
    /// Schema version found on disk (0 for a new database).
    pub schema_before: i64,
    pub schema_after: i64,
    /// The previous session did not shut down cleanly.
    pub unclean_exit: bool,
    /// `PRAGMA quick_check` was run (after an unclean exit) and its outcome.
    pub quick_check: Option<CheckOutcome>,
}

struct Shared {
    path: PathBuf,
    writer: Mutex<Option<Sender<WriteJob>>>,
    writer_thread: Mutex<Option<JoinHandle<()>>>,
    pool_tx: Sender<Connection>,
    pool_rx: Receiver<Connection>,
}

/// Cheap to clone; all clones share the same connections.
#[derive(Clone)]
pub struct Db {
    shared: Arc<Shared>,
}

impl std::fmt::Debug for Db {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Db").field("path", &self.shared.path).finish_non_exhaustive()
    }
}

fn apply_pragmas(conn: &Connection, read_only: bool) -> Result<()> {
    // Writers: WAL + NORMAL is crash-safe (no corruption) and fast; at worst the last commit is lost on power failure.
    let cache_kb = if read_only { 16 * 1024 } else { 32 * 1024 };
    let mut sql = format!(
        "PRAGMA busy_timeout = 5000;
         PRAGMA foreign_keys = ON;
         PRAGMA temp_store = MEMORY;
         PRAGMA cache_size = -{cache_kb};"
    );
    if read_only {
        sql.push_str("PRAGMA query_only = ON; PRAGMA mmap_size = 134217728;");
    } else {
        sql.push_str(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA journal_size_limit = 67108864;
             PRAGMA wal_autocheckpoint = 2000;",
        );
    }
    conn.execute_batch(&sql).db()
}

impl Db {
    /// Opens (creating if needed) the library database and migrates it to the latest schema.
    ///
    /// # Errors
    /// Fails if the file is not a database, is corrupt, or was written by a newer app version.
    pub fn open(path: &Path) -> Result<(Self, OpenReport)> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| Error::io("create directory", parent, &e))?;
        }
        let mut writer = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .db()?;
        apply_pragmas(&writer, false)?;

        let schema_before = migrate::current_version(&writer)?;
        if schema_before > migrate::LATEST_VERSION {
            return Err(Error::SchemaTooNew {
                found: schema_before,
                supported: migrate::LATEST_VERSION,
            });
        }
        if schema_before > 0 && schema_before < migrate::LATEST_VERSION {
            backup_before_migration(&writer, path, schema_before)?;
        }
        migrate::migrate(&mut writer)?;

        // Unclean-exit detection: the flag is cleared while the app runs and set again by `close()`.
        let previous: Option<String> = writer
            .query_row("SELECT value FROM settings WHERE key = ?1", [CLEAN_EXIT_KEY], |r| r.get(0))
            .ok();
        let unclean_exit = previous.as_deref() == Some("0");
        let quick_check = if unclean_exit {
            Some(quick_check(&writer))
        } else {
            None
        };
        writer
            .execute(
                "INSERT INTO settings(key, value) VALUES (?1, '0')
                 ON CONFLICT(key) DO UPDATE SET value = '0'",
                [CLEAN_EXIT_KEY],
            )
            .db()?;

        let (pool_tx, pool_rx) = bounded(READER_COUNT);
        for _ in 0..READER_COUNT {
            let conn = Connection::open_with_flags(
                path,
                OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
            )
            .db()?;
            apply_pragmas(&conn, true)?;
            pool_tx.send(conn).map_err(|_| Error::Db("reader pool closed".into()))?;
        }

        let (tx, rx) = unbounded::<WriteJob>();
        let handle = std::thread::Builder::new()
            .name("sa-db-writer".into())
            .spawn(move || {
                let mut conn = writer;
                while let Ok(job) = rx.recv() {
                    job(&mut conn);
                }
                // Channel closed: checkpoint the WAL so the file on disk is self-contained.
                let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
            })
            .map_err(|e| Error::Db(format!("cannot start writer thread: {e}")))?;

        let report = OpenReport {
            schema_before,
            schema_after: migrate::LATEST_VERSION,
            unclean_exit,
            quick_check,
        };
        let db = Self {
            shared: Arc::new(Shared {
                path: path.to_path_buf(),
                writer: Mutex::new(Some(tx)),
                writer_thread: Mutex::new(Some(handle)),
                pool_tx,
                pool_rx,
            }),
        };
        Ok((db, report))
    }

    #[must_use]
    pub fn path(&self) -> &Path {
        &self.shared.path
    }

    /// Runs `f` on a read-only connection. Many reads run in parallel with the single writer.
    pub fn read<R>(&self, f: impl FnOnce(&Connection) -> Result<R>) -> Result<R> {
        let conn = self
            .shared
            .pool_rx
            .recv()
            .map_err(|_| Error::Db("database is closed".into()))?;
        let guard = PooledConn { conn: Some(conn), pool: &self.shared.pool_tx };
        f(guard.get())
    }

    /// Runs `f` inside one write transaction on the writer thread. Commits when `f` returns `Ok`,
    /// rolls back on `Err` or panic. Keep each call short (ingest in batches of about a thousand rows).
    pub fn write<R: Send + 'static>(
        &self,
        f: impl FnOnce(&Transaction<'_>) -> Result<R> + Send + 'static,
    ) -> Result<R> {
        self.write_conn(move |conn| {
            let tx = conn
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .db()?;
            let out = f(&tx)?;
            tx.commit().db()?;
            Ok(out)
        })
    }

    /// Like [`Db::write`] but hands out the raw connection, for statements that cannot run inside a transaction
    /// (backup, `VACUUM INTO`, checkpoints).
    pub fn write_conn<R: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<R> + Send + 'static,
    ) -> Result<R> {
        let (reply_tx, reply_rx) = bounded::<Result<R>>(1);
        let job: WriteJob = Box::new(move |conn| {
            let out = catch_unwind(AssertUnwindSafe(|| f(conn)))
                .unwrap_or_else(|_| Err(Error::Db("write task panicked".into())));
            let _ = reply_tx.send(out);
        });
        {
            let guard = self.shared.writer.lock();
            let sender = guard
                .as_ref()
                .ok_or_else(|| Error::Db("database is closed".into()))?;
            sender
                .send(job)
                .map_err(|_| Error::Db("writer thread stopped".into()))?;
        }
        reply_rx
            .recv()
            .map_err(|_| Error::Db("writer thread stopped".into()))?
    }

    /// Marks the session as cleanly finished and stops the writer thread. Further calls fail with an error.
    pub fn close(&self) -> Result<()> {
        let flagged = self.write(|tx| {
            tx.execute(
                "INSERT INTO settings(key, value) VALUES (?1, '1')
                 ON CONFLICT(key) DO UPDATE SET value = '1'",
                [CLEAN_EXIT_KEY],
            )
            .db()?;
            Ok(())
        });
        let sender = self.shared.writer.lock().take();
        drop(sender);
        if let Some(handle) = self.shared.writer_thread.lock().take() {
            let _ = handle.join();
        }
        flagged
    }

    /// Copies the database to `dest` using SQLite's online backup, safe while the app is running.
    pub fn snapshot_to(&self, dest: &Path) -> Result<()> {
        let dest = dest.to_path_buf();
        self.write_conn(move |conn| {
            let mut out = Connection::open(&dest).db()?;
            let backup = rusqlite::backup::Backup::new(conn, &mut out).db()?;
            backup
                .run_to_completion(256, std::time::Duration::from_millis(5), None)
                .db()?;
            Ok(())
        })
    }

    /// `PRAGMA integrity_check`, run on a reader so the app stays usable.
    pub fn integrity_check(&self) -> Result<CheckOutcome> {
        self.read(|conn| Ok(run_check(conn, "integrity_check")))
    }
}

struct PooledConn<'a> {
    conn: Option<Connection>,
    pool: &'a Sender<Connection>,
}

impl PooledConn<'_> {
    fn get(&self) -> &Connection {
        // `conn` is only `None` after `drop` has run.
        self.conn.as_ref().expect("pooled connection present until dropped")
    }
}

impl Drop for PooledConn<'_> {
    fn drop(&mut self) {
        if let Some(conn) = self.conn.take() {
            let _ = self.pool.send(conn);
        }
    }
}

fn run_check(conn: &Connection, pragma: &str) -> CheckOutcome {
    let mut stmt = match conn.prepare(&format!("PRAGMA {pragma}")) {
        Ok(s) => s,
        Err(e) => return Err(e.to_string()),
    };
    let rows: Vec<String> = match stmt.query_map([], |r| r.get::<_, String>(0)) {
        Ok(it) => it.filter_map(std::result::Result::ok).collect(),
        Err(e) => return Err(e.to_string()),
    };
    if rows.len() == 1 && rows[0] == "ok" {
        Ok(())
    } else {
        Err(rows.join("; "))
    }
}

fn quick_check(conn: &Connection) -> CheckOutcome {
    run_check(conn, "quick_check")
}

/// Keeps a copy of the pre-upgrade database next to it so a bad migration never costs the user their library.
fn backup_before_migration(conn: &Connection, path: &Path, from_version: i64) -> Result<()> {
    conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").db()?;
    let mut name = path
        .file_name()
        .map(std::ffi::OsStr::to_os_string)
        .unwrap_or_default();
    name.push(format!(".pre-v{from_version}"));
    let dest = path.with_file_name(name);
    std::fs::copy(path, &dest).map_err(|e| Error::io("back up database", &dest, &e))?;
    Ok(())
}
