"""Loopback-only CI fixture for WKWebView -> URLSession cookie interoperability."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
import json
import time
import io
import wave
import math
import struct
from pathlib import Path
from urllib.parse import urlparse, parse_qs

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
        if self.path.startswith("/health-gone/search"):
            self.send_response(404); body = b"gone"
        elif self.path.startswith("/health-login/search"):
            self.send_response(403); body = b"login required"
        elif self.path.startswith("/tts-audio"):
            query = parse_qs(urlparse(self.path).query)
            if query.get("requireAuth") == ["1"] and (self.headers.get("X-Voice") != "native" or self.headers.get("X-Token") != "native-secret-value"):
                self.send_response(401); content_type = "application/json"; body = b'{"error":"missing credentials"}'
            else:
                self.send_response(200); content_type = "audio/wav"
                output = io.BytesIO()
                with wave.open(output, "wb") as audio:
                    audio.setnchannels(1); audio.setsampwidth(2); audio.setframerate(8000)
                    audio.writeframes(b"".join(struct.pack("<h", int(700 * math.sin(2 * math.pi * 220 * n / 8000))) for n in range(2400)))
                body = output.getvalue()
        elif self.path == "/tts-library.js":
            body = b"function sharedVoice(text){return 'http://127.0.0.1:18765/tts-audio?text='+java.encodeURI(text)+'&engine='+source.id;}"
            self.send_response(200); self.send_header("Content-Type", "application/javascript"); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        elif self.path == "/tts-config.json":
            self.send_response(200); content_type = "application/json"
            body = json.dumps([{"id": 991, "name": "本地测试音色", "url": "http://127.0.0.1:18765/tts-audio?text={{java.encodeURI(speakText)}}&speed={{speakSpeed}}", "contentType": "audio/wav"}]).encode()
        elif self.path == "/replace-rules.json":
            self.send_response(200)
            content_type = "application/json; charset=utf-8"
            body = json.dumps([{"id": 991, "name": "Import rule", "pattern": "AD_TEXT", "replacement": "", "isRegex": False}, {"name": "Invalid rule", "pattern": "(", "isRegex": True}]).encode()
        elif self.path in ("/prefetch-origin/2", "/prefetch-origin/3"):
            time.sleep(0.5)
            self.send_response(200)
            body = ("<div id='content'>第" + self.path[-1] + "章已预取。" + "提前准备好的章节正文。" * 80 + "</div>").encode()
        elif self.path == "/catalog-refresh-origin/book":
            self.send_response(200)
            body = ("<div id='list'>" + "".join(f"<a href='/catalog-refresh-origin/{n}'>第{n}章 测试</a>" for n in range(1, 5)) + "</div>").encode()
        elif self.path == "/catalog-refresh-origin/4":
            self.send_response(200)
            body = ("<div id='content'>第四章新增正文。" + "新增章节可继续阅读。" * 80 + "</div>").encode()
        elif self.path == "/font-test.ttf":
            font = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
            self.send_response(200 if font.is_file() else 404)
            content_type = "font/ttf"
            body = font.read_bytes() if font.is_file() else b"Missing test font"
        elif self.path == "/search-test-sources":
            self.send_response(200)
            content_type = "application/json; charset=utf-8"
            sources = []
            for tag, name in [("a", "搜索测试甲"), ("b", "搜索测试乙")]:
                source = dict(IMPORT_SOURCE, bookSourceName=name, bookSourceUrl="http://127.0.0.1:18765/source-" + tag,
                    bookSourceGroup="搜索测试", searchUrl="/search-ui?site=" + tag + "&q={{key}}&page={{page}}")
                source["ruleSearch"] = dict(IMPORT_SOURCE["ruleSearch"], author=".author@text", kind=".kind@text", lastChapter=".latest@text")
                sources.append(source)
            body = json.dumps(sources, ensure_ascii=False).encode()
        elif self.path.startswith("/search-ui?"):
            self.send_response(200)
            query = parse_qs(urlparse(self.path).query)
            page = query.get("page", ["1"])[0]
            tag = query.get("site", ["a"])[0]
            items = [("公版小说", "某作者"), ("其他故事", "另一位")] if page == "1" else [("第二页故事", "新作者")] if page == "2" else []
            body = "".join(f"<div class='book'><a href='/search-ui-book?site={tag}&amp;book={(int(page)-1)*10+index}'>{title}</a><span class='author'>{author}</span><span class='kind'>小说</span><span class='latest'>第一章</span></div>" for index, (title, author) in enumerate(items)).encode()
        elif self.path.startswith("/search-ui-book?"):
            self.send_response(200)
            body = b"<a class='catalog' href='/source-toc'>TOC</a>"
        elif self.path == "/source-start":
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
