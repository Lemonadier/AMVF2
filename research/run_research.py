"""Per-strategy research grid: timeframe x stop size x management, by year.

python run_research.py --hd /path/to/histdata --duka /path/to/dukascopy
"""
import argparse
import sys
import time

import numpy as np
import pandas as pd

import xau_lib as X

ap = argparse.ArgumentParser()
ap.add_argument("--hd", default="data/hd")
ap.add_argument("--duka", default=None)
ap.add_argument("--start", default="2019-01-01")
ap.add_argument("--tfs", default="15min,30min,1h")
args = ap.parse_args()

m1 = X.load_all(args.hd, args.duka, start=args.start)
print("M1 bars:", len(m1), m1.index[0], "->", m1.index[-1], flush=True)

mgmts = {
    "fixedTP": dict(be_r=0, trail_atr=0, max_bars_m15=0, partial_frac=0),
    "BE+trail": dict(),
}
rows = []
for tf in args.tfs.split(","):
    t0 = time.time()
    b = X.build_context(m1, tf)
    M = X.prepare_m1(m1, b)
    tf_mult = pd.Timedelta(tf) / pd.Timedelta("15min")
    for slmin in (0.8, 1.5):
        sig = X.gen_signals(b, dict(sl_min_atr=slmin, sl_max_atr=max(3.0, slmin * 2)))
        for mname, mg in mgmts.items():
            mg = dict(mg)
            if "max_bars_m15" not in mg:
                mg["max_bars_m15"] = X.DEFAULT_MGMT["max_bars_m15"] * tf_mult
            tr, _ = X.simulate(M, sig, mg)
            tr["year"] = pd.DatetimeIndex(tr["time"]).year
            for (st, yr), g in tr.groupby(["strat", "year"]):
                s = X.stats(g)
                rows.append(dict(tf=tf, slmin=slmin, mgmt=mname, strat=st, year=yr, **s))
            for st, g in tr.groupby("strat"):
                s = X.stats(g)
                rows.append(dict(tf=tf, slmin=slmin, mgmt=mname, strat=st, year=0, **s))
                print(f"{tf:6s} slmin={slmin} {mname:9s} {st:4s} {s}", flush=True)
    print(f"  ({tf} done in {time.time()-t0:.0f}s)", flush=True)

out = pd.DataFrame(rows)
out.to_csv("research_grid.csv", index=False)
