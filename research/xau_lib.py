"""Research library for the XAUUSD AI Bot.

Loads Dukascopy M1 data, builds higher timeframes, computes indicators that
match MetaTrader 5's built-in ones, generates the bot's strategy signals and
simulates trades bar-by-bar on M1 data (with spread, break-even, partial
close, ATR trailing, time stop, Friday close, daily guards).

Everything here mirrors the logic in MQL5/Experts/XAUUSD_AI_Bot so the
backtest numbers say something about the EA's defaults.
"""
from __future__ import annotations

import glob
import os
import struct

import numpy as np
import pandas as pd
from numba import njit

# --------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------

def load_m1(folder: str, start: str | None = None, end: str | None = None) -> pd.DataFrame:
    """Load Dukascopy daily .bin files into a UTC-indexed M1 OHLCV frame."""
    cache = os.path.join(folder, "_m1_cache.pkl")
    files = sorted(glob.glob(os.path.join(folder, "*.bin")))
    if os.path.exists(cache) and os.path.getmtime(cache) >= max(os.path.getmtime(f) for f in files):
        df = pd.read_pickle(cache)
    else:
        rec = np.dtype([("t", ">u4"), ("o", ">u4"), ("c", ">u4"), ("l", ">u4"), ("h", ">u4"), ("v", ">f4")])
        parts = []
        for f in files:
            raw = open(f, "rb").read()
            if not raw:
                continue
            a = np.frombuffer(raw, dtype=rec)
            day = pd.Timestamp(os.path.basename(f)[:10], tz="UTC")
            idx = day + pd.to_timedelta(a["t"].astype(np.int64), unit="s")
            parts.append(pd.DataFrame({
                "open": a["o"] / 1000.0, "high": a["h"] / 1000.0,
                "low": a["l"] / 1000.0, "close": a["c"] / 1000.0,
                "volume": a["v"].astype(np.float64),
            }, index=idx))
        df = pd.concat(parts).sort_index()
        df = df[~df.index.duplicated()]
        df = df[df["volume"] > 0]  # Dukascopy pads closed hours with flat zero-volume bars
        df.to_pickle(cache)
    if start:
        df = df[df.index >= pd.Timestamp(start, tz="UTC")]
    if end:
        df = df[df.index < pd.Timestamp(end, tz="UTC")]
    return df


def load_histdata(folder: str) -> pd.DataFrame:
    """Load HistData.com 'DAT_MT' M1 csv files (EST without DST = UTC-5 all year)."""
    cache = os.path.join(folder, "_m1_cache.pkl")
    files = sorted(glob.glob(os.path.join(folder, "DAT_MT_XAUUSD_M1_*.csv")))
    if os.path.exists(cache) and os.path.getmtime(cache) >= max(os.path.getmtime(f) for f in files):
        return pd.read_pickle(cache)
    parts = []
    for f in files:
        d = pd.read_csv(f, header=None, names=["d", "t", "open", "high", "low", "close", "volume"])
        idx = pd.to_datetime(d["d"] + " " + d["t"], format="%Y.%m.%d %H:%M") + pd.Timedelta(hours=5)
        d.index = idx.dt.tz_localize("UTC")
        parts.append(d[["open", "high", "low", "close", "volume"]].astype(float))
    df = pd.concat(parts).sort_index()
    df = df[~df.index.duplicated()]
    df["volume"] = 1.0  # HistData has no volume
    df.to_pickle(cache)
    return df


def load_all(histdata_dir: str, dukascopy_dir: str | None = None, start=None, end=None) -> pd.DataFrame:
    """HistData history, extended with Dukascopy bars after the last HistData bar."""
    df = load_histdata(histdata_dir)
    if dukascopy_dir and glob.glob(os.path.join(dukascopy_dir, "*.bin")):
        dk = load_m1(dukascopy_dir)
        dk = dk[dk.index > df.index[-1]]
        if len(dk):
            dk = dk.assign(volume=1.0)
            df = pd.concat([df, dk])
    if start:
        df = df[df.index >= pd.Timestamp(start, tz="UTC")]
    if end:
        df = df[df.index < pd.Timestamp(end, tz="UTC")]
    return df


def resample(m1: pd.DataFrame, rule: str) -> pd.DataFrame:
    out = m1.resample(rule, label="left", closed="left").agg(
        {"open": "first", "high": "max", "low": "min", "close": "last", "volume": "sum"})
    return out.dropna()


# --------------------------------------------------------------------------
# Indicators (MetaTrader 5 definitions)
# --------------------------------------------------------------------------

def ema(x: pd.Series, n: int) -> pd.Series:
    return x.ewm(alpha=2.0 / (n + 1), adjust=False).mean()


def sma(x: pd.Series, n: int) -> pd.Series:
    return x.rolling(n).mean()


