#!/usr/bin/env python3
"""Exercise the deployment nginx with built Web assets and a real WS echo peer.

Requires Docker and an existing Web release directory. All listeners are bound
to loopback; only this run's uniquely named container/image are removed.
"""
import argparse
import base64
import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid

IMAGE = 'nginx:stable-alpine@sha256:583b7f2fce1cdb8da5ad5c39ebd3c33b98b87d493190e548bdee1fa8c619c311'


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr[-500:]}')
    return result.stdout.strip()


def read_exact(stream, size):
    data = b''
    while len(data) < size:
        part = stream.read(size-len(data))
        if not part:
            raise EOFError('peer closed')
        data += part
    return data


def verify(conf, web_root):
    if not (web_root/'index.html').is_file() or not (web_root/'share-bootstrap.js').is_file():
        raise RuntimeError('A built cloud Web release is required')
    if not shutil.which('docker'):
        raise RuntimeError('Docker is required; no simulated/skip fallback')
    seen = {'requests': [], 'ws_origin': None, 'payload': None}

    class Peer(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def do_GET(self):
            seen['requests'].append(self.path)
            if self.path == '/gateway/v1/connect':
                assert self.headers.get('Upgrade', '').lower() == 'websocket'
                seen['ws_origin'] = self.headers.get('Origin')
                key = self.headers['Sec-WebSocket-Key']
                accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101)
                self.send_header('Upgrade', 'websocket')
                self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept)
                self.end_headers()
                head = read_exact(self.rfile, 2)
                size = head[1] & 127
                assert head[0] == 0x81 and head[1] & 128 and size < 126
                mask = read_exact(self.rfile, 4)
                raw = read_exact(self.rfile, size)
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(raw))
                seen['payload'] = payload.decode()
                self.wfile.write(bytes([0x81, len(payload)])+payload)
                self.wfile.flush()
                self.close_connection = True
            else:
                payload = b'{"fixture":true}'
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

    peer = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Peer)
    thread = threading.Thread(target=peer.serve_forever, daemon=True)
    thread.start()
    allocation = socket.socket()
    allocation.bind(('127.0.0.1', 0))
    port = allocation.getsockname()[1]
    allocation.close()
    name = 'atermius-cloud-proxy-'+uuid.uuid4().hex[:10]
    image = name+':check'
    started = False
    built = False
    with tempfile.TemporaryDirectory(prefix='cloud-proxy-', dir=os.environ.get('TMPDIR')) as directory:
        directory = Path(directory)
        # The only test substitutions are loopback endpoints/ports. Routing,
        # headers, try_files, user and image stay the deployment's real values.
        config = conf.read_text()
        assert config.count('listen 8080;') == 1
        assert config.count('http://server:8080;') == 1
        config = config.replace('listen 8080;', f'listen 127.0.0.1:{port};')
        config = config.replace('http://server:8080;', f'http://127.0.0.1:{peer.server_port};')
        (directory/'nginx.conf').write_text(config)
        shutil.copytree(web_root, directory/'web', symlinks=False)
        # Source build services use umask0077. The fixture image restores the
        # same nginx ownership/readability as the production Dockerfile.
        (directory/'Dockerfile').write_text(
            f'FROM {IMAGE}\n'
            'COPY web/ /usr/share/nginx/html/\n'
            'COPY nginx.conf /etc/nginx/nginx.conf\n'
            'RUN chmod 0644 /etc/nginx/nginx.conf && chown -R nginx:nginx /var/cache/nginx /usr/share/nginx/html && chmod -R u+rX /usr/share/nginx/html\n'
            'USER nginx\n'
            'CMD ["nginx", "-g", "daemon off;"]\n'
        )
        try:
            # Runtime staging only uses COPY/chmod/chown, so this build needs
            # no network (and does not depend on a host docker0 bridge).
            command(['docker', 'build', '--network=none', '--label', 'atermius-cloud-proxy-check=true', '-t', image, str(directory)])
            built = True
            command(['docker', 'run', '--rm', '--network=host', '--entrypoint', 'nginx', image, '-t'])
            command(['docker', 'run', '-d', '--name', name, '--label', 'atermius-cloud-proxy-check=true', '--network=host', image])
            started = True

            def get(path):
                connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
                connection.request('GET', path)
                response = connection.getresponse()
                result = response.status, dict(response.getheaders()), response.read()
                connection.close()
                return result

            deadline = time.monotonic()+10
            while True:
                try:
                    if get('/index.html')[0] == 200:
                        break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise RuntimeError('nginx did not start')
                time.sleep(0.1)
            index = (web_root/'index.html').read_bytes()
            text = index.decode()
            assert text.index('share-bootstrap.js') < text.index('flutter_bootstrap.js')
            paths = ['/s/example-link', '/s/unknown-address?preview=true', '/join', '/join/']
            for path in paths:
                status, headers, body = get(path)
                assert status == 200 and body == index, path
                for header, expected in {
                    'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer',
                    'X-Content-Type-Options': 'nosniff', 'X-Frame-Options': 'DENY',
                    'Cross-Origin-Opener-Policy': 'same-origin',
                    'Permissions-Policy': 'camera=(), geolocation=(), microphone=(), payment=()',
                }.items():
                    assert headers.get(header) == expected, (path, header)
                csp = headers['Content-Security-Policy']
                assert "script-src 'self' 'wasm-unsafe-eval'" in csp
                assert "frame-ancestors 'none'" in csp
            assert seen['requests'] == [], 'Landing pages must not call/redeem against API'
            assert get('/share-bootstrap.js')[0] == 200
            assert get('/api/v1/instance')[2] == b'{"fixture":true}'
            sock = socket.create_connection(('127.0.0.1', port), timeout=5)
            key = base64.b64encode(os.urandom(16)).decode()
            request = ('GET /gateway/v1/connect HTTP/1.1\r\nHost: fixture.example\r\n'
                       'Upgrade: websocket\r\nConnection: Upgrade\r\n'
                       'Origin: https://fixture.example\r\nSec-WebSocket-Version: 13\r\n'
                       f'Sec-WebSocket-Key: {key}\r\n\r\n')
            try:
                sock.sendall(request.encode())
                reader = sock.makefile('rb')
                assert b'101' in reader.readline(), 'gateway did not upgrade through nginx'
                while reader.readline() not in (b'\r\n', b''):
                    pass
                payload = b'gateway-proxy-roundtrip'
                mask = os.urandom(4)
                sock.sendall(bytes([0x81, 0x80 | len(payload)])+mask+bytes(b ^ mask[i % 4] for i,b in enumerate(payload)))
                head = read_exact(reader, 2)
                assert head == bytes([0x81, len(payload)])
                assert read_exact(reader, len(payload)) == payload
                assert seen['ws_origin'] == 'https://fixture.example'
                assert seen['payload'] == payload.decode()
                reader.close()
            finally:
                sock.close()
            return {'nginx_image': IMAGE, 'nginx_config_valid': True, 'nonroot_user': 'nginx',
                    'landing_paths_checked': paths, 'security_headers_checked': 7,
                    'header_assertions_per_landing': 8,
                    'landing_backend_requests': 0, 'api_proxy': True,
                    'websocket_upgrade_and_masked_echo': True, 'origin_preserved': True,
                    'config_sha256': hashlib.sha256(conf.read_bytes()).hexdigest(),
                    'web_index_sha256': hashlib.sha256(index).hexdigest()}
        finally:
            if started:
                command(['docker', 'rm', '-f', name])
            if built:
                command(['docker', 'image', 'rm', image])
            peer.shutdown()
            peer.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--nginx-conf', type=Path, default=Path('deploy/nginx.conf'))
    parser.add_argument('--web-root', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.nginx_conf.resolve(), args.web_root.resolve()), indent=2))
