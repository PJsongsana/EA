"""Phase 2: edge report for EdgeTester CSV logs.

Reads the per-trade CSVs EdgeTester writes to Terminal/Common/Files and
compares the real signal against the random baselines (one CSV per seed).

    python analysis/edge_report.py
    python analysis/edge_report.py --exit EXIT_FIXED_BARS --min-trades 50

Stdlib only. Prints a text summary and writes a self-contained HTML report
(cumulative R curve + baseline histograms) to analysis/out/edge_report.html.
"""

import argparse
import csv
import glob
import math
import os
import re
import statistics
from datetime import datetime

MODES = ("SIGNAL_REAL", "SIGNAL_RANDOM_DIRECTION", "SIGNAL_RANDOM_TIME")
DEFAULT_DIR = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal", "Common", "Files")


# ---------------------------------------------------------------- loading
def load_trades(path):
    with open(path, newline="", encoding="latin-1") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["dir"] = int(r["dir"])
        r["result_r"] = float(r["result_r"])
        r["mfe_atr"] = float(r["mfe_atr"])
        r["mae_atr"] = float(r["mae_atr"])
        r["entry_dt"] = datetime.strptime(r["entry_time"], "%Y.%m.%d %H:%M")
    return rows


def find_runs(folder, prefix, symbol, exit_mode):
    """{mode: {seed: path}}"""
    pat = re.compile(rf"^{re.escape(prefix)}_{re.escape(symbol)}_(SIGNAL_\w+?)_{exit_mode}_seed(\d+)\.csv$")
    runs = {m: {} for m in MODES}
    for path in glob.glob(os.path.join(folder, f"{prefix}_{symbol}_*.csv")):
        m = pat.match(os.path.basename(path))
        if m and m.group(1) in runs:
            runs[m.group(1)][int(m.group(2))] = path
    return runs


# ---------------------------------------------------------------- stats
def binom_two_sided(k, n, p=0.5):
    """Exact two-sided binomial test p-value."""
    probs = [math.comb(n, i) * p**i * (1 - p) ** (n - i) for i in range(n + 1)]
    obs = probs[k]
    return min(1.0, sum(q for q in probs if q <= obs * (1 + 1e-9)))


def normal_two_sided(z):
    return math.erfc(abs(z) / math.sqrt(2))


def stats(trades):
    n = len(trades)
    if n == 0:
        return {"n": 0}
    r = [t["result_r"] for t in trades]
    wins = sum(1 for x in r if x > 0)
    avg = statistics.fmean(r)
    sd = statistics.stdev(r) if n > 1 else 0.0
    t = avg / (sd / math.sqrt(n)) if sd > 0 else 0.0
    return {
        "n": n,
        "wins": wins,
        "win": wins / n,
        "p_win": binom_two_sided(wins, n),
        "avg_r": avg,
        "sd_r": sd,
        "t": t,
        "p_t": normal_two_sided(t),  # normal approx, fine for n >= 30
        "mfe": statistics.fmean(x["mfe_atr"] for x in trades),
        "mae": statistics.fmean(x["mae_atr"] for x in trades),
    }


def fmt(s):
    if s["n"] == 0:
        return "n=0"
    return (f"n={s['n']:4d}  win={s['win']*100:5.1f}% (p={s['p_win']:.3f})  "
            f"avgR={s['avg_r']:+.3f}  sdR={s['sd_r']:.3f}  t={s['t']:+.2f} (p={s['p_t']:.3f})  "
            f"MFE={s['mfe']:.2f}  MAE={s['mae']:.2f} ATR")


def span(trades):
    return (trades[0]["entry_dt"], trades[-1]["entry_dt"]) if trades else (None, None)


