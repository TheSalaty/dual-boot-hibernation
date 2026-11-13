//! Drives that Windows can write to.
//!
//! A frozen Linux that still has such a drive mounted wakes up with a stale
//! view of it, which corrupts the drive. They are unmounted before the handoff
//! and mounted again afterwards. Linux-only filesystems (Btrfs, ext4) stay
//! mounted: Windows has no driver that writes to them.

use std::fs;

const WINDOWS_WRITABLE: &[&str] = &["ntfs", "ntfs3", "ntfs-3g", "fuseblk", "exfat", "vfat"];

/// The EFI partition is shared by design and written by both systems only
/// while they run; unmounting it would break boot-entry updates.
fn is_esp(target: &str) -> bool {
    matches!(target, "/boot" | "/boot/efi" | "/efi")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mount {
    pub source: String,
    pub target: String,
    pub fstype: String,
}

/// `/proc/mounts` and `fstab` write a space as `\040`.
fn unescape(field: &str) -> String {
    let b = field.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() {
            if let Ok(code) = u8::from_str_radix(&field[i + 1..i + 4], 8) {
                out.push(code);
                i += 4;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn parse_table(text: &str) -> Vec<(Mount, String)> {
    text.lines()
        .filter(|l| !l.trim_start().starts_with('#'))
        .filter_map(|l| {
            let mut f = l.split_whitespace();
            let (source, target, fstype) = (f.next()?, f.next()?, f.next()?);
            let options = f.next().unwrap_or("").to_string();
            Some((
                Mount {
                    source: unescape(source),
                    target: unescape(target),
                    fstype: fstype.to_string(),
                },
                options,
            ))
        })
        .collect()
}

pub fn windows_writable(text: &str) -> Vec<Mount> {
    parse_table(text)
        .into_iter()
        .map(|(m, _)| m)
        .filter(|m| WINDOWS_WRITABLE.contains(&m.fstype.as_str()) && !is_esp(&m.target))
        .collect()
}

/// Windows-writable drives that are mounted right now.
pub fn mounted() -> Vec<Mount> {
    windows_writable(&fs::read_to_string("/proc/self/mounts").unwrap_or_default())
}

/// Mount points `fstab` wants mounted at boot, minus the ones that are.
pub fn missing() -> Vec<String> {
    let table = fs::read_to_string("/etc/fstab").unwrap_or_default();
    let now: Vec<String> = mounted().into_iter().map(|m| m.target).collect();
    parse_table(&table)
        .into_iter()
        .filter(|(m, opts)| {
            WINDOWS_WRITABLE.contains(&m.fstype.as_str())
                && !is_esp(&m.target)
                && !opts.split(',').any(|o| o == "noauto")
        })
        .map(|(m, _)| m.target)
        .filter(|t| !now.contains(t))
        .collect()
}

/// Processes with their working directory or an open file on `mount_point`.
/// Without root only the caller's own processes are visible.
pub fn users_of(mount_point: &str) -> Vec<(u32, String)> {
    let inside = |p: &std::path::Path| p.starts_with(mount_point);
    let me = std::process::id();
    let mut found = Vec::new();
    let Ok(procs) = fs::read_dir("/proc") else {
        return found;
    };
    for entry in procs.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        if pid == me {
            continue;
        }
        let dir = entry.path();
        let cwd = fs::read_link(dir.join("cwd"))
            .map(|p| inside(&p))
            .unwrap_or(false);
        let fd = fs::read_dir(dir.join("fd"))
            .map(|fds| {
                fds.flatten()
                    .any(|f| fs::read_link(f.path()).map(|p| inside(&p)).unwrap_or(false))
            })
            .unwrap_or(false);
        if cwd || fd {
            let name = fs::read_to_string(dir.join("comm")).unwrap_or_default();
            found.push((pid, name.trim().to_string()));
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOUNTS: &str = "/dev/nvme0n1p5 / btrfs rw 0 0\n\
/dev/nvme0n1p1 /boot/efi vfat rw 0 0\n\
/dev/nvme0n1p3 /mnt/win_nvme1_a fuseblk rw 0 0\n\
/dev/sdb1 /mnt/My\\040Stick exfat rw 0 0\n\
/dev/nvme1n1p1 /mnt/daten btrfs rw 0 0\n";

    #[test]
    fn keeps_windows_writable_drives_only() {
        let targets: Vec<String> = windows_writable(MOUNTS)
            .into_iter()
            .map(|m| m.target)
            .collect();
        assert_eq!(targets, ["/mnt/win_nvme1_a", "/mnt/My Stick"]);
    }

    #[test]
    fn skips_comments() {
        assert!(windows_writable("# /dev/sda1 /mnt/x ntfs rw 0 0\n").is_empty());
    }
}
