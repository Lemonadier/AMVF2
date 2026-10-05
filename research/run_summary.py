"""Final tables for docs/RESEARCH.md (all costs on: spread, stop slippage, swap)."""
import numpy as np
import pandas as pd

import xau_lib as X

ERAS = [("2011-2018", "/tmp/claude-0/data/hd_old", "2011-01-01", None),
        ("2019-2026", "/tmp/claude-0/data/hd", "2019-01-01", None)]
TRAIL = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)
EXITS = {
    "Fixed take-profit 2R": (dict(be_r=0, trail_atr=0, partial_frac=0, max_bars_m15=0), 2.0),
    "Fixed take-profit 3R": (dict(be_r=0, trail_atr=0, partial_frac=0, max_bars_m15=0), 3.0),
    "Break-even at 1R + trail (from 1.5R, 2.5xATR)": (dict(be_r=1.0, be_lock_r=0.1, trail_start_r=1.5, trail_atr=2.5, partial_frac=0, max_bars_m15=0), 0.0),
    "50% partial close at 1R + TP 3R": (dict(be_r=0, trail_atr=0, partial_r=1.0, partial_frac=0.5, max_bars_m15=0), 3.0),
    "Trailing only, from 1.0R, 2xATR": (dict(be_r=0, trail_start_r=1.0, trail_atr=2.0, partial_frac=0, max_bars_m15=0), 0.0),
    "Trailing only, from 1.5R, 3xATR (DEFAULT)": (TRAIL, 0.0),
    "Trailing only, from 2.0R, 3xATR": (dict(be_r=0, trail_start_r=2.0, trail_atr=3.0, partial_frac=0, max_bars_m15=0), 0.0),
}


def fmt(g):
    s = X.stats(g)
    return f"{s['avgR']:+.3f} ({s['n']})" if s["n"] else "-"


ctx = {}
for name, folder, start, _ in ERAS:
    m1 = X.load_all(folder, None, start=start)
    for tf in ("15min", "1h"):
        b = X.build_context(m1, tf)
        ctx[(name, tf)] = (b, X.prepare_m1(m1, b))

print("## Timeframe test (fixed TP 2R, no daily filter, every signal; avg R per trade (trades))\n")
print("| Era | TF | TPB | MOM | LBO | LSR | MR |\n|---|---|---|---|---|---|---|")
for name, *_ in ERAS:
    for tf in ("15min", "1h"):
        b, M = ctx[(name, tf)]
        sig = X.gen_signals(b, dict(tpb_tp_r=2, mom_tp_r=2, lbo_tp_r=2, lsr_tp_r=2))
        tr, _ = X.simulate(M, sig, EXITS["Fixed take-profit 2R"][0])
        print(f"| {name} | {tf} | " + " | ".join(fmt(tr[tr.strat == s]) for s in ["TPB", "MOM", "LBO", "LSR", "MR"]) + " |", flush=True)

print("\n## Exit test on H1 (no daily filter)\n")
print("| Exit | TPB 2011-18 | TPB 2019-26 | MOM 2011-18 | MOM 2019-26 |\n|---|---|---|---|---|")
for ename, (mg, tpr) in EXITS.items():
    cells = {}
    for name, *_ in ERAS:
        b, M = ctx[(name, "1h")]
        sig = X.gen_signals(b, dict(tpb_tp_r=tpr, mom_tp_r=tpr))
        sig = sig[sig.strat.isin(["TPB", "MOM"])]
        tr, _ = X.simulate(M, sig, mg)
        cells[name] = tr
    print(f"| {ename} | {fmt(cells['2011-2018'][cells['2011-2018'].strat == 'TPB'])} | {fmt(cells['2019-2026'][cells['2019-2026'].strat == 'TPB'])} | "
          f"{fmt(cells['2011-2018'][cells['2011-2018'].strat == 'MOM'])} | {fmt(cells['2019-2026'][cells['2019-2026'].strat == 'MOM'])} |", flush=True)

print("\n## Daily trend filter (H1, default exit)\n")
print("| Daily filter | TPB 2011-18 | TPB 2019-26 | MOM 2011-18 | MOM 2019-26 | long/short 2011-18 | long/short 2019-26 |\n|---|---|---|---|---|---|---|")
for f, label in (("none", "None"), ("ema50", "Close vs EMA50 (DEFAULT)"), ("ema50_200", "EMA50 vs EMA200")):
    cells = {}
    for name, *_ in ERAS:
        b, M = ctx[(name, "1h")]
        sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter=f))
        sig = sig[sig.strat.isin(["TPB", "MOM"])]
        tr, _ = X.simulate(M, sig, TRAIL)
        cells[name] = tr[tr.taken]
    ls = lambda t: f"{t[t.dir > 0].R.mean():+.2f} / {t[t.dir < 0].R.mean():+.2f}"
    print(f"| {label} | {fmt(cells['2011-2018'][cells['2011-2018'].strat == 'TPB'])} | {fmt(cells['2019-2026'][cells['2019-2026'].strat == 'TPB'])} | "
          f"{fmt(cells['2011-2018'][cells['2011-2018'].strat == 'MOM'])} | {fmt(cells['2019-2026'][cells['2019-2026'].strat == 'MOM'])} | "
          f"{ls(cells['2011-2018'])} | {ls(cells['2019-2026'])} |", flush=True)

print("\n## Default configuration by year (every signal, avg R / trades)\n")
rows = []
for name, *_ in ERAS:
    b, M = ctx[(name, "1h")]
    sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
    sig = sig[sig.strat.isin(["TPB", "MOM"])]
    tr, _ = X.simulate(M, sig, TRAIL)
    tr = tr[tr.taken]
    tr["year"] = pd.DatetimeIndex(tr.time).year
    for y, g in tr.groupby("year"):
        rows.append((y, len(g), g.R.mean(), g.R.sum(), (g.R > 0).mean()))
print("| Year | Trades | Avg R | Total R | Win rate |\n|---|---|---|---|---|")
for y, n, a, s, w in rows:
    print(f"| {y} | {n} | {a:+.3f} | {s:+.1f} | {w:.0%} |")
