//+------------------------------------------------------------------+
//|                                              XAUUSD_AI_Bot.mq5   |
//|  Automated trading robot for GOLD (XAUUSD) only - MetaTrader 5    |
//|                                                                  |
//|  Your rules                                                       |
//|   1. Max 50% of the day-start balance may be lost in one day.     |
//|   2. Keep trading until 40% of the day's net profit is given back |
//|      (profit $100 -> stop when it falls back to $60).             |
//|                                                                  |
//|  Engine (researched on 2011-2026 M1 data, see docs/RESEARCH.md)   |
//|   - H1 trend-following: Trend Pullback + Donchian Momentum,       |
//|     filtered by the H1 and daily trend, ATR-sized stops,          |
//|     3xATR chandelier trailing stop, no fixed take-profit.         |
//|   - Online machine-learning layer that learns from every signal   |
//|     ("shadow trades") and reports its live skill; it can filter   |
//|     and size trades once you decide it has earned it.             |
//|   - News filter, spread filter, rollover/weekend protection.      |
//|                                                                  |
//|  Trading gold with leverage can lose all deposited money.         |
//|  Test on a demo account first.                                    |
//+------------------------------------------------------------------+
#property copyright "XAUUSD AI Bot"
#property version   "1.10"
#property description "Gold-only trend-following robot with daily loss limit, profit giveback lock and online learning."

#include "Include/Common.mqh"
#include "Include/RiskGuard.mqh"
#include "Include/Market.mqh"
#include "Include/Signals.mqh"
#include "Include/Learner.mqh"
#include "Include/Executor.mqh"
#include "Include/TradeManager.mqh"
#include "Include/NewsFilter.mqh"
#include "Include/Dashboard.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== 1. Your account rules ==="
input double            InpDailyMaxLossPct   = 50.0;              // Max loss per day (% of day-start balance)
input ENUM_XB_GB_SCOPE  InpGivebackScope     = XB_GB_ACCOUNT;     // Profit giveback lock applies to
input double            InpGivebackPct       = 40.0;              // Stop after giving back this % of the best net profit
input double            InpGivebackArmPct    = 25.0;              // Lock arms once profit >= this % of the starting balance
input ENUM_XB_PEAK_BASIS InpPeakBasis        = XB_PEAK_REALIZED;  // Best profit measured on
input bool              InpResetAccountLock  = false;             // Reset the account profit lock (new start = now), then set back to false
input datetime          InpAccountStartDate  = 0;                 // Count account profit from this date (0 = when the bot starts)
input int               InpLockAutoRestartDays = 0;               // Restart automatically N days after the lock fires (0 = never)
input bool              InpCloseOnStop       = false;             // Close the bot's positions when a stop fires (false = only stop opening)
input bool              InpAccountWidePnL    = true;              // Rules use whole-account P/L (false = this bot only)
input int               InpDayResetHour      = 0;                 // New trading day starts at this server hour

input group "=== 2. Position sizing ==="
input double            InpRiskPerTradePct   = 1.0;               // Risk per trade (% of balance). Research: >2% = deep drawdowns
input double            InpCommissionPerLot  = 0.0;               // Round-turn commission per 1.0 lot (for sizing)
input double            InpMinLotOverRiskPct = 25.0;              // Allow min lot if it risks at most this % more than planned
input double            InpMaxLot            = 0.0;               // Max lots per trade (0 = broker max)
input double            InpMaxMarginUsePct   = 50.0;              // Max % of free margin one trade may use
input int               InpMaxOpenPositions  = 2;                 // Max open positions (1 per strategy)
input int               InpMaxTradesPerDay   = 8;                 // Max new trades per day
input bool              InpSizeToGuardRoom   = true;              // Never risk more than the daily rules still allow

