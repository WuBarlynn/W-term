use crate::{frb_generated::StreamSink, session};
use anyhow::{bail, Context, Result};
use russh_sftp::protocol::OpenFlags;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Clone, Debug)]
pub struct ServerIdentity {
    pub connection_id: String,
    pub fingerprint: String,
}
#[derive(Clone, Debug)]
pub struct RemoteEntry {
    pub name: String,
    pub path: String,
    pub is_directory: bool,
    pub is_symlink: bool,
    pub size: u64,
    pub modified_at: Option<u32>,
}
#[derive(Clone, Debug)]
pub struct DirectoryListing {
    pub path: String,
    pub entries: Vec<RemoteEntry>,
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

pub async fn probe_server(host: String, port: u16) -> Result<ServerIdentity> {
    let (connection_id, fingerprint) = session::probe(host, port).await?;
    Ok(ServerIdentity {
        connection_id,
        fingerprint,
    })
}
pub async fn authenticate(
    connection_id: String,
    approved_fingerprint: String,
    username: String,
    password: String,
    private_key: String,
    passphrase: String,
) -> Result<()> {
    session::authenticate(
        &connection_id,
        &approved_fingerprint,
        username,
        password,
        private_key,
        passphrase,
    )
    .await
}
pub async fn authenticate_jump(
    connection_id: String,
    approved_fingerprint: String,
    username: String,
    password: String,
    private_key: String,
    passphrase: String,
) -> Result<()> {
    session::authenticate_jump(
        &connection_id,
        &approved_fingerprint,
        username,
        password,
        private_key,
        passphrase,
    )
    .await
}
pub async fn terminal_output(connection_id: String, sink: StreamSink<Vec<u8>>) -> Result<()> {
    let live = session::live(&connection_id).await?;
    let mut rx = live
        .output
        .lock()
        .await
        .take()
        .context("Output already subscribed")?;
    let mut stop = live.stop.subscribe();
    loop {
        let data = tokio::select! { biased; _ = stop.changed() => break, data = rx.recv() => data };
        let Some(data) = data else { break };
        if sink.add(data).is_err() {
            break;
        }
        // One unacknowledged frame across FFI; no unbounded Dart message queue.
        match tokio::time::timeout(Duration::from_secs(60), live.ack.acquire()).await {
            Ok(Ok(permit)) => permit.forget(),
            _ => break,
        }
    }
    session::disconnect(&connection_id).await
}
pub async fn acknowledge_output(connection_id: String) -> Result<()> {
    let live = session::live(&connection_id).await?;
    if live.ack.available_permits() == 0 {
        live.ack.add_permits(1);
    }
    Ok(())
}
pub async fn write_terminal(connection_id: String, bytes: Vec<u8>) -> Result<()> {
    if bytes.len() > 1024 * 1024 {
        bail!("Input exceeds 1 MiB; split the paste");
    }
    session::live(&connection_id)
        .await?
        .input
        .send(session::Input::Data(bytes))
        .await
        .context("Terminal closed")
}
pub async fn resize_terminal(connection_id: String, columns: u32, rows: u32) -> Result<()> {
    session::live(&connection_id)
        .await?
        .input
        .send(session::Input::Resize(columns, rows))
        .await
        .context("Terminal closed")
}
pub async fn disconnect(connection_id: String) -> Result<()> {
    session::disconnect(&connection_id).await
}
pub async fn list_directory(connection_id: String, path: String) -> Result<DirectoryListing> {
    let sftp = session::sftp(&connection_id).await?;
    let path = sftp.canonicalize(path).await?;
    let mut entries: Vec<_> = sftp
        .read_dir(&path)
        .await?
        .map(|entry| RemoteEntry {
            name: entry.file_name(),
            path: entry.path(),
            is_directory: entry.metadata().is_dir(),
            is_symlink: entry.metadata().is_symlink(),
            size: entry.metadata().size.unwrap_or(0),
            modified_at: entry.metadata().mtime,
        })
        .collect();
    entries.sort_by(|a, b| {
        b.is_directory
            .cmp(&a.is_directory)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(DirectoryListing { path, entries })
}
/// Streams to a new local file; caller exports it with the OS file picker.
pub async fn download_file(
    connection_id: String,
    remote_path: String,
    local_path: String,
) -> Result<u64> {
    let sftp = session::sftp(&connection_id).await?;
    let before = sftp.metadata(&remote_path).await?;
    if !before.is_regular() {
        bail!("Only regular files can be downloaded");
    }
    let mut source = sftp.open(&remote_path).await?;
    let mut target = tokio::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&local_path)
        .await?;
    let result: Result<u64> = async {
        let n = tokio::io::copy(&mut source, &mut target).await?;
        target.flush().await?;
        let after = sftp.metadata(&remote_path).await?;
        if before.size != after.size || before.mtime != after.mtime || after.size != Some(n) {
            bail!("Remote file changed during download; retry");
        }
        Ok(n)
    }
    .await;
    drop(target);
    if result.is_err() {
        let _ = tokio::fs::remove_file(&local_path).await;
    }
    result
}
#[derive(Clone, Debug)]
pub struct UploadResult {
    pub bytes: u64,
    pub remote_path: String,
}

// lstat treats dangling symlinks as occupied names as well.
async fn upload_metadata(
    sftp: &russh_sftp::client::SftpSession,
    path: &str,
) -> Result<Option<russh_sftp::protocol::FileAttributes>> {
    match sftp.symlink_metadata(path).await {
        Ok(value) => Ok(Some(value)),
        Err(russh_sftp::client::error::Error::Status(status))
            if status.status_code == russh_sftp::protocol::StatusCode::NoSuchFile =>
        {
            Ok(None)
        }
        Err(error) => Err(error.into()),
    }
}

fn numbered_upload_path(path: &str, index: u32) -> String {
    let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
    let (stem, extension) = match name.rfind('.') {
        Some(dot) if dot > 0 => (&name[..dot], &name[dot..]),
        _ => (name, ""),
    };
    let name = format!("{stem} ({index}){extension}");
    if path.contains('/') {
        format!("{parent}/{name}")
    } else {
        name
    }
}

/// A separate SFTP channel on the same authenticated SSH transport exposes the
/// OpenSSH atomic-rename extension without patching russh-sftp's private state.
async fn replace_upload(connection_id: &str, from: &str, to: &str) -> Result<()> {
    use russh_sftp::{
        client::RawSftpSession,
        protocol::{Packet, StatusCode},
    };
    let live = session::live(connection_id).await?;
    let channel = live.handle.channel_open_session().await?;
    channel.request_subsystem(true, "sftp").await?;
    let raw = RawSftpSession::new(channel.into_stream());
    raw.set_timeout(20);
    let result = async {
        let version = raw.init().await?;
        if !version.extensions.contains_key("posix-rename@openssh.com") {
            bail!("服务器不支持安全替换，请选择保留两个文件；原文件未改变");
        }
        let mut data = Vec::new();
        for path in [from, to] {
            data.extend_from_slice(&(path.len() as u32).to_be_bytes());
            data.extend_from_slice(path.as_bytes());
        }
        match raw.extended("posix-rename@openssh.com", data).await? {
            Packet::Status(status) if status.status_code == StatusCode::Ok => Ok(()),
            Packet::Status(status) => bail!("替换失败：{}", status.error_message),
            _ => bail!("服务器返回了无效的替换结果"),
        }
    }
    .await;
    let _ = raw.close_session();
    result
}

pub async fn upload_file(
    connection_id: String,
    local_path: String,
    remote_path: String,
) -> Result<u64> {
    Ok(
        upload_file_with_policy(connection_id, local_path, remote_path, "reject".into())
            .await?
            .bytes,
    )
}

/// Upload completely before committing. Reject/keep-both use no-replace rename;
/// replacement requires the server's atomic POSIX rename extension.
pub async fn upload_file_with_policy(
    connection_id: String,
    local_path: String,
    remote_path: String,
    policy: String,
) -> Result<UploadResult> {
    anyhow::ensure!(
        ["reject", "replace", "keepBoth"].contains(&policy.as_str()),
        "Invalid upload policy"
    );
    let sftp = session::sftp(&connection_id).await?;
    let existing = upload_metadata(&sftp, &remote_path).await?;
    if existing.is_some() && policy == "reject" {
        bail!("Destination already exists; choose how to handle the conflict");
    }
    if policy == "replace" && existing.as_ref().is_some_and(|m| !m.is_regular()) {
        bail!("只能替换普通文件，文件夹或符号链接请选择保留两个文件");
    }
    let mut source = tokio::fs::File::open(&local_path).await?;
    let metadata = source.metadata().await?;
    anyhow::ensure!(metadata.is_file(), "请选择普通文件");
    let expected = metadata.len();
    let temporary = format!("{}.wterm-{}.part", remote_path, uuid::Uuid::new_v4());
    let mut target = sftp
        .open_with_flags(
            &temporary,
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE,
        )
        .await?;
    let result = async {
        let n = tokio::io::copy(&mut source, &mut target).await?;
        target.flush().await?;
        target.shutdown().await?;
        anyhow::ensure!(n == expected, "Local file changed during upload");
        if policy == "replace" {
            let current = upload_metadata(&sftp, &remote_path).await?;
            anyhow::ensure!(
                !current.as_ref().is_some_and(|m| !m.is_regular()),
                "目标已变为文件夹或符号链接，取消替换"
            );
            if let Some(permissions) = current.and_then(|m| m.permissions) {
                sftp.set_metadata(
                    &temporary,
                    russh_sftp::protocol::FileAttributes {
                        permissions: Some(permissions & 0o777),
                        ..Default::default()
                    },
                )
                .await?;
            }
            replace_upload(&connection_id, &temporary, &remote_path).await?;
            return Ok(UploadResult {
                bytes: n,
                remote_path,
            });
        }
        for index in 0..10_000 {
            let candidate = if index == 0 {
                remote_path.clone()
            } else {
                numbered_upload_path(&remote_path, index)
            };
            if upload_metadata(&sftp, &candidate).await?.is_some() {
                if policy == "reject" {
                    bail!("Destination already exists; choose how to handle the conflict");
                }
                continue;
            }
            match sftp.rename(&temporary, &candidate).await {
                Ok(()) => {
                    return Ok(UploadResult {
                        bytes: n,
                        remote_path: candidate,
                    })
                }
                Err(_) if upload_metadata(&sftp, &candidate).await?.is_some() => {
                    if policy == "reject" {
                        bail!("Destination already exists; choose how to handle the conflict");
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
        bail!("同名副本过多，请重命名后重试")
    }
    .await;
    drop(target);
    if result.is_err() {
        let _ = sftp.remove_file(&temporary).await;
    }
    result
}

fn mutable_remote_path(path: &str) -> Result<()> {
    anyhow::ensure!(
        path.starts_with('/')
            && !path.contains('\0')
            && path
                .split('/')
                .filter(|s| !s.is_empty())
                .all(|s| s != "." && s != "..")
            && path.split('/').any(|s| !s.is_empty()),
        "只能操作有效的远程项目路径，不能操作根目录"
    );
    anyhow::ensure!(!path.ends_with('/'), "远程项目路径不能以 / 结尾");
    Ok(())
}

/// SFTP v3 rename refuses replacement, including a concurrently-created target.
pub async fn rename_remote_entry(connection_id: String, path: String, name: String) -> Result<()> {
    mutable_remote_path(&path)?;
    anyhow::ensure!(
        !name.trim().is_empty()
            && !name.contains('/')
            && !name.contains('\0')
            && name != "."
            && name != "..",
        "请输入有效的项目名称"
    );
    let parent = path.rsplit_once('/').context("无效路径")?.0;
    let destination = format!("{parent}/{name}");
    if destination == path {
        return Ok(());
    }
    let sftp = session::sftp(&connection_id).await?;
    anyhow::ensure!(
        upload_metadata(&sftp, &destination).await?.is_none(),
        "同名项目已存在，不能覆盖"
    );
    sftp.rename(path, destination).await?;
    Ok(())
}

/// Never recurses or resolves links: unlink links themselves, rmdir empty directories.
pub async fn delete_remote_entry(connection_id: String, path: String) -> Result<()> {
    mutable_remote_path(&path)?;
    let sftp = session::sftp(&connection_id).await?;
    let metadata = sftp.symlink_metadata(&path).await?;
    if metadata.is_dir() && !metadata.is_symlink() {
        sftp.remove_dir(path)
            .await
            .context("无法删除文件夹：请确认目录为空且有权限")?;
    } else {
        sftp.remove_file(path).await?;
    }
    Ok(())
}

/// Read current mode without following the final symlink.
pub async fn remote_permissions(connection_id: String, path: String) -> Result<u32> {
    mutable_remote_path(&path)?;
    let sftp = session::sftp(&connection_id).await?;
    let metadata = sftp.symlink_metadata(path).await?;
    anyhow::ensure!(
        !metadata.is_symlink() && (metadata.is_dir() || metadata.is_regular()),
        "只支持普通文件和文件夹的权限"
    );
    Ok(metadata.permissions.context("服务器未返回权限信息")? & 0o7777)
}

/// Optimistic conflict check preserves special bits, and verifies the server result.
pub async fn change_remote_permissions(
    connection_id: String,
    path: String,
    expected: u32,
    permissions: u32,
) -> Result<()> {
    anyhow::ensure!(
        permissions <= 0o777 && expected <= 0o7777,
        "权限必须为 000 至 777"
    );
    let current = remote_permissions(connection_id.clone(), path.clone()).await?;
    anyhow::ensure!(
        current == expected,
        "权限已被其他程序修改，请重新打开权限窗口"
    );
    let next = (current & 0o7000) | permissions;
    let sftp = session::sftp(&connection_id).await?;
    sftp.set_metadata(
        &path,
        russh_sftp::protocol::FileAttributes {
            permissions: Some(next),
            ..Default::default()
        },
    )
    .await?;
    let actual = remote_permissions(connection_id, path).await?;
    anyhow::ensure!(actual == next, "服务器返回的权限与请求不一致，请刷新后检查");
    Ok(())
}

pub async fn create_directory(connection_id: String, path: String) -> Result<()> {
    session::sftp(&connection_id)
        .await?
        .create_dir(path)
        .await?;
    Ok(())
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteTextSnapshot {
    pub text: String,
    pub permissions: u32,
    pub uid: Option<u32>,
    pub gid: Option<u32>,
    pub modified_at: Option<u32>,
}

pub async fn read_remote_text(connection_id: String, path: String) -> Result<RemoteTextSnapshot> {
    mutable_remote_path(&path)?;
    let sftp = session::sftp(&connection_id).await?;
    let before = sftp.symlink_metadata(&path).await?;
    anyhow::ensure!(
        before.is_regular() && !before.is_symlink(),
        "仅支持编辑普通文件，不能编辑链接或文件夹"
    );
    let permissions = before
        .permissions
        .context("服务器未返回文件权限，无法安全编辑")?;
    let text = preview_text(connection_id, path.clone()).await?;
    anyhow::ensure!(!text.contains('\0'), "文件包含二进制数据，请下载后编辑");
    let after = sftp.symlink_metadata(&path).await?;
    anyhow::ensure!(
        after.is_regular()
            && before.size == after.size
            && before.mtime == after.mtime
            && before.permissions == after.permissions
            && before.uid == after.uid
            && before.gid == after.gid,
        "文件读取期间发生变化，请重新打开"
    );
    Ok(RemoteTextSnapshot {
        text,
        permissions: permissions & 0o7777,
        uid: before.uid,
        gid: before.gid,
        modified_at: before.mtime,
    })
}

/// Optimistic conflict detection, followed by atomic POSIX replacement.
/// SFTP does not offer atomic compare-and-swap; a final check/rename race remains.
pub async fn save_remote_text(
    connection_id: String,
    path: String,
    expected: RemoteTextSnapshot,
    text: String,
) -> Result<()> {
    anyhow::ensure!(
        text.len() <= 256 * 1024 && expected.text.len() <= 256 * 1024,
        "文本编辑最多支持 256 KiB"
    );
    anyhow::ensure!(!text.contains('\0'), "文本不能包含二进制空字符");
    let current = read_remote_text(connection_id.clone(), path.clone()).await?;
    anyhow::ensure!(
        current == expected,
        "远程文件已变化，未保存。请保留本地修改并重新打开文件"
    );
    if text == expected.text {
        return Ok(());
    }
    let sftp = session::sftp(&connection_id).await?;
    let temporary = format!("{}.wterm-{}.part", path, uuid::Uuid::new_v4());
    let mut target = sftp
        .open_with_flags(
            &temporary,
            OpenFlags::WRITE | OpenFlags::CREATE | OpenFlags::EXCLUDE,
        )
        .await?;
    let result = async {
        sftp.set_metadata(
            &temporary,
            russh_sftp::protocol::FileAttributes {
                permissions: Some(0o600),
                ..Default::default()
            },
        )
        .await?;
        target.write_all(text.as_bytes()).await?;
        target.flush().await?;
        target.shutdown().await?;
        // Refuse replacement if the server cannot preserve ownership and mode.
        sftp.set_metadata(
            &temporary,
            russh_sftp::protocol::FileAttributes {
                uid: expected.uid,
                gid: expected.gid,
                permissions: Some(expected.permissions),
                ..Default::default()
            },
        )
        .await?;
        let staged = sftp.symlink_metadata(&temporary).await?;
        anyhow::ensure!(
            staged.uid == expected.uid
                && staged.gid == expected.gid
                && staged.permissions.map(|p| p & 0o7777) == Some(expected.permissions),
            "无法保留文件属主或权限，原文件未改变"
        );
        let latest = read_remote_text(connection_id.clone(), path.clone()).await?;
        anyhow::ensure!(
            latest == expected,
            "远程文件已变化，未保存。请保留本地修改并重新打开文件"
        );
        replace_upload(&connection_id, &temporary, &path).await
    }
    .await;
    drop(target);
    if result.is_err() {
        let _ = sftp.remove_file(&temporary).await;
    }
    result
}

/// Small preview only. Never load an arbitrary remote file into memory.
pub async fn preview_text(connection_id: String, path: String) -> Result<String> {
    let sftp = session::sftp(&connection_id).await?;
    let file = sftp.open(path).await?;
    let mut bytes = Vec::new();
    file.take(256 * 1024 + 1).read_to_end(&mut bytes).await?;
    if bytes.len() > 256 * 1024 {
        bail!("Preview limited to 256 KiB; download the file instead");
    }
    String::from_utf8(bytes).context("File is not UTF-8 text")
}

#[cfg(test)]
mod upload_tests {
    use super::numbered_upload_path;
    #[test]
    fn suffix_preserves_remote_parent_extension_and_hidden_files() {
        assert_eq!(
            numbered_upload_path("/目录/name.tar.gz", 2),
            "/目录/name.tar (2).gz"
        );
        assert_eq!(numbered_upload_path("/.env", 1), "/.env (1)");
        assert_eq!(numbered_upload_path("file", 1), "file (1)");
    }
}

#[derive(Clone)]
pub struct AuthPrompt {
    pub label: String,
    pub echo: bool,
}
#[derive(Clone)]
pub struct AuthChallenge {
    pub id: String,
    pub name: String,
    pub instructions: String,
    pub prompts: Vec<AuthPrompt>,
}
pub async fn auth_challenge(connection_id: String) -> Result<Option<AuthChallenge>> {
    Ok(session::interactive::challenge(&connection_id).await)
}
pub async fn answer_auth_challenge(
    connection_id: String,
    challenge_id: String,
    answers: Vec<String>,
) -> Result<()> {
    session::interactive::respond(&connection_id, &challenge_id, answers).await
}