def true_range(df: pd.DataFrame) -> pd.Series:
    pc = df["close"].shift(1)
    return pd.concat([df["high"] - df["low"], (df["high"] - pc).abs(), (df["low"] - pc).abs()], axis=1).max(axis=1)


def atr(df: pd.DataFrame, n: int = 14) -> pd.Series:
    # MT5 iATR = simple average of true range
    return sma(true_range(df), n)


def rsi(close: pd.Series, n: int = 14) -> pd.Series:
    d = close.diff()
    up = d.clip(lower=0).ewm(alpha=1.0 / n, adjust=False).mean()
    dn = (-d.clip(upper=0)).ewm(alpha=1.0 / n, adjust=False).mean()
    rs = up / dn.replace(0, np.nan)
    return (100 - 100 / (1 + rs)).fillna(50)


def adx(df: pd.DataFrame, n: int = 14) -> pd.Series:
    # MT5 iADX: per-bar +DI/-DI ratios smoothed with EMA(n), ADX = EMA(n) of DX
    h, l, c = df["high"], df["low"], df["close"]
    up = h.diff()
    dn = -l.diff()
    pdm = np.where((up > dn) & (up > 0), up, 0.0)
    ndm = np.where((dn > up) & (dn > 0), dn, 0.0)
    tr = true_range(df).replace(0, np.nan)
    pdi = ema(pd.Series(100 * pdm, index=df.index) / tr, n).fillna(0)
    ndi = ema(pd.Series(100 * ndm, index=df.index) / tr, n).fillna(0)
    s = (pdi + ndi).replace(0, np.nan)
    dx = (100 * (pdi - ndi).abs() / s).fillna(0)
    return ema(dx, n)


def bollinger(close: pd.Series, n: int = 20, k: float = 2.0):
    m = sma(close, n)
    sd = close.rolling(n).std(ddof=0)
    return m, m + k * sd, m - k * sd


def efficiency_ratio(close: pd.Series, n: int = 20) -> pd.Series:
    change = (close - close.shift(n)).abs()
    vol = close.diff().abs().rolling(n).sum()
    return (change / vol.replace(0, np.nan)).fillna(0)


# --------------------------------------------------------------------------
# Feature / context frame on the signal timeframe
# --------------------------------------------------------------------------

def ny_days(m1: pd.DataFrame) -> pd.DataFrame:
    """Daily bars on the New-York-close (17:00 NY) convention used by most gold brokers."""
    ny = m1.index.tz_convert("America/New_York")
    key = (ny + pd.Timedelta(hours=7)).normalize().tz_localize(None)
    g = m1.groupby(key.values)
    d = pd.DataFrame({"open": g["open"].first(), "high": g["high"].max(), "low": g["low"].min(),
                      "close": g["close"].last(), "end": g.apply(lambda x: x.index[-1] + pd.Timedelta("1min"))})
    d = d[g.size() > 120]  # drop stub sessions
    return d.sort_values("end")


def align_htf(base_close_time: pd.DatetimeIndex, htf: pd.DataFrame, period: pd.Timedelta, cols) -> pd.DataFrame:
    """Values of the last *completed* higher-timeframe bar at each base close time."""
    h = htf[cols].copy()
    h["_close_time"] = h.index + period
    left = pd.DataFrame({"_t": base_close_time})
    m = pd.merge_asof(left, h.reset_index(drop=True).sort_values("_close_time"),
                      left_on="_t", right_on="_close_time", direction="backward")
    return m[cols].set_index(base_close_time)


