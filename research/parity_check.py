"""Compare the EA's signals (XauBot_ParityTest output) with research/xau_lib.py."""
import sys

import numpy as np
import pandas as pd

import xau_lib as X

mt_dir, hd_dir = sys.argv[1], sys.argv[2]
tz = sys.argv[3] if len(sys.argv) > 3 else "nyclose"   # "nyclose" or "gmt0" (Exness-style server)
suffix = "_gmt0" if tz == "gmt0" else ""


def srv_to_utc(s):
    t = pd.to_datetime(s, format="%Y.%m.%d %H:%M")
    if tz == "gmt0":
        return t.dt.tz_localize("UTC")
    # NY-close server time = New York + 7h
    ny = (t - pd.Timedelta(hours=7)).dt.tz_localize("America/New_York", ambiguous="NaT", nonexistent="shift_forward")
    return ny.dt.tz_convert("UTC")


ctx = pd.read_csv(f"{mt_dir}/parity_context{suffix}.csv")
ctx["t"] = srv_to_utc(ctx["close_time"])
sig_mt = pd.read_csv(f"{mt_dir}/parity_signals{suffix}.csv")
sig_mt["t"] = srv_to_utc(sig_mt["close_time"])

m1 = X.load_all(hd_dir, None, start="2022-01-01")
b0 = X.build_context(m1, "1h")
b = b0.set_index("close_time")
j = ctx.set_index("t").join(b, how="inner", rsuffix="_py")
print(f"bars compared: {len(j)} (MT5 {len(ctx)}, Python {len(b)})")
for col_mt, col_py in [("close", "close_py"), ("atr", "atr_py"), ("ema21", "ema21_py"), ("ema50", "ema50_py"),
                       ("rsi", "rsi_py"), ("adx", "adx_py"), ("d1close", "d1_close"), ("d1ema50", "d1_ema50"),
                       ("lon_h", "lon_h_py"), ("ny_h", "ny_h_py"), ("pdh", "pdh_py"), ("pdl", "pdl_py"), ("d1atr", "d1_atr")]:
    a, p = j[col_mt].astype(float), j[col_py].astype(float)
    rel = ((a - p).abs() / p.abs().clip(lower=1e-9))
    print(f"  {col_mt:8s} median rel diff {rel.median():.2e}  95% {rel.quantile(.95):.2e}  max {rel.max():.2e}")
h1up_py = ((j["h1_close"] > j["h1_ema50"]) & (j["h1_ema50"] > j["h1_ema200"]) & (j["h1_ema50"] > j["h1_ema50_prev"])).astype(int)
print(f"  h1 trend-up flag agreement: {(h1up_py == j['h1up']).mean():.4f}")

sig_py = X.gen_signals(b0, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
sig_py["t"] = pd.DatetimeIndex(sig_py["time"]).tz_localize("UTC")
lo, hi = sig_mt["t"].min(), sig_mt["t"].max()
sig_py = sig_py[(sig_py.t >= lo) & (sig_py.t <= hi)]
key = lambda d: set(zip(d.t.astype(str), d.strat, d.dir.astype(int)))
A, B = key(sig_mt), key(sig_py)
print(f"\nsignals: MT5 {len(A)}  Python {len(B)}  common {len(A & B)}  only-MT5 {len(A - B)}  only-Python {len(B - A)}")
for s in X.STRATS:
    a = {k for k in A if k[1] == s}; p = {k for k in B if k[1] == s}
    print(f"  {s:4s} MT5 {len(a):4d}  Py {len(p):4d}  common {len(a & p):4d}  match {len(a & p) / max(1, len(a | p)):.1%}")
