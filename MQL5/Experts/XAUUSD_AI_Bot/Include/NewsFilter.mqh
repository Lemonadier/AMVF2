//+------------------------------------------------------------------+
//| NewsFilter.mqh - no new trades around high-impact news            |
//|                                                                  |
//| Live: MetaTrader 5 economic calendar (CalendarValueHistory).      |
//| Strategy Tester: the calendar is not available there, so the EA   |
//| reads Common\Files\<csv> written by the XauBot_NewsExport script  |
//| (run it once on a live chart). Without that file it falls back to |
//| the US jobs report (first Friday, 08:30 New York).                |
//| CSV line: YYYY.MM.DD HH:MI,CCY,IMPORTANCE(1-3),Event name         |
//| (time = broker server time)                                       |
//+------------------------------------------------------------------+
#ifndef XAUBOT_NEWSFILTER_MQH
#define XAUBOT_NEWSFILTER_MQH

#include "Common.mqh"

class CNewsFilter
  {
private:
   bool              m_enabled;
   int               m_before, m_after;
   bool              m_highOnly;
   string            m_ccy[];
   string            m_csv;
   bool              m_tester;
   datetime          m_t[];
   string            m_name[];
   datetime          m_lastLoad;
   bool              m_csvLoaded;
   bool              m_usedFallback;

   bool WantCurrency(const string c)
     {
      for(int i = 0; i < ArraySize(m_ccy); i++)
         if(m_ccy[i] == c)
            return true;
      return false;
     }

   void Push(const datetime t, const string name)
     {
      int n = ArraySize(m_t);
      ArrayResize(m_t, n + 1);
      ArrayResize(m_name, n + 1);
      m_t[n] = t;
      m_name[n] = name;
     }

   void LoadLive(const datetime from, const datetime to)
     {
      ArrayResize(m_t, 0);
      ArrayResize(m_name, 0);
      for(int c = 0; c < ArraySize(m_ccy); c++)
        {
         MqlCalendarValue vals[];
         ResetLastError();
         int n = CalendarValueHistory(vals, from, to, NULL, m_ccy[c]);
         for(int i = 0; i < n; i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(vals[i].event_id, ev))
               continue;
            if(ev.importance == CALENDAR_IMPORTANCE_HIGH ||
               (!m_highOnly && ev.importance == CALENDAR_IMPORTANCE_MODERATE))
               Push(vals[i].time, m_ccy[c] + " " + ev.name);
           }
        }
      m_lastLoad = TimeTradeServer();
     }

   void LoadCSV()
     {
      m_csvLoaded = true;
      ArrayResize(m_t, 0);
      ArrayResize(m_name, 0);
      if(!FileIsExist(m_csv, FILE_COMMON))
        {
         m_usedFallback = true;
         Print("[XauBot] news CSV not found in Common\\Files (", m_csv, "): tester uses the NFP-only fallback. ",
               "Run Scripts\\XauBot_NewsExport on a live chart to create it.");
         return;
        }
      int fh = FileOpen(m_csv, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
      if(fh == INVALID_HANDLE)
        {
         m_usedFallback = true;
         return;
        }
      while(!FileIsEnding(fh))
        {
         string line = FileReadString(fh);
         string parts[];
         if(StringSplit(line, ',', parts) < 3)
            continue;
         datetime t = StringToTime(parts[0]);
         if(t <= 0 || !WantCurrency(parts[1]))
            continue;
         int imp = (int)StringToInteger(parts[2]);
         if(imp >= 3 || (!m_highOnly && imp == 2))
            Push(t, parts[1] + " " + (ArraySize(parts) > 3 ? parts[3] : "news"));
        }
      FileClose(fh);
      PrintFormat("[XauBot] %d news events loaded from %s", ArraySize(m_t), m_csv);
     }

   // first Friday of the month, 08:30 New York
   bool NFPWindow(const datetime server, CClock &clk, string &why)
     {
      datetime u = clk.ToUTC(server);
      MqlDateTime s;
      TimeToStruct(u, s);
      datetime ff = NthWeekday(s.year, s.mon, 5, 1);
      datetime ev = ff + (IsUSDST(ff + 12 * 3600) ? 12 : 13) * 3600 + 30 * 60;
      if(u >= ev - m_before * 60 && u <= ev + m_after * 60)
        {
         why = "US jobs report (NFP)";
         return true;
        }
      return false;
     }

public:
   void Init(const bool enabled, const int before, const int after, const bool highOnly,
             const string currencies, const string csv)
     {
      m_enabled = enabled;
      m_before = before;
      m_after = after;
      m_highOnly = highOnly;
      m_csv = csv;
      m_tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_lastLoad = 0;
      m_csvLoaded = false;
      m_usedFallback = false;
      string tmp = currencies;
      StringReplace(tmp, " ", "");
      StringToUpper(tmp);
      StringSplit(tmp, ',', m_ccy);
     }

   //--- true when trading should pause; why = event name
   bool Blocked(const datetime server, CClock &clk, string &why)
     {
      why = "";
      if(!m_enabled)
         return false;
      if(m_tester)
        {
         if(!m_csvLoaded)
            LoadCSV();
         if(m_usedFallback)
            return NFPWindow(server, clk, why);
        }
      else
         if(m_lastLoad == 0 || server - m_lastLoad > 6 * 3600 || server < m_lastLoad)
            LoadLive(server - 86400, server + 3 * 86400);   // refresh: new events get scheduled
      for(int i = 0; i < ArraySize(m_t); i++)
        {
         if(server >= m_t[i] - m_before * 60 && server <= m_t[i] + m_after * 60)
           {
            why = m_name[i];
            return true;
           }
        }
      return false;
     }

   //--- next event after 'server' (for the dashboard)
   string Next(const datetime server)
     {
      datetime best = 0;
      string name = "";
      for(int i = 0; i < ArraySize(m_t); i++)
         if(m_t[i] > server && (best == 0 || m_t[i] < best))
           {
            best = m_t[i];
            name = m_name[i];
           }
      if(best == 0)
         return "-";
      return TimeToString(best, TIME_DATE | TIME_MINUTES) + " " + name;
     }
  };

#endif
