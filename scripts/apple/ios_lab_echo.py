#!/usr/bin/env python3
"""Temporary HTTPS control target. No proxying, filesystem serving or request logs."""
import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import re
import ssl
import time
from urllib.parse import parse_qs, urlsplit


class EchoHandler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        query = parse_qs(url.query, max_num_fields=4)
        nonce = query.get('nonce', [''])[0]
        if url.path == '/unavailable':
            status, value = 503, {'status': 'intentionally_unavailable'}
        elif url.path == '/echo' and re.fullmatch(r'[A-Za-z0-9-]{16,64}', nonce):
            status, value = 200, {'nonce': nonce, 'marker': self.server.marker,
                                  'egress': self.client_address[0]}
        else:
            status, value = 400, {'status': 'invalid_test_request'}
        body = json.dumps(value, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)


class EchoServer(HTTPServer):
    request_queue_size = 4
    timeout = 1

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(3)
        try:
            return self.context.wrap_socket(connection, server_side=True), address
        except BaseException:
            connection.close()
            raise

    def handle_error(self, *_):
        # Malformed requests and client addresses must not reach logs.
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cert', required=True)
    parser.add_argument('--key', required=True)
    parser.add_argument('--marker', required=True)
    parser.add_argument('--port', type=int, default=18443)
    parser.add_argument('--seconds', type=int, default=3600)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535 or not 60 <= args.seconds <= 7200:
        parser.error('Use a nonprivileged port and a 60..7200 second lifetime')
    if not re.fullmatch(r'[a-z0-9-]{1,40}', args.marker):
        parser.error('Invalid public test marker')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert, args.key)
    # Read the existing TLS material once, then drop root before accepting traffic.
    if os.geteuid() == 0:
        os.setgroups([])
        os.setgid(65534)
        os.setuid(65534)
    deadline = time.monotonic() + args.seconds
    with EchoServer(('0.0.0.0', args.port), EchoHandler) as server:
        server.context = context
        server.marker = args.marker
        while time.monotonic() < deadline:
            server.handle_request()


if __name__ == '__main__':
    main()
