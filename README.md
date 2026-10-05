# XAUUSD AI Bot for MetaTrader 5

An automated trading robot (Expert Advisor) for **gold (XAUUSD) only**. It is built
around your two account rules and a trend-following engine that I tested on
**15 years of 1-minute gold data (2011 to July 2026)** before writing a single default.

> **Risk warning.** Gold is one of the most volatile instruments retail traders can
> trade, and leverage can wipe out an account in days. No bot, this one included,
> guarantees profit. Past results, including every number in this repository, do not
> predict future results. Run it on a **demo account** for several weeks first.

---

## Your rules: how the bot applies them

| Your rule | What the bot does |
|---|---|
| **1. "I can risk 50% of balance per day"** | The bot records the balance at the start of each day. If the day's result (closed trades **plus** open trades) reaches **−50%** of it, the bot **stops opening trades** until the next day. Every new trade is sized so that, even if all open stops are hit together, the day cannot lose more than 50%. |
| **2. "Keep trading until loss = 40% of net profit" — whole account** | The bot tracks the account's **best net profit since the bot started** (or since you last reset it). It keeps trading normally. When **40% of that best profit** has been given back, it **stops opening trades** and stays stopped until you reset it. Example: profit grows to **+$100**; when it falls back to **+$60**, trading stops. If profit first reaches +$250, the stop moves up to +$150. |
| **"Stop open trades"** | When either rule fires, the bot **only stops opening new trades**. Trades already open keep their stop-loss and trailing stop and finish normally. Set `InpCloseOnStop = true` if you would rather have them closed immediately. |

Details that matter:

* **When the account lock starts (arms).** It arms once the account profit reaches **+25% of
  the starting balance** (`InpGivebackArmPct`). With 1,900 USC that means +475 USC. Then 40%
  of the best profit may be given back. Why not from the first cent? In a 15-year
  simulation, arming at +1% stopped the bot after about 12 trades, almost always with
  nothing gained (see below).
* **What "net profit" means.** The best profit counts **closed (banked)** profit; the
  giveback check counts closed **plus floating** P/L. A winning open trade that pulls back
  does not stop the bot, but open losses do count. Deposits and withdrawals are ignored;
  only trading results count.
* **Restarting after the lock fires.** The bot stays stopped (dashboard: *STOPPED - ACCOUNT
  PROFIT LOCK*). To start a new round, open the bot's settings, set *Reset the account
  profit lock* = **true**, press OK, then set it back to **false** later. Or set
  `InpLockAutoRestartDays` to restart automatically after N days.
* **Restarting MetaTrader does not reset anything.** Daily totals are rebuilt from the deal
  history, and the account lock state is stored in MT5's common files folder.

## What the research found (short version)

Full details, tables and method: **[docs/RESEARCH.md](docs/RESEARCH.md)**.

1. **15-minute gold strategies lose money after costs.** The spread is 10–20% of a
   15-minute stop. On the 1-hour chart it falls to 1–3%, which is why the bot trades H1.
2. **Two strategies have a real, repeatable edge on H1: Trend Pullback and Donchian
   Momentum.** They made money in the 2011–2018 bear market (mostly from shorts) **and** in
   the 2019–2026 bull market (mostly from longs). In other words, they follow whichever way
   the big trend runs.
3. **London breakout and liquidity-sweep reversal lost money** on every timeframe I tested.
   They are in the code but **off** by default.
4. **Letting winners run beats taking profit early.** A 3×ATR trailing stop with no
   fixed target was the best exit in both eras. Moving the stop to break-even or closing
   half at +1R made results **worse**.
5. **Risk per trade decides whether the account survives.** With 1% risk per trade the
   worst drawdown was about 30–35%; with 2% about 60–65%; with 3% about 80%; **5% destroyed the
   account**. Your 50% daily limit almost never triggers at 1–2% per trade (the worst
   single day in 15 years was −7.7% at 2%).
6. **The machine-learning filter did not help** on these strategies (walk-forward test,
   2011–2026). The bot therefore ships the AI in **observe mode**: it learns from every
   signal and shows on the chart whether it is actually predicting anything. You can
   switch it to filter mode later, once it proves itself on your broker's data.
7. **Out-of-sample check (Jan–Jul 2026, data I never used for any decision):**
   +0.24R per trade over 235 signals (profit factor 1.44). The money simulation at 1%
   risk gained +17.8% over those 7 months with a 10% max drawdown. Most of that came from January's trend;
   February–July were roughly flat. **Expect long flat or losing stretches between trends.**
   The win rate is only about 40%, and runs of 14–17 losing trades in a row occurred in the
   simulations.

The Python backtester and the EA were checked against each other: replaying 2023–2026
through the EA's own code inside MetaTrader produced the **same signals 99.4% of the time**.
The result was identical on an Exness-style GMT+0 server and on a GMT+2/+3 server.

## Your setup: Exness Standard Cent, XAUUSDc, 1,900 USC

