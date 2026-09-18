import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('echo', Path(__file__).resolve().parents[1] / 'apple/ios_lab_echo.py')
echo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(echo)


class EchoTests(unittest.TestCase):
    def request(self, path):
        handler = object.__new__(echo.EchoHandler)
        handler.path = path
        handler.server = SimpleNamespace(marker='zeon-lab-a')
        handler.client_address = ('192.0.2.1', 1234)
        handler.wfile = io.BytesIO()
        handler.send_response = lambda code: setattr(handler, 'status', code)
        handler.send_header = lambda *_: None
        handler.end_headers = lambda: None
        handler.do_GET()
        return handler.status, json.loads(handler.wfile.getvalue())

    def test_fresh_nonce_and_peer_egress(self):
        nonce = '12345678-1234-1234-1234-123456789012'
        status, value = self.request('/echo?nonce=' + nonce)
        self.assertEqual(status, 200)
        self.assertEqual(value, {'nonce': nonce, 'marker': 'zeon-lab-a', 'egress': '192.0.2.1'})

    def test_failure_is_scoped_to_its_path(self):
        self.assertEqual(self.request('/unavailable')[0], 503)
        self.assertEqual(self.request('/echo?nonce=abcdefghijklmnop')[0], 200)

    def test_missing_nonce_or_other_path_never_returns_traffic_proof(self):
        for path in ['/echo', '/etc/passwd', '/echo?nonce=bad%22nonce']:
            self.assertEqual(self.request(path)[0], 400)


if __name__ == '__main__':
    unittest.main()
