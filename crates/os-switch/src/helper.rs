//! The privileged half. `install.sh` allows exactly `os-switch helper …` through
//! sudo without a password, so every action here is fixed: none of them takes a
//! free-form command, path or boot target from the caller.

use crate::config::{Backend, Config};
use crate::{drives, efi};
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// Saved boot order of a sticky trip; its presence means "a trip is active".
pub const TRIP_FILE: &str = "/var/lib/os-switch/boot-order";
const RTC_MARK: &str = "/run/os-switch/rtc";
/// Extra seconds for the clock wake-up, learned from wake-ups that came early.
const RTC_EXTRA: &str = "/var/lib/os-switch/rtc-extra";
const RTC_EXTRA_STEP: u64 = 10;
const RTC_EXTRA_MAX: u64 = 120;
const SLEEP_DROPIN: &str = "/etc/systemd/sleep.conf.d/90-os-switch.conf";
const WAKE_ALARM: &str = "/sys/class/rtc/rtc0/wakealarm";
/// Read by the GRUB snippet that `install.sh` generates for the grub backend.
pub const GRUB_ENV: &str = "EFI/os-switch/grubenv";

type Res = Result<(), String>;

fn run(cmd: &str, args: &[&str]) -> Res {
    let out = Command::new(cmd)
        .args(args)
        .stdout(Stdio::null())
        .output()
        .map_err(|e| format!("{cmd}: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{cmd} {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ))
    }
}

fn write(path: &str, content: &str) -> Res {
    if let Some(dir) = Path::new(path).parent() {
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    fs::write(path, content).map_err(|e| format!("{path}: {e}"))
}

fn is_root() -> bool {
    fs::metadata("/proc/self")
        .map(|m| m.uid() == 0)
        .unwrap_or(false)
}

/// Mount point of the EFI partition.
pub fn esp() -> Option<PathBuf> {
    let mounts = fs::read_to_string("/proc/self/mounts").ok()?;
    ["/boot/efi", "/efi", "/boot"].iter().find_map(|candidate| {
        mounts
            .lines()
            .any(|l| {
                let mut f = l.split_whitespace();
                f.nth(1) == Some(candidate) && f.next() == Some("vfat")
            })
            .then(|| PathBuf::from(candidate))
    })
}

fn grub_flag(value: &str) -> Res {
    let env = esp().ok_or("EFI partition is not mounted")?.join(GRUB_ENV);
    let env = env.to_string_lossy().into_owned();
    if !Path::new(&env).exists() {
        if value == "0" {
            return Ok(());
        }
        if let Some(dir) = Path::new(&env).parent() {
            fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        run("grub-editenv", &[&env, "create"])?;
    }
    run(
        "grub-editenv",
        &[&env, "set", &format!("os_switch_windows={value}")],
    )
}

/// Point the machine at Windows for the coming boot(s).
fn trip_begin(cfg: &Config) -> Res {
    match cfg.backend {
        Backend::Grub => grub_flag("1"),
        Backend::Efi => {
            let efi = efi::read()?;
            let win = efi
                .windows(cfg.windows_entry.as_deref())
                .ok_or("no Windows boot entry in the firmware")?
                .num
                .clone();
            if !cfg.sticky {
                return run("efibootmgr", &["-n", &win]);
            }
            if !Path::new(TRIP_FILE).exists() {
                write(TRIP_FILE, &efi.order.join(","))?;
            }
            run("efibootmgr", &["-o", &efi.order_with_first(&win).join(",")])
        }
    }
}

/// Undo `trip_begin` and the hibernate mode. Safe to call at any time.
fn trip_end(cfg: &Config) -> Res {
    hibernate_mode("normal")?;
    match cfg.backend {
        Backend::Grub => grub_flag("0"),
        Backend::Efi => {
            if let Ok(saved) = fs::read_to_string(TRIP_FILE) {
                let saved = saved.trim();
                let valid = !saved.is_empty()
                    && saved
                        .split(',')
                        .all(|n| n.len() == 4 && n.chars().all(|c| c.is_ascii_hexdigit()));
                if valid {
                    run("efibootmgr", &["-o", saved])?;
                }
                fs::remove_file(TRIP_FILE).map_err(|e| format!("{TRIP_FILE}: {e}"))?;
            }
            let efi = efi::read()?;
            let win = efi
                .windows(cfg.windows_entry.as_deref())
                .map(|e| e.num.clone());
            if efi.next.is_some() && efi.next == win {
                run("efibootmgr", &["-N"])?;
            }
            Ok(())
        }
    }
}

fn hibernate_mode(mode: &str) -> Res {
    let had_alarm = Path::new(RTC_MARK).exists();
    fs::remove_file(SLEEP_DROPIN).ok();
    fs::remove_file(RTC_MARK).ok();
    match mode {
        "normal" => {
            if had_alarm {
                fs::write(WAKE_ALARM, "0").ok();
            }
            Ok(())
        }
        "reboot" => write(SLEEP_DROPIN, "[Sleep]\nHibernateMode=reboot\n"),
        "rtc" => write(RTC_MARK, ""),
        other => Err(format!("unknown hibernate mode: {other}")),
    }
}

/// Seconds until the clock switches the machine back on. It has to outlast
/// freezing and writing the image, which grows with the image size; an alarm
/// that fires earlier counts as a wake-up and cancels the hibernation.
///
/// The image holds everything that is not free, capped at the kernel's target
/// size (`/sys/power/image_size`), but never less than what cannot be dropped.
pub fn rtc_wait_secs(meminfo: &str, image_size_bytes: u64, cfg: &Config) -> u64 {
    let kb = |key: &str| {
        meminfo
            .lines()
            .find_map(|l| l.strip_prefix(key))
            .and_then(|v| v.split_whitespace().next())
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0)
    };
    let total = kb("MemTotal:");
    let in_use = total.saturating_sub(kb("MemFree:"));
    let needed = total.saturating_sub(kb("MemAvailable:"));
    let image_kb = in_use.min(image_size_bytes / 1024).max(needed);
    cfg.rtc_base_secs + (image_kb * cfg.rtc_tenths_per_gb / 10).div_ceil(1024 * 1024)
}

fn rtc_extra() -> u64 {
    fs::read_to_string(RTC_EXTRA)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(0)
        .min(RTC_EXTRA_MAX)
}

/// The clock woke the machine before it was off: allow more time from now on.
fn rtc_slower() -> Res {
    let extra = (rtc_extra() + RTC_EXTRA_STEP).min(RTC_EXTRA_MAX);
    write(RTC_EXTRA, &extra.to_string())
}

fn arm_rtc(cfg: &Config) -> Res {
    run("sync", &[])?;
    fs::write("/proc/sys/vm/drop_caches", "3").ok();
    let image_size = fs::read_to_string("/sys/power/image_size")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or(u64::MAX);
    let wait = rtc_wait_secs(
        &fs::read_to_string("/proc/meminfo").unwrap_or_default(),
        image_size,
        cfg,
    ) + rtc_extra();
    // Lands in the journal: the number to look at when tuning the timing.
    eprintln!("os-switch: the clock switches the machine back on in {wait} s");
    fs::write(WAKE_ALARM, "0").ok();
    fs::write(WAKE_ALARM, format!("+{wait}")).map_err(|e| format!("{WAKE_ALARM}: {e}"))
}

fn checked_drive(mount_point: &str) -> Result<&str, String> {
    drives::mounted()
        .iter()
        .any(|m| m.target == mount_point)
        .then_some(mount_point)
        .ok_or_else(|| format!("{mount_point} is not a mounted Windows-writable drive"))
}

fn mount_all() -> Res {
    let failed: Vec<String> = drives::missing()
        .into_iter()
        .filter(|mp| run("mount", &[mp]).is_err())
        .collect();
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("could not mount: {}", failed.join(", ")))
    }
}

