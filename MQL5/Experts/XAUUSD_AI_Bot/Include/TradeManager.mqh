//+------------------------------------------------------------------+
//| TradeManager.mqh - managing the bot's open positions              |
//|  * chandelier ATR trailing stop (default: from +1.5R, 3 x ATR)    |
//|  * optional break-even, partial close, time stop                  |
//|  * Friday close before the weekend                                |
//| Per-position state (initial risk R, strategy, best price, partial |
//| done) lives in terminal global variables, so it survives restarts.|
//+------------------------------------------------------------------+
#ifndef XAUBOT_TRADEMANAGER_MQH
#define XAUBOT_TRADEMANAGER_MQH

#include "Common.mqh"
#include "Executor.mqh"

struct XBManageConfig
  {
   double            trailStartR;
   double            trailATR;
   double            beR;
   double            beLockR;
   double            partialR;
   double            partialPct;
   int               maxHoldBars;
   double            timeStopMinR;
   double            fridayCloseUTC;
   int               signalPeriodSec;
  };

class CTradeManager
  {
private:
   string            m_sym;
   long              m_magic;
   XBManageConfig    m_cfg;
   CExecutor        *m_exec;

   // per-position keys look like XB<magic>_T<kind><ticket>, e.g. XB20261005_TR123456
   string K(const string what, const ulong ticket) { return GVName(m_magic, StringFormat("T%s%I64u", what, ticket)); }

public:
   void Init(const string sym, const long magic, const XBManageConfig &cfg, CExecutor *exec)
     {
      m_sym = sym;
      m_magic = magic;
      m_cfg = cfg;
      m_exec = exec;
     }

   //--- remember what we need about a new position
   void Register(const ulong ticket, const int strategy, const double R, const double entry)
     {
      GVSet(K("R", ticket), R);
      GVSet(K("S", ticket), strategy);
      GVSet(K("B", ticket), entry);
      GVSet(K("P", ticket), 0);
     }

   int Strategy(const ulong ticket)
     {
      string n = K("S", ticket);
      if(GlobalVariableCheck(n))
         return (int)GlobalVariableGet(n);
      if(PositionSelectByTicket(ticket))
         return StrategyFromName(PositionGetString(POSITION_COMMENT));
      return -1;
     }

   //--- remove state of positions that no longer exist
   void Cleanup()
     {
      string prefix = GVName(m_magic, "");
      for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
        {
         string n = GlobalVariableName(i);
         if(StringFind(n, prefix) != 0)
            continue;
         string rest = StringSubstr(n, StringLen(prefix));
         if(StringLen(rest) < 3 || StringSubstr(rest, 0, 1) != "T")
            continue;
         string kind = StringSubstr(rest, 1, 1);
         if(kind != "R" && kind != "S" && kind != "B" && kind != "P")
            continue;
         string num = StringSubstr(rest, 2);
         ulong tk = (ulong)StringToInteger(num);
         if(tk == 0 || StringLen(num) < 3)
            continue;
         if(!PositionSelectByTicket(tk))
            GlobalVariableDel(n);
        }
     }

   //--- open risk: money lost if every bot position hit its current stop (0 for stops in profit)
   double OpenRisk()
     {
      double risk = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_sym)
            continue;
         double sl = PositionGetDouble(POSITION_SL);
         double cur = PositionGetDouble(POSITION_PRICE_CURRENT);
         double vol = PositionGetDouble(POSITION_VOLUME);
         int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(sl <= 0)
            continue;
         double pnl = 0.0;
         if(OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, m_sym, vol, cur, sl, pnl) && pnl < 0)
            risk += -pnl;
        }
      return risk;
     }

   int CountOpen(const int strategy = -1)
     {
      int n = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_sym)
            continue;
         if(strategy < 0 || Strategy(tk) == strategy)
            n++;
        }
      return n;
     }

   void CloseAll(const string why)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_sym)
            continue;
         m_exec.Close(tk, 0.0, why);
        }
     }

   //--- called on every tick. atr = ATR of the last closed signal-TF bar
   void Manage(const double atr, CClock &clk, const bool newM1Bar)
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_sym, tick))
         return;
      datetime now = TimeTradeServer();
      if(now <= 0)
         now = tick.time;
      datetime nowUtc = clk.ToUTC(now);
      bool fridayClose = (DayOfWeek(nowUtc) == 5 && HourOf(nowUtc) >= m_cfg.fridayCloseUTC);
      double m1Hi = 0, m1Lo = 0;
      if(newM1Bar)
        {
         m1Hi = iHigh(m_sym, PERIOD_M1, 1);
         m1Lo = iLow(m_sym, PERIOD_M1, 1);
        }

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_sym)
            continue;
         int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         double open = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         double vol = PositionGetDouble(POSITION_VOLUME);
         datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
         double px = (dir > 0) ? tick.bid : tick.ask;     // price we would exit at
         double spread = tick.ask - tick.bid;

         if(fridayClose)
           {
            m_exec.Close(tk, 0.0, "friday close");
            continue;
           }

         //--- initial risk R (fallbacks for positions opened before this version)
         double R = GVGet(K("R", tk), 0.0);
         if(R <= 0)
           {
            R = (sl > 0 && (open - sl) * dir > 0) ? MathAbs(open - sl) : 1.5 * atr;
            GVSet(K("R", tk), R);
           }

         //--- best price reached since entry (exit side)
         double best = GVGet(K("B", tk), open);
         double cand = px;
         if(newM1Bar && m1Hi > 0)
            cand = (dir > 0) ? MathMax(px, m1Hi) : MathMin(px, m1Lo + spread);
         if((dir > 0 && cand > best) || (dir < 0 && cand < best) || !GlobalVariableCheck(K("B", tk)))
           {
            best = (dir > 0) ? MathMax(best, cand) : MathMin(best, cand);
            GVSet(K("B", tk), best);
           }
         double bestR = (best - open) * dir / R;
         double curR = (px - open) * dir / R;

         //--- time stop
         if(m_cfg.maxHoldBars > 0 && now - opened >= (long)m_cfg.maxHoldBars * m_cfg.signalPeriodSec && curR < m_cfg.timeStopMinR)
           {
            m_exec.Close(tk, 0.0, "time stop");
            continue;
           }

         //--- partial close
         if(m_cfg.partialPct > 0 && GVGet(K("P", tk), 0) < 0.5 && bestR >= m_cfg.partialR)
           {
            double part = m_exec.NormalizeLots(vol * m_cfg.partialPct / 100.0);
            double rest = vol - part;
            if(part > 0 && rest >= m_exec.MinLot() - 1e-9)
              {
               if(m_exec.Close(tk, part, "partial"))
                  GVSet(K("P", tk), 1);
              }
            else
               GVSet(K("P", tk), 1);   // too small to split
           }

         //--- new stop: break-even and chandelier trailing
         double newSL = sl;
         if(m_cfg.beR > 0 && bestR >= m_cfg.beR)
           {
            double be = open + dir * m_cfg.beLockR * R;
            if(newSL <= 0 || (be - newSL) * dir > 0)
               newSL = be;
           }
         if(m_cfg.trailATR > 0 && atr > 0 && bestR >= m_cfg.trailStartR)
           {
            double tr = best - dir * m_cfg.trailATR * atr;
            if(newSL <= 0 || (tr - newSL) * dir > 0)
               newSL = tr;
           }
         if(newSL > 0 && (sl <= 0 || (newSL - sl) * dir > 0))
           {
            // broker constraints: stop must be away from price by the stops level, not inside freeze level
            double minDist = MathMax(m_exec.MinStopDistance(), m_exec.FreezeDistance());
            double lim = px - dir * minDist;
            if((newSL - lim) * dir > 0)
               newSL = lim;
            double minStep = MathMax(0.02 * atr, 10 * SymbolInfoDouble(m_sym, SYMBOL_POINT));
            if((sl <= 0 || (newSL - sl) * dir >= minStep) && (newSL - open) * dir > -R * 1.01)
               m_exec.Modify(tk, newSL, tp);
           }
        }
     }
  };

#endif