input group "=== 3. Strategies ==="
input ENUM_TIMEFRAMES   InpSignalTF          = PERIOD_H1;         // Signal timeframe (research: H1; M15 lost to costs)
input bool              InpUseTrendPullback  = true;              // Trend Pullback (TPB)  - profitable in research
input bool              InpUseMomentum       = true;              // Donchian Momentum (MOM) - profitable in research
input bool              InpUseLondonBreakout = false;             // London breakout (LBO) - lost money in research
input bool              InpUseLiquiditySweep = false;             // Liquidity sweep reversal (LSR) - lost money in research
input bool              InpUseMeanReversion  = false;             // Mean reversion (MR) - too few trades to judge
input ENUM_XB_D1_FILTER InpD1Filter          = XB_D1_EMA50;       // Daily trend filter
input double            InpSLMinATR          = 0.8;               // Min stop distance (x ATR)
input double            InpSLMaxATR          = 3.0;               // Skip if structure stop is farther than (x ATR)
input double            InpTP_TPB            = 0.0;               // Take profit TPB in R (0 = trailing only)
input double            InpTP_MOM            = 0.0;               // Take profit MOM in R (0 = trailing only)
input double            InpTP_LBO            = 2.0;               // Take profit LBO in R
input double            InpTP_LSR            = 2.0;               // Take profit LSR in R
input double            InpTP_MR             = 1.5;               // Take profit MR in R
input double            InpMomAdxMin         = 25.0;              // MOM: min ADX
input double            InpMomRangeATR       = 1.2;               // MOM: breakout bar range >= x ATR

input group "=== 4. Trade management ==="
input double            InpTrailStartR       = 1.5;               // Start trailing after +R
input double            InpTrailATR          = 3.0;               // Trailing distance (x ATR of signal TF)
input double            InpBreakEvenR        = 0.0;               // Move stop to break-even at +R (0 = off; research: hurts)
input double            InpBreakEvenLockR    = 0.1;               // Break-even stop locks this many R
input double            InpPartialCloseR     = 1.0;               // Partial close at +R
input double            InpPartialClosePct   = 0.0;               // Partial close % of volume (0 = off; research: hurts)
input int               InpMaxHoldBars       = 0;                 // Time stop after N signal bars (0 = off)
input double            InpTimeStopMinR      = 0.0;               // ...if the trade is below this R
input double            InpFridayCloseUTC    = 20.5;              // Close everything Friday at this UTC hour

input group "=== 5. AI - online learning ==="
input ENUM_XB_AI_MODE   InpAIMode            = XB_AI_OBSERVE;     // AI mode
input int               InpAIMinSamples      = 100;               // Samples before the AI may filter/size
input double            InpAIMinProb         = 0.30;              // FILTER: min probability of +2R before -1R
input double            InpAIMinMult         = 0.5;               // FILTER+SIZE: min size multiplier
input double            InpAIMaxMult         = 1.5;               // FILTER+SIZE: max size multiplier
input double            InpAILabelR          = 2.0;               // Shadow trade target (R)
input int               InpAIHorizonBars     = 48;                // Shadow trade horizon (signal bars)
input double            InpAILearnRate       = 0.02;              // Learning rate
input double            InpAIL2              = 0.0005;            // L2 regularisation
input string            InpAIModelName       = "XauBot";          // Model file name prefix (Common\Files)
input bool              InpAILoadInTester    = false;             // Strategy Tester: start from the saved model
input bool              InpAISaveFromTester  = true;              // Strategy Tester: save the trained model at the end
input bool              InpAIReset           = false;             // Start with a fresh model

input group "=== 6. Filters ==="
input double            InpMaxSpreadUSD      = 1.00;              // Max spread in price (USD per oz)
input double            InpMaxSpreadATR      = 0.10;              // Max spread as a fraction of ATR
input bool              InpUseNewsFilter     = true;              // Pause new trades around high-impact news
input int               InpNewsBeforeMin     = 30;                // Minutes before news
input int               InpNewsAfterMin      = 30;                // Minutes after news
input bool              InpNewsHighOnly      = true;              // Only high-impact events
input string            InpNewsCurrencies    = "USD";             // Currencies (comma separated)
input string            InpNewsCSV           = "XauBot_news.csv"; // Tester news file (Common\Files)
input int               InpPauseAfterLosses  = 0;                 // Pause after N losses in a row (0 = off; research: hurts)
input int               InpPauseMinutes      = 120;               // Pause length (minutes)

