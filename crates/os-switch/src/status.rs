//! `os-switch status`: check the whole chain and say what is missing.

use crate::config::{AfterFreeze, Backend, Config};
use crate::i18n::{tr, trf};
use crate::{drives, efi, flow, helper};
use std::path::Path;
use std::process::{Command, Stdio};

struct Report {
    failed: bool,
}

impl Report {
    fn ok(&self, text: &str) {
        println!("  ✓ {text}");
    }
    fn info(&self, text: &str) {
        println!("  · {text}");
    }
    fn fail(&mut self, text: &str) {
        println!("  ✗ {text}");
        self.failed = true;
    }
    fn check(&mut self, good: bool, ok: &str, bad: &str) {
        if good {
            self.ok(ok)
        } else {
            self.fail(bad)
        }
    }
}

fn unit_enabled(unit: &str) -> bool {
    Command::new("systemctl")
        .args(["is-enabled", "--quiet", unit])
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn run(cfg: &Config) -> u8 {
    let mut r = Report { failed: false };
    println!("os-switch {}", env!("CARGO_PKG_VERSION"));

    println!("\n{}", tr("Boot selection"));
    let trip = Path::new(helper::TRIP_FILE).exists();
    match cfg.backend {
        Backend::Grub => {
            r.info(&tr("Using the GRUB flag on the EFI partition (fallback)."));
            r.check(
                helper::esp().is_some(),
                &tr("EFI partition is mounted."),
                &tr("EFI partition is not mounted."),
            );
        }
        Backend::Efi => match efi::read() {
            Err(e) => r.fail(&trf("Cannot read the firmware boot entries: {}", &[&e])),
            Ok(efi) => {
                match efi.linux() {
                    Some(e) => r.ok(&trf("Linux entry: {} ({})", &[&e.num, &e.label])),
                    None => r.fail(&tr("Cannot tell which firmware entry started this Linux.")),
                }
                let win = efi.windows(cfg.windows_entry.as_deref());
                match win {
                    Some(e) => r.ok(&trf("Windows entry: {} ({})", &[&e.num, &e.label])),
                    None => r.fail(&tr("No Windows boot entry in the firmware.")),
                }
                let windows_first = win.is_some() && efi.order.first() == win.map(|e| &e.num);
                if trip {
                    r.info(&tr("A Windows trip is marked as active."));
                } else {
                    r.check(
                        !windows_first,
                        &tr("Linux starts by default."),
                        &tr("Windows is first in the boot order, so a Windows restart will not return to Linux."),
                    );
                }
                if let Some(next) = &efi.next {
                    r.info(&trf("One-time next start: {}", &[next]));
                }
            }
        },
    }

    println!("\n{}", tr("Handoff"));
    r.check(
        Path::new(flow::HELPER_BIN).exists(),
        &trf("Installed at {}.", &[flow::HELPER_BIN]),
        &trf("Not installed at {}. Run install.sh.", &[flow::HELPER_BIN]),
    );
    r.check(
        flow::helper(&["check"]),
        &tr("The privileged helper runs without a password."),
        &tr("The privileged helper needs a password. Run install.sh to add the sudo rule."),
    );
    match flow::can_hibernate() {
        Some(true) => r.ok(&tr("Hibernation is available.")),
        Some(false) => r.fail(&tr(
            "Hibernation is not available (swap or resume settings).",
        )),
        None => r.info(&tr(
            "Could not ask the system whether hibernation is available.",
        )),
    }
    for (unit, purpose) in [
        ("os-switch-resume.service", tr("cleans up after waking")),
        ("os-switch-boot.service", tr("cleans up after a cold start")),
    ] {
        r.check(
            unit_enabled(unit),
            &trf("{} is enabled ({}).", &[unit, &purpose]),
            &trf("{} is not enabled ({}). Run install.sh.", &[unit, &purpose]),
        );
    }
    r.info(&match cfg.after_freeze {
        AfterFreeze::Reboot => tr("After freezing: restart straight into Windows."),
        AfterFreeze::Rtc => {
            tr("After freezing: power off, the clock switches the machine back on.")
        }
        AfterFreeze::Poweroff => tr("After freezing: power off and wait for the power button."),
    });
    if cfg.sticky {
        r.info(&tr(
            "Sticky: Windows restarts stay in Windows until Windows asks for Linux.",
        ));
    }

    println!("\n{}", tr("Drives Windows can write to"));
    let mounted = drives::mounted();
    if mounted.is_empty() {
        r.info(&tr("None mounted."));
    }
    for m in mounted {
        r.info(&trf(
            "{} ({}) is unmounted for the handoff.",
            &[&m.target, &m.fstype],
        ));
    }
    for mp in drives::missing() {
        r.fail(&trf("{} is in fstab but not mounted.", &[&mp]));
    }

    println!();
    u8::from(r.failed)
}