pub fn main(args: &[String]) -> Res {
    if !is_root() {
        return Err("the helper must run as root (it is called through sudo)".into());
    }
    let cfg = Config::load();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["check"] => Ok(()),
        ["trip-begin"] => trip_begin(&cfg),
        ["trip-end"] => trip_end(&cfg),
        ["hibernate-mode", mode] => hibernate_mode(mode),
        ["rtc-slower"] => rtc_slower(),
        ["unmount", mp] => run("umount", &[checked_drive(mp)?]),
        ["kill-users", mp] => {
            for (pid, _) in drives::users_of(checked_drive(mp)?) {
                run("kill", &["-KILL", &pid.to_string()]).ok();
            }
            Ok(())
        }
        ["mount-all"] => mount_all(),
        // Called by the systemd units that install.sh sets up around hibernation.
        ["sleep-hook", "pre"] => {
            if Path::new(RTC_MARK).exists() { arm_rtc(&cfg) } else { Ok(()) }
        }
        ["sleep-hook", "post"] => {
            let ended = trip_end(&cfg);
            mount_all().and(ended)
        }
        _ => Err("usage: os-switch helper check|trip-begin|trip-end|hibernate-mode <reboot|rtc|normal>|rtc-slower|unmount <dir>|kill-users <dir>|mount-all|sleep-hook <pre|post>".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rtc_wait_grows_with_the_image() {
        let cfg = Config::default();
        let gb = 1024 * 1024;
        let mem = |free: u64, available: u64| {
            format!(
                "MemTotal: {} kB\nMemFree: {} kB\nMemAvailable: {} kB\n",
                32 * gb,
                free * gb,
                available * gb
            )
        };
        let no_cap = u64::MAX;
        // Nothing in use: only the base time.
        assert_eq!(rtc_wait_secs(&mem(32, 32), no_cap, &cfg), 25);
        // 12 GiB not free: 2 s per GiB on top.
        assert_eq!(rtc_wait_secs(&mem(20, 26), no_cap, &cfg), 25 + 24);
        // The kernel shrinks the image to its target size …
        assert_eq!(rtc_wait_secs(&mem(20, 26), 8 << 30, &cfg), 25 + 16);
        // … but not below what cannot be dropped.
        assert_eq!(rtc_wait_secs(&mem(20, 22), 8 << 30, &cfg), 25 + 20);
    }
}