# ---------------------------------------------------------------- html
def svg_line(series, w=760, h=260, pad=36):
    """series: list of (label, color, [y...]) plotted against trade index."""
    allv = [v for _, _, ys in series for v in ys] + [0]
    lo, hi = min(allv), max(allv)
    if hi == lo:
        hi = lo + 1
    n = max(len(ys) for _, _, ys in series)
    sx = lambda i: pad + i * (w - 2 * pad) / max(n - 1, 1)
    sy = lambda v: h - pad - (v - lo) * (h - 2 * pad) / (hi - lo)
    out = [f'<svg viewBox="0 0 {w} {h}" role="img">',
           f'<line x1="{pad}" x2="{w-pad}" y1="{sy(0):.1f}" y2="{sy(0):.1f}" class="axis"/>',
           f'<text x="4" y="{sy(hi)+4:.1f}" class="lbl">{hi:+.1f}R</text>',
           f'<text x="4" y="{sy(lo)+4:.1f}" class="lbl">{lo:+.1f}R</text>']
    for i, (label, color, ys) in enumerate(series):
        pts = " ".join(f"{sx(j):.1f},{sy(v):.1f}" for j, v in enumerate(ys))
        out.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2"/>')
        out.append(f'<text x="{pad+10+i*130}" y="16" class="lbl" fill="{color}">■ {label}</text>')
    out.append("</svg>")
    return "".join(out)


def svg_hist(values, marker, bins=25, w=760, h=240, pad=36):
    lo, hi = min(values + [marker]), max(values + [marker])
    if hi == lo:
        hi = lo + 1e-6
    step = (hi - lo) / bins
    counts = [0] * bins
    for v in values:
        counts[min(int((v - lo) / step), bins - 1)] += 1
    top = max(counts) or 1
    bw = (w - 2 * pad) / bins
    sx = lambda v: pad + (v - lo) / (hi - lo) * (w - 2 * pad)
    out = [f'<svg viewBox="0 0 {w} {h}" role="img">']
    for i, c in enumerate(counts):
        bh = c / top * (h - 2 * pad)
        out.append(f'<rect x="{pad+i*bw+1:.1f}" y="{h-pad-bh:.1f}" width="{bw-2:.1f}" height="{bh:.1f}" class="bar"/>')
    mx = sx(marker)
    out += [f'<line x1="{mx:.1f}" x2="{mx:.1f}" y1="{pad-10}" y2="{h-pad}" class="mark"/>',
            f'<text x="{mx+4:.1f}" y="{pad-2}" class="lbl mk">REAL {marker:+.3f}</text>',
            f'<text x="{pad}" y="{h-12}" class="lbl">{lo:+.3f}</text>',
            f'<text x="{w-pad-40}" y="{h-12}" class="lbl">{hi:+.3f}</text>',
            "</svg>"]
    return "".join(out)


def cumulative(rs):
    out, acc = [], 0.0
    for x in rs:
        acc += x
        out.append(acc)
    return out


