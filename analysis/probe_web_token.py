# -*- coding: utf-8 -*-
"""只读静态探查：simple.imsummer.cn 网页端把 JWT 存在哪里。

约束：只 GET 首页与前端 JS 静态资源，绝不请求任何登录/鉴权接口。
输出：HTML 中的 script 列表 + 各 JS 里 token 存储相关的代码片段。
"""
import io, json, re, ssl, sys, urllib.request, urllib.error
from html.parser import HTMLParser

BASE = "https://simple.imsummer.cn/web"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

# 直连，不用代理（本机代理会把不通的端口变成 502，干扰判断）
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
opener.addheaders = [
    ("User-Agent", UA),
    ("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
    ("Accept-Language", "zh-CN,zh;q=0.9"),
]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

out = []

def get(url):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "*/*")
    req.add_header("Accept-Language", "zh-CN,zh;q=0.9")
    handlers = [urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=ctx)]
    op = urllib.request.build_opener(*handlers)
    try:
        with op.open(req, timeout=25) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except Exception as e:
        return None, str(e).encode(), {}

class ScriptCollector(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scripts = []
        self.inline = []
        self._cur = None
    def handle_starttag(self, tag, attrs):
        if tag == "script":
            d = dict(attrs)
            if d.get("src"):
                self.scripts.append(d["src"])
            else:
                self._cur = []
    def handle_endtag(self, tag):
        if tag == "script" and self._cur is not None:
            self.inline.append("".join(self._cur))
            self._cur = None
    def handle_data(self, data):
        if self._cur is not None:
            self._cur.append(data)

status, body, headers = get(BASE)
out.append(f"GET {BASE} -> {status}, {len(body)} bytes, ct={headers.get('Content-Type')}")
if status == 200:
    text = body.decode("utf-8", "replace")
    p = ScriptCollector()
    p.feed(text)
    out.append(f"scripts: {len(p.scripts)}, inline blocks: {len(p.inline)}")
    for s in p.scripts:
        out.append(f"  SRC {s}")
    # 首页内联脚本里的线索
    for i, blk in enumerate(p.inline):
        for kw in ("localStorage", "sessionStorage", "token"):
            if kw in blk:
                for m in re.finditer(r".{80}" + kw + r".{120}", blk):
                    out.append(f"  [inline #{i}] ...{m.group(0)}...")
    # 收集 script 里的绝对地址
    urls = []
    for s in p.scripts:
        if s.startswith("http"):
            urls.append(s)
        elif s.startswith("/"):
            urls.append("https://simple.imsummer.cn" + s)
        else:
            urls.append("https://simple.imsummer.cn/web/" + s)
    # 逐个下载 JS，搜 token 存储相关代码
    for u in urls[:8]:
        st, js, hd = get(u)
        out.append(f"\n--- JS {u} -> {st}, {len(js)} bytes ---")
        if st != 200:
            continue
        js_text = js.decode("utf-8", "replace")
        hits = 0
        for kw in ("localStorage.setItem", "localStorage.getItem",
                   "sessionStorage.setItem", '"token"', "'token'",
                   "Authorization", "setToken", "getToken", "saveToken"):
            for m in re.finditer(re.escape(kw), js_text):
                s0 = max(0, m.start() - 110)
                s1 = min(len(js_text), m.end() + 150)
                out.append(f"  [{kw}] ...{js_text[s0:s1]}...")
                hits += 1
                if hits > 14:
                    break
            if hits > 14:
                break
        if hits == 0:
            out.append("  (无匹配)")
else:
    out.append(body[:500].decode("utf-8", "replace"))

with io.open(sys.argv[1], "w", encoding="utf-8") as fp:
    fp.write("\n".join(out))
print("DONE")
