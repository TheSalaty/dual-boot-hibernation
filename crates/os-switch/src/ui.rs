//! Talking to the user from a place that may have no terminal (a power-menu
//! entry): desktop dialog if one is available, terminal prompt otherwise.

use std::io::{self, IsTerminal, Write};
use std::process::{Command, Stdio};

pub const TITLE: &str = "OS Switch";

fn has(cmd: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {cmd}")])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn quiet(cmd: &str, args: &[&str]) -> bool {
    Command::new(cmd)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub fn notify(body: &str, icon: &str) {
    eprintln!("{body}");
    quiet("notify-send", &["-a", TITLE, "-i", icon, TITLE, body]);
}

/// Report a failure everywhere the user might be looking.
pub fn error(body: &str) {
    eprintln!("os-switch: {body}");
    if io::stderr().is_terminal() {
        return;
    }
    if has("zenity") {
        quiet(
            "zenity",
            &[
                "--error",
                "--title",
                TITLE,
                "--width=420",
                "--no-markup",
                "--text",
                body,
            ],
        );
    } else if has("kdialog") {
        quiet("kdialog", &["--title", TITLE, "--error", body]);
    } else {
        quiet(
            "notify-send",
            &["-a", TITLE, "-i", "dialog-error", TITLE, body],
        );
    }
}

/// Ask a yes/no question. Without any way to ask, the answer is no: every
/// question here guards something destructive.
pub fn confirm(text: &str, yes: &str, no: &str) -> bool {
    if io::stdin().is_terminal() {
        print!("{text}\n[{yes}: y / {no}: n] ");
        let _ = io::stdout().flush();
        let mut answer = String::new();
        let _ = io::stdin().read_line(&mut answer);
        return matches!(answer.trim().to_lowercase().as_str(), "y" | "j" | "s" | "o");
    }
    if has("zenity") {
        return quiet(
            "zenity",
            &[
                "--question",
                "--title",
                TITLE,
                "--width=460",
                "--no-markup",
                "--ok-label",
                yes,
                "--cancel-label",
                no,
                "--text",
                text,
            ],
        );
    }
    if has("kdialog") {
        return quiet(
            "kdialog",
            &[
                "--title",
                TITLE,
                "--warningyesno",
                text,
                "--yes-label",
                yes,
                "--no-label",
                no,
            ],
        );
    }
    false
}
