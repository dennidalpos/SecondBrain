use clap::Parser;
use secondbrain::cli::{Cli, run};

fn main() {
    let cli = Cli::parse();
    let cwd = std::env::current_dir().unwrap_or_else(|_| ".".into());
    match run(cli, &cwd) {
        Ok(out) => {
            if !out.is_empty() {
                print!("{out}");
                if !out.ends_with('\n') {
                    println!();
                }
            }
        }
        Err(e) => {
            eprintln!("sb: {e:#}");
            std::process::exit(1);
        }
    }
}