def build_context(m1: pd.DataFrame, tf: str = "15min") -> pd.DataFrame:
    tfd = pd.Timedelta(tf)
    b = resample(m1, tf)
    b["atr"] = atr(b, 14)
    b["ema21"] = ema(b["close"], 21)
    b["ema50"] = ema(b["close"], 50)
    b["rsi"] = rsi(b["close"], 14)
    b["adx"] = adx(b, 14)
    b["bb_mid"], b["bb_up"], b["bb_lo"] = bollinger(b["close"], 20, 2.0)
    b["er"] = efficiency_ratio(b["close"], 20)
    b["vol_sma"] = sma(b["volume"], 20)
    b["atr_pct"] = b["atr"].rolling(200, min_periods=50).rank(pct=True)
    b["don_hi"] = b["high"].shift(1).rolling(20).max()
    b["don_lo"] = b["low"].shift(1).rolling(20).min()

    close_time = b.index + tfd
    h1 = resample(m1, "1h")
    h1["ema50"] = ema(h1["close"], 50)
    h1["ema200"] = ema(h1["close"], 200)
    h1["ema50_prev"] = h1["ema50"].shift(5)
    h1["atr"] = atr(h1, 14)
    h1["adx"] = adx(h1, 14)
    a = align_htf(close_time, h1, pd.Timedelta("1h"), ["close", "ema50", "ema200", "ema50_prev", "atr", "adx"])
    for c in a.columns:
        b["h1_" + c] = a[c].values

    h4 = resample(m1, "4h")
    h4["ema50"] = ema(h4["close"], 50)
    a = align_htf(close_time, h4, pd.Timedelta("4h"), ["close", "ema50"])
    b["h4_close"] = a["close"].values
    b["h4_ema50"] = a["ema50"].values

    d1 = ny_days(m1)
    d1["atr"] = atr(d1, 14)
    d1["ema50"] = ema(d1["close"], 50)
    d1["ema200"] = ema(d1["close"], 200)
    a = pd.merge_asof(pd.DataFrame({"_t": close_time}), d1[["high", "low", "close", "atr", "ema50", "ema200", "end"]].reset_index(drop=True),
                      left_on="_t", right_on="end", direction="backward")
    b["pdh"], b["pdl"], b["d1_atr"] = a["high"].values, a["low"].values, a["atr"].values
    b["d1_close"], b["d1_ema50"], b["d1_ema200"] = a["close"].values, a["ema50"].values, a["ema200"].values

    # local session clocks (DST aware)
    ct = close_time
    lon = ct.tz_convert("Europe/London")
    ny = ct.tz_convert("America/New_York")
    b["close_time"] = ct
    b["utc_h"] = ct.hour + ct.minute / 60.0
    b["lon_h"] = lon.hour + lon.minute / 60.0
    b["ny_h"] = ny.hour + ny.minute / 60.0
    b["dow"] = ct.dayofweek
    b["date"] = ct.normalize()

    # Asian range (00:00-07:00 UTC) of the current UTC day, known from 07:00 on
    asia = b[(b.index.hour < 7)]
    ar = asia.groupby(asia.index.normalize()).agg(asia_hi=("high", "max"), asia_lo=("low", "min"))
    b = b.join(ar, on=b.index.normalize())
    b.loc[b.index.hour < 7, ["asia_hi", "asia_lo"]] = np.nan
    return b.dropna(subset=["atr", "h1_ema200", "d1_atr", "adx"])


# --------------------------------------------------------------------------
# Strategy signals (one row per candidate trade)
# --------------------------------------------------------------------------
STRATS = ["TPB", "LBO", "LSR", "MR", "MOM"]

DEFAULT_PARAMS = dict(
    sl_min_atr=0.8, sl_max_atr=3.0,
    tpb_tp_r=2.0, lbo_tp_r=2.0, lsr_tp_r=2.0, mr_tp_r=1.5, mom_tp_r=2.5,
    lbo_buffer_atr=0.1, lbo_min_rng_d1=0.25, lbo_max_rng_d1=1.2,
    lsr_wick=0.5, mr_adx_max=20.0, mom_adx_min=25.0, mom_range_atr=1.2,
)


def trade_window(b: pd.DataFrame) -> np.ndarray:
    """Allowed entry time: not in NY rollover (16:45-18:30 NY), not Fri after 18:00 UTC."""
    roll = (b["ny_h"] >= 16.75) & (b["ny_h"] < 18.5)
    fri = (b["dow"] == 4) & (b["utc_h"] >= 18)
    mon_open = (b["dow"] == 0) & (b["utc_h"] < 1)
    weekend = b["dow"] >= 5
    return ~(roll | fri | mon_open | weekend).values


