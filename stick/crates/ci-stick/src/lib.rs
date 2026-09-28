//! Companion Stick — library half of the `ci-stick` CLI.
//!
//! Module boundaries (each one is usable without the CLI):
//!
//! | module      | responsibility                                                         |
//! |-------------|------------------------------------------------------------------------|
//! | `size`      | parsing/formatting byte sizes (`512GB`, `476GiB`)                      |
//! | `layout`    | the pure, capacity-aware GPT partition plan                           |
//! | `manifest`  | the versioned `bundle.json` types (the schema's source of truth)      |
//! | `paths`     | relative-path validation (no `..`, absolute, or odd components)       |
//! | `hashing`   | streaming SHA-256                                                      |
//! | `signing`   | detached ed25519 signatures over the exact bytes of `bundle.json`     |
//! | `lock`      | staging directory -> deterministic `bundle.json`                       |
//! | `verify`    | bundle root -> signature + artifact integrity report                  |
//! | `packs`     | model-pack catalog loading and "does it fit" logic                     |
//! | `devices`   | read-only removable block-device discovery (lsblk / diskutil parsing) |
//! | `host`      | host OS/arch capability matrix                                         |
//! | `doctor`    | read-only host + device + bundle diagnostics                          |
//! | `progress`  | TTY-only progress reporting                                            |
//! | `timefmt`   | RFC 3339 timestamps without a date/time dependency                     |
//! | `grubenv`   | GRUB environment block (the A/B slot pointer) encode/decode            |
//! | `bootcfg`   | the stick's grub.cfg, rendered from the layout                         |
//! | `gpt`       | `sgdisk` arguments from a plan; read-only GPT parser for read-back     |
//! | `sparse`    | copy only a file's data extents (SEEK_DATA/SEEK_HOLE) to an offset     |
//! | `target`    | image/device targets and the device safety rules (pure + sysfs)        |
//! | `tools`     | running gdisk/dosfstools/exfatprogs/e2fsprogs/mtools                   |
//! | `flash`     | verify -> plan -> build filesystems -> write -> read back              |
//! | `slot`      | read/flip `active_slot` in the ESP's grubenv                           |
//!
//! Only `flash` and `slot set` write to a stick or stick image, and only after the checks
//! in `target` pass. Other filesystem writes are limited to `lock` (writes `bundle.json`
//! into the staging directory it was pointed at) and the `dev` signing helpers (write
//! key/signature files the caller names).

pub mod bootcfg;
pub mod devices;
pub mod doctor;
pub mod flash;
pub mod gpt;
pub mod grubenv;
pub mod hashing;
pub mod host;
pub mod layout;
pub mod lock;
pub mod manifest;
pub mod packs;
pub mod paths;
pub mod progress;
pub mod signing;
pub mod size;
pub mod slot;
pub mod sparse;
pub mod target;
pub mod timefmt;
pub mod tools;
pub mod verify;
