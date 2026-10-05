"""Out-of-sample check of the EA defaults on data never used for design (2026-01-10 onward)."""
import sys

import numpy as np
import pandas as pd

import xau_lib as X

m1 = pd.read_pickle(sys.argv[1])
oos_start = pd.Timestamp(sys.argv[2] if len(sys.argv) > 2 else "2026-01-10", tz="UTC")
b = X.build_context(m1, "1h")
M = X.prepare_m1(m1, b)
sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
sig = sig[sig.strat.isin(["TPB", "MOM"])].reset_index(drop=True)
MG = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)
tr, _ = X.simulate(M, sig, MG)
tr = tr[pd.DatetimeIndex(tr.time).tz_localize("UTC") >= oos_start]
print(f"OOS {oos_start.date()} -> {m1.index[-1].date()}  (every signal, 1R units)")
for s, g in tr.groupby("strat"):
    print(f"  {s}: {X.stats(g)}  long {g[g.dir > 0].R.mean():+.2f} ({(g.dir > 0).sum()}) short {g[g.dir < 0].R.mean():+.2f} ({(g.dir < 0).sum()})")
print(f"  ALL: {X.stats(tr)}")
tr["month"] = pd.DatetimeIndex(tr.time).to_period("M")
print(tr.groupby("month").R.agg(["size", "mean", "sum"]).round(2).T)
for risk in (1.0, 2.0):
    t2, eq = X.simulate(M, sig, MG, portfolio=True, start_bal=10000, risk_pct=risk, max_pos=2)
    e = eq[eq.index >= oos_start].resample("1D").last().dropna()
    start, end = e.iloc[0], e.iloc[-1]
    dd = (1 - e / e.cummax()).max() * 100
    n = (pd.DatetimeIndex(t2[t2.taken].time).tz_localize("UTC") >= oos_start).sum()
    print(f"  money sim risk {risk}%: ${start:,.0f} -> ${end:,.0f} ({(end / start - 1) * 100:+.1f}%), maxDD {dd:.1f}%, trades {n}")
