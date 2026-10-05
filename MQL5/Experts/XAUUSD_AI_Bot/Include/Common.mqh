//+------------------------------------------------------------------+
//| Common.mqh - shared types, time-zone helpers and utilities        |
//| XAUUSD AI Bot                                                     |
//+------------------------------------------------------------------+
#ifndef XAUBOT_COMMON_MQH
#define XAUBOT_COMMON_MQH

#define XB_VERSION      "1.10"
#define XB_NSTRAT       5
#define XB_NFEAT        20

enum ENUM_XB_STRATEGY
  {
   XB_TPB = 0,   // Trend pullback
   XB_LBO = 1,   // London breakout of the Asian range
   XB_LSR = 2,   // Liquidity sweep reversal
   XB_MR  = 3,   // Mean reversion (range regime)
   XB_MOM = 4    // Momentum / Donchian breakout
  };

enum ENUM_XB_GMT_MODE
  {
   XB_GMT_AUTO     = 0, // Auto (live: detect; tester: NY-close broker)
   XB_GMT_NYCLOSE  = 1, // Broker on NY-close time (GMT+2 winter / GMT+3 summer)
   XB_GMT_MANUAL   = 2  // Manual fixed offset
  };

enum ENUM_XB_PEAK_BASIS
  {
   XB_PEAK_REALIZED = 0, // Closed (banked) profit of the day
   XB_PEAK_EQUITY   = 1  // Closed + floating profit (stricter)
  };

string StrategyName(const int s)
  {
   switch(s)
     {
      case XB_TPB: return "TPB";
      case XB_LBO: return "LBO";
      case XB_LSR: return "LSR";
      case XB_MR:  return "MR";
      case XB_MOM: return "MOM";
     }
   return "?";
  }

int StrategyFromName(const string n)
  {
   for(int s = 0; s < XB_NSTRAT; s++)
      if(StringFind(n, "|" + StrategyName(s) + "|") >= 0)
         return s;
   return -1;
  }

//--- one trade idea produced by a strategy
struct XBSignal
  {
   int      strategy;
   int      dir;        // +1 buy, -1 sell
   double   slDist;     // stop distance in price units (= 1R)
   double   tpR;        // take profit in R (0 = none)
   double   feat[XB_NFEAT];
   double   prob;       // AI probability of TP before SL
   double   edgeR;      // AI expected value in R
   double   riskMult;   // position size multiplier
   string   note;
  };

//+------------------------------------------------------------------+
//| Math helpers                                                      |
//+------------------------------------------------------------------+
double Clip(const double x, const double lo, const double hi) { return MathMax(lo, MathMin(hi, x)); }
double Clip1(const double x) { return Clip(x, -1.0, 1.0); }
double SafeDiv(const double a, const double b, const double def = 0.0) { return (MathAbs(b) > 1e-12) ? a / b : def; }

//+------------------------------------------------------------------+
//| Calendar / DST helpers (all in UTC)                               |
//+------------------------------------------------------------------+
datetime MakeTime(const int y, const int mo, const int d, const int h = 0, const int mi = 0)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = y; s.mon = mo; s.day = d; s.hour = h; s.min = mi; s.sec = 0;
   return StructToTime(s);
  }

// n-th (1..5) given weekday (0=Sun) of a month; n = -1 -> last
datetime NthWeekday(const int y, const int mo, const int dow, const int n)
  {
   if(n > 0)
     {
      datetime first = MakeTime(y, mo, 1);
      MqlDateTime s; TimeToStruct(first, s);
      int add = (dow - s.day_of_week + 7) % 7;
      return first + (datetime)((add + 7 * (n - 1)) * 86400);
     }
   int ny = (mo == 12) ? y + 1 : y;
   int nm = (mo == 12) ? 1 : mo + 1;
   datetime last = MakeTime(ny, nm, 1) - 86400;
   MqlDateTime s; TimeToStruct(last, s);
   int sub = (s.day_of_week - dow + 7) % 7;
   return last - (datetime)(sub * 86400);
  }

// US daylight saving: 2nd Sunday of March 07:00 UTC .. 1st Sunday of November 06:00 UTC
bool IsUSDST(const datetime utc)
  {
   MqlDateTime s; TimeToStruct(utc, s);
   datetime a = NthWeekday(s.year, 3, 0, 2) + 7 * 3600;
   datetime b = NthWeekday(s.year, 11, 0, 1) + 6 * 3600;
   return (utc >= a && utc < b);
  }

