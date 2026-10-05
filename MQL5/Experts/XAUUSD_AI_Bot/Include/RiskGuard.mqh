//+------------------------------------------------------------------+
//| RiskGuard.mqh - the account protection rules                      |
//|                                                                  |
//|  Rule 1  Daily loss limit: the day's net result (closed + open)   |
//|          may never fall below -DailyMaxLossPct % of the balance   |
//|          the day started with.                                    |
//|  Rule 2  Profit giveback lock: once the day is in profit, keep    |
//|          trading until GivebackPct % of the day's best net profit |
//|          has been given back (profit $100 -> stop at -$40, i.e.   |
//|          when the day is back at +$60).                           |
//|                                                                  |
//|  Both rules stop new trades until the next trading day and        |
//|  (optionally) close the bot's open positions. The state is        |
//|  rebuilt from the deal history, so restarting the terminal or     |
//|  re-attaching the EA cannot reset a stop.                         |
//+------------------------------------------------------------------+
#ifndef XAUBOT_RISKGUARD_MQH
#define XAUBOT_RISKGUARD_MQH

#include "Common.mqh"

class CRiskGuard
  {
private:
   //--- configuration
   long              m_magic;
   string            m_sym;
   double            m_lossPct;
   double            m_givebackPct;
   double            m_armPct;
   ENUM_XB_PEAK_BASIS m_basis;
   bool              m_accountWide;
   int               m_resetHour;
   int               m_maxConsec;
   int               m_pauseMin;

   //--- state
   datetime          m_dayStart;      // server time
   double            m_base;          // balance at day start
   double            m_realized;      // today's closed P/L (scope)
   double            m_realizedPeak;  // best running closed P/L today (scope)
   double            m_floating;      // open P/L now (scope)
   double            m_equityPeak;    // best closed+open P/L seen today (persisted)
   bool              m_stopped;
   string            m_reason;
   int               m_tradesToday;   // bot entries today
   int               m_consecLosses;  // bot losing exits in a row
   datetime          m_lastExitTime;
   bool              m_dirty;
   datetime          m_lastRefresh;

   string            Key(const string k) { return GVName(m_magic, k); }

   datetime CalcDayStart(const datetime srv)
     {
      datetime shifted = srv - m_resetHour * 3600;
      return DayFloor(shifted) + m_resetHour * 3600;
     }

   bool InScope(const string sym, const long magic)
     {
      if(m_accountWide)
         return true;
      return (sym == m_sym && magic == m_magic);
     }

public:
   void Init(const long magic, const string sym, const double lossPct, const double givebackPct,
             const double armPct, const ENUM_XB_PEAK_BASIS basis, const bool accountWide,
             const int resetHour, const int maxConsec, const int pauseMin)
     {
      m_magic = magic; m_sym = sym;
      m_lossPct = lossPct; m_givebackPct = givebackPct; m_armPct = armPct;
      m_basis = basis; m_accountWide = accountWide;
      m_resetHour = (int)Clip(resetHour, 0, 23);
      m_maxConsec = maxConsec; m_pauseMin = pauseMin;
      m_dayStart = 0; m_stopped = false; m_reason = "";
      m_dirty = true; m_lastRefresh = 0;
      Refresh();
     }

   void MarkDirty() { m_dirty = true; }

   //--- rebuild today's numbers from the deal history
   void Refresh()
     {
      datetime now = TimeTradeServer();
      if(now <= 0)
         now = TimeCurrent();
      datetime ds = CalcDayStart(now);
      if(ds != m_dayStart)
        {
         m_dayStart = ds;
         m_stopped = false;
         m_reason = "";
         m_equityPeak = 0.0;
         // a stop recorded earlier today survives restarts
         if((datetime)GVGet(Key("stopday"), 0) == m_dayStart)
           {
            m_stopped = true;
            int code = (int)GVGet(Key("stopcode"), 0);
            m_reason = (code == 1) ? "DAILY LOSS LIMIT" : (code == 2 ? "PROFIT GIVEBACK LOCK" : "STOPPED");
           }
         if((datetime)GVGet(Key("peakday"), 0) == m_dayStart)
            m_equityPeak = GVGet(Key("peak"), 0.0);
        }

      double accRealized = 0.0;
      double scopeRealized = 0.0, runPeak = 0.0;
      m_tradesToday = 0;
      m_consecLosses = 0;
      m_lastExitTime = 0;
      datetime from = MathMin(m_dayStart, now - 7 * 86400);
      if(HistorySelect(from, now + 86400))
        {
         int total = HistoryDealsTotal();
         // bot exits, newest first, for the losing-streak counter
         bool streakOpen = true;
         for(int i = total - 1; i >= 0; i--)
           {
            ulong tk = HistoryDealGetTicket(i);
            if(tk == 0)
               continue;
            long type = HistoryDealGetInteger(tk, DEAL_TYPE);
            if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
               continue;
            if(HistoryDealGetInteger(tk, DEAL_MAGIC) != m_magic || HistoryDealGetString(tk, DEAL_SYMBOL) != m_sym)
               continue;
            long entry = HistoryDealGetInteger(tk, DEAL_ENTRY);
            if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
               continue;
            double pnl = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                         HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
            if(m_lastExitTime == 0)
               m_lastExitTime = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
            if(streakOpen)
              {
               if(pnl < 0)
                  m_consecLosses++;
               else
                  streakOpen = false;
              }
            else
               break;
           }
         // today's realized P/L in chronological order
         for(int i = 0; i < total; i++)
           {
            ulong tk = HistoryDealGetTicket(i);
            if(tk == 0)
               continue;
            if((datetime)HistoryDealGetInteger(tk, DEAL_TIME) < m_dayStart)
               continue;
            long type = HistoryDealGetInteger(tk, DEAL_TYPE);
            if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
               continue;
            string sym = HistoryDealGetString(tk, DEAL_SYMBOL);
            long magic = HistoryDealGetInteger(tk, DEAL_MAGIC);
            double pnl = HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
                         HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
            accRealized += pnl;
            if(InScope(sym, magic))
              {
               scopeRealized += pnl;
               if(scopeRealized > runPeak)
                  runPeak = scopeRealized;
              }
            if(magic == m_magic && sym == m_sym && HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
               m_tradesToday++;
           }
        }
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      m_base = bal - accRealized;
      if(m_base <= 0)
         m_base = bal;
      m_realized = scopeRealized;
      m_realizedPeak = runPeak;
      m_dirty = false;
      m_lastRefresh = now;
     }

   double Floating()
     {
      double f = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0)
            continue;
         if(!InScope(PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_MAGIC)))
            continue;
         f += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      return f;
     }

   //--- call on every tick. Returns true when a stop has JUST been triggered.
   bool Check()
     {
      datetime now = TimeTradeServer();
      if(now <= 0)
         now = TimeCurrent();
      if(m_dirty || CalcDayStart(now) != m_dayStart || now - m_lastRefresh >= 60)
         Refresh();
      m_floating = Floating();
      double net = Net();
      if(net > m_equityPeak)
        {
         m_equityPeak = net;
         if(m_basis == XB_PEAK_EQUITY)
           {
            GVSet(Key("peak"), m_equityPeak);
            GVSet(Key("peakday"), (double)m_dayStart);
           }
        }
      if(m_stopped)
         return false;
      // account data not loaded yet (terminal just started / not logged in): never judge on a zero balance
      if(m_base <= 0 || AccountInfoDouble(ACCOUNT_BALANCE) <= 0)
        {
         m_dirty = true;
         return false;
        }
      if(net <= -LossLimit())
        {
         Stop(1, "DAILY LOSS LIMIT");
         return true;
        }
      if(Armed() && net <= Peak() * (1.0 - m_givebackPct / 100.0))
        {
         Stop(2, "PROFIT GIVEBACK LOCK");
         return true;
        }
      return false;
     }

   void Stop(const int code, const string why)
     {
      m_stopped = true;
      m_reason = why;
      GVSet(Key("stopday"), (double)m_dayStart);
      GVSet(Key("stopcode"), code);
      PrintFormat("[XauBot] %s hit: day net %.2f, peak %.2f, base %.2f -> no new trades until next day",
                  why, Net(), Peak(), m_base);
     }

   //--- numbers
   double   Base()        { return m_base; }
   double   Realized()    { return m_realized; }
   double   FloatingPL()  { return m_floating; }
   double   Net()         { return m_realized + m_floating; }
   double   Peak()        { return (m_basis == XB_PEAK_REALIZED) ? m_realizedPeak : m_equityPeak; }
   double   LossLimit()   { return m_base * m_lossPct / 100.0; }
   double   ArmLevel()    { return m_base * m_armPct / 100.0; }
   bool     Armed()       { double p = Peak(); return (p > 0.0 && p >= ArmLevel()); }
   double   LockLevel()   { return Armed() ? Peak() * (1.0 - m_givebackPct / 100.0) : -LossLimit(); }
   bool     Stopped()     { return m_stopped; }
   string   Reason()      { return m_reason; }
   int      TradesToday() { return m_tradesToday; }
   int      ConsecLosses(){ return m_consecLosses; }
   datetime DayStart()    { return m_dayStart; }

   //--- money that can still be lost before a guard triggers
   double Room()
     {
      double net = Net();
      double room = LossLimit() + net;
      if(Armed())
         room = MathMin(room, net - LockLevel());
      return MathMax(0.0, room);
     }

   //--- losing-streak pause
   bool InLossPause(const datetime now)
     {
      if(m_maxConsec <= 0 || m_consecLosses < m_maxConsec)
         return false;
      return (now - m_lastExitTime) < m_pauseMin * 60;
     }
  };

#endif