**Use the preset `XauBot_Exness_Cent.set`** (Inputs tab → *Load*). It sets: risk 2% per trade,
50% daily loss limit, 40% whole-account giveback lock arming at +25%, stop = no new trades
(open trades keep running), and time zone Manual GMT+0 (Exness server time).

What your account size means:

* On a cent account **0.01 lot of XAUUSDc ≈ 0.01 oz**, so a $1 move in gold = **1 US cent**.
  A typical stop of the bot is $25–60 (median ~$37), so the **smallest trade (0.01 lot)
  risks about 25–60 cents = 1.3–3.2% of 1,900 USC**. The bot cannot trade smaller than that.
* That is why the preset uses **2% risk**: at 1% the bot would skip ~90% of signals until
  the balance grows (it never over-risks to force a trade). With 2% plus the 25% tolerance,
  each trade risks at most ~2.5% (47 cents), and trades with very wide stops are skipped.
* The bot sizes from Exness's own tick values (`OrderCalcProfit`), so it always uses the real
  contract size of your symbol.

Simulation of exactly this setup (start 1,900 USC, cent lots, 2% risk, your rules,
53 different start dates 2011–2025, each run for up to 3 years, all costs):

| Account lock | Lock fired | Typical time to fire | Typical result | Bad case (worst 10%) | Good case (best 10%) | Runs that lost money |
|---|---|---|---|---|---|---|
| None | – | – | 2,127 USC | 1,233 USC | 9,726 USC | 40% |
| Arms at +1% | 94% | under 1 month | 1,964 USC | 1,902 USC | 2,445 USC | 9% |
| Arms at +10% | 89% | 2.6 months | 2,110 USC | 2,010 USC | 2,659 USC | 8% |
| **Arms at +25% (preset)** | **81%** | **7.8 months** | **2,277 USC (+20%)** | **1,993 USC** | **3,360 USC** | **9%** |

How to read this: **your lock turns the bot into "grow the account, bank a gain, stop".**
Without the lock, results are far more spread out (both bigger wins and many more losses).
**What you do after the lock fires matters most.** If you withdraw (or keep aside) the
profit and then reset, you keep the gain. If you reset and let it keep trading the whole
balance, the long-run result is the same as having no lock (15-year simulation with
immediate restarts: 1,900 → ~3,350 USC in 2011–18 and ~11,000 USC in 2019–26, with
drawdowns of 60–68% along the way).

**Important for a 1,900 USC account:** drawdowns of 50–60% happened at 2% risk. Treat the
balance as money you can fully lose, and watch it on a demo cent account first.

## Quick start

1. **Copy the files** into your MetaTrader 5 data folder
   (in MT5: *File → Open Data Folder*):
   * `MQL5/Experts/XAUUSD_AI_Bot/` (whole folder) → `MQL5/Experts/`
   * `MQL5/Scripts/XauBot_NewsExport.mq5` → `MQL5/Scripts/`
   * `MQL5/Presets/*.set` → `MQL5/Presets/` (optional)
2. In MT5 open the **Navigator**, right-click *Expert Advisors → Refresh*. If you see no
   `XAUUSD_AI_Bot`, open `XAUUSD_AI_Bot.mq5` in MetaEditor and press **F7** (Compile).
3. Open an **XAUUSD, H1** chart (any timeframe works; the bot uses H1 internally).
   The symbol may be called `XAUUSDc` (Exness cent), `XAUUSD`, `XAUUSDm`, `XAUUSD.r`, `GOLD`…
   The bot refuses to run on anything that is not gold quoted in USD.
4. Drag the bot onto the chart. In **Common** tick *Allow Algo Trading*. In **Inputs** click
   **Load** and choose `XauBot_Exness_Cent.set` (or review sections 1 and 2 yourself). Click OK.
5. Press the **Algo Trading** button in the toolbar (it must be green).
6. The status panel appears top-left on the chart. Watch it on a **demo** account first.

### Account size (standard accounts)

At gold prices around $4,000–4,500 the bot's typical stop is **$25–60 per ounce**
(median about $37). On a standard account the smallest trade (0.01 lot = 1 oz) therefore
risks about **$37**. (Cent accounts: see the section above.)

| Risk per trade | Balance needed for the minimum lot |
|---|---|
| 0.5% | about $7,400 |
| **1% (default)** | **about $3,700** |
| 2% | about $1,850 |

With a smaller balance the bot skips trades it cannot size safely ("account too small"
in the log) instead of over-risking. On small balances, use a **cent account** (if your
broker offers gold on cent accounts) or accept that many signals will be skipped.

## How the bot trades

* **Timeframe:** signals on closed H1 candles; the stop is managed on every tick.
* **Trend Pullback (TPB):** H1 uptrend (price > EMA50 > EMA200, EMA50 rising), price pulls
  back to the 21-EMA without breaking the 50-EMA, then an H1 candle closes strongly back up
  (above the previous high, RSI 45–70). Mirror image for shorts.
