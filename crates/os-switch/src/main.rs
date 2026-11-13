//! os-switch: freeze Linux, hop into Windows and come back.

mod config;
mod drives;
mod efi;
mod flow;
mod helper;
mod i18n;
mod status;
mod ui;

use std::process::ExitCode;

const USAGE: &str = "\
Usage: os-switch <command>

  windows          freeze the Linux session and start Windows
  reboot-windows   shut Linux down and start Windows
  hibernate        freeze the Linux session and power off
  status           check the setup and say what is missing
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("windows") => flow::to_windows(&config::Config::load(), true),
        Some("reboot-windows") => flow::to_windows(&config::Config::load(), false),
        Some("hibernate") => flow::hibernate(),
        Some("status") => status::run(&config::Config::load()),
        Some("helper") => match helper::main(&args[1..]) {
            Ok(()) => 0,
            Err(message) => {
                eprintln!("os-switch helper: {message}");
                1
            }
        },
        Some("--version" | "-V") => {
            println!("os-switch {}", env!("CARGO_PKG_VERSION"));
            0
        }
        Some("--help" | "-h") => {
            print!("{USAGE}");
            0
        }
        _ => {
            eprint!("{USAGE}");
            2
        }
    };
    ExitCode::from(code)
}
