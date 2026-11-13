//! Firmware boot entries, read through `efibootmgr`.
//!
//! Entries are identified by what they load, never by a menu title: titles
//! contain device names that change between boots.

use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Four hex digits, e.g. `0001`.
    pub num: String,
    pub label: String,
    /// The whole line, used to recognise the loader path.
    pub raw: String,
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Efi {
    pub current: Option<String>,
    pub next: Option<String>,
    pub order: Vec<String>,
    pub entries: Vec<Entry>,
}

pub fn parse(out: &str) -> Efi {
    let mut efi = Efi::default();
    for line in out.lines() {
        if let Some(v) = line.strip_prefix("BootCurrent:") {
            efi.current = Some(v.trim().to_ascii_uppercase());
        } else if let Some(v) = line.strip_prefix("BootNext:") {
            efi.next = Some(v.trim().to_ascii_uppercase());
        } else if let Some(v) = line.strip_prefix("BootOrder:") {
            efi.order = v
                .split(',')
                .map(|s| s.trim().to_ascii_uppercase())
                .filter(|s| !s.is_empty())
                .collect();
        } else if let Some(rest) = line.strip_prefix("Boot") {
            let Some(num) = rest.get(..4) else { continue };
            if !num.chars().all(|c| c.is_ascii_hexdigit()) {
                continue;
            }
            let tail = rest[4..].trim_start_matches('*').trim_start();
            let label = tail.split('\t').next().unwrap_or("").trim().to_string();
            efi.entries.push(Entry {
                num: num.to_ascii_uppercase(),
                label,
                raw: line.to_string(),
            });
        }
    }
    efi
}

pub fn read() -> Result<Efi, String> {
    let out = Command::new("efibootmgr")
        .arg("-v")
        .output()
        .map_err(|e| format!("efibootmgr: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(parse(&String::from_utf8_lossy(&out.stdout)))
}

impl Efi {
    fn by_num(&self, num: &str) -> Option<&Entry> {
        self.entries
            .iter()
            .find(|e| e.num.eq_ignore_ascii_case(num))
    }

    /// The Windows entry: the configured number, else the entry that loads the
    /// Windows boot manager, else one that is merely labelled Windows.
    pub fn windows(&self, configured: Option<&str>) -> Option<&Entry> {
        if let Some(num) = configured {
            return self.by_num(num);
        }
        self.entries
            .iter()
            .find(|e| e.raw.to_ascii_lowercase().contains("bootmgfw.efi"))
            .or_else(|| {
                self.entries
                    .iter()
                    .find(|e| e.label.to_ascii_lowercase().contains("windows"))
            })
    }

    /// The entry this Linux was started from.
    pub fn linux(&self) -> Option<&Entry> {
        self.current.as_deref().and_then(|n| self.by_num(n))
    }

    /// The boot order with `first` moved to the front.
    pub fn order_with_first(&self, first: &str) -> Vec<String> {
        let mut order = vec![first.to_ascii_uppercase()];
        order.extend(
            self.order
                .iter()
                .filter(|n| !n.eq_ignore_ascii_case(first))
                .cloned(),
        );
        order
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "BootCurrent: 0001\nTimeout: 1 seconds\nBootOrder: 0001,0000\n\
Boot0000* Windows Boot Manager\tHD(1,GPT,c968ed71,0x800,0x32000)/\\EFI\\MICROSOFT\\BOOT\\BOOTMGFW.EFI5749\n\
      dp: 04 01 2a 00\n\
Boot0001* Manjaro\tHD(1,GPT,c968ed71,0x800,0x32000)/\\EFI\\MANJARO\\GRUBX64.EFI\n";

    #[test]
    fn parses_entries_and_order() {
        let efi = parse(SAMPLE);
        assert_eq!(efi.current.as_deref(), Some("0001"));
        assert_eq!(efi.order, ["0001", "0000"]);
        assert_eq!(efi.entries.len(), 2);
        assert_eq!(efi.entries[1].label, "Manjaro");
        assert_eq!(efi.next, None);
    }

    #[test]
    fn finds_windows_by_loader_and_linux_by_current() {
        let efi = parse(SAMPLE);
        assert_eq!(efi.windows(None).unwrap().num, "0000");
        assert_eq!(efi.linux().unwrap().num, "0001");
    }

    #[test]
    fn configured_entry_wins_and_must_exist() {
        let efi = parse(SAMPLE);
        assert_eq!(efi.windows(Some("0001")).unwrap().num, "0001");
        assert!(efi.windows(Some("0009")).is_none());
    }

    #[test]
    fn falls_back_to_label_without_loader_path() {
        let efi = parse("BootOrder: 0003\nBoot0003  Windows Boot Manager\n");
        assert_eq!(efi.windows(None).unwrap().num, "0003");
    }

    #[test]
    fn reorders_without_duplicates() {
        let efi = parse(SAMPLE);
        assert_eq!(efi.order_with_first("0000"), ["0000", "0001"]);
        assert_eq!(efi.order_with_first("0001"), ["0001", "0000"]);
    }
}