def gen_signals(b: pd.DataFrame, p: dict | None = None) -> pd.DataFrame:
    p = {**DEFAULT_PARAMS, **(p or {})}
    o, h, l, c = b["open"].values, b["high"].values, b["low"].values, b["close"].values
    A = b["atr"].values
    n = len(b)
    ok_time = trade_window(b)

    d1f = p.get("d1_filter", "none")
    if d1f == "ema50":
        d1_up = (b["d1_close"] > b["d1_ema50"]).values
        d1_dn = (b["d1_close"] < b["d1_ema50"]).values
    elif d1f == "ema50_200":
        d1_up = (b["d1_ema50"] > b["d1_ema200"]).values
        d1_dn = (b["d1_ema50"] < b["d1_ema200"]).values
    else:
        d1_up = np.ones(len(b), bool)
        d1_dn = np.ones(len(b), bool)
    h1_up = ((b["h1_close"] > b["h1_ema50"]) & (b["h1_ema50"] > b["h1_ema200"]) & (b["h1_ema50"] > b["h1_ema50_prev"])).values
    h1_dn = ((b["h1_close"] < b["h1_ema50"]) & (b["h1_ema50"] < b["h1_ema200"]) & (b["h1_ema50"] < b["h1_ema50_prev"])).values
    ema21, ema50 = b["ema21"].values, b["ema50"].values
    rsi_v, adx_v = b["rsi"].values, b["adx"].values
    bb_up, bb_lo, bb_mid = b["bb_up"].values, b["bb_lo"].values, b["bb_mid"].values
    vol, vol_sma = b["volume"].values, b["vol_sma"].values
    don_hi, don_lo = b["don_hi"].values, b["don_lo"].values
    asia_hi, asia_lo = b["asia_hi"].values, b["asia_lo"].values
    pdh, pdl, d1_atr = b["pdh"].values, b["pdl"].values, b["d1_atr"].values
    lon_h, ny_h = b["lon_h"].values, b["ny_h"].values
    date = b["date"].values
    h1_adx = b["h1_adx"].values

    rows = []

    def add(i, strat, d, sl_price, tp_r):
        if (d > 0 and not d1_up[i]) or (d < 0 and not d1_dn[i]):
            return
        entry = c[i]
        dist = (entry - sl_price) * d
        if not np.isfinite(dist):
            return
        lo, hi = p["sl_min_atr"] * A[i], p["sl_max_atr"] * A[i]
        if dist > hi:
            return  # structure too far away: skip
        dist = max(dist, lo)
        rows.append((i, strat, d, dist, tp_r))

    lbo_done = {}
    lsr_last = -100
    for i in range(30, n):
        if not ok_time[i] or not np.isfinite(A[i]) or A[i] <= 0:
            continue
        rng = h[i] - l[i]
        # ---- 1) Trend pullback (H1 trend + M15 pullback to EMA21 + momentum close)
        lo5 = l[i - 4:i + 1].min()
        hi5 = h[i - 4:i + 1].max()
        if h1_up[i] and lo5 <= ema21[i] + 0.1 * A[i] and l[i - 4:i + 1].min() > ema50[i] - 1.0 * A[i] \
                and c[i] > o[i] and c[i] > ema21[i] and c[i] > h[i - 1] and 45 <= rsi_v[i] <= 70:
            add(i, "TPB", 1, lo5 - 0.3 * A[i], p["tpb_tp_r"])
        if h1_dn[i] and hi5 >= ema21[i] - 0.1 * A[i] and h[i - 4:i + 1].max() < ema50[i] + 1.0 * A[i] \
                and c[i] < o[i] and c[i] < ema21[i] and c[i] < l[i - 1] and 30 <= rsi_v[i] <= 55:
            add(i, "TPB", -1, hi5 + 0.3 * A[i], p["tpb_tp_r"])

        # ---- 2) London breakout of the Asian range (07:00-10:30 London time)
        if 7.0 <= lon_h[i] <= 10.5 and np.isfinite(asia_hi[i]):
            ar = asia_hi[i] - asia_lo[i]
            key = date[i]
            if p["lbo_min_rng_d1"] * d1_atr[i] <= ar <= p["lbo_max_rng_d1"] * d1_atr[i] and key not in lbo_done:
                buf = p["lbo_buffer_atr"] * A[i]
                mid = (asia_hi[i] + asia_lo[i]) / 2
                if c[i] > asia_hi[i] + buf and c[i - 1] <= asia_hi[i] + buf and not h1_dn[i]:
                    add(i, "LBO", 1, mid, p["lbo_tp_r"]); lbo_done[key] = 1
                elif c[i] < asia_lo[i] - buf and c[i - 1] >= asia_lo[i] - buf and not h1_up[i]:
                    add(i, "LBO", -1, mid, p["lbo_tp_r"]); lbo_done[key] = 1

        # ---- 3) Liquidity sweep reversal at PDH/PDL/Asian extremes (London+NY hours)
        if 7.0 <= lon_h[i] and ny_h[i] <= 12.0 and rng > 0 and i - lsr_last > 4:
            for lvl in (pdh[i], asia_hi[i]):
                if np.isfinite(lvl) and h[i] > lvl + 0.1 * A[i] and c[i] < lvl and (h[i] - max(o[i], c[i])) >= p["lsr_wick"] * rng and rsi_v[i] > 55:
                    add(i, "LSR", -1, h[i] + 0.2 * A[i], p["lsr_tp_r"]); lsr_last = i; break
            else:
                for lvl in (pdl[i], asia_lo[i]):
                    if np.isfinite(lvl) and l[i] < lvl - 0.1 * A[i] and c[i] > lvl and (min(o[i], c[i]) - l[i]) >= p["lsr_wick"] * rng and rsi_v[i] < 45:
                        add(i, "LSR", 1, l[i] - 0.2 * A[i], p["lsr_tp_r"]); lsr_last = i; break

        # ---- 4) Mean reversion in a range regime (Bollinger re-entry + RSI)
        if adx_v[i] < p["mr_adx_max"] and h1_adx[i] < 25:
            if c[i - 1] < bb_lo[i - 1] and rsi_v[i - 1] < 30 and c[i] > bb_lo[i] and c[i] > o[i]:
                add(i, "MR", 1, min(l[i], l[i - 1]) - 0.3 * A[i], p["mr_tp_r"])
            elif c[i - 1] > bb_up[i - 1] and rsi_v[i - 1] > 70 and c[i] < bb_up[i] and c[i] < o[i]:
                add(i, "MR", -1, max(h[i], h[i - 1]) + 0.3 * A[i], p["mr_tp_r"])

        # ---- 5) Momentum / Donchian breakout with range expansion, in a trend regime
        if adx_v[i] > p["mom_adx_min"] and adx_v[i] > adx_v[i - 1] and rng >= p["mom_range_atr"] * A[i]:
            if h1_up[i] and c[i] > don_hi[i] and c[i - 1] <= don_hi[i - 1]:
                add(i, "MOM", 1, c[i] - 1.5 * A[i], p["mom_tp_r"])
            elif h1_dn[i] and c[i] < don_lo[i] and c[i - 1] >= don_lo[i - 1]:
                add(i, "MOM", -1, c[i] + 1.5 * A[i], p["mom_tp_r"])

    sig = pd.DataFrame(rows, columns=["bar", "strat", "dir", "sl_dist", "tp_r"])
    sig["time"] = b["close_time"].values[sig["bar"].values]
    return sig


