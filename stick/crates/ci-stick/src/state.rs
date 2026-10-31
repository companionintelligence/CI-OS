//! The per-user state directory: the sequence floors, and the optional extra revocations.
//!
//! A *floor* is the highest `sequence` of a schema 2 bundle this machine has accepted, per
//! bundle `id`. `verify` and `flash` refuse a bundle below the floor (`bundle-rollback`), or
//! at the floor with different `bundle.json` bytes (`bundle-sequence-conflict`); the very same
//! bytes are accepted again, so a stick can be re-flashed. The floor is keyed by `id` alone,
//! never by signer, so rotating the signing key cannot reset it. The signer's fingerprint is
//! stored only for diagnostics.
//!
//! Where the directory is, first match wins:
//!
//! 1. `--state-dir <dir>`
//! 2. `$CI_STICK_STATE_DIR` (an absolute path)
//! 3. Linux: `$XDG_STATE_HOME/ci-stick`, else `$HOME/.local/state/ci-stick`;
//!    macOS: `$HOME/Library/Application Support/ci-stick`;
//!    Windows: `%LOCALAPPDATA%\ci-stick`.
//!
//! Files in it:
//!
//! * `floors.json`: `{"schema":1,"floors":{"<id>":{"sequence":N,"bundle_sha256":"...",
//!   "signer":"<fingerprint>"}}}`. Replaced atomically (temp file, `fsync`, rename, `fsync`
//!   of the directory) while an exclusive `flock` on `floors.lock` is held, so two `ci-stick`
//!   processes cannot lose each other's update. On Windows the replace is atomic but not
//!   locked. The directory is created with mode 0700.
//! * `revoked.txt`: optional, one key fingerprint per line. It can only add refusals
//!   ([`crate::trust`]).
//!
//! A damaged `floors.json` is never repaired or reset: every command that needs it stops and
//! names the file, because resetting it would silently re-open the door to an old bundle.

use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::hashing::is_sha256_hex;
use crate::trust::{is_fingerprint, parse_revoked_txt};

/// Environment variable that names the state directory.
pub const STATE_DIR_ENV: &str = "CI_STICK_STATE_DIR";
pub const FLOORS_FILE: &str = "floors.json";
pub const REVOKED_FILE: &str = "revoked.txt";
const LOCK_FILE: &str = "floors.lock";
const FLOORS_SCHEMA: u32 = 1;
const APP_DIR: &str = "ci-stick";

#[derive(Debug, Error)]
pub enum StateError {
    /// No directory could be chosen (no `HOME`, a relative path, ...).
    #[error("{0}")]
    Undetermined(String),
    /// The directory, or a file that has to be created in it, cannot be used.
    #[error("{0}")]
    Unusable(String),
    /// `floors.json` or `revoked.txt` exists but cannot be read or understood. The message
    /// names the file; the file is left exactly as it was.
    #[error("{0}")]
    Damaged(String),
    /// Two accepted bundles claim the same sequence with different bytes.
    #[error("{0}")]
    Conflict(String),
}

fn unusable(dir: &Path, what: &str, e: &io::Error) -> StateError {
    StateError::Unusable(format!(
        "cannot use the state directory {}: {what}: {e}",
        dir.display()
    ))
}

fn damaged(path: &Path, why: &str) -> StateError {
    StateError::Damaged(format!(
        "{} is damaged: {why}. It was left untouched, and ci-stick never resets it: fix it, or \
         move it away to forget what it records",
        path.display()
    ))
}

// ---- where the directory is -------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Linux,
    MacOs,
    Windows,
}

impl Os {
    pub fn current() -> Os {
        if cfg!(target_os = "macos") {
            Os::MacOs
        } else if cfg!(windows) {
            Os::Windows
        } else {
            Os::Linux
        }
    }
}