def write_html(path, title, real, real_stats, baselines, text):
    real_sorted = sorted(real, key=lambda t: t["entry_dt"])
    parts = [f"<h1>{title}</h1>"]
    if real_sorted:
        parts.append("<h2>Cumulative R — real signal</h2>")
        parts.append(svg_line([
            ("all", "#3b82f6", cumulative([t["result_r"] for t in real_sorted])),
            ("buy", "#16a34a", cumulative([t["result_r"] for t in real_sorted if t["dir"] > 0])),
            ("sell", "#dc2626", cumulative([t["result_r"] for t in real_sorted if t["dir"] < 0])),
        ]))
    for mode, vals in baselines.items():
        if vals and real_stats["n"]:
            parts.append(f"<h2>{mode}: avgR of {len(vals)} seeds vs real</h2>")
            parts.append(svg_hist(vals, real_stats["avg_r"]))
    parts.append(f"<pre>{text}</pre>")
    html = f"""<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Edge Report</title>
<style>
:root{{--bg:#fff;--fg:#1f2937;--mut:#6b7280;--bar:#94a3b8;--mk:#dc2626}}
@media (prefers-color-scheme:dark){{:root{{--bg:#111827;--fg:#e5e7eb;--mut:#9ca3af;--bar:#475569;--mk:#f87171}}}}
body{{background:var(--bg);color:var(--fg);font:14px system-ui,sans-serif;max-width:800px;margin:auto;padding:16px}}
svg{{width:100%;height:auto}} .axis{{stroke:var(--mut);stroke-dasharray:4}} .lbl{{fill:var(--mut);font-size:11px}}
.bar{{fill:var(--bar)}} .mark{{stroke:var(--mk);stroke-width:2}} .mk{{fill:var(--mk)}}
pre{{white-space:pre-wrap;font-size:12px}}
</style></head><body>{''.join(parts)}</body></html>"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(html)


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", default=DEFAULT_DIR, help="folder with EdgeTester CSVs (default: Terminal/Common/Files)")
    ap.add_argument("--prefix", default="EdgeTester")
    ap.add_argument("--symbol", default="XAUUSD")
    ap.add_argument("--exit", default="EXIT_ATR_SYMMETRIC", choices=["EXIT_ATR_SYMMETRIC", "EXIT_FIXED_BARS"])
    ap.add_argument("--min-trades", type=int, default=30, help="drop random seeds with fewer trades")
    ap.add_argument("--html", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "edge_report.html"))
    a = ap.parse_args()

    runs = find_runs(a.dir, a.prefix, a.symbol, a.exit)
    lines = [f"folder: {a.dir}", f"{a.symbol} | {a.exit}", ""]

    real = []
    if runs["SIGNAL_REAL"]:
        seed = min(runs["SIGNAL_REAL"])
        real = load_trades(runs["SIGNAL_REAL"][seed])
    real_stats = stats(real)
    real_span = span(sorted(real, key=lambda t: t["entry_dt"]))

    lines.append("REAL SIGNAL")
    if real:
        lines.append(f"  period  {real_span[0]:%Y-%m-%d} → {real_span[1]:%Y-%m-%d}")
        lines.append(f"  all     {fmt(real_stats)}")
        lines.append(f"  buy     {fmt(stats([t for t in real if t['dir'] > 0]))}")
        lines.append(f"  sell    {fmt(stats([t for t in real if t['dir'] < 0]))}")
        by_year = {}
        for t in real:
            by_year.setdefault(t["entry_dt"].year, []).append(t)
        for y in sorted(by_year):
            lines.append(f"  {y}    {fmt(stats(by_year[y]))}")
    else:
        lines.append("  no CSV found — run SIGNAL_REAL first")

    baselines = {}
    for mode in MODES[1:]:
        files = runs[mode]
        lines += ["", f"BASELINE {mode}"]
        if not files:
            lines.append("  no CSVs found")
            continue
        avgs, dropped, mismatched = [], 0, 0
        for seed in sorted(files):
            tr = load_trades(files[seed])
            if len(tr) < a.min_trades:
                dropped += 1
                continue
            sp = span(sorted(tr, key=lambda t: t["entry_dt"]))
            # CSV names carry no dates: catch leftovers from runs over another period
            if real and (abs((sp[0] - real_span[0]).days) > 31 or abs((sp[1] - real_span[1]).days) > 31):
                mismatched += 1
            avgs.append(stats(tr)["avg_r"])
        baselines[mode] = avgs
        lines.append(f"  seeds used {len(avgs)}  (dropped {dropped} with < {a.min_trades} trades)")
        if mismatched:
            lines.append(f"  WARNING: {mismatched} seed files cover a different period than the real run")
        if avgs:
            q = statistics.quantiles(avgs, n=20) if len(avgs) >= 20 else None
            lines.append(f"  avgR mean={statistics.fmean(avgs):+.3f}  sd={statistics.pstdev(avgs):.3f}"
                         + (f"  p5={q[0]:+.3f}  p95={q[-1]:+.3f}" if q else ""))
            if real:
                ra = real_stats["avg_r"]
                pct = sum(1 for v in avgs if v < ra) / len(avgs) * 100
                p_emp = (sum(1 for v in avgs if v >= ra) + 1) / (len(avgs) + 1)
                verdict = "PASS (> p95)" if pct >= 95 else "not distinguishable from random"
                lines.append(f"  REAL avgR {ra:+.3f} is at percentile {pct:.1f}  (empirical p={p_emp:.3f}) → {verdict}")

    text = "\n".join(lines)
    print(text)
    write_html(a.html, f"Edge report — {a.symbol} {a.exit}", real, real_stats, baselines, text)
    print(f"\nHTML: {a.html}")


if __name__ == "__main__":
    main()