# --------------------------------------------------------------------------
# Features for the online learner (same order as the EA)
# --------------------------------------------------------------------------
FEATURES = ["bias", "h1_trend", "h1_slope", "h4_trend", "dist_ema50", "adx", "er", "rsi", "atr_pct",
            "body", "bbpos", "s_asia", "s_london", "s_ny", "s_late",
            "st_TPB", "st_LBO", "st_LSR", "st_MR", "st_MOM"]


def features(b: pd.DataFrame, sig: pd.DataFrame) -> np.ndarray:
    i = sig["bar"].values
    d = sig["dir"].values.astype(float)
    r = b.iloc[i]
    clip = lambda x: np.clip(x, -1, 1)
    h1a = r["h1_atr"].values
    X = np.zeros((len(sig), len(FEATURES)))
    X[:, 0] = 1.0
    X[:, 1] = clip((r["h1_ema50"].values - r["h1_ema200"].values) / h1a / 3 * d)
    X[:, 2] = clip((r["h1_ema50"].values - r["h1_ema50_prev"].values) / h1a * d)
    X[:, 3] = clip((r["h4_close"].values - r["h4_ema50"].values) / h1a / 4 * d)
    X[:, 4] = clip((r["close"].values - r["ema50"].values) / r["atr"].values / 3 * d)
    X[:, 5] = clip(r["adx"].values / 50)
    X[:, 6] = clip(r["er"].values)
    X[:, 7] = clip((r["rsi"].values - 50) / 50 * d)
    X[:, 8] = clip(r["atr_pct"].fillna(0.5).values - 0.5)
    rng = (r["high"] - r["low"]).replace(0, np.nan).values
    X[:, 9] = np.nan_to_num(clip((r["close"].values - r["open"].values) / rng * d))
    bw = (r["bb_up"] - r["bb_lo"]).replace(0, np.nan).values
    X[:, 10] = np.nan_to_num(clip(((r["close"].values - r["bb_mid"].values) / bw) * 2 * d))
    uh = r["utc_h"].values
    X[:, 11] = (uh < 7)
    X[:, 12] = (uh >= 7) & (uh < 12)
    X[:, 13] = (uh >= 12) & (uh < 16)
    X[:, 14] = (uh >= 16)
    for k, s in enumerate(STRATS):
        X[:, 15 + k] = (sig["strat"].values == s)
    return X


