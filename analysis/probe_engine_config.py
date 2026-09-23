# -*- coding: utf-8 -*-
"""查找 flutter_bootstrap.js 里的引擎配置（canvasKitBaseUrl / engineRevision / renderer）。"""
import io, re, ssl, sys, urllib.request, urllib.error

ROOT = "https://simple.imsummer.cn/web/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE

def get(url):
    req = urllib.request.Request(url)
    req.add_header("User-Agent", UA)
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
st, body = get(ROOT + "flutter_bootstrap.js")
t = body.decode("utf-8", "replace")
out.append(f"=== flutter_bootstrap.js {st}, {len(t)} chars ===")

# 打印 _flutter.loader.load({...}) 段
i = t.find("_flutter.loader.load")
out.append("\n----- loader.load 段 -----")
out.append(t[i:i + 1500] if i >= 0 else "(未找到 loader.load)")

for kw in ["canvasKitBaseUrl", "engineRevision", "renderer", "useLocalCanvasKit",
           "compileTarget", "gstatic", "dart2wasm", "skwasm"]:
    hits = [m.start() for m in re.finditer(re.escape(kw), t)]
    out.append(f"\n[{kw}] {len(hits)} 次")
    for h in hits[:3]:
        out.append("   ..." + t[max(0, h - 120):h + 160].replace("\n", " ") + "...")

with io.open(sys.argv[1], "w", encoding="utf-8") as fp:
    fp.write("\n".join(out))
print("DONE")
