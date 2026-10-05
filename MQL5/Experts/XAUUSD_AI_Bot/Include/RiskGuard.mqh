//+------------------------------------------------------------------+
//| RiskGuard.mqh - the account protection rules                      |
//|                                                                  |
//|  Rule 1  Daily loss limit: the day's net result (closed + open)   |
//|          may never fall below -DailyMaxLossPct % of the balance   |
//|          the day started with. Trades are also SIZED so that all  |
//|          open stops together cannot break this limit.             |
//|  Rule 2  Profit giveback lock: keep trading until GivebackPct %   |
//|          of the best net profit has been given back (profit $100  |
//|          -> stop when it is back at $60).                         |
//|          Scope ACCOUNT (default): profit since the bot started or |
//|          was reset; the stop stays until you reset it.            |
//|          Scope DAY: profit of the day; the stop ends next day.    |
//|          Rule 2 is a stop trigger only - it does not shrink trade |
//|          size (sizing to its small early room would freeze the    |
//|          bot right after the lock arms).                          |
//|                                                                  |
//|  Totals are rebuilt from the deal history and the account lock    |
//|  state is kept in Common\Files, so restarts cannot reset a stop.  |
//+------------------------------------------------------------------+
#ifndef XAUBOT_RISKGUARD_MQH
#define XAUBOT_RISKGUARD_MQH

#include "Common.mqh"

enum ENUM_XB_GB_SCOPE
  {
   XB_GB_ACCOUNT = 0, // Whole account (since start / reset)
   XB_GB_DAY     = 1, // Each trading day
   XB_GB_OFF     = 2  // Off
  };

