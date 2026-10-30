"""Isolated loopback SSH/SFTP server. Never enable system Remote Login.
Install asyncssh in a venv; run with --root <temporary-dir> --port 22222.
Only synthetic credentials: wterm / wterm-test-only.
"""
import argparse
import asyncio
import base64
import pathlib
import asyncssh


class TestServer(asyncssh.SSHServer):
    def __init__(self, own_port=0):
        self.own_port = own_port

    def connection_requested(self, dest_host, dest_port, orig_host, orig_port):
        # Reject connecting to itself so a client-side direct fallback is observable.
        return dest_host == '127.0.0.1' and dest_port != self.own_port

    def server_requested(self, listen_host, listen_port):
        # Allow remote -R only on server loopback; external exposure is explicit.
        return listen_host in ('127.0.0.1', 'localhost', '')

    def begin_auth(self, username):
        self.username = username
        self.round = 0
        return True

    def kbdint_auth_supported(self):
        return self.username == 'mfa'

    def get_kbdint_challenge(self, username, lang, submethods):
        return ('Fixture MFA', 'Synthetic prompts only', '', [('One-time code', False), ('Label', True)])

    def validate_kbdint_response(self, username, responses):
        if self.round == 0:
            if responses != ['654321', 'visible']:
                return False
            self.round = 1
            return ('Confirm', 'No input required', '', [])
        return responses == []

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


async def shell_impl(process, marker):
    process.stdout.write(f'WTERM_FIXTURE_READY{marker}\r\n')
    async for line in process.stdin:
        if line.strip() == 'exit':
            break
        process.stdout.write('ECHO:' + line)
    process.exit(0)


async def shell(process):
    await shell_impl(process, '')


async def jump_shell(process):
    await shell_impl(process, ':JUMP')


async def jump2_shell(process):
    await shell_impl(process, ':JUMP2')


async def stall_connection(reader, writer):
    """Accepts TCP but never sends an SSH banner; used for probe cancellation."""
    try:
        await asyncio.sleep(60)
    except asyncio.CancelledError:
        pass
    finally:
        writer.close()


async def proxy_connection(reader, writer, mode, ssh_port):
    """Loopback-only proxy: resolves just fixture.invalid to the fixture SSH server."""
    upstream = None
    try:
        if mode == 'http':
            data = await reader.readuntil(b'\r\n\r\n')
            expected = f'CONNECT fixture.invalid:{ssh_port} HTTP/1.1\r\n'.encode()
            basic = base64.b64encode(b'proxy-user:proxy-secret')
            if not data.startswith(expected) or b'Proxy-Authorization: Basic ' + basic + b'\r\n' not in data:
                writer.write(b'HTTP/1.1 407 Rejected\r\n\r\n')
                await writer.drain()
                return
        else:
            if await reader.readexactly(3) != b'\x05\x01\x02':
                return
            writer.write(b'\x05\x02')
            await writer.drain()
            version, n = await reader.readexactly(2)
            user = await reader.readexactly(n)
            n = (await reader.readexactly(1))[0]
            password = await reader.readexactly(n)
            if version != 1 or user != b'proxy-user' or password != b'proxy-secret':
                writer.write(b'\x01\x01')
                await writer.drain()
                return
            writer.write(b'\x01\x00')
            await writer.drain()
            if await reader.readexactly(4) != b'\x05\x01\x00\x03':
                return
            n = (await reader.readexactly(1))[0]
            host = await reader.readexactly(n)
            port = int.from_bytes(await reader.readexactly(2), 'big')
            if host != b'fixture.invalid' or port != ssh_port:
                return
        remote, upstream = await asyncio.open_connection('127.0.0.1', ssh_port)
        writer.write(b'HTTP/1.1 200 Connected\r\n\r\n' if mode == 'http' else b'\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x16')
        await writer.drain()

        async def relay(source, target):
            while data := await source.read(65536):
                target.write(data)
                await target.drain()
            if target.can_write_eof():
                target.write_eof()
        await asyncio.gather(relay(reader, upstream), relay(remote, writer))
    except (OSError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
        pass
    finally:
        if upstream:
            upstream.close()
        writer.close()


async def run_proxy(reader, writer, mode, port):
    try:
        await asyncio.wait_for(proxy_connection(reader, writer, mode, port), 30)
    except asyncio.TimeoutError:
        writer.close()


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
        lambda: TestServer(args.port), '127.0.0.1', args.port,
        server_host_keys=[key], process_factory=shell,
        sftp_factory=lambda channel: TestSFTPServer(channel, chroot=str(root)),
    )
    jump_key = asyncssh.generate_private_key('ssh-ed25519')
    jump_server = await asyncssh.create_server(
        lambda: TestServer(), '127.0.0.1', 0,
        server_host_keys=[jump_key], process_factory=jump_shell,
    )
    jump_port = jump_server.get_addresses()[0][1]
    (root / 'jump_port').write_text(str(jump_port))
    (root / 'jump_fingerprint').write_text(jump_key.get_fingerprint())
    jump2_key = asyncssh.generate_private_key('ssh-ed25519')
    jump2_server = await asyncssh.create_server(
        lambda: TestServer(), '127.0.0.1', 0,
        server_host_keys=[jump2_key], process_factory=jump2_shell,
    )
    jump2_port = jump2_server.get_addresses()[0][1]
    (root / 'jump2_port').write_text(str(jump2_port))
    (root / 'jump2_fingerprint').write_text(jump2_key.get_fingerprint())
    stall = await asyncio.start_server(stall_connection, '127.0.0.1', 0)
    (root / 'stall_port').write_text(str(stall.sockets[0].getsockname()[1]))
    proxies = []
    for mode in ['http', 'socks5']:
        server = await asyncio.start_server(
            lambda r, w, m=mode: run_proxy(r, w, m, args.port), '127.0.0.1', 0)
        proxies.append(server)
        (root / f'{mode}_proxy_port').write_text(str(server.sockets[0].getsockname()[1]))
    print(f'READY {args.port} {key.get_fingerprint()}', flush=True)
    await asyncio.Future()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--port', type=int, default=22222)
    asyncio.run(main(parser.parse_args()))