// UK/EU summer time: last Sunday of March 01:00 UTC .. last Sunday of October 01:00 UTC
bool IsUKDST(const datetime utc)
  {
   MqlDateTime s; TimeToStruct(utc, s);
   datetime a = NthWeekday(s.year, 3, 0, -1) + 3600;
   datetime b = NthWeekday(s.year, 10, 0, -1) + 3600;
   return (utc >= a && utc < b);
  }

double HourOf(const datetime t)
  {
   MqlDateTime s; TimeToStruct(t, s);
   return s.hour + s.min / 60.0;
  }

int DayOfWeek(const datetime t)
  {
   MqlDateTime s; TimeToStruct(t, s);
   return s.day_of_week;
  }

datetime DayFloor(const datetime t) { return t - (t % 86400); }

//+------------------------------------------------------------------+
//| Server <-> UTC conversion                                         |
//+------------------------------------------------------------------+
class CClock
  {
private:
   ENUM_XB_GMT_MODE m_mode;
   int              m_manualHours;
   bool             m_tester;
   int              m_liveOffset;   // seconds, detected live
   datetime         m_lastDetect;

public:
   void Init(const ENUM_XB_GMT_MODE mode, const int manualHours)
     {
      m_mode = mode;
      m_manualHours = manualHours;
      m_tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_liveOffset = 0;
      m_lastDetect = 0;
      Detect();
     }

   void Detect()
     {
      if(m_tester || m_mode != XB_GMT_AUTO)
         return;
      datetime srv = TimeTradeServer();
      datetime gmt = TimeGMT();
      if(srv <= 0 || gmt <= 0)
         return;
      int off = (int)(srv - gmt);
      m_liveOffset = (int)MathRound(off / 1800.0) * 1800;
      m_lastDetect = srv;
     }

   // seconds to subtract from server time to get UTC
   int OffsetAt(const datetime server)
     {
      if(m_mode == XB_GMT_MANUAL)
         return m_manualHours * 3600;
      if(m_mode == XB_GMT_AUTO && !m_tester)
        {
         if(server - m_lastDetect > 3600)
            Detect();
         return m_liveOffset;
        }
      // NY-close convention: server = New York time + 7h
      datetime approxUtc = server - 2 * 3600;
      return IsUSDST(approxUtc) ? 3 * 3600 : 2 * 3600;
     }

   datetime ToUTC(const datetime server)   { return server - OffsetAt(server); }
   // OffsetAt() expects server time; utc + 2h is close enough to pick the right DST side
   datetime ToServer(const datetime utc)   { return utc + OffsetAt(utc + 2 * 3600); }
   double   UTCHour(const datetime server) { return HourOf(ToUTC(server)); }
   double   LondonHour(const datetime server)
     {
      datetime u = ToUTC(server);
      return HourOf(u + (IsUKDST(u) ? 3600 : 0));
     }
   double   NYHour(const datetime server)
     {
      datetime u = ToUTC(server);
      return HourOf(u - (IsUSDST(u) ? 4 : 5) * 3600);
     }
   string   Describe(const datetime server)
     {
      int off = OffsetAt(server);
      return StringFormat("GMT%+.1f (%s)", off / 3600.0,
                          m_mode == XB_GMT_MANUAL ? "manual" : (m_mode == XB_GMT_AUTO && !m_tester ? "auto" : "NY-close"));
     }
  };

//+------------------------------------------------------------------+
//| Symbol helpers                                                    |
//+------------------------------------------------------------------+
bool IsGoldUSD(const string sym)
  {
   string u = sym;
   StringToUpper(u);
   string base = SymbolInfoString(sym, SYMBOL_CURRENCY_BASE);
   string prof = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
   StringToUpper(base);
   StringToUpper(prof);
   if(StringFind(u, "XAUUSD") >= 0)
      return true;
   if(base == "XAU" && prof == "USD")
      return true;
   // brokers that call it GOLD / GOLD.m / GOLDm, quoted in USD
   if(StringFind(u, "GOLD") == 0 && prof == "USD")
     {
      string rest = StringSubstr(u, 4);
      if(StringFind(rest, "EUR") < 0 && StringFind(rest, "AUD") < 0 && StringFind(rest, "JPY") < 0 &&
         StringFind(rest, "GBP") < 0 && StringFind(rest, "CHF") < 0)
         return true;
     }
   return false;
  }

string GVName(const long magic, const string key)
  {
   return StringFormat("XB%I64d_%s", magic, key);
  }

double GVGet(const string name, const double def = 0.0)
  {
   if(GlobalVariableCheck(name))
      return GlobalVariableGet(name);
   return def;
  }

void GVSet(const string name, const double v)
  {
   GlobalVariableSet(name, v);
  }

#endif
