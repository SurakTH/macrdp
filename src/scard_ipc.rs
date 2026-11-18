//! Shared smart-card IPC contract used by the server and the installed IFD driver.
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub fn socket_path(port: u16) -> PathBuf {
    // Stable across the user's launchd process and the system reader daemon.
    PathBuf::from(format!("/private/tmp/macrdp-scard-{port}/bridge.sock"))
}

pub fn validate_directory(path: &Path, owner: u32) -> io::Result<()> {
    let meta = std::fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.uid() != owner || meta.mode() & 0o022 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "unsafe smart-card socket directory",
        ));
    }
    Ok(())
}

pub fn prepare_directory(path: &Path) -> io::Result<()> {
    match std::fs::DirBuilder::new().mode(0o755).create(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    validate_directory(path, unsafe { libc::geteuid() })?;
    // Override a restrictive umask so _ctkd can traverse the directory. Only
    // its owner can create/unlink entries; commands still require kernel auth.
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
}

pub fn peer_uid(fd: std::os::fd::RawFd) -> io::Result<u32> {
    let mut uid = 0;
    let mut gid = 0;
    // SAFETY: getpeereid only writes the two initialized uid/gid values.
    if unsafe { libc::getpeereid(fd, &mut uid, &mut gid) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(uid)
}

/// Bounded dialing for the synchronous slotd driver, even with a full backlog.
#[allow(dead_code)] // called by the separately-built IFD driver
pub fn connect_timeout(
    path: &Path,
    timeout: std::time::Duration,
) -> io::Result<std::os::unix::net::UnixStream> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    let bytes = path.as_os_str().as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() || bytes.contains(&0) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid socket path",
        ));
    }
    address.sun_family = libc::AF_UNIX as _;
    address.sun_len = std::mem::size_of::<libc::sockaddr_un>() as _;
    for (target, byte) in address.sun_path.iter_mut().zip(bytes) {
        *target = *byte as _;
    }
    let raw = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    let fd = unsafe { OwnedFd::from_raw_fd(raw) };
    let stream = std::os::unix::net::UnixStream::from(fd);
    stream.set_nonblocking(true)?;
    let connected = unsafe {
        libc::connect(
            stream.as_raw_fd(),
            (&address as *const libc::sockaddr_un).cast(),
            std::mem::size_of_val(&address) as _,
        )
    };
    if connected != 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EINPROGRESS) {
            return Err(error);
        }
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "smart-card connect timed out",
                ));
            }
            let mut poll = libc::pollfd {
                fd: stream.as_raw_fd(),
                events: libc::POLLOUT,
                revents: 0,
            };
            let ready = unsafe {
                libc::poll(
                    &mut poll,
                    1,
                    remaining.as_millis().clamp(1, i32::MAX as u128) as i32,
                )
            };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "smart-card connect timed out",
                ));
            }
            let mut error: libc::c_int = 0;
            let mut length = std::mem::size_of_val(&error) as libc::socklen_t;
            if unsafe {
                libc::getsockopt(
                    stream.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    (&mut error as *mut libc::c_int).cast(),
                    &mut length,
                )
            } != 0
            {
                return Err(io::Error::last_os_error());
            }
            if error != 0 {
                return Err(io::Error::from_raw_os_error(error));
            }
            break;
        }
    }
    stream.set_nonblocking(false)?;
    Ok(stream)
}

pub fn reader_daemon_uid() -> Option<u32> {
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result = std::ptr::null_mut();
    let mut buffer = vec![0u8; 16 * 1024];
    // Reentrant lookup; do not share getpwnam's process-global storage.
    let status = unsafe {
        libc::getpwnam_r(
            c"_ctkd".as_ptr(),
            &mut pwd,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        )
    };
    if status == 0 && !result.is_null() {
        Some(pwd.pw_uid)
    } else {
        None
    }
}

pub fn authorized_reader(uid: u32, daemon_uid: Option<u32>) -> bool {
    uid == 0 || daemon_uid == Some(uid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsRawFd;
    use std::os::unix::net::UnixStream;

    #[test]
    fn peer_identity_comes_from_kernel() {
        let (a, _) = UnixStream::pair().unwrap();
        assert_eq!(peer_uid(a.as_raw_fd()).unwrap(), unsafe { libc::geteuid() });
    }

    #[test]
    fn bounded_connect_reaches_listener_and_rejects_missing_socket() {
        use std::io::{Read, Write};
        let root = std::env::temp_dir().join(format!(
            "macrdp-dialtest-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("reader.sock");
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let mut client = connect_timeout(&path, std::time::Duration::from_millis(300)).unwrap();
        let (mut server, _) = listener.accept().unwrap();
        assert_eq!(peer_uid(client.as_raw_fd()).unwrap(), unsafe {
            libc::geteuid()
        });
        client.write_all(&[4]).unwrap();
        let mut opcode = [0];
        server.read_exact(&mut opcode).unwrap();
        assert_eq!(opcode, [4]);
        assert!(
            connect_timeout(&root.join("missing"), std::time::Duration::from_millis(300)).is_err()
        );
        drop(listener);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_system_reader_accounts_are_authorized() {
        assert!(authorized_reader(0, Some(258)));
        assert!(authorized_reader(258, Some(258)));
        assert!(!authorized_reader(501, Some(258)));
        assert!(!authorized_reader(501, None));
    }

    #[test]
    fn socket_parent_rejects_symlinks_and_writable_directories() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let root = std::env::temp_dir().join(format!(
            "macrdp-ipctest-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let private = root.join("private");
        prepare_directory(&private).unwrap();
        let link = root.join("link");
        symlink(&private, &link).unwrap();
        assert!(validate_directory(&link, unsafe { libc::geteuid() }).is_err());
        std::fs::set_permissions(&private, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(validate_directory(&private, unsafe { libc::geteuid() }).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
