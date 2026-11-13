//! Translations from gettext `.po` files that are compiled into the binary, so
//! there is no runtime dependency and nothing to install next to it.

use std::collections::HashMap;
use std::env;
use std::sync::OnceLock;

const CATALOGS: &[(&str, &str)] = &[
    ("de", include_str!("../po/de.po")),
    ("pt_BR", include_str!("../po/pt_BR.po")),
    ("es", include_str!("../po/es.po")),
    ("fr", include_str!("../po/fr.po")),
];

fn unquote(s: &str) -> String {
    let s = s.trim().trim_start_matches('"').trim_end_matches('"');
    s.replace("\\n", "\n")
        .replace("\\\"", "\"")
        .replace("\\\\", "\\")
}

pub fn parse_po(text: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let (mut id, mut value, mut in_value) = (String::new(), String::new(), false);
    let mut flush = |id: &mut String, value: &mut String| {
        if !id.is_empty() && !value.is_empty() {
            map.insert(std::mem::take(id), std::mem::take(value));
        }
        id.clear();
        value.clear();
    };
    for line in text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("msgid ") {
            flush(&mut id, &mut value);
            id = unquote(rest);
            in_value = false;
        } else if let Some(rest) = line.strip_prefix("msgstr ") {
            value = unquote(rest);
            in_value = true;
        } else if line.starts_with('"') {
            if in_value {
                value.push_str(&unquote(line))
            } else {
                id.push_str(&unquote(line))
            }
        }
    }
    flush(&mut id, &mut value);
    map
}

/// Language from the environment, in gettext's order of precedence.
fn language() -> String {
    ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(|k| env::var(k).ok())
        .find(|v| !v.is_empty())
        .map(|v| v.split([':', '.', '@']).next().unwrap_or("").to_string())
        .unwrap_or_default()
}

fn catalog_for(lang: &str) -> Option<&'static str> {
    let short = lang.split('_').next().unwrap_or("");
    CATALOGS
        .iter()
        .find(|(code, _)| *code == lang)
        .or_else(|| {
            CATALOGS
                .iter()
                .find(|(code, _)| code.split('_').next() == Some(short))
        })
        .map(|(_, text)| *text)
}

fn catalog() -> &'static HashMap<String, String> {
    static CATALOG: OnceLock<HashMap<String, String>> = OnceLock::new();
    CATALOG.get_or_init(|| catalog_for(&language()).map(parse_po).unwrap_or_default())
}

/// Translate `msgid`; the English source text is the fallback.
pub fn tr(msgid: &str) -> String {
    catalog()
        .get(msgid)
        .cloned()
        .unwrap_or_else(|| msgid.to_string())
}

/// Translate and fill each `{}` in order.
pub fn trf(msgid: &str, args: &[&str]) -> String {
    let mut text = tr(msgid);
    for arg in args {
        text = text.replacen("{}", arg, 1);
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_single_and_multi_line_entries() {
        let po = "msgid \"\"\nmsgstr \"\"\n\"Language: de\\n\"\n\n\
                  msgid \"Hello\"\nmsgstr \"Hallo\"\n\n\
                  msgid \"\"\n\"Two \"\n\"parts\"\nmsgstr \"\"\n\"Zwei \"\n\"Teile\"\n\n\
                  msgid \"Untranslated\"\nmsgstr \"\"\n";
        let map = parse_po(po);
        assert_eq!(map.get("Hello").map(String::as_str), Some("Hallo"));
        assert_eq!(map.get("Two parts").map(String::as_str), Some("Zwei Teile"));
        assert!(!map.contains_key("Untranslated"));
    }

    #[test]
    fn regional_code_falls_back_to_language() {
        assert!(catalog_for("de_AT").is_some());
        assert!(catalog_for("pt_PT").is_some());
        assert!(catalog_for("ja_JP").is_none());
    }

    /// String literals passed to `tr(` / `trf(` in `source`.
    fn msgids(source: &str) -> Vec<String> {
        let mut ids = Vec::new();
        for call in ["tr(", "trf("] {
            let mut rest = source;
            while let Some(at) = rest.find(call) {
                let before_ok = !rest[..at].ends_with(|c: char| c.is_alphanumeric() || c == '_');
                rest = &rest[at + call.len()..];
                let arg = rest.trim_start();
                if !before_ok || !arg.starts_with('"') {
                    continue;
                }
                let mut id = String::new();
                let mut chars = arg[1..].chars();
                while let Some(c) = chars.next() {
                    match c {
                        '"' => break,
                        '\\' => match chars.next() {
                            Some('n') => id.push('\n'),
                            Some(other) => id.push(other),
                            None => break,
                        },
                        _ => id.push(c),
                    }
                }
                ids.push(id);
            }
        }
        ids
    }

    /// A message used in the code but absent from the catalogs would silently
    /// stay English.
    #[test]
    fn every_message_in_the_code_is_translated() {
        let reference = parse_po(CATALOGS[0].1);
        let sources = [include_str!("flow.rs"), include_str!("status.rs")];
        let used: Vec<String> = sources.iter().flat_map(|s| msgids(s)).collect();
        assert!(
            used.len() > 40,
            "extraction found only {} messages",
            used.len()
        );
        let missing: Vec<_> = used
            .iter()
            .filter(|id| !reference.contains_key(*id))
            .collect();
        assert!(missing.is_empty(), "not in de.po: {missing:?}");
    }

    /// Every catalog must translate exactly the same messages with the same
    /// number of placeholders, or a dialog would show a broken sentence.
    #[test]
    fn catalogs_are_complete_and_consistent() {
        let reference = parse_po(CATALOGS[0].1);
        for (code, text) in CATALOGS {
            let map = parse_po(text);
            for (id, value) in &map {
                assert_eq!(
                    id.matches("{}").count(),
                    value.matches("{}").count(),
                    "{code}: {id}"
                );
            }
            let mut missing: Vec<_> = reference.keys().filter(|k| !map.contains_key(*k)).collect();
            missing.sort();
            assert!(missing.is_empty(), "{code} lacks {missing:?}");
        }
    }
}
