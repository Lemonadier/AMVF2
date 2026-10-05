"""Online learner used by the EA, replayed walk-forward in Python.

The EA keeps a logistic-regression model that is updated every time a
"shadow trade" resolves. A shadow trade is opened for EVERY signal (taken or
not) with a fixed stop (-1R) and a fixed target (+label_r R); its label is
1 if the target is touched first, 0 if the stop is, and a soft value in
between if neither happens within the horizon. Learning from all signals,
not only the executed ones, removes the selection bias of learning only from
trades the model itself allowed.
"""
from __future__ import annotations

import heapq

import numpy as np
from numba import njit


@njit(cache=True)
def shadow_labels(o, h, l, c, spread, s_idx, s_dir, s_dist, label_r, horizon):
    """First-touch outcome of a fixed -1R / +label_r R bracket, on M1 bars."""
    n = len(c)
    ns = len(s_idx)
    y = np.zeros(ns)
    r_out = np.zeros(ns)
    res = np.zeros(ns, np.int64)
    for k in range(ns):
        i0 = s_idx[k]
        d = s_dir[k]
        R = s_dist[k]
        if i0 >= n:
            res[k] = n - 1
            y[k] = 0.5
            continue
        # entry at bar open (ask for buys)
        entry = (o[i0] + spread[i0]) if d > 0 else o[i0]
        sl = entry - d * R
        tp = entry + d * label_r * R
        done = False
        last = min(n, i0 + horizon)
        for i in range(i0, last):
            if d > 0:
                lo = l[i]; hi = h[i]
                if lo <= sl:
                    y[k] = 0.0; r_out[k] = -1.0; res[k] = i; done = True; break
                if hi >= tp:
                    y[k] = 1.0; r_out[k] = label_r; res[k] = i; done = True; break
            else:
                lo = l[i] + spread[i]; hi = h[i] + spread[i]
                if hi >= sl:
                    y[k] = 0.0; r_out[k] = -1.0; res[k] = i; done = True; break
                if lo <= tp:
                    y[k] = 1.0; r_out[k] = label_r; res[k] = i; done = True; break
        if not done:
            i = last - 1
            px = c[i] if d > 0 else c[i] + spread[i]
            r = d * (px - entry) / R
            r_out[k] = r
            y[k] = min(1.0, max(0.0, (r + 1.0) / (label_r + 1.0)))
            res[k] = i
    return y, r_out, res


class OnlineLogit:
    """Same update rule as CLearner in the EA (SGD with L2, no decay on bias)."""

    def __init__(self, nfeat: int, lr: float = 0.02, l2: float = 0.0005):
        self.w = np.zeros(nfeat)
        self.w[0] = -0.7  # prior ~33% chance of +2R before -1R, same as the EA
        self.lr = lr
        self.l2 = l2
        self.n = 0

    def predict(self, x: np.ndarray) -> float:
        z = float(np.clip(self.w @ x, -30, 30))
        return 1.0 / (1.0 + np.exp(-z))

    def update(self, x: np.ndarray, y: float):
        p = self.predict(x)
        g = (y - p) * x
        reg = self.l2 * self.w
        reg[0] = 0.0
        self.w += self.lr * (g - reg)
        self.n += 1


def walk_forward(X: np.ndarray, sig_m1_idx: np.ndarray, res_m1_idx: np.ndarray, y: np.ndarray,
                 strat_r: np.ndarray, strat_id: np.ndarray, lr=0.02, l2=0.0005, ewma_alpha=0.05):
    """Predict each signal using only shadows resolved before it. Returns p and per-strategy EWMA of R."""
    order = np.argsort(sig_m1_idx, kind="stable")
    model = OnlineLogit(X.shape[1], lr, l2)
    pending: list = []
    p_out = np.full(len(y), np.nan)
    n_seen = np.zeros(len(y), np.int64)
    ewma_out = np.zeros(len(y))
    ewma = {}
    cnt = {}
    for k in order:
        t = sig_m1_idx[k]
        while pending and pending[0][0] < t:
            _, j = heapq.heappop(pending)
            model.update(X[j], y[j])
            s = strat_id[j]
            ewma[s] = (1 - ewma_alpha) * ewma.get(s, 0.0) + ewma_alpha * strat_r[j]
            cnt[s] = cnt.get(s, 0) + 1
        p_out[k] = model.predict(X[k])
        n_seen[k] = model.n
        ewma_out[k] = ewma.get(strat_id[k], 0.0) if cnt.get(strat_id[k], 0) >= 30 else 0.0
        heapq.heappush(pending, (res_m1_idx[k], k))
    return p_out, n_seen, ewma_out, model
