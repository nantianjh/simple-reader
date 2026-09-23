# -*- coding: utf-8 -*-
"""Analyze APK size composition: top entries, grouped by directory/ABI/component."""
import zipfile, sys, io, json, os
from collections import defaultdict

def human(n):
    for u in ["B", "KB", "MB", "GB"]:
        if n < 1024 or u == "GB":
            return f"{n:.2f} {u}" if u != "B" else f"{int(n)} B"
        n /= 1024.0

def analyze(apk_path, out_path):
    zf = zipfile.ZipFile(apk_path)
    entries = []
    for info in zf.infolist():
        entries.append((info.filename, info.file_size, info.compress_size))

    total_unc = sum(e[1] for e in entries)
    total_cmp = sum(e[2] for e in entries)

    # group by top dir / component
    groups = defaultdict(lambda: [0, 0])  # compressed sum, uncompressed sum
    def group_of(name):
        if name.startswith("lib/"):
            parts = name.split("/")
            if len(parts) >= 3:
                return f"lib/{parts[1]} (ABI)"
            return "lib/"
        top = name.split("/")[0]
        if top in ("res", "assets", "META-INF", "lib"):
            return top + "/"
        if name == "AndroidManifest.xml":
            return "AndroidManifest.xml"
        if name.startswith("classes"):
            return "classes*.dex (code)"
        if name.startswith("resources.arsc"):
            return "resources.arsc"
        return "other"
    for name, unc, cmp_ in entries:
        g = group_of(name)
        groups[g][0] += cmp_
        groups[g][1] += unc

    # ABI aggregated: libflutter.so, libapp.so sizes per ABI
    abi_detail = defaultdict(lambda: defaultdict(int))
    for name, unc, cmp_ in entries:
        if name.startswith("lib/") and name.endswith(".so"):
            parts = name.split("/")
            abi_detail[parts[1]][parts[2]] += cmp_

    # top 40 entries by compressed size
    top = sorted(entries, key=lambda e: -e[2])[:40]

    lines = []
    lines.append(f"APK: {apk_path}")
    lines.append(f"File size on disk: {human(os.path.getsize(apk_path))}")
    lines.append(f"Entries: {len(entries)}, uncompressed total: {human(total_unc)}, compressed total (zip payload): {human(total_cmp)}")
    lines.append("")
    lines.append("== Group summary (compressed / uncompressed) ==")
    for g, (cmp_, unc) in sorted(groups.items(), key=lambda kv: -kv[1][0]):
        lines.append(f"  {g:28s} {human(cmp_):>12s} / {human(unc):>12s}")
    lines.append("")
    lines.append("== ABI detail (compressed .so sizes) ==")
    for abi, files in sorted(abi_detail.items()):
        lines.append(f"  [{abi}]")
        for f, s in sorted(files.items(), key=lambda kv: -kv[1]):
            lines.append(f"      {f:40s} {human(s):>12s}")
    lines.append("")
    lines.append("== Top 40 entries by compressed size ==")
    for name, unc, cmp_ in top:
        lines.append(f"  {human(cmp_):>12s} (unc {human(unc):>12s})  {name}")

    with io.open(out_path, "w", encoding="utf-8") as fp:
        fp.write("\n".join(lines))
    print("OK", len(entries))

if __name__ == "__main__":
    analyze(sys.argv[1], sys.argv[2])
