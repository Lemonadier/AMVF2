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
| **1. "I can risk 50% of balance per day"** | At the start of each trading day the bot records the balance. If the day's result (closed trades **plus** open trades) reaches **−50%** of that balance, it closes its positions and stops opening trades until the next day. Every new trade is also sized so that, even if all open stops are hit, the 50% limit cannot be crossed. |
| **2. "Keep trading until loss = 40% of net profit"** | The bot tracks the day's best net profit (the peak). It keeps trading normally. When the day gives back **40% of that peak** it closes its positions and stops for the day. Example: day profit reaches **+$100**; if it falls back to **+$60** (a $40 giveback), trading stops. If profit first grows to +$250, the stop moves up to +$150. |

Details that matter:

* **When the profit lock starts.** It switches on once the day's profit reaches **1% of
  the balance** (`InpGivebackArmPct`). Without this threshold, a first +$3 win followed
  by a $1.20 dip would stop the bot for the whole day. Set it to `0` if you want the rule
  to apply from the very first dollar.
* **How "net profit" is measured.** By default the peak counts **closed (banked)** profit,
  while the giveback check counts closed **plus floating** P/L. So a winning open trade
  that pulls back does not stop the day, but open losses do count. You can switch the
  peak to closed+floating (`InpPeakBasis`).
* **It cannot be bypassed by restarting.** The daily numbers are rebuilt from the
  account's deal history, and a stop is stored in the terminal, so re-attaching the
  bot or restarting MetaTrader does not reset a stopped day.

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
through the EA's own code inside MetaTrader produced the **same signals 97% of the time**
(the rest differ by tiny indicator rounding near thresholds).

## Quick start

1. **Copy the files** into your MetaTrader 5 data folder
   (in MT5: *File → Open Data Folder*):
   * `MQL5/Experts/XAUUSD_AI_Bot/` (whole folder) → `MQL5/Experts/`
   * `MQL5/Scripts/XauBot_NewsExport.mq5` → `MQL5/Scripts/`
   * `MQL5/Presets/*.set` → `MQL5/Presets/` (optional)
2. In MT5 open the **Navigator**, right-click *Expert Advisors → Refresh*. If you see no
   `XAUUSD_AI_Bot`, open `XAUUSD_AI_Bot.mq5` in MetaEditor and press **F7** (Compile).
3. Open an **XAUUSD, H1** chart (any timeframe works; the bot uses H1 internally).
   The symbol may be called `XAUUSD`, `XAUUSDm`, `XAUUSD.r`, `GOLD`… The bot refuses to run on
   anything that is not gold quoted in USD.
4. Drag the bot onto the chart. In **Common** tick *Allow Algo Trading*. In **Inputs**
   review section 1 and 2 (your rules and risk per trade). Click OK.
5. Press the **Algo Trading** button in the toolbar (it must be green).
6. The status panel appears top-left on the chart. Watch it on a **demo** account first.

### Account size

At gold prices around $4,000–4,500 the bot's typical stop is **$25–60 per ounce**
(median about $37). The smallest trade (0.01 lot = 1 oz) therefore risks about **$37**.

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
  capped by the room left under your daily rules, by free margin, and by max lot.
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
   Pepperstone, FP Markets, Vantage, XM and most others). If your broker's server
   runs on GMT+0 (for example Exness), set *7. Time zone → Manual* and offset `0`.
   Live trading detects the offset automatically.
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
| Loss limit / room left | Distance to the −50% daily stop |
| Profit lock | Shows the day's peak and the level at which the 40% giveback stop fires |
| STATUS | TRADING, or STOPPED with the reason until the next day |
| H1 trend / ADX / ATR / spread | What the bot sees right now |
| News | Next high-impact event, or PAUSED during a news window |
| AI calibration / skill | Predicted vs. real hit rate; **skill > 0** means the model beats guessing |
| Shadow trades per strategy | Live track record of every signal, taken or not |

## Repository layout

```
MQL5/Experts/XAUUSD_AI_Bot/       the robot (main file + Include/ modules, compiled .ex5)
MQL5/Scripts/XauBot_NewsExport    exports the news calendar for the Strategy Tester
MQL5/Presets/                     Conservative (0.5%) / Balanced (1%) / Aggressive (2%)
docs/SETTINGS.md                  every input explained
docs/RESEARCH.md                  how the strategy was chosen, all results
research/                         Python backtester, data downloader, parity test tools
```

## Things to decide (tell me and I will adjust)

1. **Which broker and account type?** (symbol name, server time zone, commission, cent or
   standard account). This affects the time zone setting, sizing and the realistic minimum
   balance.
2. **Your balance?** If it is below about $3,700 at 1% risk, many trades will be skipped.
   Options: a cent account, 2% risk, or accept fewer trades.
3. **Profit lock scope.** I applied rule 2 **per day**, with the daily reset at broker
   midnight. Did you mean per day, or across the whole account history?
4. **Close or hold on a daily stop?** By default, when a daily rule fires, the bot closes
   its open trades. The alternative (`InpCloseOnStop = false`) only blocks new trades and
   lets open ones finish. That can lose more than the rule allows, but it does not cut
   trend trades short.
5. **MetaTrader 4?** This bot is MetaTrader 5. An MT4 version needs a port.
