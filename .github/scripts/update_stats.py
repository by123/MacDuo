#!/usr/bin/env python3
"""Rewrite the usage-stats block in both READMEs from GitHub's own API.

Two tiers of numbers:

  * stars / forks / watchers / release downloads — public, always available.
  * views / unique visitors / clones — GitHub's traffic API, a rolling 14-day
    window that only a token with Administration:read can see. The default
    GITHUB_TOKEN cannot (403), so set a STATS_TOKEN secret to turn these on.

Values are cached as JSON inside the block, so a run without traffic access
keeps the last known traffic figures instead of blanking them. No third-party
tracker is involved.
"""
import datetime as dt
import json
import os
import re
import urllib.error
import urllib.request

REPO = os.environ["REPO"]
TOKEN = os.environ["GH_TOKEN"]
START, END = "<!-- stats:start -->", "<!-- stats:end -->"
DATA_RE = re.compile(r"<!-- stats:data (.*?) -->")
BLOCK_RE = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
DASH = "—"

TEMPLATES = {
    "README.md": {
        "head": "| ⭐ Stars | Forks | Watchers | Downloads | Views (14d) | Visitors (14d) | Clones (14d) |",
        "note_on": "<sub>Refreshed daily by [`stats.yml`](.github/workflows/stats.yml) straight from "
                   "GitHub's API — no third-party tracker. Views, visitors and clones are a rolling "
                   "14-day window, last read {traffic_stamp} UTC.</sub>",
        "note_off": "<sub>Refreshed daily by [`stats.yml`](.github/workflows/stats.yml) straight from "
                    "GitHub's API — no third-party tracker. Views, visitors and clones need a "
                    "`STATS_TOKEN` secret (a fine-grained PAT with Administration: read); "
                    "without it they stay blank.</sub>",
    },
    "README.zh-CN.md": {
        "head": "| ⭐ Star | Fork | Watch | 下载 | 浏览量（14天）| 独立访客（14天）| Clone（14天）|",
        "note_on": "<sub>每天由 [`stats.yml`](.github/workflows/stats.yml) 直接从 GitHub 官方接口拉取，"
                   "不接任何第三方统计。浏览量、访客和 clone 是滚动 14 天窗口，最后读取于 "
                   "{traffic_stamp} UTC。</sub>",
        "note_off": "<sub>每天由 [`stats.yml`](.github/workflows/stats.yml) 直接从 GitHub 官方接口拉取，"
                    "不接任何第三方统计。浏览量、访客和 clone 需要仓库 secret `STATS_TOKEN`"
                    "（细粒度 PAT，勾 Administration: read），没配就一直留空。</sub>",
    },
}
COLS = ["stars", "forks", "watchers", "downloads", "views", "visitors", "clones"]


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
fresh = {
    "stars": info["stargazers_count"],
    "forks": info["forks_count"],
    "watchers": info["subscribers_count"],
    "downloads": sum(a["download_count"] for rel in api("/releases") for a in rel["assets"]),
}

try:
    views, clones = api("/traffic/views"), api("/traffic/clones")
    fresh |= {
        "views": views["count"],
        "visitors": views["uniques"],
        "clones": clones["count"],
        "traffic_stamp": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M"),
    }
except urllib.error.HTTPError as e:
    if e.code != 403:
        raise
    print("traffic API not readable with this token (403) — keeping previous traffic figures")

for path, tpl in TEMPLATES.items():
    with open(path, encoding="utf-8") as f:
        text = f.read()
    block = BLOCK_RE.search(text)
    if not block:
        raise SystemExit(f"{path}: no stats block")
    cached = DATA_RE.search(block.group(0))
    data = (json.loads(cached.group(1)) if cached else {}) | fresh

    row = " | ".join(str(data.get(c, DASH)) for c in COLS)
    note = tpl["note_on"] if data.get("traffic_stamp") else tpl["note_off"]
    new_block = "\n".join([
        START,
        f"<!-- stats:data {json.dumps(data, sort_keys=True)} -->",
        tpl["head"],
        "|" + "---|" * len(COLS),
        f"| {row} |",
        "",
        note.format(**data),
        END,
    ])

    new = BLOCK_RE.sub(lambda _: new_block, text, count=1)
    if new != text:
        with open(path, "w", encoding="utf-8") as f:
            f.write(new)
        print(f"{path}: updated")
    else:
        print(f"{path}: unchanged")
