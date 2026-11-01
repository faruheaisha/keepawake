"""Run two real MCP stdio sessions against one isolated data root, with no synthetic input."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import uuid

root = Path(__file__).resolve().parent.parent
local_dotnet = root / '_tmp' / 'dotnet-sdk' / 'dotnet.exe'
dotnet = os.environ.get('KA_DOTNET') or (str(local_dotnet) if local_dotnet.exists() else shutil.which('dotnet'))
server = root / 'mcp-server' / 'bin' / 'Release' / 'net10.0' / 'KeepAwake.Mcp.dll'
executable = os.environ.get('KA_MCP_EXE')
engine_root = Path(os.environ.get('KA_MCP_ROOT', str(root)))
data = root / '_tmp' / ('mcp-rpc-' + uuid.uuid4().hex)
data.mkdir(parents=True)
env = os.environ.copy()
env.update(KA_DATA=str(data), KEEP_AWAKE_ROOT=str(engine_root), DOTNET_CLI_TELEMETRY_OPTOUT='1')

class Client:
    def __init__(self, name):
        self.name = name
        self.q = queue.Queue()
        self.n = 0
        if not executable and not dotnet: raise RuntimeError('A .NET 10 SDK is required to run the source MCP test.')
        command = [executable] if executable else [str(dotnet), str(server)]
        self.p = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, encoding='utf-8')
        threading.Thread(target=self._read, daemon=True).start()
        result = self.call('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {},
                                         'clientInfo': {'name': name, 'version': '1.0'}})
        assert result['protocolVersion'] == '2025-11-25', result
        self.send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})

    def _read(self):
        for line in self.p.stdout:
            try: self.q.put(json.loads(line))
            except json.JSONDecodeError: self.q.put({'bad': line})
        self.q.put(None)

    def send(self, message):
        self.p.stdin.write(json.dumps(message, separators=(',', ':')) + '\n')
        self.p.stdin.flush()

    def call(self, method, params):
        self.n += 1
        self.send({'jsonrpc': '2.0', 'id': self.n, 'method': method, 'params': params})
        while True:
            message = self.q.get(timeout=180)
            if message is None: raise RuntimeError(self.name + ' exited early')
            if message.get('id') != self.n: continue
            if 'error' in message: raise RuntimeError(message['error'])
            return message['result']

    def tool(self, name, args):
        result = self.call('tools/call', {'name': name, 'arguments': args})
        if result.get('isError'): raise RuntimeError(result)
        return json.loads(result['content'][0]['text'])

    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try: self.p.wait(timeout=45)
            except subprocess.TimeoutExpired: self.p.kill(); self.p.wait(timeout=10)

clients = []
try:
    a = Client('probe-a'); clients.append(a)
    b = Client('probe-b'); clients.append(b)
    names = {tool['name'] for tool in a.call('tools/list', {})['tools']}
    assert names == {'keepawake_status', 'keepawake_acquire', 'keepawake_renew', 'keepawake_release', 'keepawake_evidence'}, names
    status = a.tool('keepawake_status', {})
    assert not status['running'] and str(data) not in json.dumps(status)
    one = a.tool('keepawake_acquire', {'reason': 'probe-a', 'requestId': 'request-a', 'minutes': 10,
                                       'keepDisplayOn': False, 'antiLock': False})
    two = b.tool('keepawake_acquire', {'reason': 'probe-b', 'requestId': 'request-b', 'minutes': 10,
                                       'keepDisplayOn': False, 'antiLock': False})
    assert one['id'] != two['id']
    a_status = a.tool('keepawake_status', {})
    assert a_status['taskCount'] == 2 and [item['id'] for item in a_status['ownTasks']] == [one['id']]
    forbidden = b.call('tools/call', {'name': 'keepawake_release', 'arguments': {'id': one['id']}})
    assert forbidden.get('isError'), forbidden
    assert a.tool('keepawake_renew', {'id': one['id'], 'minutes': 11})['ok']
    assert a.tool('keepawake_release', {'id': one['id']})['ok']
    remaining = b.tool('keepawake_status', {})
    assert remaining['running'] and remaining['taskCount'] == 1
    assert a.tool('keepawake_release', {'id': one['id']})['alreadyReleased']
    assert b.tool('keepawake_release', {'id': two['id']})['ok']
    final = b.tool('keepawake_status', {})
    assert not final['running'] and final['taskCount'] == 0, final
    print('PROBE OK: two MCP sessions negotiated, acquired, renewed and independently released real protection')
finally:
    for client in reversed(clients): client.close()
    ps = Path(os.environ['SystemRoot']) / 'System32' / 'WindowsPowerShell' / 'v1.0' / 'powershell.exe'
    result = subprocess.run([str(ps), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / 'ka.ps1'), 'stop'],
                            cwd=root, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=180)
    if result.returncode != 0: print('CLEANUP WARNING: isolated protection may require inspection')