/// Everything the location depends on, so that it can be resolved (and tested) without
/// touching the process environment.
#[derive(Debug, Clone, Default)]
pub struct StateEnv {
    /// `$CI_STICK_STATE_DIR`
    pub state_dir: Option<OsString>,
    /// `$XDG_STATE_HOME`
    pub xdg_state_home: Option<OsString>,
    /// `$HOME`
    pub home: Option<OsString>,
    /// `%LOCALAPPDATA%`
    pub local_app_data: Option<OsString>,
    /// The working directory, which only a relative `--state-dir` is resolved against.
    pub cwd: Option<PathBuf>,
}

impl StateEnv {
    pub fn from_process() -> Self {
        let var = |name: &str| std::env::var_os(name);
        Self {
            state_dir: var(STATE_DIR_ENV),
            xdg_state_home: var("XDG_STATE_HOME"),
            home: var("HOME"),
            local_app_data: var("LOCALAPPDATA"),
            cwd: std::env::current_dir().ok(),
        }
    }
}

/// Which rule chose the directory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum StateDirSource {
    Flag,
    Env,
    Default,
}

impl StateDirSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Flag => "--state-dir",
            Self::Env => "CI_STICK_STATE_DIR",
            Self::Default => "default location",
        }
    }
}

fn non_empty(v: &Option<OsString>) -> Option<PathBuf> {
    v.as_ref().filter(|s| !s.is_empty()).map(PathBuf::from)
}

/// Pick the state directory. Pure: it reads nothing but its arguments.
pub fn resolve_state_dir(
    os: Os,
    env: &StateEnv,
    flag: Option<&Path>,
) -> Result<(PathBuf, StateDirSource), StateError> {
    if let Some(p) = flag {
        if p.as_os_str().is_empty() {
            return Err(StateError::Undetermined("--state-dir is empty".into()));
        }
        if p.is_absolute() {
            return Ok((p.to_path_buf(), StateDirSource::Flag));
        }
        let cwd = env.cwd.as_ref().ok_or_else(|| {
            StateError::Undetermined(
                "--state-dir is relative and the working directory is unknown".into(),
            )
        })?;
        return Ok((cwd.join(p), StateDirSource::Flag));
    }
    if let Some(p) = non_empty(&env.state_dir) {
        // A relative path would put the floors wherever the command happens to run, which
        // is the same as having none.
        if !p.is_absolute() {
            return Err(StateError::Undetermined(format!(
                "{STATE_DIR_ENV} must be an absolute path (it is {:?})",
                p.display().to_string()
            )));
        }
        return Ok((p, StateDirSource::Env));
    }
    let abs = |p: Option<PathBuf>| p.filter(|p| p.is_absolute());
    let dir = match os {
        Os::Linux => abs(non_empty(&env.xdg_state_home))
            .map(|x| x.join(APP_DIR))
            .or_else(|| {
                abs(non_empty(&env.home)).map(|h| h.join(".local").join("state").join(APP_DIR))
            })
            .ok_or_else(|| {
                StateError::Undetermined(
                    "neither XDG_STATE_HOME nor HOME is an absolute path".into(),
                )
            })?,
        Os::MacOs => abs(non_empty(&env.home))
            .map(|h| h.join("Library").join("Application Support").join(APP_DIR))
            .ok_or_else(|| StateError::Undetermined("HOME is not an absolute path".into()))?,
        Os::Windows => non_empty(&env.local_app_data)
            .map(|d| d.join(APP_DIR))
            .ok_or_else(|| StateError::Undetermined("LOCALAPPDATA is not set".into()))?,
    };
    Ok((dir, StateDirSource::Default))
}

// ---- the floors ---------------------------------------------------------------------------

/// What this machine last accepted for one bundle `id`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Floor {
    pub sequence: u64,
    /// SHA-256 of the exact `bundle.json` bytes that were accepted at this sequence.
    pub bundle_sha256: String,
    /// Fingerprint of the key that signed it. For diagnostics; it never decides anything.
    pub signer: String,
}