class CRiskGuard
  {
private:
   //--- configuration
   long              m_magic;
   string            m_sym;
   double            m_lossPct;
   double            m_gbPct;
   double            m_armPct;
   ENUM_XB_GB_SCOPE  m_scope;
   ENUM_XB_PEAK_BASIS m_basis;
   bool              m_accountWide;
   int               m_resetHour;
   int               m_maxConsec;
   int               m_pauseMin;
   int               m_autoRestartDays;
   bool              m_tester;
   string            m_file;
   long              m_fileLogin;     // account number the state file was opened for

   //--- day state
   datetime          m_dayStart;      // server time
   double            m_base;          // balance at day start
   double            m_dayRealized;
   double            m_dayRealizedPeak;
   double            m_dayEquityPeak;
   bool              m_dayStopped;
   string            m_dayReason;

   //--- account (lock) state
   datetime          m_acctStart;     // baseline time (server)
   double            m_acctBase;      // balance at baseline
   double            m_acctRealized;
   double            m_acctRealizedPeak;
   double            m_acctEquityPeak;
   bool              m_acctStopped;
   datetime          m_acctStopTime;

   //--- shared
   double            m_floating;
   int               m_tradesToday;
   int               m_consecLosses;
   datetime          m_lastExitTime;
   bool              m_dirty;
   datetime          m_lastRefresh;

   string            Key(const string k) { return GVName(m_magic, k); }

   datetime Now()
     {
      datetime t = TimeTradeServer();
      return (t > 0) ? t : TimeCurrent();
     }

   datetime CalcDayStart(const datetime srv)
     {
      datetime shifted = srv - m_resetHour * 3600;
      return DayFloor(shifted) + m_resetHour * 3600;
     }

   bool InScope(const string sym, const long magic)
     {
      return m_accountWide || (sym == m_sym && magic == m_magic);
     }

   //--- account lock state file (live only; the tester keeps it in memory)
   void SaveAccount()
     {
      if(m_tester)
         return;
      int fh = FileOpen(m_file, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(fh == INVALID_HANDLE)
         return;
      FileWriteString(fh, StringFormat("%I64d,%d,%I64d,%.2f\r\n", (long)m_acctStart, m_acctStopped ? 1 : 0,
                                       (long)m_acctStopTime, m_acctEquityPeak));
      FileClose(fh);
     }

   bool LoadAccount()
     {
      if(m_tester || !FileIsExist(m_file, FILE_COMMON))
         return false;
      int fh = FileOpen(m_file, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(fh == INVALID_HANDLE)
         return false;
      string line = FileReadString(fh);
      FileClose(fh);
      string p[];
      if(StringSplit(line, ',', p) < 4)
         return false;
      m_acctStart = (datetime)StringToInteger(p[0]);
      m_acctStopped = (StringToInteger(p[1]) != 0);
      m_acctStopTime = (datetime)StringToInteger(p[2]);
      m_acctEquityPeak = StringToDouble(p[3]);
      return (m_acctStart > 0);
     }

   double DealPnL(const ulong tk)
     {
      return HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP) +
             HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);
     }

public:
   void Init(const long magic, const string sym, const double lossPct, const double gbPct, const double armPct,
             const ENUM_XB_GB_SCOPE scope, const ENUM_XB_PEAK_BASIS basis, const bool accountWide,
             const int resetHour, const int maxConsec, const int pauseMin, const int autoRestartDays,
             const bool resetLock, const datetime fixedStart)
     {
      m_magic = magic; m_sym = sym;
      m_lossPct = lossPct; m_gbPct = gbPct; m_armPct = armPct;
      m_scope = scope; m_basis = basis; m_accountWide = accountWide;
      m_resetHour = (int)Clip(resetHour, 0, 23);
      m_maxConsec = maxConsec; m_pauseMin = pauseMin;
      m_autoRestartDays = autoRestartDays;
      m_tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_fileLogin = AccountInfoInteger(ACCOUNT_LOGIN);
      m_file = StringFormat("XauBot_%I64d_%I64d_account.txt", m_fileLogin, magic);
      m_dayStart = 0; m_dayStopped = false; m_dayReason = "";
      m_dayEquityPeak = 0.0;
      m_acctStopped = false; m_acctStopTime = 0; m_acctEquityPeak = 0.0;
      m_acctStart = 0;
      if(fixedStart > 0)
        {
         bool had = LoadAccount();
         if(!had || m_acctStart != fixedStart || resetLock)
           {
            m_acctStopped = false; m_acctStopTime = 0; m_acctEquityPeak = 0.0;
           }
         m_acctStart = fixedStart;
        }
      else
         if(resetLock || !LoadAccount())
           {
            m_acctStart = Now();
            m_acctStopped = false; m_acctStopTime = 0; m_acctEquityPeak = 0.0;
           }
      SaveAccount();
      if(m_scope == XB_GB_ACCOUNT)
         PrintFormat("[XauBot] profit lock: whole account since %s%s", TimeToString(m_acctStart, TIME_DATE | TIME_MINUTES),
                     m_acctStopped ? " - STOPPED (set 'Reset the account profit lock' = true to restart)" : "");
      m_dirty = true;
      m_lastRefresh = 0;
      Refresh();
     }

   void MarkDirty() { m_dirty = true; }

   //--- start a new account baseline now (reset of the lock)
   void ResetAccountLock()
     {
      m_acctStart = Now();
      m_acctStopped = false;
      m_acctStopTime = 0;
      m_acctEquityPeak = 0.0;
      SaveAccount();
      m_dirty = true;
      PrintFormat("[XauBot] account profit lock reset - new baseline %s", TimeToString(m_acctStart, TIME_DATE | TIME_MINUTES));
     }

   //--- rebuild totals from the deal history
   void Refresh()
     {
      datetime now = Now();
      datetime ds = CalcDayStart(now);
      if(ds != m_dayStart)
        {
         m_dayStart = ds;
         m_dayStopped = false;
         m_dayReason = "";
         m_dayEquityPeak = 0.0;
         // a daily stop recorded earlier today survives restarts
         if((datetime)GVGet(Key("stopday"), 0) == m_dayStart)
           {
            m_dayStopped = true;
            int code = (int)GVGet(Key("stopcode"), 0);
            m_dayReason = (code == 1) ? "DAILY LOSS LIMIT" : (code == 2 ? "DAILY PROFIT GIVEBACK" : "STOPPED");
           }
         if((datetime)GVGet(Key("peakday"), 0) == m_dayStart)
            m_dayEquityPeak = GVGet(Key("peak"), 0.0);
        }

      double accDay = 0.0, scopeDay = 0.0, dayRun = 0.0;
      double accSince = 0.0, scopeSince = 0.0, acctRun = 0.0;
      m_tradesToday = 0;
      m_consecLosses = 0;
      m_lastExitTime = 0;
      datetime from = MathMin(MathMin(m_dayStart, now - 7 * 86400), m_acctStart > 0 ? m_acctStart : now);
      if(HistorySelect(from, now + 86400))
        {
         int total = HistoryDealsTotal();
         // losing streak of the bot, newest exit first
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
            if(m_lastExitTime == 0)
               m_lastExitTime = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
            if(DealPnL(tk) < 0)
               m_consecLosses++;
            else
               break;
           }
         // chronological totals for today and since the account baseline
         for(int i = 0; i < total; i++)
           {
            ulong tk = HistoryDealGetTicket(i);
            if(tk == 0)
               continue;
            long type = HistoryDealGetInteger(tk, DEAL_TYPE);
            if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
               continue;
            datetime t = (datetime)HistoryDealGetInteger(tk, DEAL_TIME);
            string sym = HistoryDealGetString(tk, DEAL_SYMBOL);
            long magic = HistoryDealGetInteger(tk, DEAL_MAGIC);
            double pnl = DealPnL(tk);
            bool scope = InScope(sym, magic);
            if(t >= m_dayStart)
              {
               accDay += pnl;
               if(scope)
                 {
                  scopeDay += pnl;
                  dayRun = MathMax(dayRun, scopeDay);
                 }
               if(magic == m_magic && sym == m_sym && HistoryDealGetInteger(tk, DEAL_ENTRY) == DEAL_ENTRY_IN)
                  m_tradesToday++;
              }
            if(m_acctStart > 0 && t >= m_acctStart)
              {
               accSince += pnl;
               if(scope)
                 {
                  scopeSince += pnl;
                  acctRun = MathMax(acctRun, scopeSince);
                 }
              }
           }
        }
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      m_base = bal - accDay;
      if(m_base <= 0)
         m_base = bal;
      m_acctBase = bal - accSince;
      if(m_acctBase <= 0)
         m_acctBase = bal;
      m_dayRealized = scopeDay;
      m_dayRealizedPeak = dayRun;
      m_acctRealized = scopeSince;
      m_acctRealizedPeak = acctRun;
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
      datetime now = Now();
      if(m_dirty || CalcDayStart(now) != m_dayStart || now - m_lastRefresh >= 60)
         Refresh();
      m_floating = Floating();

      // the account number can read 0 right after a terminal start: re-link the lock state to the real account
      if(!m_tester && m_fileLogin == 0 && AccountInfoInteger(ACCOUNT_LOGIN) != 0)
        {
         datetime keepStart = m_acctStart;
         bool keepStop = m_acctStopped;
         datetime keepStopTime = m_acctStopTime;
         double keepPeak = m_acctEquityPeak;
         m_fileLogin = AccountInfoInteger(ACCOUNT_LOGIN);
         m_file = StringFormat("XauBot_%I64d_%I64d_account.txt", m_fileLogin, m_magic);
         if(!LoadAccount())
           {
            m_acctStart = keepStart; m_acctStopped = keepStop; m_acctStopTime = keepStopTime; m_acctEquityPeak = keepPeak;
           }
         SaveAccount();
         m_dirty = true;
        }

      // automatic restart of a fired account lock (0 = manual only)
      if(m_acctStopped && m_autoRestartDays > 0 && now - m_acctStopTime >= (long)m_autoRestartDays * 86400)
        {
         ResetAccountLock();
         Refresh();
        }

      double dayNet = DayNet(), acctNet = AccountNet();
      if(dayNet > m_dayEquityPeak)
        {
         m_dayEquityPeak = dayNet;
         if(m_basis == XB_PEAK_EQUITY && m_scope == XB_GB_DAY)
           {
            GVSet(Key("peak"), m_dayEquityPeak);
            GVSet(Key("peakday"), (double)m_dayStart);
           }
        }
      if(acctNet > m_acctEquityPeak)
        {
         m_acctEquityPeak = acctNet;
         if(m_basis == XB_PEAK_EQUITY && m_scope == XB_GB_ACCOUNT)
            SaveAccount();
        }

      // account data not loaded yet (terminal just started / not logged in): never judge on a zero balance
      if(m_base <= 0 || AccountInfoDouble(ACCOUNT_BALANCE) <= 0)
        {
         m_dirty = true;
         return false;
        }
      bool fired = false;
      if(!m_dayStopped && dayNet <= -LossLimit())
        {
         StopDay(1, "DAILY LOSS LIMIT");
         fired = true;
        }
      if(!m_dayStopped && m_scope == XB_GB_DAY && DayArmed() && dayNet <= DayPeak() * (1.0 - m_gbPct / 100.0))
        {
         StopDay(2, "DAILY PROFIT GIVEBACK");
         fired = true;
        }
      if(!m_acctStopped && m_scope == XB_GB_ACCOUNT && AccountArmed() && acctNet <= AccountPeak() * (1.0 - m_gbPct / 100.0))
        {
         m_acctStopped = true;
         m_acctStopTime = now;
         SaveAccount();
         PrintFormat("[XauBot] ACCOUNT PROFIT LOCK hit: profit %.2f, best %.2f (gave back %.0f%%) -> no new trades until reset%s",
                     acctNet, AccountPeak(), (AccountPeak() - acctNet) / AccountPeak() * 100.0,
                     m_autoRestartDays > 0 ? StringFormat(" (auto restart in %d days)", m_autoRestartDays) : "");
         fired = true;
        }
      return fired;
     }

   void StopDay(const int code, const string why)
     {
      m_dayStopped = true;
      m_dayReason = why;
      GVSet(Key("stopday"), (double)m_dayStart);
      GVSet(Key("stopcode"), code);
      PrintFormat("[XauBot] %s hit: day net %.2f, day-start balance %.2f -> no new trades until next day", why, DayNet(), m_base);
     }

   //--- day numbers
   double   Base()          { return m_base; }
   double   DayRealized()   { return m_dayRealized; }
   double   FloatingPL()    { return m_floating; }
   double   DayNet()        { return m_dayRealized + m_floating; }
   double   DayPeak()       { return (m_basis == XB_PEAK_REALIZED) ? m_dayRealizedPeak : m_dayEquityPeak; }
   bool     DayArmed()      { double p = DayPeak(); return (p > 0.0 && p >= m_base * m_armPct / 100.0); }
   double   LossLimit()     { return m_base * m_lossPct / 100.0; }

   //--- account numbers
   datetime AccountStart()  { return m_acctStart; }
   double   AccountBase()   { return m_acctBase; }
   double   AccountNet()    { return m_acctRealized + m_floating; }
   double   AccountPeak()   { return (m_basis == XB_PEAK_REALIZED) ? m_acctRealizedPeak : m_acctEquityPeak; }
   double   AccountArmLevel(){ return m_acctBase * m_armPct / 100.0; }
   bool     AccountArmed()  { double p = AccountPeak(); return (p > 0.0 && p >= AccountArmLevel()); }
   double   AccountLockLevel() { return AccountPeak() * (1.0 - m_gbPct / 100.0); }
   bool     AccountStopped(){ return m_acctStopped; }

   //--- combined state
   bool     Stopped()       { return m_dayStopped || m_acctStopped; }
   string   Reason()
     {
      if(m_acctStopped)
         return "ACCOUNT PROFIT LOCK";
      return m_dayReason;
     }
   ENUM_XB_GB_SCOPE Scope() { return m_scope; }
   int      TradesToday()   { return m_tradesToday; }
   int      ConsecLosses()  { return m_consecLosses; }
   datetime DayStart()      { return m_dayStart; }

   //--- money that can still be lost today before the daily loss limit (sizing cap)
   double Room()
     {
      return MathMax(0.0, LossLimit() + DayNet());
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
