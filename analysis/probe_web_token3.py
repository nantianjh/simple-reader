# -*- coding: utf-8 -*-
"""在 main.dart.js 中定位 token 的存储实现。"""
import io, re, ssl, sys, urllib.request, urllib.error

ROOT = "https://simple.imsummer.cn/web/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def get(url):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", UA)
    req.add_header("Accept", "*/*")
    req.add_header("Referer", ROOT)
    op = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                     urllib.request.HTTPSHandler(context=ctx))
    try:
        with op.open(req, timeout=90) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return None, str(e).encode()

out = []
st, body = get(ROOT + "main.dart.js")
out.append(f"=== main.dart.js -> {st}, {len(body)} bytes ===")
if st == 200:
    js = body.decode("utf-8", "replace")
    io.open(sys.argv[2], "w", encoding="utf-8").write(js)  # 原文留档，供后续精查

    def scan(kw, before=120, after=200, limit=8):
        out.append(f"\n########## {kw} ##########")
        n = 0
        for m in re.finditer(re.escape(kw), js):
            s0 = max(0, m.start() - before)
            s1 = min(len(js), m.end() + after)
            seg = js[s0:s1].replace("\n", " ")
            out.append(f"  [{m.start()}] ...{seg}...")
            n += 1
            if n >= limit:
                out.append("  (更多匹配已省略)")
                break
        if n == 0:
            out.append("  (无匹配)")

    scan("localStorage")
    scan("flutter.")
    scan("auth_token")
    scan('"auths')
    scan("auths")
    scan("setItem")
else:
    out.append(body[:400].decode("utf-8", "replace"))

with io.open(sys.argv[1], "w", encoding="utf-8") as fp:
    fp.write("\n".join(out))
print("DONE")
