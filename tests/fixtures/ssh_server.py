"""Isolated loopback SSH/SFTP server. Never enable system Remote Login.
Install asyncssh in a venv; run with --root <temporary-dir> --port 22222.
Only synthetic credentials: wterm / wterm-test-only.
"""
import argparse
import asyncio
import pathlib
import asyncssh


class TestServer(asyncssh.SSHServer):
    def connection_requested(self, dest_host, dest_port, orig_host, orig_port):
        return dest_host == "127.0.0.1"

    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == 'wterm' and password == 'wterm-test-only'

    def public_key_auth_supported(self):
        return True

    def validate_public_key(self, username, key):
        return username == 'wterm' and key == public_key


class TestSFTPServer(asyncssh.SFTPServer):
    def posix_rename(self, oldpath, newpath):
        if newpath.endswith(b'denied-rename.bin'):
            raise asyncssh.SFTPPermissionDenied('Fixture rejects atomic rename')
        return super().posix_rename(oldpath, newpath)


async def shell(process):
    process.stdout.write('WTERM_FIXTURE_READY\r\n')
    async for line in process.stdin:
        if line.strip() == 'exit':
            break
        process.stdout.write('ECHO:' + line)
    process.exit(0)


async def main(args):
    root = pathlib.Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    key = asyncssh.generate_private_key('ssh-ed25519')
    (root / 'fixture.txt').write_text('hello SSH / 你好\n')
    client_key = asyncssh.generate_private_key('ssh-ed25519')
    global public_key
    public_key = client_key.convert_to_public()
    (root / 'client_key').write_bytes(client_key.export_private_key('openssh', passphrase='fixture-passphrase'))
    (root / 'host_fingerprint').write_text(key.get_fingerprint())
    await asyncssh.create_server(
        TestServer, '127.0.0.1', args.port,
        server_host_keys=[key], process_factory=shell,
        sftp_factory=lambda channel: TestSFTPServer(channel, chroot=str(root)),
    )
    print(f'READY {args.port} {key.get_fingerprint()}', flush=True)
    await asyncio.Future()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--port', type=int, default=22222)
    asyncio.run(main(parser.parse_args()))