# --------------------------------------------------------------------------
# Trade simulator on M1 bars (numba)
# --------------------------------------------------------------------------
@njit(cache=True)
def _simulate(t_min, o, h, l, c, spread, atr_m1, dow, utc_h,
              s_idx, s_dir, s_dist, s_tp_r, s_strat, s_risk_mult,
              be_r, be_lock_r, partial_r, partial_frac, trail_start_r, trail_atr,
              max_bars_m1, time_stop_min_r, friday_close_h, intraday_close_ny_h, ny_h,
              portfolio, start_bal, risk_pct, daily_loss_pct, giveback_pct, giveback_arm_pct,
              max_pos, contract, min_lot, lot_step, day_id, slip, roll_mult, swap_long, swap_short):
    n = len(c)
    ns = len(s_idx)
    MAXP = 16
    # open position slots
    p_on = np.zeros(MAXP, np.int8)
    p_dir = np.zeros(MAXP); p_entry = np.zeros(MAXP); p_sl = np.zeros(MAXP); p_tp = np.zeros(MAXP)
    p_r = np.zeros(MAXP); p_lots = np.zeros(MAXP); p_lots0 = np.zeros(MAXP); p_best = np.zeros(MAXP)
    p_bar = np.zeros(MAXP, np.int64); p_sig = np.zeros(MAXP, np.int64); p_part = np.zeros(MAXP, np.int8)
    p_real = np.zeros(MAXP); p_strat = np.zeros(MAXP, np.int64)
    # outputs
    out_sig = np.full(ns, -1, np.int64)
    out_R = np.zeros(ns); out_exit_bar = np.full(ns, -1, np.int64); out_pnl = np.zeros(ns); out_reason = np.zeros(ns, np.int8)
    out_mfe = np.zeros(ns)
    taken = np.zeros(ns, np.int8)
    eq_day = np.zeros(n)
    bal = start_bal
    cur_day = -1
    day_start_bal = bal
    day_peak = 0.0
    day_stop = False
    k = 0
    for i in range(n):
        if day_id[i] != cur_day:
            cur_day = day_id[i]
            day_start_bal = bal
            day_peak = 0.0
            day_stop = False
        bid_o, bid_h, bid_l, bid_c = o[i], h[i], l[i], c[i]
        sp = spread[i]
        # ---------------- manage open positions on this bar
        for j in range(MAXP):
            if p_on[j] == 0:
                continue
            d = p_dir[j]
            R = p_r[j]
            if roll_mult[i] > 0:
                # overnight financing, charged at the NY-close rollover (x3 on Wednesday)
                p_real[j] -= (swap_long if d > 0 else swap_short) * bid_o * roll_mult[i] * p_lots[j] * contract
            closed = False
            exit_px = 0.0
            reason = 0
            # prices from the side we exit on
            if d > 0:
                ex_o, ex_h, ex_l = bid_o, bid_h, bid_l
            else:
                ex_o, ex_h, ex_l = bid_o + sp, bid_h + sp, bid_l + sp
            # stop first (conservative), gap-aware
            if d > 0 and ex_l <= p_sl[j]:
                exit_px = min(p_sl[j], ex_o) - slip; closed = True; reason = 1
            elif d < 0 and ex_h >= p_sl[j]:
                exit_px = max(p_sl[j], ex_o) + slip; closed = True; reason = 1
            elif d > 0 and ex_h >= p_tp[j]:
                exit_px = max(p_tp[j], ex_o); closed = True; reason = 2
            elif d < 0 and ex_l <= p_tp[j]:
                exit_px = min(p_tp[j], ex_o); closed = True; reason = 2
            if not closed:
                # favourable excursion at bar extreme (management applied for next bar)
                fav = (ex_h - p_entry[j]) if d > 0 else (p_entry[j] - ex_l)
                if fav > p_best[j]:
                    p_best[j] = fav
                # partial close
                if partial_frac > 0 and p_part[j] == 0 and p_best[j] >= partial_r * R:
                    px = p_entry[j] + d * partial_r * R
                    part_lots = p_lots[j] * partial_frac
                    p_real[j] += d * (px - p_entry[j]) * part_lots * contract
                    p_lots[j] -= part_lots
                    p_part[j] = 1
                # break-even
                if be_r > 0 and p_best[j] >= be_r * R:
                    nsl = p_entry[j] + d * be_lock_r * R
                    if d > 0 and nsl > p_sl[j]:
                        p_sl[j] = nsl
                    if d < 0 and nsl < p_sl[j]:
                        p_sl[j] = nsl
                # ATR trailing
                if trail_atr > 0 and p_best[j] >= trail_start_r * R:
                    if d > 0:
                        nsl = ex_h - trail_atr * atr_m1[i]
                        if nsl > p_sl[j]:
                            p_sl[j] = nsl
                    else:
                        nsl = ex_l + trail_atr * atr_m1[i]
                        if nsl < p_sl[j]:
                            p_sl[j] = nsl
                # time stop
                held = i - p_bar[j]
                cur_px = bid_c if d > 0 else bid_c + sp
                cur_r = d * (cur_px - p_entry[j]) / R
                if max_bars_m1 > 0 and held >= max_bars_m1 and cur_r < time_stop_min_r:
                    exit_px = cur_px; closed = True; reason = 3
                # friday close / intraday close
                if not closed and dow[i] == 4 and utc_h[i] >= friday_close_h:
                    exit_px = cur_px; closed = True; reason = 4
                if not closed and intraday_close_ny_h > 0 and ny_h[i] >= intraday_close_ny_h and ny_h[i] < intraday_close_ny_h + 0.5:
                    exit_px = cur_px; closed = True; reason = 5
            if closed:
                pnl = p_real[j] + d * (exit_px - p_entry[j]) * p_lots[j] * contract
                s = p_sig[j]
                out_pnl[s] = pnl
                out_R[s] = pnl / (R * p_lots0[j] * contract)
                out_exit_bar[s] = i
                out_reason[s] = reason
                out_mfe[s] = p_best[j] / R
                bal += pnl
                p_on[j] = 0
        # ---------------- account guards (equity incl. floating, at bar close)
        flo = 0.0
        for j in range(MAXP):
            if p_on[j]:
                px = c[i] if p_dir[j] > 0 else c[i] + sp
                flo += p_real[j] + p_dir[j] * (px - p_entry[j]) * p_lots[j] * contract
        realized_day = bal - day_start_bal
        if portfolio:
            if realized_day > day_peak:
                day_peak = realized_day
            cur = realized_day + flo
            hit = False
            if cur <= -daily_loss_pct / 100.0 * day_start_bal:
                hit = True
            if day_peak >= giveback_arm_pct / 100.0 * day_start_bal and day_peak > 0 and cur <= day_peak * (1.0 - giveback_pct / 100.0):
                hit = True
            if hit and not day_stop:
                day_stop = True
                for j in range(MAXP):
                    if p_on[j]:
                        d = p_dir[j]
                        px = c[i] if d > 0 else c[i] + sp
                        pnl = p_real[j] + d * (px - p_entry[j]) * p_lots[j] * contract
                        s = p_sig[j]
                        out_pnl[s] = pnl; out_R[s] = pnl / (p_r[j] * p_lots0[j] * contract)
                        out_exit_bar[s] = i; out_reason[s] = 6; out_mfe[s] = p_best[j] / p_r[j]
                        bal += pnl; p_on[j] = 0
                flo = 0.0
        eq_day[i] = bal + flo
        # ---------------- new entries scheduled at this bar's open (signals from previous close)
        while k < ns and s_idx[k] <= i:
            if s_idx[k] == i:
                d = s_dir[k]
                R = s_dist[k]
                ok = True
                nopen = 0
                for j in range(MAXP):
                    if p_on[j]:
                        nopen += 1
                        if portfolio and p_strat[j] == s_strat[k]:
                            ok = False
                if portfolio:
                    if day_stop or nopen >= max_pos:
                        ok = False
                if ok and s_risk_mult[k] <= 0:
                    ok = False
                lots = 1.0
                if ok and portfolio:
                    risk_money = (risk_pct / 100.0) * bal * s_risk_mult[k]
                    # never let a single stop breach the daily guards
                    room = daily_loss_pct / 100.0 * day_start_bal + (bal - day_start_bal) + flo
                    if day_peak >= giveback_arm_pct / 100.0 * day_start_bal and day_peak > 0:
                        room2 = (bal - day_start_bal) + flo - day_peak * (1.0 - giveback_pct / 100.0)
                        if room2 < room:
                            room = room2
                    if room * 0.9 < risk_money:
                        risk_money = room * 0.9
                    lots = np.floor(risk_money / ((R + sp) * contract) / lot_step) * lot_step
                    if lots < min_lot:
                        ok = False
                if ok:
                    for j in range(MAXP):
                        if p_on[j] == 0:
                            entry = bid_o + sp if d > 0 else bid_o
                            p_on[j] = 1; p_dir[j] = d; p_entry[j] = entry; p_r[j] = R
                            p_sl[j] = entry - d * R
                            p_tp[j] = entry + d * R * s_tp_r[k] if s_tp_r[k] > 0 else entry + d * 1e9
                            p_lots[j] = lots; p_lots0[j] = lots; p_best[j] = 0.0; p_bar[j] = i
                            p_sig[j] = k; p_part[j] = 0; p_real[j] = 0.0; p_strat[j] = s_strat[k]
                            taken[k] = 1
                            break
            k += 1
    return taken, out_R, out_exit_bar, out_pnl, out_reason, out_mfe, eq_day


