#!/usr/bin/env python3
# TimeCalc Star History 生成脚本（自托管，替代第三方 star-history 服务）。
#
# GitHub 已将 stargazers 端点限制为仅仓库管理员/协作者可读，且第三方服务
# 的静态图拿不到令牌后会渲染「GitHub restricted access」提示图。因此改为：
#   - 由 GitHub Actions 用仓库内置 GITHUB_TOKEN（不出仓库）分页拉取 stargazers
#     （Accept: application/vnd.github.star+json，含 starred_at 日期）；
#   - 按天聚合累计 star 数，渲染成一张 SVG 折线图提交到 docs/star-history.svg；
#   - README 直接引用本地图，不依赖任何第三方服务。
#
# 用法（仓库根目录）：
#   GITHUB_REPOSITORY=xiegaoxiao/timecalc GH_TOKEN=<token> python3 tool/star_history.py
# 输出：docs/star-history.svg（可用 STAR_HISTORY_OUT 覆盖）。

import datetime
import json
import os
import sys
import urllib.request

REPO = os.environ.get("GITHUB_REPOSITORY", "").strip()
TOKEN = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
OUT = os.environ.get("STAR_HISTORY_OUT", "docs/star-history.svg")

API = "https://api.github.com"


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


if "/" not in REPO:
    fail("GITHUB_REPOSITORY 环境变量未设置（期望 owner/repo）")
if not TOKEN:
    fail("GH_TOKEN/GITHUB_TOKEN 环境变量未设置")


def fetch_page(url):
    """请求一页 stargazers，返回 (json 数据, 下一页 url 或 None)。"""
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github.star+json",
            "User-Agent": "timecalc-star-history",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            next_url = None
            for part in resp.headers.get("Link", "").split(","):
                if 'rel="next"' in part:
                    s, e = part.find("<"), part.find(">")
                    if s != -1 and e != -1:
                        next_url = part[s + 1 : e]
            return json.loads(body), next_url
    except urllib.error.HTTPError as e:
        # 401/403：令牌无效或无权限（stargazers 仅限仓库管理员/协作者）。
        # 404：令牌未绑定本仓库或仓库不存在。
        fail(
            f"GitHub API {e.code}：{url}\n"
            "  请确认令牌有效、已绑定该仓库（fine-grained 的 Repository access 勾选 timecalc），"
            "且为仓库管理员/协作者。"
        )
    except urllib.error.URLError as e:
        fail(f"网络错误：{e}")


# ---- 分页拉取全部 stargazers ----
stars = []  # [(starred_at: str|None), ...]
url = f"{API}/repos/{REPO}/stargazers?per_page=100&page=1"
page = 0
while url:
    page += 1
    if page > 100:  # 上限 100 页（1 万星），足够且防死循环
        fail("分页超过 100 页上限，已中止")
    data, url = fetch_page(url)
    if not isinstance(data, list):
        fail(f"非预期响应：{str(data)[:200]}")
    stars.extend(item.get("starred_at") for item in data)
    if page == 1:
        print(f"== {REPO} 分页拉取 stargazers ==")

print(f"star 总数：{len(stars)}")

# ---- 按天聚合累计数 ----
# 时间序列：每一天取当日最后的累计值（同一天多颗星只保留末值）。
by_day = {}
count = 0
for iso in stars:
    if not iso:
        continue
    try:
        day = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).date()
    except ValueError:
        continue
    count += 1
    by_day[day] = count

series = sorted(by_day.items())  # [(date, cumulative_count), ...]


