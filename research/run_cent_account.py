"""User setup study: Exness Standard Cent XAUUSDc, 1,900 USC (= $19), whole-account 40% giveback lock.

Cent lot: 0.01 lot = 0.01 oz, so in USD terms contract = 1 oz per lot, min lot 0.01.
Rules: 50% daily loss (stop opening only), whole-account giveback lock (latched),
risk % per trade with 25% min-lot tolerance. Rolling start dates, 3-year horizon.
"""
import sys

import numpy as np
import pandas as pd

import xau_lib as X

MG = dict(be_r=0, trail_start_r=1.5, trail_atr=3.0, partial_frac=0, max_bars_m15=0)
eras = []
m_old = X.load_all("/tmp/claude-0/data/hd_old", None, start="2011-01-01")
eras.append(m_old)
m_new = X.load_all("/tmp/claude-0/data/hd", None, start="2019-01-01")
oos = pd.read_pickle("/tmp/claude-0/data/oos/full_2023_2026.pkl")
m_new = pd.concat([m_new, oos[oos.index > m_new.index[-1]]])
eras.append(m_new)

spread_bp = float(sys.argv[1]) if len(sys.argv) > 1 else 1.0
rows = []
for m1 in eras:
    b = X.build_context(m1, "1h")
    M = X.prepare_m1(m1, b, spread_bp=spread_bp)
    sig = X.gen_signals(b, dict(tpb_tp_r=0, mom_tp_r=0, d1_filter="ema50"))
    sig = sig[sig.strat.isin(["TPB", "MOM"])].reset_index(drop=True)
    t = M["t"]
    starts = pd.date_range(t[0] + pd.Timedelta(days=60), t[-1] - pd.Timedelta(days=365), freq="3MS", tz="UTC")
    for st in starts:
        i0 = t.searchsorted(st)
        i1 = t.searchsorted(st + pd.Timedelta(days=3 * 365))
        Ms = {k: (v[i0:i1] if isinstance(v, np.ndarray) else v) for k, v in M.items()}
        Ms["t"] = t[i0:i1]
        ss = sig[(pd.DatetimeIndex(sig.time).tz_localize("UTC") >= t[i0]) & (pd.DatetimeIndex(sig.time).tz_localize("UTC") < t[min(i1, len(t) - 1)])]
        years = (Ms["t"][-1] - Ms["t"][0]).days / 365.25
        for risk in (1.0, 2.0, 3.0):
            for arm in (None, 1.0, 10.0, 25.0):
                tr, eq, lock = X.simulate(Ms, ss, MG, portfolio=True, start_bal=19.0, contract=1.0, risk_pct=risk,
                                          minlot_tol=0.25, close_on_stop=False, daily_giveback=False,
                                          account_lock=arm is not None, account_gb_pct=40.0,
                                          account_arm_pct=arm or 0.0, return_lock=True)
                e = eq.resample("1D").last().dropna()
                dd = (1 - e / e.cummax()).max() * 100
                rows.append(dict(start=st, years=years, risk=risk, arm=arm if arm is not None else -1,
                                 locked=lock is not None,
                                 months_to_lock=((lock - st).days / 30.4) if lock is not None else np.nan,
                                 final=e.iloc[-1], maxdd=dd, trades=int(tr.taken.sum())))
out = pd.DataFrame(rows)
out.to_pickle(f"cent_study_{spread_bp}.pkl")
print(f"spread model {spread_bp} bp; {out.start.nunique()} start dates, 3-year horizon, $19 start\n")
g = out.groupby(["risk", "arm"])
summ = g.agg(locked=("locked", "mean"), med_months=("months_to_lock", "median"),
             med_final=("final", "median"), p10_final=("final", lambda x: x.quantile(.1)),
             p90_final=("final", lambda x: x.quantile(.9)), lose_money=("final", lambda x: (x < 19).mean()),
             med_dd=("maxdd", "median"), trades=("trades", "median"))
print(summ.round(2).to_string())
