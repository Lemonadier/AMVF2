# Settings reference

Every input of `XAUUSD_AI_Bot`, grouped as in the MT5 inputs dialog. Defaults come from
the research in [RESEARCH.md](RESEARCH.md). If a setting says "research: hurts", turning it
on made the 2011–2026 results worse.

## 1. Your account rules

| Input | Default | Meaning |
|---|---|---|
| `InpDailyMaxLossPct` | 50 | Max loss per day as % of the day-start balance, measured on closed + open P/L. New trades are sized so all open stops together cannot break it. |
| `InpGivebackScope` | Whole account | Where rule 2 applies. *Whole account*: profit since the bot started (or `InpAccountStartDate`), stays stopped until you reset it. *Each trading day*: profit of the day, the stop ends the next day. *Off*. |
| `InpGivebackPct` | 40 | Stop after giving back this % of the best net profit (profit $100 → stop at $60). |
| `InpGivebackArmPct` | 25 | The lock arms once profit reaches this % of the starting balance (account scope) or of the day-start balance (day scope; use about 1 there). Lower values stop the bot very early: arming at 1% stopped it after ~12 trades in simulation. |
| `InpPeakBasis` | Closed profit | How the best profit is measured. *Closed (banked) profit*: an open winner swinging back does not count as giveback. *Closed + floating*: stricter. |
| `InpResetAccountLock` | false | Set to **true** and press OK to start a new round: baseline = now, lock cleared. It acts once; set it back to false afterwards (the bot reminds you). |
| `InpAccountStartDate` | 0 | Count account profit from this date instead of from when the bot first started. Example: the date you deposited. |
| `InpLockAutoRestartDays` | 0 | Restart automatically this many days after the account lock fires (new baseline = that moment). 0 = only by manual reset. |
| `InpCloseOnStop` | false | When a rule fires: *false* = only stop opening new trades, open trades keep their stops; *true* = also close the bot's open trades. |
| `InpAccountWidePnL` | true | Rules use the whole account's P/L (all symbols, manual trades too). `false` = only this bot's trades. The bot only ever closes **its own** positions. |
| `InpDayResetHour` | 0 | Server hour when a new trading day starts (Exness: 0 = 00:00 UTC). |

## 2. Position sizing

| Input | Default | Meaning |
|---|---|---|
| `InpRiskPerTradePct` | 1.0 | Money lost if the stop is hit, as % of balance. Research: 1% → ~30–35% worst drawdown, 2% → ~60–65%, 3% → ~80%, 5% → account wiped. |
| `InpCommissionPerLot` | 0 | Round-turn commission per 1.0 lot in account currency (e.g. 7). Included in sizing. |
| `InpMinLotOverRiskPct` | 25 | If even the minimum lot risks more than planned, still trade it when the excess is at most this % (and it fits the daily limit). Otherwise skip. On a 1,900 USC cent account at 2% risk this allows trades with stops up to ~$47. |
| `InpMaxLot` | 0 | Hard cap on lots per trade (0 = broker maximum). |
| `InpMaxMarginUsePct` | 50 | A new trade may use at most this % of free margin; lots are reduced to fit. |
| `InpMaxOpenPositions` | 2 | Max simultaneous positions (also max one per strategy). Netting accounts: always 1. |
| `InpMaxTradesPerDay` | 8 | Max new trades per day. |
| `InpSizeToGuardRoom` | true | Shrinks a trade so that, even if every open stop is hit, the 50% daily loss limit cannot be breached. (The profit giveback lock is a stop trigger only. Sizing to its small early room would freeze the bot.) |

## 3. Strategies

| Input | Default | Meaning |
|---|---|---|
| `InpSignalTF` | H1 | Timeframe of the signal candles. Research: M15 and M30 lost money after costs. |
| `InpUseTrendPullback` | true | Trend Pullback (TPB). Profitable in 2011–18 and 2019–26. |
| `InpUseMomentum` | true | Donchian Momentum (MOM). Profitable in 2011–18 and 2019–26. |
| `InpUseLondonBreakout` | false | Breakout of the Asian range in the London morning. Mixed: positive 2011–18, negative 2019–26. |
| `InpUseLiquiditySweep` | false | Reversal after a sweep of the previous-day or Asian high/low. Negative in both eras. |
| `InpUseMeanReversion` | false | Bollinger re-entry in a range. Fewer than 20 trades in 8 years, so there is no evidence either way. |
| `InpD1Filter` | Close vs EMA50 | Buy only if the daily close is above the 50-day EMA, sell only below it. *EMA50 vs EMA200* trades less with a higher average; *None* trades more. |
| `InpSLMinATR` / `InpSLMaxATR` | 0.8 / 3.0 | Stop distance limits in ATR. A setup whose logical stop is farther than the max is skipped. |
| `InpTP_TPB`, `InpTP_MOM` | 0 | Take-profit in R; 0 = no target, exit by trailing stop (the best option in research). |
| `InpTP_LBO`, `InpTP_LSR`, `InpTP_MR` | 2 / 2 / 1.5 | Targets for the experimental strategies. |
| `InpMomAdxMin` / `InpMomRangeATR` | 25 / 1.2 | Momentum needs ADX above this and a breakout candle at least this many ATR long. |

