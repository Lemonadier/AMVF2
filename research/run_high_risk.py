"""Can the bot make +50%..+200% per day? Cent account (1,900 USC), increasing risk per trade,
with the daily rule: once the day is +50%, stop if it falls back under +50%; stop at +200%."""
import numpy as np
import pandas as pd

import xau_lib as X

MG = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)
m_old = X.load_all("/tmp/claude-0/data/hd_old", None, start="2011-01-01")
m_new = X.load_all("/tmp/claude-0/data/hd", None, start="2019-01-01")
oos = pd.read_pickle("/tmp/claude-0/data/oos/full_2023_2026.pkl")
m_new = pd.concat([m_new, oos[oos.index > m_new.index[-1]]])
for name, m1 in (("2011-2018", m_old), ("2019-2026", m_new)):
    b = X.build_context(m1, "1h"); M = X.prepare_m1(m1, b)
    sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
    sig = sig[sig.strat.isin(["TPB", "MOM"])].reset_index(drop=True)
    for risk in (2, 5, 10, 20, 30):
        for rule in (False, True):
            tr, eq = X.simulate(M, sig, MG, portfolio=True, start_bal=19.0, contract=1.0, risk_pct=risk, max_pos=2,
                                minlot_tol=0.25, close_on_stop=False, daily_giveback=False,
                                day_floor_pct=50.0 if rule else 0.0, day_target_pct=200.0 if rule else 0.0)
            d = eq.resample("1D").last().dropna(); d = d[d.index.dayofweek < 5]
            r = d.pct_change().dropna() * 100
            dd = (1 - d / d.cummax()).max() * 100
            ruin = d[d < 1.9]
            ruin_t = f"wiped (<10%) on {ruin.index[0].date()}" if len(ruin) else "never wiped"
            print(f"{name} risk {risk:2d}%/trade {'rule ON ' if rule else 'rule off'}: 1900 -> {d.iloc[-1]*100:12,.0f} USC | "
                  f"days >= +50%: {(r >= 50).sum():3d} of {len(r)} | days <= -20%: {(r <= -20).sum():3d} | "
                  f"best {r.max():+.0f}% worst {r.min():+.0f}% | maxDD {dd:.0f}% | {ruin_t}", flush=True)
