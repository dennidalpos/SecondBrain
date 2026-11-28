use anyhow::{Context as _, Result};
use std::io::{Read, Write};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::mpsc::{Sender, channel};
use std::thread;
use std::time::{Duration, Instant};

pub(super) struct Capture {
    pub status: Option<ExitStatus>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

enum Event {
    Output(usize, Vec<u8>),
    Closed,
}

fn drain(mut pipe: impl Read, stream: usize, events: Sender<Event>) {
    let mut buffer = [0; 8192];
    loop {
        match pipe.read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                if events
                    .send(Event::Output(stream, buffer[..n].to_vec()))
                    .is_err()
                {
                    return;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
    let _ = events.send(Event::Closed);
}

/// Drain both pipes concurrently. Completion includes EOF, which can outlive the direct child.
pub(super) fn capture(
    mut command: Command,
    input: Option<&str>,
    timeout: Duration,
) -> Result<Capture> {
    let started = Instant::now();
    let mut tree = Tree::new(&mut command)?;
    let mut child = command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    if let Err(error) = tree.attach(&child) {
        let _ = child.kill();
        let _ = child.wait();
        return Err(error).context("placing the child in its process tree");
    }
    let (events, collected) = channel();
    let stdout = child.stdout.take().expect("piped stdout");
    let stderr = child.stderr.take().expect("piped stderr");
    let stdout_events = events.clone();
    let stderr_events = events.clone();
    thread::spawn(move || drain(stdout, 0, stdout_events));
    thread::spawn(move || drain(stderr, 1, stderr_events));
    let mut remaining = 2;
    if let (Some(mut stdin), Some(input)) = (child.stdin.take(), input) {
        let input = input.as_bytes().to_vec();
        let writer_events = events.clone();
        remaining += 1;
        thread::spawn(move || {
            let _ = stdin.write_all(&input);
            drop(stdin);
            let _ = writer_events.send(Event::Closed);
        });
    }
    let mut output = [Vec::new(), Vec::new()];
    let status = loop {
        let status = child.try_wait()?;
        if status.is_some() && remaining == 0 {
            break status;
        }
        let time_left = timeout.saturating_sub(started.elapsed());
        if time_left.is_zero() {
            tree.terminate();
            if status.is_none() {
                let _ = child.kill();
                // Reap the child without letting cleanup extend the caller's deadline.
                thread::spawn(move || {
                    let _ = child.wait();
                });
            }
            break None;
        }
        let wait = time_left.min(Duration::from_millis(20));
        match collected.recv_timeout(wait) {
            Ok(Event::Output(stream, bytes)) => output[stream].extend(bytes),
            Ok(Event::Closed) => remaining -= 1,
            Err(_) => thread::sleep(wait.min(Duration::from_millis(1))),
        }
    };
    let [stdout, stderr] = output;
    Ok(Capture {
        status,
        stdout,
        stderr,
    })
}

#[cfg(unix)]
struct Tree {
    group: Option<i32>,
}

#[cfg(unix)]
impl Tree {
    fn new(command: &mut Command) -> Result<Self> {
        use std::os::unix::process::CommandExt as _;
        command.process_group(0);
        Ok(Self { group: None })
    }

    fn attach(&mut self, child: &Child) -> std::io::Result<()> {
        self.group = i32::try_from(child.id()).ok();
        Ok(())
    }

    fn terminate(&mut self) {
        unsafe extern "C" {
            fn kill(pid: i32, signal: i32) -> i32;
        }
        if let Some(group) = self.group.take() {
            // A negative PID addresses the child's process group. SIGKILL is 9 on supported Unix.
            unsafe {
                kill(-group, 9);
            }
        }
    }
}

#[cfg(windows)]
struct Tree(std::os::windows::io::OwnedHandle);

#[cfg(windows)]
mod job {
    use std::ffi::c_void;

    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};

    pub(super) const CREATE_SUSPENDED: u32 = 0x0000_0004;
    const SNAP_THREADS: u32 = 0x0000_0004;
    const SUSPEND_RESUME: u32 = 0x0002;

    #[repr(C)]
    struct ThreadEntry {
        size: u32,
        usage: u32,
        thread: u32,
        process: u32,
        base_priority: i32,
        delta_priority: i32,
        flags: u32,
    }

    #[link(name = "kernel32")]
    unsafe extern "system" {
        pub(super) fn CreateJobObjectW(attributes: *mut c_void, name: *const u16) -> *mut c_void;
        pub(super) fn AssignProcessToJobObject(job: *mut c_void, process: *mut c_void) -> i32;
        pub(super) fn TerminateJobObject(job: *mut c_void, exit_code: u32) -> i32;
        fn CreateToolhelp32Snapshot(flags: u32, process: u32) -> *mut c_void;
        fn Thread32First(snapshot: *mut c_void, entry: *mut ThreadEntry) -> i32;
        fn Thread32Next(snapshot: *mut c_void, entry: *mut ThreadEntry) -> i32;
        fn OpenThread(access: u32, inherit: i32, thread: u32) -> *mut c_void;
        fn ResumeThread(thread: *mut c_void) -> u32;
    }

    // std's Child exposes the process handle but not the primary thread handle.
    // The suspended process has only its primary thread, so find it by process ID.
    pub(super) fn resume_primary_thread(process: u32) -> std::io::Result<()> {
        let snapshot = unsafe { CreateToolhelp32Snapshot(SNAP_THREADS, 0) };
        if snapshot as isize == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let snapshot = unsafe { OwnedHandle::from_raw_handle(snapshot) };
        let mut entry: ThreadEntry = unsafe { std::mem::zeroed() };
        entry.size = size_of::<ThreadEntry>() as u32;
        let handle = snapshot.as_raw_handle();
        let mut found = unsafe { Thread32First(handle, &mut entry) };
        while found != 0 {
            if entry.process == process {
                let thread = unsafe { OpenThread(SUSPEND_RESUME, 0, entry.thread) };
                if thread.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                let thread = unsafe { OwnedHandle::from_raw_handle(thread) };
                if unsafe { ResumeThread(thread.as_raw_handle()) } == u32::MAX {
                    return Err(std::io::Error::last_os_error());
                }
                return Ok(());
            }
            entry.size = size_of::<ThreadEntry>() as u32;
            found = unsafe { Thread32Next(handle, &mut entry) };
        }
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(windows)]
impl Tree {
    fn new(command: &mut Command) -> Result<Self> {
        use std::os::windows::io::FromRawHandle as _;
        use std::os::windows::process::CommandExt as _;
        // Assign the job before the command can create children or exit.
        command.creation_flags(job::CREATE_SUSPENDED);
        // Null arguments create a new, unnamed job with a non-inheritable handle.
        let handle = unsafe { job::CreateJobObjectW(std::ptr::null_mut(), std::ptr::null()) };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error()).context("creating a Windows job");
        }
        Ok(Self(unsafe {
            std::os::windows::io::OwnedHandle::from_raw_handle(handle)
        }))
    }

    fn attach(&mut self, child: &Child) -> std::io::Result<()> {
        use std::os::windows::io::AsRawHandle as _;
        // Both handles are owned and remain valid for the duration of the call.
        if unsafe { job::AssignProcessToJobObject(self.0.as_raw_handle(), child.as_raw_handle()) }
            == 0
        {
            return Err(std::io::Error::last_os_error());
        }
        job::resume_primary_thread(child.id())
    }

    fn terminate(&mut self) {
        use std::os::windows::io::AsRawHandle as _;
        unsafe {
            job::TerminateJobObject(self.0.as_raw_handle(), 1);
        }
    }
}

#[cfg(windows)]
impl Drop for Tree {
    fn drop(&mut self) {
        self.terminate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drains_both_streams_even_when_stderr_fills_first() {
        let mut command;
        if cfg!(windows) {
            command = Command::new("powershell.exe");
            command.args([
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Console]::Error.Write(('e' * 131072)); [Console]::Write('done')",
            ]);
        } else {
            command = Command::new("sh");
            command.args([
                "-c",
                "dd if=/dev/zero bs=1024 count=128 >&2 2>/dev/null; printf done",
            ]);
        }
        let result = capture(command, None, Duration::from_secs(10)).unwrap();
        assert!(result.status.is_some_and(|status| status.success()));
        assert_eq!(result.stdout, b"done");
        assert_eq!(result.stderr.len(), 131_072);
    }

    #[test]
    fn timeout_includes_descendants_that_hold_the_pipes_open() {
        let mut command;
        if cfg!(windows) {
            command = Command::new("cmd");
            command.args(["/D", "/C", "ping -n 9 127.0.0.1"]);
        } else {
            command = Command::new("sh");
            command.args(["-c", "sleep 8 &"]);
        }
        let started = Instant::now();
        let result = capture(command, None, Duration::from_millis(600)).unwrap();
        assert!(result.status.is_none());
        assert!(started.elapsed() < Duration::from_secs(4));
    }
}
