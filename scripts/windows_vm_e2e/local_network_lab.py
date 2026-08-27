from __future__ import annotations

import argparse
import selectors
import socket
import socketserver
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


MAX_HEADER_BYTES = 64 * 1024


class QuietHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *args: object) -> None:
        return


class QuietThreadingHTTPServer(ThreadingHTTPServer):
    def handle_error(self, request: object, client_address: object) -> None:
        # Connection resets are expected when a TLS/proxy negative test aborts
        # a handshake. Do not emit peer details or request-adjacent data.
        return


class PacHandler(QuietHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        body = b'function FindProxyForURL(url, host) { return "PROXY 10.0.2.2:18080"; }\n'
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class HealthHandler(QuietHandler):
    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler contract
        body = b"zeon-e2e-ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ProxyHandler(socketserver.BaseRequestHandler):
    require_auth = False

    def handle(self) -> None:
        self.request.settimeout(10)
        header = bytearray()
        while b"\r\n\r\n" not in header and len(header) < MAX_HEADER_BYTES:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            header.extend(chunk)
        if b"\r\n\r\n" not in header:
            return
        if self.require_auth:
            self.request.sendall(
                b"HTTP/1.1 407 Proxy Authentication Required\r\n"
                b"Proxy-Authenticate: Negotiate\r\n"
                b"Proxy-Authenticate: NTLM\r\n"
                b"Content-Length: 0\r\nConnection: close\r\n\r\n"
            )
            return

        header_end = header.index(b"\r\n\r\n") + 4
        head = bytes(header[:header_end])
        remainder = bytes(header[header_end:])
        lines = head.split(b"\r\n")
        request_line = lines[0].decode("ascii", "strict")
        method, target, version = request_line.split(" ", 2)

        if method.upper() == "CONNECT":
            host, port = split_authority(target, 443)
            with socket.create_connection((host, port), timeout=10) as upstream:
                self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                if remainder:
                    upstream.sendall(remainder)
                relay(self.request, upstream)
            return

        parsed = urlsplit(target)
        if parsed.scheme.lower() != "http" or not parsed.hostname:
            self.request.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return
        port = parsed.port or 80
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        filtered = [
            line
            for line in lines[1:]
            if not line.lower().startswith((b"proxy-authorization:", b"proxy-connection:"))
        ]
        outbound = f"{method} {path} {version}\r\n".encode("ascii")
        outbound += b"\r\n".join(filtered) + b"\r\n"
        with socket.create_connection((parsed.hostname, port), timeout=10) as upstream:
            upstream.sendall(outbound)
            if remainder:
                upstream.sendall(remainder)
            relay(self.request, upstream)


def split_authority(value: str, default_port: int) -> tuple[str, int]:
    if value.startswith("["):
        end = value.find("]")
        if end < 0:
            raise ValueError("invalid authority")
        host = value[1:end]
        port = int(value[end + 2 :]) if value[end + 1 :].startswith(":") else default_port
        return host, port
    if ":" not in value:
        return value, default_port
    host, port = value.rsplit(":", 1)
    return host, int(port)


def relay(left: socket.socket, right: socket.socket) -> None:
    selector = selectors.DefaultSelector()
    selector.register(left, selectors.EVENT_READ, right)
    selector.register(right, selectors.EVENT_READ, left)
    try:
        while True:
            events = selector.select(timeout=15)
            if not events:
                return
            for key, _ in events:
                data = key.fileobj.recv(64 * 1024)
                if not data:
                    return
                key.data.sendall(data)
    finally:
        selector.close()


class ThreadingProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request: object, client_address: object) -> None:
        return


def start_thread(server: socketserver.BaseServer) -> None:
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--private-key", required=True)
    arguments = parser.parse_args()

    pac = QuietThreadingHTTPServer(("127.0.0.1", 18081), PacHandler)
    https_server = QuietThreadingHTTPServer(("127.0.0.1", 18443), HealthHandler)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(arguments.certificate, arguments.private_key)
    https_server.socket = tls.wrap_socket(https_server.socket, server_side=True)
    proxy = ThreadingProxyServer(("127.0.0.1", 18080), ProxyHandler)
    auth_handler = type("AuthProxyHandler", (ProxyHandler,), {"require_auth": True})
    auth_proxy = ThreadingProxyServer(("127.0.0.1", 18083), auth_handler)
    servers = [pac, https_server, proxy, auth_proxy]
    for server in servers:
        start_thread(server)
    print("network_lab_ready=true", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
