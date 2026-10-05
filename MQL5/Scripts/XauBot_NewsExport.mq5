//+------------------------------------------------------------------+
//| XauBot_NewsExport.mq5                                             |
//| Exports the MT5 economic calendar to Common\Files so the XAUUSD   |
//| AI Bot can use the news filter inside the Strategy Tester         |
//| (the calendar API does not work in the tester).                   |
//|                                                                  |
//| Run it once on any chart of a LIVE (or demo) connected terminal.  |
//| Output line: YYYY.MM.DD HH:MI,CCY,IMPORTANCE(1-3),Event name      |
//| Times are broker server time, the same clock the tester uses.     |
//+------------------------------------------------------------------+
#property script_show_inputs
#property copyright "XAUUSD AI Bot"
#property version   "1.00"

input datetime InpFrom       = D'2018.01.01';      // From
input datetime InpTo         = D'2027.01.01';      // To
input string   InpCurrencies = "USD";              // Currencies (comma separated)
input string   InpFile       = "XauBot_news.csv";  // File name in Common\Files

void OnStart()
  {
   string list = InpCurrencies;
   StringReplace(list, " ", "");
   StringToUpper(list);
   string ccy[];
   StringSplit(list, ',', ccy);

   int fh = FileOpen(InpFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE)
     {
      Print("Cannot create ", InpFile, " error ", GetLastError());
      return;
     }
   int written = 0;
   for(int c = 0; c < ArraySize(ccy); c++)
     {
      MqlCalendarValue vals[];
      int n = CalendarValueHistory(vals, InpFrom, InpTo, NULL, ccy[c]);
      if(n <= 0)
        {
         PrintFormat("No calendar data for %s (error %d). Is the terminal connected?", ccy[c], GetLastError());
         continue;
        }
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;
         int imp = (ev.importance == CALENDAR_IMPORTANCE_HIGH) ? 3 : (ev.importance == CALENDAR_IMPORTANCE_MODERATE ? 2 : 1);
         if(imp < 2)
            continue;
         string name = ev.name;
         StringReplace(name, ",", " ");
         FileWriteString(fh, StringFormat("%s,%s,%d,%s\r\n", TimeToString(vals[i].time, TIME_DATE | TIME_MINUTES),
                                          ccy[c], imp, name));
         written++;
        }
     }
   FileClose(fh);
   PrintFormat("XauBot_NewsExport: %d events written to <Common>\\Files\\%s", written, InpFile);
   MessageBox(StringFormat("%d news events exported to Common\\Files\\%s", written, InpFile), "XauBot News Export");
  }
