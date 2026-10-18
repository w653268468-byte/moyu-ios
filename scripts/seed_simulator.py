"""CI-only UI data; never bundled in the app."""
from pathlib import Path
import json
import sys

container = Path(sys.argv[1])
directory = container / "Documents/MoyuOnline"
directory.mkdir(parents=True, exist_ok=True)
source = json.loads(Path("Examples/booksource.example.json").read_text(encoding="utf-8"))
source["bookSourceName"] = "示例书源 · CSS"
source["bookSourceGroup"] = "界面测试示例"
second = dict(source, bookSourceName="示例书源 · 待适配脚本", bookSourceUrl="https://script.example.invalid", ruleContent={"content": "@js:result"})
(directory / "index.json").write_text(json.dumps(dict(sources=[source, second], novels=[]), ensure_ascii=False), encoding="utf-8")