def render_svg():
    """渲染折线图 SVG。series 为空时输出占位图。"""
    W, H = 860, 440
    ML, MR, MT, MB = 60, 24, 46, 56
    PW, PH = W - ML - MR, H - MT - MB
    accent = "#2ea44f"  # GitHub 绿，与徽章一致
    grid = "#e5e5e5"
    text_c = "#444444"

    now = datetime.date.today().isoformat()
    title = f"⭐ {REPO} · Star History"
    sub = f"更新于 {now} · 共 {len(stars)} 颗星"

    if not series:
        # 无数据占位图
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
            f'viewBox="0 0 {W} {H}" role="img" aria-label="{title}（暂无数据）">\n'
            f'  <rect width="{W}" height="{H}" fill="#ffffff"/>\n'
            f'  <text x="{W/2}" y="36" font-family="Segoe UI, Arial, sans-serif" font-size="20" '
            f'font-weight="600" fill="{text_c}" text-anchor="middle">{title}</text>\n'
            f'  <text x="{W/2}" y="210" font-family="Segoe UI, Arial, sans-serif" font-size="16" '
            f'fill="#888888" text-anchor="middle">暂无星标数据</text>\n'
            f'</svg>\n'
        )

    xs = [d for d, _ in series]
    ymax = max(c for _, c in series)
    xmin, xmax = xs[0], xs[-1]
    if xmin == xmax:  # 单点：给横轴留出跨度
        xmax = xmin + datetime.timedelta(days=1)

    def px(d):
        return ML + (d - xmin) / (xmax - xmin) * PW

    def py(c):
        return MT + (1 - c / ymax) * PH

    # Y 轴刻度（4 段整数步长）
    step = max(1, -(-ymax // 4))  # 向上取整
    yticks = [i * step for i in range((ymax // step) + 1)]

    # X 轴刻度（5 个均匀日期，含首末；跨度不足 4 天时只显示首末两个）
    xrange_days = (xmax - xmin).days
    if xrange_days >= 4:
        xmarks = [xmin + datetime.timedelta(days=int(round(xrange_days * i / 4))) for i in range(5)]
    else:
        xmarks = [xmin, xmax]

    def fmt_date(d):
        if d.year == xmin.year:
            return d.strftime("%m-%d")
        return d.strftime("%Y-%m")

    lines = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'viewBox="0 0 {W} {H}" role="img" aria-label="{title}">']
    lines.append(f'  <rect width="{W}" height="{H}" fill="#ffffff"/>')
    # 标题
    lines.append(f'  <text x="{ML}" y="30" font-family="Segoe UI, Arial, sans-serif" '
                 f'font-size="19" font-weight="600" fill="{text_c}">{title}</text>')
    lines.append(f'  <text x="{ML}" y="48" font-family="Segoe UI, Arial, sans-serif" '
                 f'font-size="12" fill="#888888">{sub}</text>')

    # 网格 + Y 刻度
    for c in yticks:
        y = py(c)
        lines.append(f'  <line x1="{ML}" y1="{y:.1f}" x2="{ML + PW}" y2="{y:.1f}" '
                     f'stroke="{grid}" stroke-width="1"/>')
        lines.append(f'  <text x="{ML - 8}" y="{y + 4:.1f}" font-family="Segoe UI, Arial, sans-serif" '
                     f'font-size="12" fill="#888888" text-anchor="end">{c}</text>')

    # X 轴刻度
    for d in xmarks:
        x = px(d)
        lines.append(f'  <line x1="{x:.1f}" y1="{MT + PH}" x2="{x:.1f}" y2="{MT + PH + 5}" '
                     f'stroke="#bbbbbb" stroke-width="1"/>')
        lines.append(f'  <text x="{x:.1f}" y="{MT + PH + 20}" font-family="Segoe UI, Arial, sans-serif" '
                     f'font-size="12" fill="#888888" text-anchor="middle">{fmt_date(d)}</text>')

    # 面积填充（透明绿色）
    pts = [f"{px(d):.1f},{py(c):.1f}" for d, c in series]
    area = [f"{px(series[0][0]):.1f},{MT + PH}"] + pts + [f"{px(series[-1][0]):.1f},{MT + PH}"]
    lines.append(f'  <polygon points="{" ".join(area)}" fill="{accent}" fill-opacity="0.08"/>')

    # 折线
    lines.append(f'  <polyline points="{" ".join(pts)}" fill="none" stroke="{accent}" '
                 f'stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>')

    # 末点高亮 + 数值
    last_d, last_c = series[-1]
    lx, ly = px(last_d), py(last_c)
    lines.append(f'  <circle cx="{lx:.1f}" cy="{ly:.1f}" r="5" fill="{accent}" '
                 f'stroke="#ffffff" stroke-width="2"/>')
    label_y = ly - 14 if ly - 14 > MT + 12 else ly + 22
    lines.append(f'  <text x="{lx:.1f}" y="{label_y:.1f}" font-family="Segoe UI, Arial, sans-serif" '
                 f'font-size="13" font-weight="600" fill="{accent}" text-anchor="middle">'
                 f'{last_c} ⭐</text>')

    lines.append("</svg>\n")
    return "\n".join(lines)


svg = render_svg()
os.makedirs(os.path.dirname(OUT) or ".", exist_ok=True)
with open(OUT, "w", encoding="utf-8") as f:
    f.write(svg)

if series:
    print(f"已生成 {OUT}（{len(stars)} 颗星，{len(series)} 个数据点，峰值 {max(c for _, c in series)}）")
else:
    print(f"已生成占位图 {OUT}（暂无星标数据）")
