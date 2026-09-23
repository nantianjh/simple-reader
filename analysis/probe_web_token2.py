# -*- coding: utf-8 -*-
"""继续探查：Flutter Web 前端的 localStorage / token 存储实现。"""
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
        with op.open(req, timeout=40) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return None, str(e).encode()

out = []

st, js = get(ROOT + "flutter_bootstrap.js")
out.append(f"=== flutter_bootstrap.js -> {st}, {len(js)} bytes ===")
if st == 200:
    t = js.decode("utf-8", "replace")
    out.append(t[:4000])
    # 找入口 bundle 名
    cands = set(re.findall(r'["\']([A-Za-z0-9_./-]*\.js)["\']', t))
    out.append("\n候选入口：")
    for c in sorted(cands):
        out.append("  " + c)

with io.open(sys.argv[1], "w", encoding="utf-8") as fp:
    fp.write("\n".join(out))
print("DONE")
