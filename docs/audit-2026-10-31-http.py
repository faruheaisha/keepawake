"""Run isolated read/rejection HTTP probes; never start protection or change settings."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import time

root = Path(__file__).resolve().parent.parent
out = root / '_tmp' / 'audit-20261031'
out.mkdir(parents=True, exist_ok=True)
with socket.socket() as pick:
    pick.bind(('127.0.0.1', 0))
    port = pick.getsockname()[1]
log = open(out / 'server.log', 'w', encoding='utf-8')
env = dict(os.environ, KA_DATA=str(out / 'http-data'))
proc = subprocess.Popen(
    ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
     str(root / 'ka-server.ps1'), '-Port', str(port), '-DataDir', env['KA_DATA']],
    env=env, stdout=log, stderr=subprocess.STDOUT,
    creationflags=subprocess.CREATE_NO_WINDOW,
)
rows = []


def request(method, path, headers=None, body=None, timeout=2):
    client = http.client.HTTPConnection('127.0.0.1', port, timeout=timeout)
    try:
        client.request(method, path, body=body, headers=headers or {})
        response = client.getresponse()
        data = response.read()
        return response.status, dict(response.getheaders()), data
    finally:
        client.close()


try:
    headers = {'X-Ka-Client': 'ka-dashboard'}
    for _ in range(60):
        try:
            if request('GET', '/api/ping', headers)[0] == 200:
                break
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(.2)
    else:
        raise RuntimeError('server not ready')

    cases = [
        ('ping', 'GET', '/api/ping', headers, None, [200]),
        ('missing-client', 'GET', '/api/ping', {}, None, [403]),
        ('external-origin', 'GET', '/api/ping',
         dict(headers, Origin='https://example.org'), None, [403]),
        # HTTP.sys / HttpListener may reject the encoded path before our whitelist.
        ('traversal', 'GET', '/..%2fka-core.ps1', {}, None, [403, 404]),
        ('get-stop', 'GET', '/api/stop', headers, None, [404]),
        ('bad-json', 'POST', '/api/start',
         dict(headers, **{'Content-Type': 'application/json'}), '{bad', [400]),
        ('oversize', 'POST', '/api/config',
         dict(headers, **{'Content-Type': 'application/json'}), 'x' * 65537, [400]),
    ]
    for name, method, path, hs, body, expected in cases:
        status, _, _ = request(method, path, hs, body)
        rows.append({'check': name, 'status': status, 'expected': expected,
                     'passed': status in expected})
    _, static_headers, _ = request('GET', '/')
    rows.append({'check': 'frame-policy',
                 'xFrameOptions': static_headers.get('X-Frame-Options'),
                 'csp': static_headers.get('Content-Security-Policy')})
    slow = socket.create_connection(('127.0.0.1', port), timeout=2)
    try:
        slow.sendall((
            f'POST /api/config HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n'
            'X-Ka-Client: ka-dashboard\r\nContent-Type: application/json\r\n'
            'Content-Length: 1024\r\n\r\n{}'
        ).encode())
        time.sleep(.25)
        blocked = False
        try:
            request('GET', '/api/ping', headers, timeout=1.5)
        except (OSError, http.client.HTTPException):
            blocked = True
    finally:
        slow.close()
    status, _, _ = request('GET', '/api/ping', headers, timeout=4)
    rows.append({'check': 'B12-incomplete-body-blocks-all',
                 'blocked': blocked, 'pingAfterClose': status})
    print(json.dumps(rows, indent=2))
    (out / 'http-results.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
    assert all(row.get('passed', True) for row in rows)
    assert blocked and status == 200
finally:
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    log.close()
