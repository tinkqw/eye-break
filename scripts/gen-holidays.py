#!/usr/bin/env python3
"""从 holiday-cn（MIT，github.com/NateScarlet/holiday-cn）拉法定节假日与调休，生成 HolidayData.swift。

国务院一般每年 11 月发布下一年安排，holiday-cn 随后更新；发布后重跑本脚本、重新构建即可：
    python3 scripts/gen-holidays.py 2025 2026 2027
某年数据为空（还没发布）时跳过该年，不写空表。
"""
import json, sys, urllib.request
from pathlib import Path

years = [int(y) for y in sys.argv[1:]] or [2025, 2026]
rows = []
for y in years:
    url = f"https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{y}.json"
    days = json.load(urllib.request.urlopen(url, timeout=20))["days"]
    if not days:
        print(f"{y}: 尚未发布，跳过")
        continue
    rows += days
    print(f"{y}: {len(days)} 天")

out = Path(__file__).resolve().parent.parent / "Sources/EyeBreak/HolidayData.swift"
lines = [
    "// 由 scripts/gen-holidays.py 生成，勿手改。数据源 holiday-cn（MIT），覆盖年份："
    + ", ".join(str(y) for y in sorted({int(r['date'][:4]) for r in rows})),
    "",
    "enum HolidayData {",
    "    /// \"yyyy-MM-dd\" → (节日名, 是否放假)。isOffDay=false 即调休上班",
    "    static let days: [String: (name: String, isOffDay: Bool)] = [",
]
for r in sorted(rows, key=lambda r: r["date"]):
    lines.append(f'        "{r["date"]}": ("{r["name"]}", {"true" if r["isOffDay"] else "false"}),')
lines += ["    ]", "}", ""]
out.write_text("\n".join(lines), encoding="utf-8")
print("写出", out)
