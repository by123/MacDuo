#!/usr/bin/env python3
"""Rewrite the usage-stats block in both READMEs from GitHub's own traffic API.

Traffic numbers (views / clones) are a rolling 14-day window and are only readable
with push access, which is why this runs in Actions instead of being a badge.
No third-party tracker is involved.
"""
import datetime as dt
import json
import os
import re
import urllib.request

REPO = os.environ["REPO"]
TOKEN = os.environ["GH_TOKEN"]
FILES = {
    "README.md": (
        "| Stars | Forks | Views (14d) | Unique visitors (14d) | Clones (14d) | Unique cloners (14d) |\n"
        "|---|---|---|---|---|---|\n"
        "| {stars} | {forks} | {views} | {view_uniques} | {clones} | {clone_uniques} |\n"
        "\n"
        "<sub>Updated daily from GitHub's traffic API by "
        "[`stats.yml`](.github/workflows/stats.yml) — no third-party tracker. "
        "Views and clones are a rolling 14-day window; last run {stamp} UTC.</sub>\n"
    ),
    "README.zh-CN.md": (
        "| Star | Fork | 浏览量（14天）| 独立访客（14天）| Clone（14天）| 独立 Clone（14天）|\n"
        "|---|---|---|---|---|---|\n"
        "| {stars} | {forks} | {views} | {view_uniques} | {clones} | {clone_uniques} |\n"
        "\n"
        "<sub>每天由 [`stats.yml`](.github/workflows/stats.yml) 从 GitHub 官方流量接口拉取，"
        "不接任何第三方统计。浏览量和 clone 是滚动 14 天窗口；最后更新 {stamp} UTC。</sub>\n"
    ),
}
START, END = "<!-- stats:start -->", "<!-- stats:end -->"


def api(path):
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}{path}",
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "User-Agent": "macduo-stats",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


info = api("")
views = api("/traffic/views")
clones = api("/traffic/clones")
values = {
    "stars": info["stargazers_count"],
    "forks": info["forks_count"],
    "views": views["count"],
    "view_uniques": views["uniques"],
    "clones": clones["count"],
    "clone_uniques": clones["uniques"],
    "stamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M"),
}

for path, template in FILES.items():
    with open(path, encoding="utf-8") as f:
        text = f.read()
    block = f"{START}\n{template.format(**values)}{END}"
    new, n = re.subn(
        re.escape(START) + r".*?" + re.escape(END), lambda _: block, text, flags=re.S
    )
    if n != 1:
        raise SystemExit(f"{path}: expected exactly one stats block, found {n}")
    if new != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"{path}: updated")
    else:
        print(f"{path}: unchanged")
