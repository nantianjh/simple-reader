# -*- coding: utf-8 -*-
"""从已下载的 main.dart.js 中提取：所有含 token/auth 的字符串常量 + shared_preferences 前缀 + 登录流程线索。"""
import io, re, sys

js = io.open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
out = []

# 1) 含 token 的字符串常量
cands = {}
for m in re.finditer(r'"([^"\\\n]{0,70}token[^"\\\n]{0,70})"', js, re.I):
    cands.setdefault(m.group(1), []).append(m.start())
out.append("=== 含 token 的字符串常量（去重，带出现次数） ===")
for k, v in sorted(cands.items(), key=lambda kv: -len(kv[1])):
    out.append(f"  {len(v):3d}x  {k!r}")
    for pos in v[:3]:
        s0 = max(0, pos - 90)
        s1 = min(len(js), pos + 130)
        out.append(f"        ...{js[s0:s1].replace(chr(10),' ')}...")

# 2) 含 auth 的字符串常量
out.append("\n=== 含 auth 的字符串常量 ===")
cands2 = {}
for m in re.finditer(r'"([^"\\\n]{0,70}auth[^"\\\n]{0,70})"', js, re.I):
    cands2.setdefault(m.group(1), []).append(m.start())
for k, v in sorted(cands2.items(), key=lambda kv: -len(kv[1])):
    out.append(f"  {len(v):3d}x  {k!r}")

# 3) shared_preferences 的 Web 前缀
out.append("\n=== flutter. 前缀 / prefs 相关 ===")
for kw in ['"flutter."', "flutter.", "SharedPreferences", "getString", "containsKey"]:
    n = len(re.findall(re.escape(kw), js))
    out.append(f"  {kw!r}: {n} 次")
for m in list(re.finditer(re.escape('"flutter."'), js))[:5]:
    s0 = max(0, m.start() - 150)
    s1 = min(len(js), m.start() + 200)
    out.append(f"    ...{js[s0:s1].replace(chr(10),' ')}...")

# 4) 登录接口周边：auths 前后各 1200 字符
out.append("\n=== api/v2/auths 调用点上下文 ===")
for m in list(re.finditer(r'"api/v2/auths"', js))[:3]:
    s0 = max(0, m.start() - 1200)
    s1 = min(len(js), m.end() + 900)
    out.append(js[s0:s1])
    out.append("\n-----")

# 5) phone_messages（短信验证码）周边，确认登录方式
out.append("\n=== phone_messages 上下文（确认登录方式） ===")
for m in list(re.finditer(r'"api/v2/phone_messages[^"]*"', js))[:6]:
    out.append(f"  命中：{m.group(0)!r}")

with io.open(sys.argv[2], "w", encoding="utf-8") as fp:
    fp.write("\n".join(out))
print("DONE")