DEFAULT_MGMT = dict(be_r=1.0, be_lock_r=0.1, partial_r=1.0, partial_frac=0.0, trail_start_r=1.5, trail_atr=2.5,
                    max_bars_m15=24, time_stop_min_r=0.3, friday_close_h=20.5, intraday_close_ny_h=0.0, slip=0.05)


def prepare_m1(m1: pd.DataFrame, b: pd.DataFrame, spread_floor=0.25, spread_bp=1.0):
    t = m1.index
    ny = t.tz_convert("America/New_York")
    ny_h = (ny.hour + ny.minute / 60.0).values.astype(np.float64)
    # spread model: max(floor, price*bp/10000), x3 around NY rollover
    spread = np.maximum(spread_floor, m1["close"].values * spread_bp / 10000.0)
    roll = (ny_h >= 16.9) & (ny_h < 18.25)
    spread = np.where(roll, spread * 3, spread)
    # ATR of last completed signal bar for each M1 bar
    a = pd.Series(b["atr"].values, index=pd.DatetimeIndex(b["close_time"]))
    atr_m1 = a.reindex(t, method="ffill").bfill().values
    day = t.normalize()
    day_id = np.asarray((day - day[0]).days, dtype=np.int64)
    nyk = (ny + pd.Timedelta(hours=7)).normalize()
    knum = np.asarray((nyk.tz_localize(None) - pd.Timestamp("1970-01-01")).days, dtype=np.int64)
    roll = np.zeros(len(t))
    chg = np.r_[False, knum[1:] != knum[:-1]]
    roll[chg] = 1.0
    roll[chg & (nyk.dayofweek.values == 3)] = 3.0  # Wed->Thu rollover carries the weekend
    return dict(t=t, o=m1["open"].values, h=m1["high"].values, l=m1["low"].values, c=m1["close"].values,
                spread=spread, atr_m1=atr_m1, dow=t.dayofweek.values.astype(np.int64),
                utc_h=(t.hour + t.minute / 60.0).values.astype(np.float64), ny_h=ny_h, day_id=day_id, roll=roll)


