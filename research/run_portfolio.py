"""Money simulation of the EA's default configuration with the account rules.

Daily loss limit (50% of day-start balance) and profit giveback lock (40%) are
applied on equity at every M1 bar, exactly like CRiskGuard in the EA.
"""
import argparse

import numpy as np
import pandas as pd

import xau_lib as X

ap = argparse.ArgumentParser()
ap.add_argument("--data", required=True, help="folder[:start]")
ap.add_argument("--balance", type=float, default=1000.0)
args = ap.parse_args()

folder, _, start = args.data.partition(":")
m1 = X.load_all(folder, None, start=start or None)
b = X.build_context(m1, "1h")
M = X.prepare_m1(m1, b)
sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
sig = sig[sig.strat.isin(["TPB", "MOM"])].reset_index(drop=True)
MG = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)


def run(risk, loss_pct=50.0, gb=40.0, arm=1.0, label=""):
    tr, eq = X.simulate(M, sig, MG, portfolio=True, start_bal=args.balance, risk_pct=risk,
                        daily_loss_pct=loss_pct, giveback_pct=gb, giveback_arm_pct=arm, max_pos=2)
    t = tr[tr.taken]
    e = eq.resample("1D").last().dropna()
    e = e[e > 0]
    dd = (1 - e / e.cummax()).max() * 100
    yrs = (e.index[-1] - e.index[0]).days / 365.25
    final = e.iloc[-1]
    cagr = ((final / args.balance) ** (1 / yrs) - 1) * 100 if final > 0 else -100
    worst_day = e.pct_change().min() * 100
    stops = (t.reason == 6).sum()
    yearly = e.resample("YE").last()
    yr = (yearly / yearly.shift(1).fillna(args.balance) - 1) * 100
    print(f"{label:34s} risk={risk:>3}% trades={len(t):5d} final=${final:>14,.0f} CAGR={cagr:6.1f}% maxDD={dd:5.1f}% "
          f"worstDay={worst_day:6.1f}% guardCloses={stops:3d} | " + " ".join(f"{d.year % 100}:{v:+.0f}%" for d, v in yr.items()),
          flush=True)
    return t, e


for r in (0.5, 1.0, 2.0, 3.0, 5.0):
    run(r, label="your rules (50% day / 40% giveback)")
print()
for r in (1.0, 2.0):
    run(r, gb=100.0, label="no giveback lock")
    run(r, arm=0.0, label="giveback armed from first $")
    run(r, arm=3.0, label="giveback armed at 3%")