## 4. Trade management

| Input | Default | Meaning |
|---|---|---|
| `InpTrailStartR` | 1.5 | Trailing starts once the trade has been this many R in profit. |
| `InpTrailATR` | 3.0 | Trailing stop distance behind the best price, in ATR of the signal timeframe (chandelier stop). |
| `InpBreakEvenR` | 0 (off) | Move the stop to break-even at +R. Research: hurts trend trades. |
| `InpBreakEvenLockR` | 0.1 | Profit locked by the break-even move. |
| `InpPartialCloseR` / `InpPartialClosePct` | 1.0 / 0 (off) | Close a % of the position at +R. Research: hurts. |
| `InpMaxHoldBars` / `InpTimeStopMinR` | 0 (off) / 0 | Close a trade after N signal bars if it is below the given R. |
| `InpFridayCloseUTC` | 20.5 | Close everything on Friday at this UTC hour (gold closes 21:00/22:00 UTC) to avoid weekend gaps. |

## 5. AI / online learning

The model estimates, for each signal, the probability that price reaches **+2R before −1R**.
It learns from *shadow trades*: every signal, taken or not, is followed on 1-minute bars
until it hits +2R, −1R or the 48-bar horizon. That removes the bias of learning only from
the trades the model allowed. The panel shows its calibration (predicted vs. actual hit
rate) and a **skill score** (>0 = better than always guessing the average).

| Input | Default | Meaning |
|---|---|---|
| `InpAIMode` | Observe | *Off*; *Observe* (learn and report, never block); *Filter* (skip signals below `InpAIMinProb`); *Filter + size* (also scale the position by probability between `InpAIMinMult` and `InpAIMaxMult`). |
| `InpAIMinSamples` | 100 | The model may only filter or size after this many learned shadow trades. |
| `InpAIMinProb` | 0.30 | Filter threshold. The break-even hit rate for a +2R/−1R bracket is 0.33. |
| `InpAIMinMult` / `InpAIMaxMult` | 0.5 / 1.5 | Size range in *Filter + size* mode. |
| `InpAILabelR` / `InpAIHorizonBars` | 2.0 / 48 | Shadow trade target and how long it is followed. |
| `InpAILearnRate` / `InpAIL2` | 0.02 / 0.0005 | Learning speed and regularisation. |
| `InpAIModelName` | XauBot | Model file `Common\Files\<name>_<magic>_model.bin`. |
| `InpAILoadInTester` / `InpAISaveFromTester` | false / true | Tester runs start fresh by default and save the trained model at the end, so a live chart can start from it. |
| `InpAIReset` | false | Ignore the saved model and start from scratch. |

**When to switch on Filter mode:** only when the panel's skill stays clearly above 0
(for example, above 0.02) after several hundred shadow trades on your broker. In the
2011–2026 walk-forward test it never did, which is why the default is Observe.

## 6. Filters

| Input | Default | Meaning |
|---|---|---|
| `InpMaxSpreadUSD` | 1.00 | No new trade when the spread is above this (USD per ounce). |
| `InpMaxSpreadATR` | 0.10 | ...or above this fraction of ATR. |
| `InpUseNewsFilter` | true | Pause new entries around high-impact news. Live: MT5 calendar. Tester: `XauBot_news.csv` from the export script; without it, US jobs report (NFP) only. |
| `InpNewsBeforeMin` / `InpNewsAfterMin` | 30 / 30 | Window around each event. |
| `InpNewsHighOnly` | true | High impact only (`false` adds medium impact). |
| `InpNewsCurrencies` | USD | Calendar currencies to watch, comma separated. |
| `InpNewsCSV` | XauBot_news.csv | File name in the common files folder (tester only). |
| `InpPauseAfterLosses` / `InpPauseMinutes` | 0 (off) / 120 | Pause after N losing trades in a row. Research: for these strategies the trades right after a losing streak were the **best**, so this is off. |

## 7. Time zone

| Input | Default | Meaning |
|---|---|---|
| `InpGMTMode` | Auto | Live: detects the broker offset from server and GMT clocks. Tester: assumes "New York close" (GMT+2 / GMT+3 with US daylight saving). |
| `InpManualGMTOffset` | 2 | Fixed offset in hours when mode = Manual (**0 for Exness**; the Exness preset sets it). |

The time zone affects the session clocks (London/New York hours, rollover filter,
Friday close) and how H1 bars are grouped into New-York-close daily bars for the daily
filter. Use **Manual** in the tester if your broker is not on New York close time.

## 8. General

| Input | Default | Meaning |
|---|---|---|
| `InpMagic` | 20261005 | Identifies the bot's trades. Use a different number per chart if you run several copies. |
| `InpComment` | XauAI | Order comment prefix (strategy name is appended). |
| `InpMaxSlippageUSD` | 0.50 | Max price deviation for market orders, in USD per ounce (works for 2- and 3-digit gold quotes). |
| `InpShowDashboard` | true | On-chart status panel. |
| `InpVerbose` | false | Log every bar's readings and every skipped signal with the reason. |
