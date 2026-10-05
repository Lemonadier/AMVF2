# Research: how the XAUUSD AI Bot was designed

The goal was to build the best gold robot I could while respecting two account rules
(max 50% daily loss, stop after giving back 40% of the day's profit), and to test each
idea on real data before adopting it rather than trusting popular "gold EA" folklore.
This page documents the data, the method, every result that shaped a default, and the
limits of the evidence.

## 1. Data

| Period | Source | Use |
|---|---|---|
| 2011-01 → 2018-12 | HistData.com M1 bid bars (mirror: Hugging Face `fokan/xauusd-2009-2026`) | Era A: gold bear market / range |
| 2019-01 → 2026-01-09 | same | Era B: gold bull market ($1,280 → $4,500) |
| 2026-01-10 → 2026-05-22 | Tick data (`CarlosSilva1/xauusd-ticks`), resampled to M1 | **Out-of-sample** |
| 2026-05-22 → 2026-07-21 | Broker M1 bars (`hussain28/kzy-xauusd-tft`), shifted −3h to UTC | **Out-of-sample** |

Consistency checks: the tick data matched HistData exactly where they overlap. The broker
bars were labelled UTC but were really server time (UTC+3); after shifting, they matched
the tick data to $0.27 (one spread).

## 2. Cost model (applied to every simulated trade)

* **Spread:** max($0.25, 0.01% of price), i.e. about $0.40 at $4,000; **×3** around the
  New York rollover. Long trades enter at ask, shorts exit at ask.
* **Stop slippage:** $0.05 per stop exit, and gaps are filled at the worse open price.
* **Swap (overnight financing):** longs pay 5%/year of price, shorts 1%/year, charged at
  the 17:00 New York rollover, triple on Wednesday.
* **Intrabar order:** if a 1-minute bar touches both stop and target, the **stop** is
  assumed first (pessimistic).
* Entry is at the open of the bar after the signal candle closes; no look-ahead.
  Higher-timeframe values come from the last *completed* H1/H4/daily bar.

## 3. Method

1. Implement each strategy in Python (`research/xau_lib.py`) with MetaTrader's own
   indicator formulas (MT5's ATR is a simple average of true range; its ADX smooths the
   per-bar DI ratios with an EMA).
2. Simulate **every** signal on 1-minute bars to measure the raw edge in R (1R = the
   initial stop distance). Do this separately in era A and era B. A rule is kept only if
   it helps in **both** eras, so it does not depend on gold's direction.
3. Run a money simulation of the full bot (sizing, max positions, both daily rules on
   equity at every minute).
4. Test the machine-learning layer **walk-forward**: the model may only learn from trades
   that had finished before the moment it predicts.
5. **Parity test:** replay 2023–2026 through the EA's actual MQL5 code inside MetaTrader 5
   and compare with Python, signal by signal.
6. Final check on 2026 data that no decision used.

## 4. Results

### 4.1 Timeframe: 15-minute trading loses, 1-hour has an edge

Average R per trade (number of trades), fixed 2R target, no daily filter, all costs:

| Era | TF | Trend Pullback | Momentum | London Breakout | Liquidity Sweep | Mean Reversion |
|---|---|---|---|---|---|---|
| 2011-2018 | M15 | −0.079 (9,490) | −0.088 (2,143) | +0.169 (216) | −0.090 (1,442) | −0.064 (28) |
| 2011-2018 | **H1** | **+0.037** (2,976) | +0.001 (838) | +0.070 (496) | −0.029 (638) | −0.211 (14) |
| 2019-2026 | M15 | −0.041 (8,757) | −0.063 (1,810) | −0.212 (314) | −0.179 (1,211) | +0.349 (16) |
| 2019-2026 | **H1** | **+0.036** (2,740) | +0.018 (642) | −0.076 (481) | −0.087 (511) | +0.424 (15) |

On M15 the spread and slippage are 10–20% of a typical stop; on H1 they are 1–3%. An
M30 run was also negative or flat. **Decision: H1 signals.** London Breakout flips sign
between eras, Liquidity Sweep is negative in both, and Mean Reversion has too few trades
to judge: all three are **off by default**.

### 4.2 Exits: let winners run

H1, no daily filter, all costs:

| Exit | TPB 2011-18 | TPB 2019-26 | MOM 2011-18 | MOM 2019-26 |
|---|---|---|---|---|
| Fixed take-profit 2R | +0.037 | +0.036 | +0.001 | +0.018 |
| Fixed take-profit 3R | +0.051 | +0.077 | +0.034 | +0.073 |
| Break-even at 1R + trailing | +0.137 | +0.023 | +0.047 | +0.027 |
| 50% partial close at 1R + TP 3R | +0.014 | +0.032 | −0.004 | +0.035 |
| Trailing only, from 1.0R, 2×ATR | +0.079 | +0.034 | +0.050 | +0.029 |
| **Trailing only, from 1.5R, 3×ATR (default)** | **+0.179** | **+0.108** | **+0.127** | **+0.108** |
| Trailing only, from 2.0R, 3×ATR | +0.174 | +0.125 | +0.151 | +0.086 |

A wide chandelier stop with no target was best in both eras for both strategies. The
neighbouring settings (start 2.0R) are similar, so the choice is not a fragile optimum.
Break-even and partial profit-taking, both popular, cut the winners that pay for this
kind of system.

### 4.3 Direction: the edge follows the big trend

With the default exit and no daily filter, long/short average R:

| Era | Longs | Shorts |
|---|---|---|
| 2011-2018 (bear/range) | +0.02 | **+0.32** |
| 2019-2026 (bull) | **+0.22** | −0.09 |

The strategy is a genuine trend follower, not a disguised "always buy gold" bet. That is
why I did **not** make it long-only, even though that would have looked great on 2019–2026.

### 4.4 Daily trend filter

| Daily filter | TPB 2011-18 | TPB 2019-26 | MOM 2011-18 | MOM 2019-26 |
|---|---|---|---|---|
| None | +0.179 (2,977) | +0.108 (2,740) | +0.127 (838) | +0.108 (642) |
| **Close vs EMA50 (default)** | **+0.184** (2,341) | **+0.159** (2,204) | +0.124 (637) | **+0.151** (501) |
| EMA50 vs EMA200 | +0.171 (1,607) | +0.190 (1,599) | +0.219 (452) | +0.242 (388) |

The EMA50 filter improves or keeps the average in all four cells with ~20% fewer trades.
EMA50/200 is stronger on 2019–26 but halves the trade count in era A; it is available as
an option.

### 4.5 Default configuration, year by year (every signal, all costs)

| Year | Trades | Avg R | Total R | Win rate |
|---|---|---|---|---|
| 2011 | 406 | +0.155 | +62.8 | 38% |
| 2012 | 344 | +0.218 | +75.0 | 34% |
| 2013 | 328 | +0.381 | +125.0 | 45% |
| 2014 | 389 | +0.175 | +68.0 | 39% |
| 2015 | 387 | +0.212 | +82.2 | 39% |
| 2016 | 380 | +0.249 | +94.6 | 36% |
| 2017 | 334 | +0.056 | +18.8 | 36% |
| 2018 | 410 | −0.040 | −16.5 | 38% |
| 2019 | 375 | −0.084 | −31.5 | 34% |
| 2020 | 411 | +0.487 | +200.2 | 44% |
| 2021 | 349 | −0.011 | −3.8 | 34% |
| 2022 | 387 | +0.062 | +24.0 | 43% |
| 2023 | 332 | +0.105 | +35.0 | 39% |
| 2024 | 403 | +0.108 | +43.5 | 38% |
| 2025 | 433 | +0.375 | +162.3 | 44% |

12 of 15 years positive. The win rate is only 34–45%: most trades lose a little and a
few trend trades win big. **Long losing streaks are normal for this system.** Streaks of
8+ losses in a row happened about 10 times a year. In the money simulation (trades
actually taken) the longest streaks were **14 losses in a row (2011–18) and 17 (2019–26)**.
At 1% risk that is a 14–17% dip from streaks alone. Size your risk so you can sit through it.

### 4.6 Money simulation with your rules

Full bot: risk % per trade, max 2 positions (one per strategy), 50% daily loss limit and
40% **daily** giveback lock (arming at 1%; first design, closing positions when a rule
fired) checked on equity every minute, 0.01-lot granularity, $1,000 start. Max DD =
worst peak-to-trough fall of the account. For the final whole-account lock see 4.11.

| Risk/trade | 2011–2018: CAGR / max DD | 2019–2026: CAGR / max DD | Worst single day |
|---|---|---|---|
| 0.5% | +2.0% / 13.5% | +0.8% / 10.7% (*) | −1.8% |
| **1%** | **+5.5% / 33.7%** | **+10.0% / 28.8%** | −3.7% |
| 2% | +10.2% / 59.1% | +16.5% / 65.0% | −7.7% |
| 3% | +4.2% / 78.9% | +16.0% / 80.0% | −10.9% |
| 5% | **−13.1% / 96.5%** | −0.9% / 94.4% | −17.1% |

(*) With $1,000 and gold above $2,000, most trades could not be sized at 0.5% (the
minimum lot was too big), so few trades were taken. See the account-size table in the
README.

Observations:

* **Above 2% per trade, more risk earns less.** Deep drawdowns compound against you.
  At 5% the account was effectively destroyed in both eras.
* **The 50% daily limit never came close to triggering** at 1–2% per trade; it is
  a safety net for abnormal days, not something that shapes normal trading.
* **The 40% giveback lock** (your rule 2), compared with no lock:

  | Variant (1% risk) | 2011–18 final | 2019–26 final |
  |---|---|---|
  | No giveback lock | $1,533 | $1,953 |
  | **Giveback 40%, arms at 1% (default)** | **$1,533** | **$1,948** |
  | Giveback 40%, from the first dollar | $1,482 | $1,370 |

  With the 1% arming threshold your rule costs almost nothing. Applied from the very
  first dollar it cut 2019–26 profits by about 30%, because it kept closing trend trades
  during normal pullbacks. That is why the threshold exists.

### 4.7 The machine-learning layer

Walk-forward over both eras (5,485 out-of-sample trades). Trades were split into five
equal groups by the probability the model predicted *before* the trade:

| Predicted probability | Trades | Realised avg R |
|---|---|---|
| 0.13 – 0.27 | 1,097 | +0.189 |
| 0.27 – 0.33 | 1,097 | +0.197 |
| 0.33 – 0.38 | 1,097 | +0.222 |
| 0.38 – 0.43 | 1,097 | +0.158 |
| 0.43 – 0.68 | 1,097 | +0.107 |

There is no useful ranking: the "most confident" group did worst. Filtering at
p ≥ 0.30 cut total profit from 957R to 675R. The learned weights were informative,
though: they penalised entries late in an already-strong trend (high ADX, price far from
the EMAs).

**Decision:** ship the learner in **Observe** mode. It learns from every signal (shadow
trades), saves itself, and shows a live skill score. It can filter or size trades only
if you enable it after it proves itself on your broker.

A second adaptive idea, **disabling a strategy after a bad run**, was also tested:

| Strategy's recent shadow result | 2011-18 next trade avg R | 2019-26 next trade avg R |
|---|---|---|
| Very bad (EWMA < −0.2R) | **+0.463** | +0.144 |
| Bad (−0.2 to 0) | +0.200 | +0.176 |
| Good (0 to +0.2) | +0.079 | +0.156 |
| Very good (> +0.2R) | +0.009 | +0.197 |

After a losing streak the next trades were the **best** in era A. Trend systems lose
during choppy markets and then catch the next trend. So the bot does **not** turn itself
off after losses, and the "pause after N losses" option is off by default.

### 4.8 Session and weekday

| Entry time (UTC) | 2011-18 avg R | 2019-26 avg R |
|---|---|---|
| 00–07 Asia | +0.335 | +0.118 |
| 07–12 London | +0.191 | +0.103 |
| 12–16 New York | −0.001 | +0.193 |
| 16–21 late NY | +0.088 | +0.266 |

No session was consistently bad, so there is no session filter (the rollover hour, Friday
evening and Monday open are blocked for cost and gap reasons). Wednesday entries were the
weakest in both eras (+0.04 and −0.04). That fits FOMC announcements and triple swap,
both on Wednesdays, but weekday effects are notoriously unstable, so I did not hard-code a
Wednesday filter. The live news filter covers FOMC days.

### 4.9 Parity: does the EA do what was backtested?

`research/mt5/XauBot_ParityTest.mq5` replays 2023-03 → 2026-01 (16,242 H1 bars) through
the EA's own `CMarket` and `CSignals` classes inside MetaTrader 5 build 6238, on custom
symbols built from the same data. It was run twice: on a "New York close" server
(GMT+2/+3) and on an **Exness-style GMT+0 server** (with Sunday stub candles).

| | Result (both server time zones) |
|---|---|
| Close, EMA21, EMA50 | identical (relative difference < 0.0002%) |
| ATR, RSI | within 0.01–0.08% |
| Session clocks (London/NY hour) | identical |
| Previous-day high/low | identical on 95%+ of days |
| H1 trend flag | 99.99% agreement |
| **Signals (all 5 strategies)** | **1,290 common of 1,292 (MT5) / 1,298 (Python), 99.4%**; Momentum 100%, Trend Pullback 99.1% |
| GMT+0 vs GMT+2/+3 server | **identical signal lists** |

The first version used the broker's own daily candles for the daily EMA50 filter. That
gave 97% agreement and would have differed on GMT+0 brokers like Exness, whose
daily candles include a short Sunday-evening session. The EA now builds its own
New-York-close daily bars from H1 data (holiday and Sunday stubs dropped, exactly like the
research). That made the daily filter broker-independent and lifted agreement to 99.4%.

**Live-mode smoke test.** The EA was attached to a custom gold symbol in MT5 (Wine, offline)
and driven by a 1-second timer (`research/mt5/XauBot_SmokeDriver.mq5`; an offline terminal does
not deliver `OnTick`), with ticks pushed in by `XauBot_TickFeeder`. It detected bar closes on
schedule and computed indicators and the daily filter. Injected signals went through the real
feature, AI, shadow-trade, pre-trade-check and sizing code: features mirror correctly for buy and
sell, shadow trades resolved and the model learned from them, and the model was saved and
reloaded. No runtime errors. This test found and fixed one real bug: right after a terminal start,
before account data loads, the balance reads 0 and the daily-loss check fired a false all-day stop.

MetaTrader's Strategy Tester itself could not run in this environment because it requires a
broker account login. **Please run the Strategy Tester on your broker's data** (see README)
before going live.

### 4.10 Out-of-sample: January–July 2026

Default configuration, data never used for any decision:

| | Trades | Avg R | Profit factor | Win rate |
|---|---|---|---|---|
| Trend Pullback | 200 | +0.255 | 1.46 | 42% |
| Momentum | 35 | +0.171 | 1.32 | 37% |
| **All** | **235** | **+0.243** | **1.44** | 41% |

| Month 2026 | Jan | Feb | Mar | Apr | May | Jun | Jul (to 21st) |
|---|---|---|---|---|---|---|---|
| Total R | **+58.6** | −10.6 | −0.6 | +2.3 | −2.2 | +20.1 | −10.5 |

Money simulation over the same period: **+17.8% at 1% risk (max DD 10.0%)**, +40.0% at 2%
risk (max DD 21.1%). The result is real but lumpy: January's trend made the year so far;
February–July together were about flat.

### 4.11 Your setup: Exness Standard Cent, 1,900 USC, whole-account lock

`research/run_cent_account.py` and `run_cent_cycles.py`. Cent lots (0.01 lot ≈ 0.01 oz, so a
$1 gold move = 1 US cent), start 1,900 USC, 50% daily loss limit, 40% **whole-account**
giveback lock, stop = no new trades (open trades finish on their own stops), 25% min-lot
tolerance, all costs.

**A design flaw this study caught.** If trades are sized so they can never break the
account lock, the room right after the lock arms is tiny (40% of a small profit). Every
trade is then too small to place, and the bot freezes without the lock ever firing (only
14 trades in 3 years). The lock is therefore a **stop trigger only**; only the 50% daily
limit caps trade size.

**Rolling starts** (53 start dates 2011–2025, each up to 3 years; final balance in USC):

| Risk | Lock arms at | Lock fired | Median time to fire | Median | Worst 10% | Best 10% | Runs losing money | Median max DD |
|---|---|---|---|---|---|---|---|---|
| 1% | no lock | – | – | 2,186 | 1,638 | 4,346 | 34% | 27% |
| 1% | +25% | 45% | 14.5 mo | 2,264 | 1,638 | 3,914 | 23% | 16% |
| 2% | no lock | – | – | 2,127 | 1,233 | 9,726 | 40% | 53% |
| 2% | +1% | 94% | 0.8 mo | 1,964 | 1,902 | 2,445 | 9% | 8% |
| 2% | +10% | 89% | 2.6 mo | 2,110 | 2,010 | 2,659 | 8% | 14% |
| **2%** | **+25%** | **81%** | **7.8 mo** | **2,277** | **1,993** | **3,360** | **9%** | **22%** |
| 3% | no lock | – | – | 1,748 | 810 | 19,032 | 55% | 70% |
| 3% | +25% | 81% | 4.3 mo | 2,364 | 1,420 | 3,803 | 13% | 25% |

At 1% risk the minimum lot is usually too large for the 1,900 USC balance, so most signals
are skipped and the lock rarely arms. 2% with arming at +25% gives the best balance:
the lock usually fires with a gain of about 20%, and only 9% of runs ended below the start.

**With 50% wider spreads** (cent accounts often quote wider): practically unchanged, because
H1 stops (~$37) are about 60× the spread.

**Restarting immediately after every lock** (continuous run, 1,900 USC start):

| Period | Risk | No lock | Lock +25%, restart next day |
|---|---|---|---|
| 2011–2018 | 1% | 3,000 (max DD 35%) | 2,998 |
| 2011–2018 | 2% | 3,346 (max DD 60%) | 3,342 |
| 2019–2026 | 1% | 5,644 (max DD 39%) | 5,644 |
| 2019–2026 | 2% | 10,997 (max DD 68%) | 11,631 |

If you restart right away, the lock changes almost nothing in the long run, because the
edge comes from the strategy. Its value is in what you do when it fires: **bank the
profit** (withdraw or keep it aside) before starting the next round.

## 5. Limits of this research. Read before trusting any number

* **Backtests are not the future.** Gold's behaviour can change: central-bank buying,
  rates, wars. The edge is modest (+0.1 to +0.2R per trade). A worse broker (wide
  spreads, slippage, high swaps) can erase a large part of it.
* **Your broker differs from my cost model.** Check your real spread, commission and
  swap and run the MT5 tester on your broker's data.
* **Drawdowns will happen.** Even at 1% risk, expect 20–35% drawdowns and losing years
  (2018, 2019 and 2021 were slightly negative).
* **Small accounts cannot follow the sizing.** Below about $3,700 at 1% risk, the
  minimum lot is too large for many signals.
* **The daily rules limit losses per day, not over weeks.** Several bad days in a row can
  still add up. Risk per trade is what controls that.

## 6. Reproducing

```bash
cd research
pip install pandas numpy numba pyarrow
# data: HistData M1 csv files into data/hd (see README in research/)
python run_research.py --hd data/hd                  # timeframe x stop x exit grid
python run_summary.py                                # the tables on this page (edit paths)
python run_ai_eval.py --data data/hd_old:2011-01-01 --data data/hd:2019-01-01
python run_portfolio.py --data data/hd:2019-01-01    # money simulation with the rules
python run_oos.py data/oos/full_2023_2026.pkl 2026-01-10
python parity_check.py <MT5 MQL5/Files folder> data/hd
```
