#!/usr/bin/env python3
"""Local-only driver for ClaudeLiveRotationHarness.swift; never forwards requests."""
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
from claude_rotation_process import OwnedProcess

root, config, cli = map(Path, sys.argv[1:])
assert root.name.startswith('claude-live-rotation-') and config.parent == root
requests = []
responses = queue.Queue()
state = {'stage': 'initial', 'failure': None}


class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        auth = self.headers.get('Authorization')
        if auth not in ('Bearer TEST-ONLY-A', 'Bearer TEST-ONLY-B'):
            state['failure'] = 'Unexpected authorization; value deliberately omitted'
            self.send_error(403)
            return
        if self.path.split('?')[0] != '/v1/messages':
            self.send_error(404)
            return
        incoming = json.loads(body)
        requests.append({'stage': state['stage'], 'authorization': auth, 'stream': incoming.get('stream', False)})
        message = {'id': 'msg_test_only', 'type': 'message', 'role': 'assistant', 'model': 'claude-sonnet-4-6',
                   'content': [], 'stop_reason': None, 'stop_sequence': None,
                   'usage': {'input_tokens': 1, 'output_tokens': 0}}
        if incoming.get('stream'):
            events = [
                ('message_start', {'type': 'message_start', 'message': message}),
                ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
                ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': 'TEST OK'}}),
                ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 2}}),
                ('message_stop', {'type': 'message_stop'}),
            ]
            encoded = ''.join(f'event: {name}\ndata: {json.dumps(data)}\n\n' for name, data in events).encode()
            mime = 'text/event-stream'
        else:
            message.update(content=[{'type': 'text', 'text': 'TEST OK'}], stop_reason='end_turn')
            message['usage']['output_tokens'] = 2
            encoded, mime = json.dumps(message).encode(), 'application/json'
        self.send_response(200)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


# Every vendor security command is intercepted; no fallback to a default
# keychain or user search list is possible through this helper.
manifest_path = root / 'fixture-keychain.json'
manifest = json.loads(manifest_path.read_text())
assert Path(manifest['keychain']).parent == root
shim_directory = root / 'bin'
shim_directory.mkdir(mode=0o700)
shim = shim_directory / 'security'
shim.write_text("#!/usr/bin/python3\nimport json,os,sys\n" +
    "m=json.load(open(" + repr(str(manifest_path)) + "))\n" +
    "a=sys.argv[1:]\n" +
    "if len(a)!=6 or a[:2]!=['find-generic-password','-a'] or a[2]!=m['account'] or a[3:5]!=['-w','-s'] or a[5] not in m['services']: sys.exit(44)\n" +
    "os.execv('/usr/bin/security',['/usr/bin/security']+a+[m['keychain']])\n")
shim.chmod(0o700)

with OwnedProcess(lambda: (root / 'driver-cleanup.done').write_text('Owned process group exited')) as owner:
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Mock)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # A strict allowlist prevents inherited provider credentials, plugins, settings,
    # proxies, or token overrides from replacing the unique dummy Keychain namespace.
    env = {key: os.environ[key] for key in ('PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG') if key in os.environ}
    env['PATH'] = str(shim_directory) + ':/usr/bin:/bin:/usr/sbin:/sbin'
    env.update(CLAUDE_CONFIG_DIR=str(config), ANTHROPIC_BASE_URL=f'http://127.0.0.1:{server.server_port}',
               CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1', DISABLE_AUTOUPDATER='1',
               DISABLE_TELEMETRY='1', DISABLE_ERROR_REPORTING='1', CLAUDE_CODE_DISABLE_AUTO_MEMORY='1')
    # Kernel-enforced egress restriction applies to CLI and all its subprocesses.
    # The mock binds loopback only, contains no forwarding implementation, and serves
    # only synthetic inference responses. No real model usage or paid request occurs.
    profile = '(version 1)(allow default)(deny network*)(allow network-outbound (remote ip "localhost:*"))(allow network-inbound (local ip "localhost:*"))'
    args = ['/usr/bin/sandbox-exec', '-p', profile, str(cli), '-p', '--verbose', '--input-format', 'stream-json',
            '--output-format', 'stream-json', '--no-session-persistence', '--setting-sources', '',
            '--strict-mcp-config', '--tools', '', '--disable-slash-commands', '--model', 'claude-sonnet-4-6',
            '--system-prompt', 'Respond TEST OK.']
    child = owner.start(args, cwd=config, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    identity = {'pid': child.pid}


    def read_stdout():
        for line in child.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get('subtype') == 'init':
                identity.update(version=event.get('claude_code_version'), session=event.get('session_id'))
            if event.get('type') == 'result':
                responses.put(event)


    threading.Thread(target=read_stdout, daemon=True).start()
    # Drain diagnostic output without recording arbitrary vendor data or secrets.
    threading.Thread(target=lambda: [None for _ in child.stderr], daemon=True).start()


    def turn(stage, expected):
        assert child.poll() is None, 'CLI exited before next turn'
        state['stage'] = stage
        start = len(requests)
        child.stdin.write(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': f'{stage}: say TEST OK'}}) + '\n')
        child.stdin.flush()
        result = responses.get(timeout=30)
        assert not result.get('is_error'), f"CLI turn failed: {stage}: {result.get('result')} (HTTP {result.get('api_error_status')}); request stages: {requests}; mock failure: {state['failure']}"
        assert result.get('session_id') == identity.get('session'), 'Conversation changed across switch'
        observed = requests[start:]
        assert observed and all(item['authorization'] == f'Bearer TEST-ONLY-{expected}' for item in observed), observed
        assert result.get('result') == 'TEST OK'
        print(f'PASS {stage}: TEST-ONLY-{expected}, same PID {child.pid}, same conversation', flush=True)


    def switch(action):
        (root / f'{action}.request').write_text('requested')
        deadline = time.monotonic() + 15
        while not (root / f'{action}.done').exists():
            assert child.poll() is None, 'CLI exited during switch'
            assert time.monotonic() < deadline, 'Swift copyLogin callback timed out'
            time.sleep(0.05)
        assert (config / '.credentials.json').read_text() == '{}', 'Expected secret-free invalidation marker'


    try:
        turn('initial', 'A')
        switch('copy-b')
        turn('immediate-switch', 'B')
        switch('copy-a')
        idle_start = time.monotonic()
        time.sleep(37)
        assert not (config / '.credentials.json').exists(), '35-second marker cleanup did not happen'
        idle_seconds = time.monotonic() - idle_start
        turn('idle-past-marker-cleanup', 'A')
        assert state['failure'] is None, state['failure']
        proof = {'passed': True, 'cli': identity, 'requests': requests, 'idle_seconds': idle_seconds,
                 'marker_removed': True, 'external_network': 'kernel-denied', 'production_copy_login_calls': 2, 'keychain': 'explicit disposable keychain; guarded helper; search list unchanged'}
        (root / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    finally:
        owner.close()
        server.shutdown()