def simulate(M: dict, sig: pd.DataFrame, mgmt: dict | None = None, portfolio=False, risk_mult=None,
             start_bal=1000.0, risk_pct=2.0, daily_loss_pct=50.0, giveback_pct=40.0, giveback_arm_pct=1.0,
             max_pos=2, contract=100.0, min_lot=0.01, lot_step=0.01,
             swap_long_pa=0.05, swap_short_pa=0.01):
    mg = {**DEFAULT_MGMT, **(mgmt or {})}
    t = M["t"]
    # entry at the first M1 bar that opens at/after the signal bar close
    s_idx = np.searchsorted(t.asi8, pd.DatetimeIndex(sig["time"]).asi8, side="left")
    order = np.argsort(s_idx, kind="stable")
    sig = sig.iloc[order].reset_index(drop=True)
    s_idx = s_idx[order]
    valid = s_idx < len(t)
    sig, s_idx = sig[valid].reset_index(drop=True), s_idx[valid]
    rm = np.ones(len(sig)) if risk_mult is None else np.asarray(risk_mult, dtype=float)[order][valid]
    strat_id = sig["strat"].map({s: k for k, s in enumerate(STRATS)}).values.astype(np.int64)
    res = _simulate(M["t"].asi8 // 60_000_000_000, M["o"], M["h"], M["l"], M["c"], M["spread"], M["atr_m1"],
                    M["dow"], M["utc_h"], s_idx.astype(np.int64), sig["dir"].values.astype(np.float64),
                    sig["sl_dist"].values.astype(np.float64), sig["tp_r"].values.astype(np.float64), strat_id, rm,
                    mg["be_r"], mg["be_lock_r"], mg["partial_r"], mg["partial_frac"], mg["trail_start_r"], mg["trail_atr"],
                    int(mg["max_bars_m15"] * 15), mg["time_stop_min_r"], mg["friday_close_h"], mg["intraday_close_ny_h"],
                    M["ny_h"], portfolio, start_bal, risk_pct, daily_loss_pct, giveback_pct, giveback_arm_pct,
                    max_pos, contract, min_lot, lot_step, M["day_id"], mg["slip"], M["roll"],
                    swap_long_pa / 360.0, swap_short_pa / 360.0)
    taken, R, exit_bar, pnl, reason, mfe, eq = res
    sig = sig.copy()
    sig["taken"] = taken.astype(bool) & (exit_bar >= 0)  # drop trades still open at the end of data
    sig["R"] = R
    sig["pnl"] = pnl
    sig["reason"] = reason
    sig["mfe"] = mfe
    sig["exit_time"] = t.values[np.clip(exit_bar, 0, len(t) - 1)]
    sig["orig_order"] = order[valid]
    return sig, pd.Series(eq, index=t)


def stats(tr: pd.DataFrame) -> dict:
    tr = tr[tr["taken"]]
    if len(tr) == 0:
        return dict(n=0)
    R = tr["R"].values
    wins = R[R > 0]
    losses = R[R <= 0]
    cum = np.cumsum(R)
    dd = (np.maximum.accumulate(cum) - cum).max()
    pf = wins.sum() / -losses.sum() if losses.sum() < 0 else np.inf
    return dict(n=len(R), win=round(len(wins) / len(R) * 100, 1), avgR=round(R.mean(), 3),
                totR=round(R.sum(), 1), PF=round(pf, 2), maxDD_R=round(dd, 1))
