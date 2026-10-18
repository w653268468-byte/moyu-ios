"""Loopback-only CI fixture for WKWebView -> URLSession cookie interoperability."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer


class FixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer normally does a reverse DNS lookup even for 127.0.0.1.
        # This loopback-only fixture has no need to consult external DNS.
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        print("GET", self.path, flush=True)
        if self.path.startswith("/login"):
            self.send_response(200)
            self.send_header("Set-Cookie", "gavin_fixture=verified; Path=/; HttpOnly; SameSite=Lax")
            body = b"<!doctype html><title>Gavin login fixture</title><p>Login complete.</p>"
        elif self.path == "/private" and "gavin_fixture=verified" in self.headers.get("Cookie", ""):
            self.send_response(200)
            body = b"GAVIN_AUTHENTICATED_CHAPTER"
        else:
            self.send_response(401)
            body = b"Authentication required"
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


print("SERVER_STARTING", flush=True)
server = FixtureServer(("127.0.0.1", 18765), Handler)
print("SERVER_READY", server.server_address, flush=True)
server.serve_forever()
