import os
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
import tempfile
from pathlib import Path

# Use local imports by adjusting sys.path inside tests if necessary
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from compose_init_up import generate_skeleton_toml


class SimpleHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        # respond with a fake IP
        self.send_response(200)
        self.send_header('Content-type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'203.0.113.45')

    def log_message(self, format, *args):
        return


def run_test_server(port):
    server = HTTPServer(('127.0.0.1', port), SimpleHandler)
    server.serve_forever()


def test_ip_detection_override(tmp_path, monkeypatch):
    # start a local HTTP server on an ephemeral port
    import socket
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()

    t = threading.Thread(target=run_test_server, args=(port,), daemon=True)
    t.start()

    # point the detection to our local server
    monkeypatch.setenv('COMPINIT_IP_DETECT_URLS', f'http://127.0.0.1:{port}/')

    out = tmp_path / 'test.toml'
    # wait until the server is ready (avoid race on some CI/hosts)
    import time, socket as _socket
    deadline = time.time() + 2.0
    while time.time() < deadline:
        try:
            with _socket.create_connection(('127.0.0.1', port), timeout=0.2):
                break
        except Exception:
            time.sleep(0.05)

    # generate skeleton - should query our local server and embed the ip
    generate_skeleton_toml(str(out))

    content = out.read_text(encoding='utf-8')
    assert '203.0.113.45' in content
