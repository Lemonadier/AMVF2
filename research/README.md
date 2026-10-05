# Research tools

Python backtester and MetaTrader helpers used to design and verify the EA.
Results and conclusions: [../docs/RESEARCH.md](../docs/RESEARCH.md).

| File | Purpose |
|---|---|
| `xau_lib.py` | Data loading (HistData / Dukascopy), MT5-identical indicators, the 5 strategy signal generators, feature vector, numba M1 trade simulator (spread, slippage, swap, trailing, partials, daily guards). |
| `xau_ai.py` | Shadow-trade labelling and the walk-forward replay of the EA's online learner. |
| `run_research.py` | Timeframe × stop × exit grid per strategy and year. |
| `run_summary.py` | Generates the tables in docs/RESEARCH.md. |
| `run_ai_eval.py` | Does the online learner add value? (walk-forward) |
| `run_portfolio.py` | Money simulation with risk per trade and both daily rules. |
| `run_oos.py` | Out-of-sample check of the defaults. |
| `parity_check.py` | Compares the EA's own signals (from `mt5/XauBot_ParityTest`) with Python. |
| `download_dukascopy.py` | Free Dukascopy M1 downloader (rate-limited and slow, but resumable). |
| `mt5/XauBot_ImportGold.mq5` | Builds a custom gold symbol in MT5 from an M1 CSV. |
| `mt5/XauBot_ParityTest.mq5` | Replays history through the EA's `CMarket`/`CSignals` and writes all signals. |
| `mt5/XauBot_TickFeeder.mq5` | Pushes synthetic ticks into a custom symbol for an offline live-mode smoke test. |

## Data

* HistData M1 (2009 – Jan 2026) mirrored on Hugging Face:
  `https://huggingface.co/datasets/fokan/xauusd-2009-2026/resolve/main/DAT_MT_XAUUSD_M1_<YEAR>.csv`
  Put the files into one folder per era (for example `data/hd_old` for 2011–2018 and `data/hd` for 2019+).
  Timestamps are EST without daylight saving (UTC−5); the loader converts them.
* Dukascopy: `python download_dukascopy.py --start 2026-01-01 --out data/m1` (bid M1, UTC).

```bash
pip install pandas numpy numba pyarrow
python run_research.py --hd data/hd --tfs 15min,1h
python run_portfolio.py --data data/hd:2019-01-01
```