input group "=== 7. Time zone ==="
input ENUM_XB_GMT_MODE  InpGMTMode           = XB_GMT_AUTO;       // Broker time zone
input int               InpManualGMTOffset   = 2;                 // Manual offset (hours) if mode = manual

input group "=== 8. General ==="
input long              InpMagic             = 20261005;          // Magic number
input string            InpComment           = "XauAI";           // Order comment prefix
input double            InpMaxSlippageUSD    = 0.50;              // Max slippage (price, USD per oz)
input bool              InpShowDashboard     = true;              // Show the on-chart panel
input bool              InpVerbose           = false;             // Detailed log

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
CClock         g_clock;
CRiskGuard     g_guard;
CMarket        g_market;
CSignals       g_signals;
CLearner       g_ai;
CExecutor      g_exec;
CTradeManager  g_mgr;
CNewsFilter    g_news;
CDashboard     g_dash;

bool           g_ready = false;
bool           g_tester = false;
datetime       g_lastSignalBar = 0;
datetime       g_lastM1Bar = 0;
datetime       g_lastDash = 0;
datetime       g_lastCleanup = 0;
datetime       g_lastDataWarn = 0;
double         g_lastATR = 0.0;
string         g_lastDecision = "waiting for the first closed bar";
string         g_newsState = "";
int            g_signalsToday = 0;
datetime       g_signalDay = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_tester = (bool)MQLInfoInteger(MQL_TESTER);

   if(!IsGoldUSD(_Symbol))
     {
      Alert("XAUUSD AI Bot trades GOLD (XAUUSD) only. Attach it to an XAUUSD chart, not ", _Symbol, ".");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPerTradePct <= 0 || InpRiskPerTradePct > 20 || InpDailyMaxLossPct <= 0 || InpDailyMaxLossPct > 100 ||
      InpGivebackPct <= 0 || InpGivebackPct > 100 || InpSLMinATR <= 0 || InpSLMaxATR < InpSLMinATR)
     {
      Alert("XAUUSD AI Bot: invalid risk inputs.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(PeriodSeconds(InpSignalTF) < PeriodSeconds(PERIOD_M5))
     {
      Alert("XAUUSD AI Bot: signal timeframe must be M5 or higher.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRiskPerTradePct > 2.0)
      PrintFormat("[XauBot] WARNING: %.1f%% risk per trade. In 2011-2026 research 3%% gave ~80%% drawdowns and 5%% wiped the account.",
                  InpRiskPerTradePct);

   g_clock.Init(InpGMTMode, InpManualGMTOffset);
   //--- one-shot reset of the account profit lock (not repeated on chart/timeframe re-inits)
   bool resetLock = false;
   string resetKey = GVName(InpMagic, "lockresetdone");
   if(InpResetAccountLock && !g_tester)
     {
      if(GVGet(resetKey, 0) < 0.5)
        {
         resetLock = true;
         GVSet(resetKey, 1);
         Alert("XAUUSD AI Bot: account profit lock reset. Set 'Reset the account profit lock' back to false.");
        }
     }
   else
      GlobalVariableDel(resetKey);
   g_guard.Init(InpMagic, _Symbol, InpDailyMaxLossPct, InpGivebackPct, InpGivebackArmPct, InpGivebackScope, InpPeakBasis,
                InpAccountWidePnL, InpDayResetHour, InpPauseAfterLosses, InpPauseMinutes, InpLockAutoRestartDays,
                resetLock, InpAccountStartDate);

   if(!g_market.Init(_Symbol, InpSignalTF))
      return INIT_FAILED;

   XBSignalConfig sc;
   sc.use[XB_TPB] = InpUseTrendPullback;
   sc.use[XB_LBO] = InpUseLondonBreakout;
   sc.use[XB_LSR] = InpUseLiquiditySweep;
   sc.use[XB_MR]  = InpUseMeanReversion;
   sc.use[XB_MOM] = InpUseMomentum;
   sc.tpR[XB_TPB] = InpTP_TPB;
   sc.tpR[XB_LBO] = InpTP_LBO;
   sc.tpR[XB_LSR] = InpTP_LSR;
   sc.tpR[XB_MR]  = InpTP_MR;
   sc.tpR[XB_MOM] = InpTP_MOM;
   sc.slMinATR = InpSLMinATR;
   sc.slMaxATR = InpSLMaxATR;
   sc.d1Filter = InpD1Filter;
   sc.lboBufferATR = 0.1;
   sc.lboMinRangeD1 = 0.25;
   sc.lboMaxRangeD1 = 1.2;
   sc.lsrWick = 0.5;
   sc.mrAdxMax = 20.0;
   sc.momAdxMin = InpMomAdxMin;
   sc.momRangeATR = InpMomRangeATR;
   if(!g_signals.Init(_Symbol, InpMagic, sc))
      return INIT_FAILED;

   bool loadModel = g_tester ? InpAILoadInTester : true;
   g_ai.Init(InpAIModelName, InpMagic, InpAILearnRate, InpAIL2, InpAILabelR,
             InpAIHorizonBars * PeriodSeconds(InpSignalTF), InpAIMinSamples, loadModel, InpAIReset);

   int slipPts = (int)MathCeil(InpMaxSlippageUSD / MathMax(SymbolInfoDouble(_Symbol, SYMBOL_POINT), 1e-9));
   g_exec.Init(_Symbol, InpMagic, slipPts, InpMaxLot, InpVerbose);

   XBManageConfig mc;
   mc.trailStartR = InpTrailStartR;
   mc.trailATR = InpTrailATR;
   mc.beR = InpBreakEvenR;
   mc.beLockR = InpBreakEvenLockR;
   mc.partialR = InpPartialCloseR;
   mc.partialPct = InpPartialClosePct;
   mc.maxHoldBars = InpMaxHoldBars;
   mc.timeStopMinR = InpTimeStopMinR;
   mc.fridayCloseUTC = InpFridayCloseUTC;
   mc.signalPeriodSec = PeriodSeconds(InpSignalTF);
   g_mgr.Init(_Symbol, InpMagic, mc, GetPointer(g_exec));

   g_news.Init(InpUseNewsFilter, InpNewsBeforeMin, InpNewsAfterMin, InpNewsHighOnly, InpNewsCurrencies, InpNewsCSV);

   bool visual = !g_tester || (bool)MQLInfoInteger(MQL_VISUAL_MODE);
   g_dash.Init(InpShowDashboard && visual);

   if(!g_tester && !(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("[XauBot] NOTE: 'Algo Trading' is disabled in the terminal - the bot will not open trades until you enable it.");

   PrintFormat("[XauBot] v%s started on %s | risk %.2f%%/trade | daily loss %.0f%% | giveback %.0f%% %s (arms at +%.1f%%) | %s | TF %s | AI %s | %s",
               XB_VERSION, _Symbol, InpRiskPerTradePct, InpDailyMaxLossPct, InpGivebackPct,
               InpGivebackScope == XB_GB_ACCOUNT ? "of account profit" : (InpGivebackScope == XB_GB_DAY ? "of day profit" : "OFF"),
               InpGivebackArmPct, InpCloseOnStop ? "close on stop" : "stop = no new trades",
               EnumToString(InpSignalTF), EnumToString(InpAIMode), g_clock.Describe(TimeTradeServer()));
   g_ready = true;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(InpAIMode != XB_AI_OFF)
     {
      bool optimizing = (bool)MQLInfoInteger(MQL_OPTIMIZATION);
      if(!g_tester || (InpAISaveFromTester && !optimizing))
        {
         if(g_ai.Save())
            PrintFormat("[XauBot] AI model saved: Common\\Files\\%s (%I64d samples, skill %.3f)",
                        g_ai.FileName(), g_ai.Samples(), g_ai.Skill());
        }
     }
   g_market.Release();
   g_signals.Release();
   g_dash.Remove();
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_guard.MarkDirty();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_ready)
      return;
   datetime now = TimeTradeServer();
   if(now <= 0)
      now = TimeCurrent();

   //--- 1) account rules, every tick
   if(g_guard.Check())
     {
      if(InpCloseOnStop)
         g_mgr.CloseAll(g_guard.Reason());
      g_lastDecision = "STOPPED: " + g_guard.Reason();
     }
   else
      if(g_guard.Stopped() && InpCloseOnStop && g_mgr.CountOpen() > 0)
         g_mgr.CloseAll(g_guard.Reason());    // e.g. after a restart

   //--- 2) new M1 bar: shadow trades, housekeeping
   datetime m1 = iTime(_Symbol, PERIOD_M1, 0);
   bool newM1 = (m1 != g_lastM1Bar && m1 > 0);
   if(newM1)
     {
      g_lastM1Bar = m1;
      if(InpAIMode != XB_AI_OFF)
        {
         MqlTick tk;
         if(SymbolInfoTick(_Symbol, tk))
            g_ai.Resolve(iHigh(_Symbol, PERIOD_M1, 1), iLow(_Symbol, PERIOD_M1, 1), tk.ask - tk.bid, tk.bid, tk.ask, now);
        }
      if(now - g_lastCleanup > 6 * 3600)
        {
         g_mgr.Cleanup();
         g_lastCleanup = now;
        }
     }

   //--- 3) manage open positions
   g_mgr.Manage(g_lastATR > 0 ? g_lastATR : iATRFallback(), g_clock, newM1);

   //--- 4) new signal bar: look for trades
   datetime sb = iTime(_Symbol, InpSignalTF, 0);
   if(sb > 0 && sb != g_lastSignalBar)
     {
      if(g_market.Update(g_clock))
        {
         g_lastSignalBar = sb;
         g_lastATR = g_market.atr[1];
         OnSignalBar(now);
        }
      else
         if(now - g_lastDataWarn >= 300)
           {
            g_lastDataWarn = now;
            g_lastDecision = "waiting for data: " + g_market.lastError;
            Print("[XauBot] waiting for market data: ", g_market.lastError);
           }
     }

   //--- 5) dashboard
   if(g_dash.On() && now - g_lastDash >= 1)
     {
      g_lastDash = now;
      DrawDashboard(now);
     }
  }

//--- ATR before the first signal bar was processed
double iATRFallback()
  {
   if(ArraySize(g_market.atr) > 1 && g_market.atr[1] > 0)
      return g_market.atr[1];
   return 0.0;
  }

//+------------------------------------------------------------------+
//| Signal processing                                                 |
//+------------------------------------------------------------------+
void OnSignalBar(const datetime now)
  {
   XBSignal sig[];
   int n = g_signals.Generate(g_market, sig);
   if(InpVerbose)
      PrintFormat("[XauBot] bar %s closed %.2f | ATR %.2f ADX %.1f RSI %.1f | H1 %s | D1 close %.2f vs EMA50 %.2f | signals %d",
                  TimeToString(g_market.barOpen, TIME_DATE | TIME_MINUTES), g_market.c[1], g_market.atr[1], g_market.adx[1],
                  g_market.rsi[1], g_market.h1Up ? "up" : (g_market.h1Dn ? "down" : "flat"), g_market.d1Close,
                  g_market.d1Ema50, n);
   if(g_guard.DayStart() != g_signalDay)
     {
      g_signalDay = g_guard.DayStart();
      g_signalsToday = 0;
     }
   if(n == 0)
      return;
   g_signalsToday += n;

   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
      return;

   for(int i = 0; i < n; i++)
     {
      g_signals.Features(g_market, sig[i]);
      sig[i].prob = g_ai.Predict(sig[i].feat);
      sig[i].edgeR = g_ai.EdgeR(sig[i].prob);
      if(InpAIMode != XB_AI_OFF)
         g_ai.AddShadow(sig[i], sig[i].dir > 0 ? tk.ask : tk.bid, now);

      string why = "";
      bool ok = CanTrade(sig[i], now, why);
      string head = StringFormat("%s %s %s p=%.2f", TimeToString(now, TIME_DATE | TIME_MINUTES),
                                 StrategyName(sig[i].strategy), sig[i].dir > 0 ? "BUY" : "SELL", sig[i].prob);
      if(!ok)
        {
         g_lastDecision = head + " skipped: " + why;
         if(InpVerbose)
            Print("[XauBot] ", g_lastDecision);
         continue;
        }
      if(Execute(sig[i], why))
         g_lastDecision = head + " OPENED " + why;
      else
         g_lastDecision = head + " not opened: " + why;
      if(InpVerbose || StringFind(g_lastDecision, "OPENED") < 0)
         Print("[XauBot] ", g_lastDecision);
     }
  }

bool CanTrade(XBSignal &s, const datetime now, string &why)
  {
   if(g_guard.Stopped())
     {
      why = "daily stop (" + g_guard.Reason() + ")";
      return false;
     }
   if(!g_tester && (!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !(bool)MQLInfoInteger(MQL_TRADE_ALLOWED)))
     {
      why = "algo trading disabled";
      return false;
     }
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (mode == SYMBOL_TRADE_MODE_LONGONLY && s.dir < 0) || (mode == SYMBOL_TRADE_MODE_SHORTONLY && s.dir > 0))
     {
      why = "symbol trade mode does not allow it";
      return false;
     }
   if(g_guard.TradesToday() >= InpMaxTradesPerDay)
     {
      why = "max trades per day";
      return false;
     }
   if(g_guard.InLossPause(now))
     {
      why = "pause after losses in a row";
      return false;
     }
   int open = g_mgr.CountOpen();
   bool netting = (AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(open >= InpMaxOpenPositions || (netting && open > 0))
     {
      why = "max open positions";
      return false;
     }
   if(g_mgr.CountOpen(s.strategy) > 0)
     {
      why = "strategy already in a trade";
      return false;
     }
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
     {
      why = "no price";
      return false;
     }
   double spread = tk.ask - tk.bid;
   if(spread > InpMaxSpreadUSD || (g_lastATR > 0 && spread > InpMaxSpreadATR * g_lastATR))
     {
      why = StringFormat("spread %.2f too wide", spread);
      return false;
     }
   string ev = "";
   if(g_news.Blocked(now, g_clock, ev))
     {
      why = "news: " + ev;
      return false;
     }
   s.riskMult = 1.0;
   if((InpAIMode == XB_AI_FILTER || InpAIMode == XB_AI_FILTER_SIZE) && g_ai.Ready())
     {
      if(s.prob < InpAIMinProb)
        {
         why = StringFormat("AI probability %.2f < %.2f", s.prob, InpAIMinProb);
         return false;
        }
      if(InpAIMode == XB_AI_FILTER_SIZE)
         s.riskMult = Clip(s.prob / MathMax(InpAIMinProb + 0.05, 0.05), InpAIMinMult, InpAIMaxMult);
     }
   return true;
  }

bool Execute(XBSignal &s, string &info)
  {
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk))
     {
      info = "no price";
      return false;
     }
   int d = s.dir;
   double entry = (d > 0) ? tk.ask : tk.bid;
   double dist = MathMax(s.slDist, g_exec.MinStopDistance() * 1.2);
   double sl = entry - d * dist;
   double tp = (s.tpR > 0) ? entry + d * s.tpR * dist : 0.0;

   //--- how much money this trade may lose
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double baseRisk = balance * InpRiskPerTradePct / 100.0 * s.riskMult;
   double riskMoney = baseRisk;
   double cap = DBL_MAX;                       // daily-loss room left after all open stops
   if(InpSizeToGuardRoom)
     {
      cap = (g_guard.Room() - g_mgr.OpenRisk()) * 0.9;
      riskMoney = MathMin(riskMoney, cap);
     }
   if(riskMoney <= 0)
     {
      info = "no risk budget left today";
      return false;
     }
   double perLot = g_exec.LossPerLot(d, entry, sl, InpCommissionPerLot);
   if(perLot <= 0)
     {
      info = "cannot value the stop";
      return false;
     }
   double lots = g_exec.NormalizeLots(riskMoney / perLot);
   if(lots <= 0)
     {
      double minLot = g_exec.MinLot();
      double minRisk = minLot * perLot;
      if(minRisk <= baseRisk * (1.0 + InpMinLotOverRiskPct / 100.0) && minRisk <= cap)
         lots = g_exec.NormalizeLots(minLot);
      if(lots <= 0)
        {
         info = StringFormat("min lot risks %.2f, budget %.2f (account too small for this stop)", minRisk, riskMoney);
         return false;
        }
     }
   //--- margin
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margin = g_exec.MarginFor(d, lots, entry);
   if(margin > 0 && margin > freeMargin * InpMaxMarginUsePct / 100.0)
     {
      double scaled = g_exec.NormalizeLots(lots * freeMargin * InpMaxMarginUsePct / 100.0 / margin);
      if(scaled <= 0)
        {
         info = "not enough free margin";
         return false;
        }
      lots = scaled;
     }

   string comment = StringFormat("%s|%s|", InpComment, StrategyName(s.strategy));
   ulong ticket = g_exec.Open(d, lots, sl, tp, comment);
   if(ticket == 0)
     {
      info = "broker rejected the order";
      return false;
     }
   double openPrice = entry;
   if(PositionSelectByTicket(ticket))
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   g_mgr.Register(ticket, s.strategy, dist, openPrice);
   g_guard.MarkDirty();
   info = StringFormat("%.2f lots, risk %.2f (%s)", lots, lots * perLot, s.note);
   return true;
  }

//+------------------------------------------------------------------+
//| Dashboard                                                         |
//+------------------------------------------------------------------+
void DrawDashboard(const datetime now)
  {
   color ok = C'120,220,140', warn = C'255,190,90', bad = C'255,110,110', dim = C'150,160,175', txt = C'220,225,235';
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   double net = g_guard.DayNet();
   g_dash.Set(0, StringFormat("XAUUSD AI Bot v%s  |  %s  |  %s", XB_VERSION, _Symbol, g_clock.Describe(now)), C'255,215,90');
   g_dash.Set(1, StringFormat("Day start balance : %.2f %s", g_guard.Base(), ccy), txt);
   g_dash.Set(2, StringFormat("Day net P/L       : %+.2f (closed %+.2f, open %+.2f)", net, g_guard.DayRealized(), g_guard.FloatingPL()),
              net >= 0 ? ok : bad);
   g_dash.Set(3, StringFormat("Day loss limit %.0f%%: -%.2f   room left %.2f", InpDailyMaxLossPct, g_guard.LossLimit(), g_guard.Room()), txt);
   if(InpGivebackScope == XB_GB_ACCOUNT)
     {
      double an = g_guard.AccountNet();
      if(g_guard.AccountArmed())
         g_dash.Set(4, StringFormat("Account lock      : profit %+.2f, best %+.2f -> stop at %+.2f", an, g_guard.AccountPeak(),
                                    g_guard.AccountLockLevel()), warn);
      else
         g_dash.Set(4, StringFormat("Account lock      : profit %+.2f since %s, arms at +%.2f", an,
                                    TimeToString(g_guard.AccountStart(), TIME_DATE), g_guard.AccountArmLevel()), dim);
     }
   else
      if(InpGivebackScope == XB_GB_DAY)
         g_dash.Set(4, g_guard.DayArmed() ? StringFormat("Day profit lock   : best %+.2f -> stop at %+.2f", g_guard.DayPeak(),
                    g_guard.DayPeak() * (1.0 - InpGivebackPct / 100.0)) :
                    StringFormat("Day profit lock   : arms at +%.2f", g_guard.Base() * InpGivebackArmPct / 100.0), dim);
      else
         g_dash.Set(4, "Profit lock       : off", dim);
   string stopTxt = g_guard.AccountStopped() ? "STATUS            : STOPPED - ACCOUNT PROFIT LOCK (reset in inputs)" :
                    (g_guard.Stopped() ? "STATUS            : STOPPED - " + g_guard.Reason() + " (until next day)" :
                     "STATUS            : TRADING");
   g_dash.Set(5, stopTxt, g_guard.Stopped() ? bad : ok);
   g_dash.Set(6, StringFormat("Trades today      : %d / %d   open: %d   signals: %d", g_guard.TradesToday(), InpMaxTradesPerDay,
                              g_mgr.CountOpen(), g_signalsToday), txt);
   string trend = g_market.h1Up ? "UP" : (g_market.h1Dn ? "DOWN" : "NONE");
   g_dash.Set(7, StringFormat("H1 trend %s | ADX %.1f | ATR %.2f | spread %.2f", trend,
                              ArraySize(g_market.adx) > 1 ? g_market.adx[1] : 0.0, g_lastATR,
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)), txt);
   string ev = "";
   bool nb = g_news.Blocked(now, g_clock, ev);
   g_dash.Set(8, nb ? "News              : PAUSED - " + ev : "News              : next " + g_news.Next(now), nb ? warn : dim);
   g_dash.Set(9, StringFormat("AI %s | samples %I64d | open shadows %d", EnumToString(InpAIMode), g_ai.Samples(), g_ai.OpenShadows()), txt);
   g_dash.Set(10, StringFormat("AI calibration    : predicted %.2f vs real %.2f (n=%I64d) skill %+.3f",
                               g_ai.CalMeanP(), g_ai.CalMeanY(), g_ai.CalN(), g_ai.Skill()),
              g_ai.Skill() > 0.02 ? ok : dim);
   int line = 11;
   for(int s = 0; s < XB_NSTRAT && line < 16; s++)
     {
      if(g_ai.StrategyCount(s) == 0)
         continue;
      g_dash.Set(line++, StringFormat("  %-4s shadow trades %4I64d  avg %+.2fR  recent %+.2fR", StrategyName(s),
                                      g_ai.StrategyCount(s), g_ai.StrategyAvgR(s), g_ai.StrategyEwma(s)), dim);
     }
   while(line < 16)
      g_dash.Set(line++, " ", dim);
   g_dash.Set(16, "Last: " + StringSubstr(g_lastDecision, 0, 62), dim);
   g_dash.Set(17, StringFormat("Risk/trade %.2f%%  |  magic %I64d", InpRiskPerTradePct, InpMagic), dim);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Strategy Tester custom criterion                                  |
//| (profit factor and trade count, punished by drawdown)             |
//+------------------------------------------------------------------+
double OnTester()
  {
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades = TesterStatistics(STAT_TRADES);
   double dd = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double profit = TesterStatistics(STAT_PROFIT);
   if(trades < 30 || profit <= 0)
      return 0.0;
   return (pf - 1.0) * MathSqrt(trades) * (1.0 - MathMin(dd, 99.0) / 100.0);
  }
//+------------------------------------------------------------------+
