"""CI-only UI data; never bundled in the app."""
from pathlib import Path
import json
import sys
import zipfile
import xml.etree.ElementTree as ET

container = Path(sys.argv[1])
directory = container / "Documents/MoyuOnline"
directory.mkdir(parents=True, exist_ok=True)
source = json.loads(Path("Examples/booksource.example.json").read_text(encoding="utf-8"))
source["bookSourceName"] = "示例书源 · CSS"
source["bookSourceGroup"] = "界面测试示例"
second = dict(source, bookSourceName="示例书源 · 待适配脚本", bookSourceUrl="https://script.example.invalid", ruleContent={"content": "@js:result"})
(directory / "index.json").write_text(json.dumps(dict(sources=[source, second], novels=[]), ensure_ascii=False), encoding="utf-8")

local = container / "Documents/Moyu"
local.mkdir(parents=True, exist_ok=True)
book_id = "A143B664-7214-43DC-8AB9-EFE83C537842"
text = "清晨的海风翻过书页，山与海之间，故事慢慢展开。"
document = dict(chapters=[dict(id=0,title="春日插图",firstPage=0),dict(id=1,title="海边的信",firstPage=1)], pages=[dict(id=0,chapter=0,text=text),dict(id=1,chapter=1,text=text)],wordCount=len(text)*2)
book = dict(id=book_id,title="Gavin 原版 EPUB 预览",addedAt=0,page=0,pageCount=2,chapterCount=2,wordCount=len(text)*2,bookmarks=[],colorIndex=1,originalEPUB=True,epubChapter=0,epubProgress=0)
(local / "library.json").write_text(json.dumps([book],ensure_ascii=False),encoding="utf-8")
(local / f"{book_id}.json").write_text(json.dumps(document,ensure_ascii=False),encoding="utf-8")
with zipfile.ZipFile(local / f"{book_id}.epub","w",zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    archive.writestr("META-INF/container.xml","<container xmlns='urn:oasis:names:tc:opendocument:xmlns:container' version='1.0'><rootfiles><rootfile full-path='OPS/package.opf' media-type='application/oebps-package+xml'/></rootfiles></container>")
    archive.writestr("OPS/package.opf","<package xmlns='http://www.idpf.org/2007/opf' version='3.0' unique-identifier='id'><metadata xmlns:dc='http://purl.org/dc/elements/1.1/'><dc:identifier id='id'>gavin-ci-epub</dc:identifier><dc:title>Gavin EPUB fixture</dc:title><dc:language>zh-CN</dc:language><meta property='dcterms:modified'>2026-10-19T00:00:00Z</meta></metadata><manifest><item id='a' href='one.xhtml' media-type='application/xhtml+xml'/><item id='b' href='two.xhtml' media-type='application/xhtml+xml'/><item id='nav' href='nav.xhtml' properties='nav' media-type='application/xhtml+xml'/><item id='css' href='style.css' media-type='text/css'/><item id='image' href='images/sea.svg' media-type='image/svg+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>")
    archive.writestr("OPS/style.css","body{font:20px Georgia,serif;margin:24px;color:#283c36;background:#f6f2e8}h1{font-size:30px;color:rgb(30, 100, 80)}img{max-width:100%;height:auto}p{line-height:1.9}")
    archive.writestr("OPS/images/sea.svg","<svg xmlns='http://www.w3.org/2000/svg' width='400' height='280'><rect width='400' height='280' fill='#d5e6da'/><circle cx='310' cy='65' r='30' fill='#edcf86'/><path d='M0 180L90 80L190 180L280 110L400 185V280H0Z' fill='#6b9580'/><path d='M0 215Q100 180 200 220T400 215V280H0Z' fill='#86b5bd'/></svg>")
    archive.writestr("OPS/one.xhtml","<html xmlns='http://www.w3.org/1999/xhtml'><head><title>春日插图</title><meta name='viewport' content='width=device-width,initial-scale=1'/><link rel='stylesheet' href='style.css'/></head><body><h1>春日插图</h1><img id='local-illustration' src='images/sea.svg' alt='山海插图'/><p>这张插图、字体颜色和版式均来自 EPUB 原书。</p><script>document.documentElement.dataset.bookScriptRan='yes'</script>"+"<p>"+text+"</p>"*1+"".join("<p>"+text+"</p>" for _ in range(20))+"</body></html>")
    archive.writestr("OPS/two.xhtml","<html xmlns='http://www.w3.org/1999/xhtml'><head><title>海边的信</title><link rel='stylesheet' href='style.css'/></head><body><h1 id='letter'>海边的信</h1><p>"+text+"</p></body></html>")
    archive.writestr("OPS/nav.xhtml","<html xmlns='http://www.w3.org/1999/xhtml' xmlns:epub='http://www.idpf.org/2007/ops'><head><title>目录</title></head><body><nav epub:type='toc'><a href='one.xhtml'>春日插图</a><a href='two.xhtml#letter'>海边的信</a></nav></body></html>")

# XHTML without its namespace becomes generic XML in WebKit, with no HTML
# image/dataset APIs. Reject a broken fixture before testing the reader.
with zipfile.ZipFile(local / f"{book_id}.epub") as archive:
    for name in archive.namelist():
        if name.endswith((".xml", ".opf", ".xhtml", ".svg")):
            node = ET.fromstring(archive.read(name))
            if name.endswith(".xhtml"):
                assert node.tag == "{http://www.w3.org/1999/xhtml}html", name
