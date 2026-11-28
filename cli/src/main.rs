use clap::Parser;
use secondbrain::cli::{Cli, Exit, run};

fn main() {
    let cli = Cli::parse();
    let cwd = std::env::current_dir().unwrap_or_else(|_| ".".into());
    match run(cli, &cwd) {
        Ok(out) => print_out(&out),
        Err(e) => match e.downcast_ref::<Exit>() {
            Some(exit) => {
                print_out(&exit.text);
                std::process::exit(exit.code);
            }
            None => {
                eprintln!("sb: {e:#}");
                std::process::exit(1);
            }
        },
    }
}

fn print_out(out: &str) {
    if !out.is_empty() {
        print!("{out}");
        if !out.ends_with('\n') {
            println!();
        }
    }
}