* **Donchian Momentum (MOM):** in a strong trend (ADX > 25 and rising) price closes beyond
  the 20-bar high/low on a wide range candle (≥ 1.2×ATR).
* **Daily filter:** buys only when the daily close is above its 50-day EMA, sells only
  below it.
* **Stop loss:** behind the pullback swing (TPB) or 1.5×ATR (MOM), never closer than 0.8×ATR;
  skipped if the logical stop would be farther than 3×ATR.
* **Exit:** once a trade is +1.5R in profit, a trailing stop follows 3×ATR behind the best
  price. No fixed take-profit. Everything is closed Friday 20:30 UTC (weekend gap risk).
* **Filters:** no new trades within 30 min of high-impact USD news (MT5 calendar), around the
  New York rollover (wide spreads), late Friday, Monday open, or when the spread is wider
  than $1.00 or 10% of ATR.
* **Position sizing:** risk % of balance per trade, using the broker's own tick values,
  capped so that all open stops together cannot break the 50% daily limit, by free margin,
  and by max lot. (The profit lock is a stop trigger only; it does not shrink trades.)
* **AI layer:** an online logistic-regression model learns from "shadow trades" (every
  signal, taken or not, followed for 48 hours with a −1R stop and +2R target). It
  never peeks at the future, saves itself to disk, and keeps learning live. Modes:
  *Off*, *Observe* (default), *Filter*, *Filter + size*. See
  [docs/SETTINGS.md](docs/SETTINGS.md#5-ai--online-learning).

## Testing in the MT5 Strategy Tester

1. *View → Strategy Tester*, choose **XAUUSD_AI_Bot**, your gold symbol, **H1**,
   modelling **"1 minute OHLC"** or better, deposit e.g. 10,000 USD.
2. **Time zone:** the tester cannot detect your broker's time zone. The default assumes
   the common "New York close" server time (GMT+2 winter / GMT+3 summer: IC Markets,
   Pepperstone, FP Markets, Vantage, XM and most others). **Exness runs on GMT+0**: the
   Exness preset already sets *7. Time zone → Manual* with offset `0`. Live trading detects
   the offset automatically either way.
3. **News in the tester:** MT5's calendar does not work in the tester. Run the script
   `XauBot_NewsExport` once on a live/demo chart; it writes `XauBot_news.csv` to the common
   folder and the tester then uses real news times. Without it, the tester only avoids the
   US jobs report (NFP).
4. **Training the AI in the tester:** a test run saves the learned model to
   `Common\Files\XauBot_<magic>_model.bin`. A live chart with the same magic number loads
   it automatically and keeps learning.
5. Optimisation: the custom criterion (*Custom max*) rewards profit factor and number of
   trades and penalises drawdown. Optimise sparingly; the defaults come from research
   designed to avoid curve-fitting.

## The status panel

| Line | Meaning |
|---|---|
| Day start balance / Day net P/L | Basis for your rules; net = closed + open |
| Day loss limit / room left | Distance to the −50% daily stop |
| Account lock | Account profit since the start date, the arming level, then the best profit and the level where the 40% giveback stop fires |
| STATUS | TRADING; STOPPED (daily loss, until next day); or STOPPED - ACCOUNT PROFIT LOCK (until you reset) |
| H1 trend / ADX / ATR / spread | What the bot sees right now |
| News | Next high-impact event, or PAUSED during a news window |
| AI calibration / skill | Predicted vs. real hit rate; **skill > 0** means the model beats guessing |
| Shadow trades per strategy | Live track record of every signal, taken or not |

## Repository layout

```
MQL5/Experts/XAUUSD_AI_Bot/       the robot (main file + Include/ modules, compiled .ex5)
MQL5/Scripts/XauBot_NewsExport    exports the news calendar for the Strategy Tester
MQL5/Presets/                     Exness_Cent (your setup) / Conservative (0.5%) / Balanced (1%) / Aggressive (2%)
docs/SETTINGS.md                  every input explained
docs/RESEARCH.md                  how the strategy was chosen, all results
research/                         Python backtester, data downloader, parity test tools
```

## Your answers and what changed

| You said | Change in the bot |
|---|---|
| Exness Standard Cent, XAUUSDc | Preset `XauBot_Exness_Cent.set`; GMT+0 time zone. Daily bars are now built on the New York calendar from H1 data, so Exness's Sunday candle no longer affects the daily trend filter (signals identical to a GMT+2/+3 broker). Slippage is set in USD, so 3-digit gold quotes work. |
| 1,900 cents | 2% risk in the preset; the minimum lot already risks ~2% on a typical trade. |
| Rule 2 = whole account | Profit giveback lock now tracks the whole account since the bot started (or since a date you choose), stays stopped until you reset it, and arms at +25%. The per-day version is still available (`InpGivebackScope`). |
| Stop open(ing) trades | `InpCloseOnStop = false`: when a rule fires, no new trades; open trades finish on their own stops. |
| MT5 (MT4 optional) | Kept on MT5, which you use. An MT4 port would be untested code; ask if you ever switch. |
