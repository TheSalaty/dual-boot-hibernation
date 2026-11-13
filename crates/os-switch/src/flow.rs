//! The handoff itself, run as the normal user. Anything that needs root goes
//! through the helper.

use crate::config::{AfterFreeze, Backend, Config};
use crate::i18n::{tr, trf};
use crate::{drives, efi, ui};
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::thread::sleep;
use std::time::Duration;

/// Fixed path: this is what the sudo rule allows.
pub const HELPER_BIN: &str = "/usr/local/bin/os-switch";

pub fn helper(args: &[&str]) -> bool {
    Command::new("sudo")
        .args(["-n", HELPER_BIN, "helper"])
        .args(args)
        .stdout(Stdio::null())
        // The probe is expected to fail on a machine that is not set up yet.
        .stderr(if args == ["check"] {
            Stdio::null()
        } else {
            Stdio::inherit()
        })
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn systemctl(action: &str) -> bool {
    Command::new("systemctl")
        .arg(action)
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Watches logind's sleep signal. `systemctl hibernate` only queues the
/// request and returns at once, so this is how the handoff learns that the
/// machine went to sleep and came back.
struct SleepWatch {
    child: Child,
    lines: Receiver<String>,
}

impl SleepWatch {
    /// `None` if the bus cannot be watched; the units then clean up alone.
    fn start() -> Option<Self> {
        let mut child = Command::new("dbus-monitor")
            .args([
                "--system",
                "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let out = child.stdout.take()?;
        let (tx, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let watch = Self { child, lines };
        // The first line is the bus greeting: the subscription is in place.
        watch
            .lines
            .recv_timeout(Duration::from_secs(3))
            .is_ok()
            .then_some(watch)
    }

    /// Wait for "going to sleep" (`true`) or "back" (`false`).
    fn wait_for(&self, asleep: bool, limit: Option<Duration>) -> bool {
        let wanted = format!("boolean {asleep}");
        loop {
            let line = match limit {
                Some(limit) => self.lines.recv_timeout(limit).ok(),
                None => self.lines.recv().ok(),
            };
            match line {
                Some(line) if line.trim() == wanted => return true,
                Some(_) => {}
                None => return false,
            }
        }
    }
}

impl Drop for SleepWatch {
    fn drop(&mut self) {
        self.child.kill().ok();
        self.child.wait().ok();
    }
}

fn hibernation_succeeded() -> bool {
    Command::new("systemctl")
        .args([
            "show",
            "--value",
            "-p",
            "Result",
            "systemd-hibernate.service",
        ])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim() == "success")
        .unwrap_or(true)
}

/// `None` when logind cannot be asked; the hibernate call then decides.
pub fn can_hibernate() -> Option<bool> {
    let out = Command::new("busctl")
        .args([
            "call",
            "org.freedesktop.login1",
            "/org/freedesktop/login1",
            "org.freedesktop.login1.Manager",
            "CanHibernate",
        ])
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).contains("\"yes\""))
}

fn vm_running() -> bool {
    std::fs::read_dir("/proc")
        .map(|d| {
            d.flatten().any(|e| {
                std::fs::read_to_string(e.path().join("comm"))
                    .map(|c| c.starts_with("qemu-system"))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn preflight(cfg: &Config, freeze: bool) -> Result<(), String> {
    if !helper(&["check"]) {
        return Err(tr(
            "The privileged helper is not set up. Run install.sh, then try again.",
        ));
    }
    if cfg.backend == Backend::Efi {
        let found = efi::read().map(|e| e.windows(cfg.windows_entry.as_deref()).is_some());
        if found != Ok(true) {
            return Err(tr(
                "No Windows boot entry was found in the firmware. Run “os-switch status” for details.",
            ));
        }
    }
    if freeze && can_hibernate() == Some(false) {
        return Err(tr(
            "Hibernation is not available. Is the swap file active? Run “os-switch status” for details.",
        ));
    }
    if freeze
        && vm_running()
        && !ui::confirm(
            &tr("A virtual machine is running. A graphics card passed through to it does not survive hibernation. Continue anyway?"),
            &tr("Continue"),
            &tr("Cancel"),
        )
    {
        return Err(tr("Cancelled. Linux keeps running."));
    }
    Ok(())
}

/// Unmount one drive; if it is busy, offer to close what is using it.
fn unmount_or_ask(mount_point: &str) -> bool {
    loop {
        if helper(&["unmount", mount_point]) {
            return true;
        }
        let users: Vec<String> = drives::users_of(mount_point)
            .into_iter()
            .map(|(pid, name)| format!("• {name} (PID {pid})"))
            .collect();
        let list = if users.is_empty() {
            tr("• (programs of another user)")
        } else {
            users.join("\n")
        };
        let question = trf(
            "{} is still in use and cannot be unmounted.\n\nThese programs are using it:\n{}\n\nClosing them by force loses unsaved work.",
            &[mount_point, &list],
        );
        if !ui::confirm(&question, &tr("Close them and continue"), &tr("Cancel")) {
            return false;
        }
        helper(&["kill-users", mount_point]);
        sleep(Duration::from_secs(2));
    }
}

/// Undo everything a started handoff changed, then report why it stopped.
fn abort(message: &str) -> u8 {
    helper(&["trip-end"]);
    helper(&["mount-all"]);
    ui::error(message);
    1
}

/// Go to Windows: `freeze` keeps the Linux session on disk, otherwise Linux
/// shuts down.
pub fn to_windows(cfg: &Config, freeze: bool) -> u8 {
    if let Err(message) = preflight(cfg, freeze) {
        ui::error(&message);
        return 1;
    }

    if freeze {
        // Windows may write to these while Linux is frozen.
        for drive in drives::mounted() {
            if !unmount_or_ask(&drive.target) {
                helper(&["mount-all"]);
                ui::notify(&tr("Cancelled. Linux keeps running."), "dialog-information");
                return 1;
            }
        }
    }

    if !freeze {
        if !helper(&["trip-begin"]) {
            return abort(&tr("Could not select Windows for the next start."));
        }
        if !systemctl("reboot") {
            return abort(&tr("The restart failed. Linux keeps running."));
        }
        return 0;
    }

    let mode = match cfg.after_freeze {
        AfterFreeze::Reboot => "reboot",
        AfterFreeze::Rtc => "rtc",
        AfterFreeze::Poweroff => "normal",
    };
    if cfg.lock_screen {
        Command::new("loginctl").arg("lock-session").status().ok();
    }
    // A clock wake-up that comes before the machine is off cancels the
    // hibernation. Then try again with more time; the helper remembers it.
    let attempts = if cfg.after_freeze == AfterFreeze::Rtc {
        3
    } else {
        1
    };
    for attempt in 1..=attempts {
        if !helper(&["trip-begin"]) {
            return abort(&tr("Could not select Windows for the next start."));
        }
        // If this fails the machine powers off instead: one extra press of
        // the power button, not a reason to stop.
        helper(&["hibernate-mode", mode]);

        let watch = SleepWatch::start();
        if !systemctl("hibernate") {
            break;
        }
        let Some(watch) = watch else {
            // Cannot tell when the machine is back: os-switch-resume.service
            // undoes the handoff after waking.
            return 0;
        };
        // Nothing may be undone before the image is written and the machine
        // is back, or it would power off and start Linux again.
        if !watch.wait_for(true, Some(Duration::from_secs(60))) {
            break;
        }
        watch.wait_for(false, None);
        // os-switch-resume.service undoes the handoff as well; let it finish
        // so that it cannot undo the next attempt.
        sleep(Duration::from_secs(3));
        helper(&["trip-end"]);
        if hibernation_succeeded() {
            helper(&["mount-all"]);
            return 0;
        }
        if attempt < attempts {
            helper(&["rtc-slower"]);
        }
    }
    abort(&tr(
        "Hibernation failed. Windows was deselected again; Linux keeps running.",
    ))
}

/// Plain hibernate that powers off, whatever an earlier handoff left behind.
pub fn hibernate() -> u8 {
    helper(&["trip-end"]);
    if systemctl("hibernate") {
        0
    } else {
        ui::error(&tr("Hibernation failed."));
        1
    }
}
