//! `/etc/os-switch.conf`: plain `key = value` lines, `#` starts a comment.
//! The file is root-owned because the privileged helper reads it too.

use std::fs;

pub const CONFIG_PATH: &str = "/etc/os-switch.conf";

/// What the machine does once the session is frozen to disk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AfterFreeze {
    /// Reboot straight into Windows (systemd `HibernateMode=reboot`).
    Reboot,
    /// Power off and let the real-time clock switch the machine back on.
    /// For hardware where the reboot variant hangs.
    Rtc,
    /// Power off and wait for the power button.
    Poweroff,
}

/// How the next operating system is selected.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// Firmware boot entries (`efibootmgr`). Works with any boot loader.
    Efi,
    /// A flag in a GRUB environment file on the EFI partition, for firmware
    /// that ignores one-time boot entries.
    Grub,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub after_freeze: AfterFreeze,
    pub backend: Backend,
    /// Keep booting Windows until Windows itself asks for Linux again. Only
    /// useful once the Windows companion is installed, so it is off by default.
    pub sticky: bool,
    /// Firmware entry number of Windows (e.g. `0000`); detected when unset.
    pub windows_entry: Option<String>,
    pub rtc_base_secs: u64,
    pub rtc_tenths_per_gb: u64,
    pub lock_screen: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            after_freeze: AfterFreeze::Rtc,
            backend: Backend::Efi,
            sticky: false,
            windows_entry: None,
            rtc_base_secs: 25,
            rtc_tenths_per_gb: 20,
            lock_screen: true,
        }
    }
}

fn yes(v: &str) -> bool {
    matches!(v.to_ascii_lowercase().as_str(), "yes" | "true" | "1" | "on")
}

impl Config {
    pub fn load() -> Self {
        fs::read_to_string(CONFIG_PATH)
            .map(|s| Self::parse(&s))
            .unwrap_or_default()
    }

    /// Unknown keys and unparsable values are ignored: a typo must never turn
    /// into a different boot target.
    pub fn parse(text: &str) -> Self {
        let mut c = Self::default();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            let Some((k, v)) = line.split_once('=') else {
                continue;
            };
            let v = v.trim().trim_matches('"');
            match k.trim() {
                "after_freeze" => {
                    c.after_freeze = match v {
                        "reboot" => AfterFreeze::Reboot,
                        "poweroff" => AfterFreeze::Poweroff,
                        _ => AfterFreeze::Rtc,
                    }
                }
                "backend" => {
                    c.backend = if v == "grub" {
                        Backend::Grub
                    } else {
                        Backend::Efi
                    }
                }
                "sticky" => c.sticky = yes(v),
                "windows_entry" => {
                    let ok = v.len() == 4 && v.chars().all(|ch| ch.is_ascii_hexdigit());
                    c.windows_entry = ok.then(|| v.to_ascii_uppercase());
                }
                "rtc_base_secs" => c.rtc_base_secs = v.parse().unwrap_or(c.rtc_base_secs),
                "rtc_tenths_per_gb" => {
                    c.rtc_tenths_per_gb = v.parse().unwrap_or(c.rtc_tenths_per_gb)
                }
                "lock_screen" => c.lock_screen = yes(v),
                _ => {}
            }
        }
        c
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_when_empty() {
        assert_eq!(Config::parse(""), Config::default());
    }

    #[test]
    fn parses_values_and_ignores_junk() {
        let c = Config::parse(
            "# comment\nafter_freeze = rtc\nbackend=grub\nsticky = yes # trailing\n\
             windows_entry = \"000a\"\nrtc_base_secs = 9\nnonsense\nunknown = 1\n",
        );
        assert_eq!(c.after_freeze, AfterFreeze::Rtc);
        assert_eq!(c.backend, Backend::Grub);
        assert!(c.sticky);
        assert_eq!(c.windows_entry.as_deref(), Some("000A"));
        assert_eq!(c.rtc_base_secs, 9);
    }

    #[test]
    fn rejects_bad_windows_entry() {
        assert_eq!(
            Config::parse("windows_entry = 0000; reboot").windows_entry,
            None
        );
    }
}
