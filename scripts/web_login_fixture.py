"""Loopback-only CI fixture for WKWebView -> URLSession cookie interoperability."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
import json

IMPORT_SOURCE = {
    "bookSourceName": "Gavin 导入链路测试", "bookSourceUrl": "http://127.0.0.1:18765",
    "enabled": True, "customUnknownField": {"preserve": True}, "searchUrl": "/source-search?q={{key}}",
    "ruleSearch": {"bookList": ".book", "name": "a@text", "bookUrl": "a@href"},
    "ruleBookInfo": {"tocUrl": ".catalog@href"},
    "ruleToc": {"chapterList": "#list a", "chapterName": "text", "chapterUrl": "href"},
    "ruleContent": {"content": "#content@text"}
}


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
        content_type = "text/html; charset=utf-8"
        if self.path == "/source-start":
            self.send_response(302)
            self.send_header("Location", "/sources.json")
            body = b""
        elif self.path == "/sources.json":
            self.send_response(200)
            content_type = "application/json; charset=utf-8"
            body = json.dumps([IMPORT_SOURCE], ensure_ascii=False, indent=2).encode()
        elif self.path == "/broken-sources":
            self.send_response(200)
            body = b"<!doctype html><title>Verification required</title>"
        elif self.path.startswith("/source-search?"):
            self.send_response(200)
            body = "<div class='book'><a href='/source-book'>公版导入测试</a></div>".encode()
        elif self.path == "/source-book":
            self.send_response(200)
            body = b"<a class='catalog' href='/source-toc'>TOC</a>"
        elif self.path == "/source-toc":
            self.send_response(200)
            body = "<div id='list'><a href='/source-chapter'>第一章</a></div>".encode()
        elif self.path == "/source-chapter":
            self.send_response(200)
            body = "<div id='content'>书源导入、保存、搜索、目录、正文完整链路。</div>".encode()
        elif self.path.startswith("/login"):
            self.send_response(200)
            self.send_header("Set-Cookie", "gavin_fixture=verified; Path=/; HttpOnly; SameSite=Lax")
            body = b"<!doctype html><title>Gavin login fixture</title><p>Login complete.</p>"
        elif self.path == "/private" and "gavin_fixture=verified" in self.headers.get("Cookie", ""):
            self.send_response(200)
            body = b"GAVIN_AUTHENTICATED_CHAPTER"
        elif self.path == "/dynamic" and "gavin_fixture=verified" in self.headers.get("Cookie", ""):
            self.send_response(200)
            body = b"<!doctype html><title>Gavin dynamic fixture</title><div id='content'>Loading</div><script>setTimeout(()=>document.getElementById('content').textContent='GAVIN_RENDERED_DYNAMIC_CHAPTER',400)</script>"
        else:
            self.send_response(401)
            body = b"Authentication required"
        self.send_header("Content-Type", content_type)
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
