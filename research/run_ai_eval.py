"""Does the online learner add value? Walk-forward evaluation.

For each era: generate H1 signals, simulate every signal independently with the
EA's default management, replay the online learner walk-forward and bucket the
realised R by the probability the model predicted *before* the trade.
"""
import argparse

import numpy as np
import pandas as pd

import xau_ai as A
import xau_lib as X

ap = argparse.ArgumentParser()
ap.add_argument("--data", action="append", required=True, help="folder[:start] (repeatable)")
ap.add_argument("--label_r", type=float, default=2.0)
ap.add_argument("--horizon_h", type=int, default=48)
ap.add_argument("--d1", default="ema50")
ap.add_argument("--minsamples", type=int, default=100)
args = ap.parse_args()

MG = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)
frames = []
for spec in args.data:
    folder, _, start = spec.partition(":")
    m1 = X.load_all(folder, None, start=start or None)
    b = X.build_context(m1, "1h")
    M = X.prepare_m1(m1, b)
    sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter=args.d1))
    sig = sig[sig.strat.isin(["TPB", "MOM"])].reset_index(drop=True)
    tr, _ = X.simulate(M, sig, MG)
    # tr is sorted by entry index; rebuild features in the same order
    feats = X.features(b, tr)
    s_idx = np.searchsorted(M["t"].asi8, pd.DatetimeIndex(tr["time"]).asi8, side="left")
    y, r_sh, res = A.shadow_labels(M["o"], M["h"], M["l"], M["c"], M["spread"], s_idx.astype(np.int64),
                                   tr["dir"].values.astype(float), tr["sl_dist"].values, args.label_r,
                                   args.horizon_h * 60)
    sid = tr["strat"].map({s: k for k, s in enumerate(X.STRATS)}).values
    p, nseen, ew, model = A.walk_forward(feats, s_idx, res, y, r_sh, sid)
    tr["p"], tr["nseen"], tr["ewma"], tr["y"] = p, nseen, ew, y
    tr["era"] = spec
    frames.append(tr)
    print(f"{spec}: signals={len(tr)} shadow win-rate={np.mean(y==1):.3f} final weights:")
    print("   " + " ".join(f"{f}={w:+.2f}" for f, w in zip(X.FEATURES, model.w)))

tr = pd.concat(frames)
tr = tr[tr.taken]
oos = tr[tr.nseen >= args.minsamples]
print(f"\nOut-of-sample (model had >= {args.minsamples} samples): {len(oos)} trades, avgR={oos.R.mean():+.3f}")
oos = oos.assign(bucket=pd.qcut(oos.p, 5, labels=False, duplicates="drop"))
print(oos.groupby("bucket").agg(n=("R", "size"), p_lo=("p", "min"), p_hi=("p", "max"), avgR=("R", "mean"),
                                 win=("R", lambda r: (r > 0).mean())).round(3))
for thr in (0.25, 0.30, 0.33, 0.36, 0.40):
    g = oos[oos.p >= thr]
    print(f"take only p>={thr:.2f}: n={len(g)} avgR={g.R.mean():+.3f} totR={g.R.sum():.0f}  (all: totR={oos.R.sum():.0f})")
for era, g in oos.groupby("era"):
    for thr in (0.0, 0.30, 0.33):
        gg = g[g.p >= thr]
        print(f"  {era} p>={thr:.2f}: n={len(gg)} avgR={gg.R.mean():+.3f} totR={gg.R.sum():.0f}")
tr.to_pickle("ai_eval_trades.pkl")