/// A floor to record once a bundle was fully accepted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FloorUpdate {
    pub bundle_id: String,
    pub floor: Floor,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FloorFile {
    schema: u32,
    floors: BTreeMap<String, Floor>,
}

/// What [`FloorStore::record`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Recorded {
    /// The floor was raised (from `from`, or created).
    Raised { from: Option<u64> },
    /// The same bundle was already recorded.
    Unchanged,
    /// Another process recorded a higher sequence in the meantime; it was left alone.
    KeptNewer { stored: u64 },
}

fn parse_floors(bytes: &[u8]) -> Result<BTreeMap<String, Floor>, String> {
    let file: FloorFile =
        serde_json::from_slice(bytes).map_err(|e| format!("it is not floor data ({e})"))?;
    if file.schema != FLOORS_SCHEMA {
        return Err(format!(
            "schema {} is not understood (this ci-stick reads schema {FLOORS_SCHEMA})",
            file.schema
        ));
    }
    for (id, f) in &file.floors {
        if id.is_empty() || f.sequence == 0 || !is_sha256_hex(&f.bundle_sha256) {
            return Err(format!("the entry for {id:?} is not valid"));
        }
        if !is_fingerprint(&f.signer) {
            return Err(format!("the signer of {id:?} is not a key fingerprint"));
        }
    }
    Ok(file.floors)
}

#[cfg(unix)]
fn lock_exclusive(file: &File) -> io::Result<()> {
    loop {
        match rustix::fs::flock(file, rustix::fs::FlockOperation::LockExclusive) {
            Ok(()) => return Ok(()),
            Err(e) if e == rustix::io::Errno::INTR => continue,
            Err(e) => return Err(e.into()),
        }
    }
}

/// Windows has no `flock` here: the replace of `floors.json` is still atomic.
#[cfg(not(unix))]
fn lock_exclusive(_file: &File) -> io::Result<()> {
    Ok(())
}

fn create_private_dir(dir: &Path) -> Result<(), StateError> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt as _;
        builder.mode(0o700);
    }
    builder
        .create(dir)
        .map_err(|e| unusable(dir, "creating it", &e))
}

#[cfg(unix)]
fn sync_dir(dir: &Path) -> io::Result<()> {
    File::open(dir)?.sync_all()
}

#[cfg(not(unix))]
fn sync_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

/// The floors and extra revocations in one state directory.
#[derive(Debug, Clone)]
pub struct FloorStore {
    dir: PathBuf,
}

impl FloorStore {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn floors_path(&self) -> PathBuf {
        self.dir.join(FLOORS_FILE)
    }

    pub fn revoked_path(&self) -> PathBuf {
        self.dir.join(REVOKED_FILE)
    }

