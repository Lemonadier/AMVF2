"""Whole-account lock with restarts: run until the lock fires, wait 1 day, restart with the
current balance as the new baseline. Compared with never locking. $19 cent account."""
import numpy as np
import pandas as pd

import xau_lib as X

MG = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)
m_old = X.load_all("/tmp/claude-0/data/hd_old", None, start="2011-01-01")
m_new = X.load_all("/tmp/claude-0/data/hd", None, start="2019-01-01")
oos = pd.read_pickle("/tmp/claude-0/data/oos/full_2023_2026.pkl")
m_new = pd.concat([m_new, oos[oos.index > m_new.index[-1]]])

for name, m1 in (("2011-2018", m_old), ("2019-2026", m_new)):
    b = X.build_context(m1, "1h")
    M = X.prepare_m1(m1, b)
    sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
    sig = sig[sig.strat.isin(["TPB", "MOM"])].reset_index(drop=True)
    st_all = pd.DatetimeIndex(sig.time).tz_localize("UTC")
    t = M["t"]
    t0 = t[0] + pd.Timedelta(days=60)
    for risk in (1.0, 2.0, 3.0):
        for arm in (None, 10.0, 25.0, 50.0):
            bal, cur, cycles, curve = 19.0, t0, 0, []
            while True:
                i0 = t.searchsorted(cur)
                if i0 >= len(t) - 1000:
                    break
                Ms = {k: (v[i0:] if isinstance(v, np.ndarray) else v) for k, v in M.items()}
                Ms["t"] = t[i0:]
                tr, eq, lock = X.simulate(Ms, sig[st_all >= t[i0]], MG, portfolio=True, start_bal=bal, contract=1.0,
                                          risk_pct=risk, minlot_tol=0.25, close_on_stop=False, daily_giveback=False,
                                          account_lock=arm is not None, account_gb_pct=40.0,
                                          account_arm_pct=arm or 0.0, return_lock=True)
                if lock is None:
                    curve.append(eq)
                    bal = eq.iloc[-1]
                    break
                # open trades run to their own exits; restart the next day from the then-current equity
                restart = lock + pd.Timedelta(days=1)
                seg = eq[eq.index < restart]
                curve.append(seg)
                bal = seg.iloc[-1]
                cur = restart
                cycles += 1
                if bal < 1:
                    break
            e = pd.concat(curve).resample("1D").last().dropna()
            dd = (1 - e / e.cummax()).max() * 100
            yrs = (e.index[-1] - e.index[0]).days / 365.25
            cagr = ((e.iloc[-1] / 19.0) ** (1 / yrs) - 1) * 100 if e.iloc[-1] > 0 else -100
            print(f"{name} risk {risk:.0f}% lock {'off' if arm is None else f'arms +{arm:.0f}%':>12s}: "
                  f"$19 -> ${e.iloc[-1]:8.2f}  CAGR {cagr:6.1f}%  maxDD {dd:5.1f}%  lock cycles {cycles}", flush=True)
