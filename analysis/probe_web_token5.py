# -*- coding: utf-8 -*-
"""确证：Authorization 头的取值字段 + UserInfo 落盘点。"""
import io, re, sys

js = io.open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
out = []

def ctx(pat, before, after, limit=6, title=None):
    out.append(f"\n########## {title or pat} ##########")
    n = 0
    for m in re.finditer(pat, js):
        s0 = max(0, m.start() - before)
        s1 = min(len(js), m.end() + after)
        out.append(f"  [{m.start()}] {js[s0:s1].replace(chr(10),' ')}")
        n += 1
        if n >= limit:
            out.append("  (省略更多)")
            break
    if n == 0:
        out.append("  (无匹配)")

ctx(r'"Authorization"', 420, 420, 6, "Authorization 头构造")
ctx(r'"UserInfo"', 300, 300, 6, "UserInfo 键的读写")
ctx(r'"USER_TOKEN_REFRESH"', 300, 300, 6, "USER_TOKEN_REFRESH 键")
ctx(r'"api/v2/refresh_token"', 600, 700, 3, "refresh_token 调用")
ctx(r'gHV\(\)', 200, 200, 4, "auth_token getter gHV 用处")
ctx(r'gnC\(\)', 200, 200, 4, "token getter gnC 用处")

with io.open(sys.argv[2], "w", encoding="utf-8") as fp:
    fp.write("\n".join(out))
print("DONE")