    /// `Ok(true)` if the directory exists, `Ok(false)` if there is nothing there yet. A file
    /// in the way, or a directory that cannot be inspected, is an error: it must not read as
    /// "no floors".
    fn exists(&self) -> Result<bool, StateError> {
        match fs::metadata(&self.dir) {
            Ok(m) if m.is_dir() => Ok(true),
            Ok(_) => Err(StateError::Unusable(format!(
                "cannot use the state directory {}: it exists and is not a directory",
                self.dir.display()
            ))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(unusable(&self.dir, "looking at it", &e)),
        }
    }

    /// Every stored floor. Read-only: it creates nothing. Missing means none; damaged is an
    /// error ([`StateError::Damaged`]) and the file is not touched.
    pub fn load(&self) -> Result<BTreeMap<String, Floor>, StateError> {
        if !self.exists()? {
            return Ok(BTreeMap::new());
        }
        let path = self.floors_path();
        match fs::read(&path) {
            Ok(bytes) => parse_floors(&bytes).map_err(|why| damaged(&path, &why)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(BTreeMap::new()),
            Err(e) => Err(damaged(&path, &format!("it cannot be read ({e})"))),
        }
    }

    /// The floor for one bundle `id`, if there is one.
    pub fn floor(&self, bundle_id: &str) -> Result<Option<Floor>, StateError> {
        Ok(self.load()?.remove(bundle_id))
    }

    /// The fingerprints in `revoked.txt`: none if the file is absent, an error naming the
    /// file and line if it is malformed.
    pub fn extra_revoked(&self) -> Result<Vec<String>, StateError> {
        if !self.exists()? {
            return Ok(Vec::new());
        }
        let path = self.revoked_path();
        match fs::read_to_string(&path) {
            Ok(text) => parse_revoked_txt(&text).map_err(|e| damaged(&path, &format!("{e}"))),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(e) => Err(damaged(&path, &format!("it cannot be read ({e})"))),
        }
    }

    /// Prove that a floor can be written here: create the directory (mode 0700) and a file in
    /// it. Nothing is left behind except the directory.
    pub fn ensure_writable(&self) -> Result<(), StateError> {
        create_private_dir(&self.dir)?;
        tempfile::Builder::new()
            .prefix(".probe-")
            .tempfile_in(&self.dir)
            .map(drop)
            .map_err(|e| unusable(&self.dir, "writing a file in it", &e))
    }

    /// Raise the floor for `update.bundle_id`. The floor only ever goes up: a lower sequence
    /// is left alone ([`Recorded::KeptNewer`]), the same bytes at the same sequence change
    /// nothing, and different bytes at the same sequence are a conflict.
    pub fn record(&self, update: &FloorUpdate) -> Result<Recorded, StateError> {
        create_private_dir(&self.dir)?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.dir.join(LOCK_FILE))
            .map_err(|e| unusable(&self.dir, "opening its lock file", &e))?;
        lock_exclusive(&lock).map_err(|e| unusable(&self.dir, "locking it", &e))?;

        // Under the lock: what is stored now, not what was read minutes ago.
        let mut floors = self.load()?;
        let new = &update.floor;
        let outcome = match floors.get(&update.bundle_id) {
            None => Recorded::Raised { from: None },
            Some(f) if f.sequence < new.sequence => Recorded::Raised {
                from: Some(f.sequence),
            },
            Some(f) if f.sequence == new.sequence && f.bundle_sha256 == new.bundle_sha256 => {
                Recorded::Unchanged
            }
            Some(f) if f.sequence == new.sequence => {
                return Err(StateError::Conflict(format!(
                    "{} already records sequence {} of {} with a different bundle.json",
                    self.floors_path().display(),
                    f.sequence,
                    update.bundle_id
                )))
            }
            Some(f) => Recorded::KeptNewer { stored: f.sequence },
        };
        if matches!(outcome, Recorded::Raised { .. }) {
            floors.insert(update.bundle_id.clone(), new.clone());
            self.write(&floors)?;
        }
        Ok(outcome)
    }

    /// Replace `floors.json`: temp file in the same directory, `fsync`, rename, `fsync` of
    /// the directory. A crash leaves either the old file or the new one.
    fn write(&self, floors: &BTreeMap<String, Floor>) -> Result<(), StateError> {
        let file = FloorFile {
            schema: FLOORS_SCHEMA,
            floors: floors.clone(),
        };
        let mut bytes = serde_json::to_vec_pretty(&file)
            .map_err(|e| StateError::Unusable(format!("cannot serialise the floors: {e}")))?;
        bytes.push(b'\n');
        let fail = |what: &str, e: &io::Error| unusable(&self.dir, what, e);
        let mut tmp = tempfile::Builder::new()
            .prefix(".floors-")
            .suffix(".tmp")
            .tempfile_in(&self.dir)
            .map_err(|e| fail("creating a temporary file", &e))?;
        tmp.write_all(&bytes)
            .map_err(|e| fail("writing the floors", &e))?;
        tmp.as_file()
            .sync_all()
            .map_err(|e| fail("flushing the floors", &e))?;
        tmp.persist(self.floors_path())
            .map_err(|e| fail("replacing floors.json", &e.error))?;
        sync_dir(&self.dir).map_err(|e| fail("flushing the directory", &e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sha(c: char) -> String {
        c.to_string().repeat(64)
    }

    fn update(id: &str, sequence: u64, sha_char: char) -> FloorUpdate {
        FloorUpdate {
            bundle_id: id.into(),
            floor: Floor {
                sequence,
                bundle_sha256: sha(sha_char),
                signer: "0123456789abcdef".into(),
            },
        }
    }

    fn store() -> (tempfile::TempDir, FloorStore) {
        let t = tempfile::tempdir().unwrap();
        let s = FloorStore::new(t.path().join("state"));
        (t, s)
    }

    // ---- location ----

    fn env() -> StateEnv {
        StateEnv {
            state_dir: None,
            xdg_state_home: Some("/xdg".into()),
            home: Some("/home/u".into()),
            local_app_data: Some("C:\\Users\\u\\AppData\\Local".into()),
            cwd: Some("/work".into()),
        }
    }

    #[test]
    fn the_flag_beats_the_variable_beats_the_default() {
        let mut e = env();
        e.state_dir = Some("/from-env".into());
        let (p, src) = resolve_state_dir(Os::Linux, &e, Some(Path::new("/from-flag"))).unwrap();
        assert_eq!((p, src), ("/from-flag".into(), StateDirSource::Flag));
        let (p, src) = resolve_state_dir(Os::Linux, &e, None).unwrap();
        assert_eq!((p, src), ("/from-env".into(), StateDirSource::Env));
        e.state_dir = None;
        let (p, src) = resolve_state_dir(Os::Linux, &e, None).unwrap();
        assert_eq!((p, src), ("/xdg/ci-stick".into(), StateDirSource::Default));
    }

    #[test]
    fn the_default_follows_the_platform() {
        let mut e = env();
        let linux = |e: &StateEnv| resolve_state_dir(Os::Linux, e, None).unwrap().0;
        assert_eq!(linux(&e), PathBuf::from("/xdg/ci-stick"));
        e.xdg_state_home = None;
        assert_eq!(linux(&e), PathBuf::from("/home/u/.local/state/ci-stick"));
        e.xdg_state_home = Some("relative/xdg".into());
        assert_eq!(
            linux(&e),
            PathBuf::from("/home/u/.local/state/ci-stick"),
            "a relative XDG_STATE_HOME is ignored"
        );
        e.xdg_state_home = Some("".into());
        assert_eq!(linux(&e), PathBuf::from("/home/u/.local/state/ci-stick"));

        let (mac, _) = resolve_state_dir(Os::MacOs, &env(), None).unwrap();
        assert_eq!(
            mac,
            PathBuf::from("/home/u/Library/Application Support/ci-stick")
        );
        let (win, _) = resolve_state_dir(Os::Windows, &env(), None).unwrap();
        assert!(win.starts_with("C:\\Users\\u\\AppData\\Local"), "{win:?}");
        assert_eq!(win.file_name().unwrap(), "ci-stick");
    }

    #[test]
    fn an_undeterminable_directory_is_an_error_not_a_guess() {
        let nothing = StateEnv::default();
        for os in [Os::Linux, Os::MacOs, Os::Windows] {
            assert!(
                matches!(
                    resolve_state_dir(os, &nothing, None),
                    Err(StateError::Undetermined(_))
                ),
                "{os:?}"
            );
        }
        let mut e = env();
        e.state_dir = Some("relative".into());
        let err = resolve_state_dir(Os::Linux, &e, None).unwrap_err();
        assert!(format!("{err}").contains("absolute"), "{err}");
        e.state_dir = None;
        e.xdg_state_home = None;
        e.home = Some("relative-home".into());
        assert!(resolve_state_dir(Os::Linux, &e, None).is_err());
        assert!(resolve_state_dir(Os::MacOs, &e, None).is_err());
        assert!(resolve_state_dir(Os::Linux, &env(), Some(Path::new(""))).is_err());
    }

    #[test]
    fn a_relative_flag_is_taken_from_the_working_directory() {
        let (p, _) = resolve_state_dir(Os::Linux, &env(), Some(Path::new("here/state"))).unwrap();
        assert_eq!(p, PathBuf::from("/work/here/state"));
        let mut e = env();
        e.cwd = None;
        assert!(resolve_state_dir(Os::Linux, &e, Some(Path::new("here"))).is_err());
    }

    // ---- the store ----

    #[test]
    fn reading_creates_nothing() {
        let (_t, s) = store();
        assert!(s.load().unwrap().is_empty());
        assert_eq!(s.floor("x").unwrap(), None);
        assert!(s.extra_revoked().unwrap().is_empty());
        assert!(!s.dir().exists(), "a read must not create the directory");
    }

    #[test]
    fn a_recorded_floor_is_read_back() {
        let (_t, s) = store();
        let out = s.record(&update("alpha", 2, 'a')).unwrap();
        assert_eq!(out, Recorded::Raised { from: None });
        let f = s.floor("alpha").unwrap().unwrap();
        assert_eq!(f.sequence, 2);
        assert_eq!(f.bundle_sha256, sha('a'));
        assert_eq!(s.floor("beta").unwrap(), None);
        let text = fs::read_to_string(s.floors_path()).unwrap();
        assert!(
            text.contains("\"schema\": 1") && text.ends_with("}\n"),
            "{text}"
        );
        let names: Vec<String> = fs::read_dir(s.dir())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            names.iter().all(|n| n == FLOORS_FILE || n == LOCK_FILE),
            "temporary files are cleaned up: {names:?}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn the_directory_is_private() {
        use std::os::unix::fs::PermissionsExt as _;
        let (_t, s) = store();
        s.record(&update("alpha", 1, 'a')).unwrap();
        let mode = |p: PathBuf| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(s.dir().to_path_buf()), 0o700);
        assert_eq!(mode(s.floors_path()), 0o600);
    }

    #[test]
    fn the_floor_only_goes_up() {
        let (_t, s) = store();
        s.record(&update("alpha", 3, 'a')).unwrap();
        // A lower sequence (another process won the race) leaves the floor where it is.
        assert_eq!(
            s.record(&update("alpha", 2, 'b')).unwrap(),
            Recorded::KeptNewer { stored: 3 }
        );
        assert_eq!(s.floor("alpha").unwrap().unwrap().sequence, 3);
        // The same bytes again change nothing.
        assert_eq!(
            s.record(&update("alpha", 3, 'a')).unwrap(),
            Recorded::Unchanged
        );
        // Different bytes at the same sequence are a conflict, and nothing is written.
        let before = fs::read(s.floors_path()).unwrap();
        let err = s.record(&update("alpha", 3, 'c')).unwrap_err();
        assert!(matches!(err, StateError::Conflict(_)), "{err}");
        assert_eq!(fs::read(s.floors_path()).unwrap(), before);
        // A higher one raises it, and other ids are independent.
        assert_eq!(
            s.record(&update("alpha", 4, 'd')).unwrap(),
            Recorded::Raised { from: Some(3) }
        );
        s.record(&update("beta", 1, 'e')).unwrap();
        assert_eq!(s.load().unwrap().len(), 2);
    }

    #[test]
    fn a_damaged_floor_file_is_refused_and_left_alone() {
        for (what, content) in [
            ("garbage", "not json at all".to_string()),
            ("empty", String::new()),
            ("another schema", "{\"schema\":2,\"floors\":{}}".to_string()),
            ("unknown key", "{\"schema\":1,\"floors\":{},\"x\":1}".to_string()),
            (
                "sequence zero",
                format!(
                    "{{\"schema\":1,\"floors\":{{\"a\":{{\"sequence\":0,\"bundle_sha256\":\"{}\",\"signer\":\"0123456789abcdef\"}}}}}}",
                    sha('a')
                ),
            ),
            (
                "short digest",
                "{\"schema\":1,\"floors\":{\"a\":{\"sequence\":1,\"bundle_sha256\":\"abc\",\"signer\":\"0123456789abcdef\"}}}".to_string(),
            ),
            (
                "bad signer",
                format!(
                    "{{\"schema\":1,\"floors\":{{\"a\":{{\"sequence\":1,\"bundle_sha256\":\"{}\",\"signer\":\"zz\"}}}}}}",
                    sha('a')
                ),
            ),
        ] {
            let (_t, s) = store();
            fs::create_dir_all(s.dir()).unwrap();
            fs::write(s.floors_path(), &content).unwrap();
            for result in [
                s.load().map(drop),
                s.floor("a").map(drop),
                s.record(&update("a", 9, 'f')).map(drop),
            ] {
                let err = result.unwrap_err();
                assert!(matches!(err, StateError::Damaged(_)), "{what}: {err}");
                assert!(format!("{err}").contains("floors.json"), "{what}: {err}");
            }
            assert_eq!(
                fs::read_to_string(s.floors_path()).unwrap(),
                content,
                "{what}: the damaged file must be left exactly as it was"
            );
        }
    }

    #[test]
    fn a_file_in_the_way_is_an_unusable_directory_not_an_empty_one() {
        let t = tempfile::tempdir().unwrap();
        let blocker = t.path().join("blocker");
        fs::write(&blocker, b"x").unwrap();
        for dir in [blocker.clone(), blocker.join("below")] {
            let s = FloorStore::new(dir);
            assert!(matches!(s.ensure_writable(), Err(StateError::Unusable(_))));
            assert!(matches!(
                s.record(&update("a", 1, 'a')),
                Err(StateError::Unusable(_))
            ));
        }
        assert!(matches!(
            FloorStore::new(blocker).load(),
            Err(StateError::Unusable(_))
        ));
    }

    #[test]
    fn a_writable_directory_is_proved_without_leaving_files() {
        let (_t, s) = store();
        s.ensure_writable().unwrap();
        assert!(s.dir().is_dir());
        assert_eq!(fs::read_dir(s.dir()).unwrap().count(), 0);
        assert!(!s.floors_path().exists(), "probing must not record a floor");
    }

    #[test]
    fn extra_revocations_come_from_revoked_txt() {
        let (_t, s) = store();
        fs::create_dir_all(s.dir()).unwrap();
        fs::write(s.revoked_path(), "# why\n0123456789ABCDEF\n").unwrap();
        assert_eq!(s.extra_revoked().unwrap(), vec!["0123456789abcdef"]);
        fs::write(s.revoked_path(), "0123456789abcdef\nnope\n").unwrap();
        let err = s.extra_revoked().unwrap_err();
        assert!(matches!(err, StateError::Damaged(_)), "{err}");
        let msg = format!("{err}");
        assert!(
            msg.contains("revoked.txt") && msg.contains("line 2"),
            "{msg}"
        );
    }

    #[test]
    fn simultaneous_writers_do_not_lose_updates() {
        let (_t, s) = store();
        let ids: Vec<String> = (0..8).map(|i| format!("bundle-{i}")).collect();
        let threads: Vec<_> = ids
            .iter()
            .map(|id| {
                let (s, id) = (s.clone(), id.clone());
                std::thread::spawn(move || {
                    for seq in 1..=10u64 {
                        s.record(&update(&id, seq, 'a')).unwrap();
                    }
                })
            })
            .collect();
        for t in threads {
            t.join().unwrap();
        }
        let floors = s.load().unwrap();
        assert_eq!(floors.len(), ids.len(), "{floors:?}");
        assert!(floors.values().all(|f| f.sequence == 10));
    }
}
