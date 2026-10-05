//+------------------------------------------------------------------+
//| XauBot_ImportGold.mq5 - build a custom gold symbol from M1 CSV    |
//| for offline Strategy Tester runs (research only).                 |
//| CSV in MQL5\Files: YYYY.MM.DD HH:MI,open,high,low,close           |
//| (times already converted to the desired server time zone)         |
//+------------------------------------------------------------------+
#property script_show_inputs
input string InpFile   = "gold_m1.csv";   // CSV in MQL5\Files
input string InpSymbol = "XAUUSD.sim";    // custom symbol name
input int    InpSpreadPoints = 30;        // fixed spread (points of 0.01)

void OnStart()
  {
   if(!SymbolSelect(InpSymbol, false) && !CustomSymbolCreate(InpSymbol, "Custom\\Gold"))
     {
      Print("CustomSymbolCreate failed ", GetLastError());
      return;
     }
   CustomSymbolSetString(InpSymbol, SYMBOL_CURRENCY_BASE, "XAU");
   CustomSymbolSetString(InpSymbol, SYMBOL_CURRENCY_PROFIT, "USD");
   CustomSymbolSetString(InpSymbol, SYMBOL_CURRENCY_MARGIN, "USD");
   CustomSymbolSetString(InpSymbol, SYMBOL_DESCRIPTION, "Gold vs US Dollar (research copy)");
   CustomSymbolSetInteger(InpSymbol, SYMBOL_DIGITS, 2);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_POINT, 0.01);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_TRADE_TICK_SIZE, 0.01);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_TRADE_TICK_VALUE, 1.0);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_TRADE_CONTRACT_SIZE, 100.0);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_VOLUME_MIN, 0.01);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_VOLUME_STEP, 0.01);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_VOLUME_MAX, 100.0);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_TRADE_CALC_MODE, SYMBOL_CALC_MODE_CFDLEVERAGE);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_TRADE_MODE, SYMBOL_TRADE_MODE_FULL);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_TRADE_EXEMODE, SYMBOL_TRADE_EXECUTION_MARKET);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_FILLING_MODE, SYMBOL_FILLING_FOK | SYMBOL_FILLING_IOC);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_ORDER_MODE, 127);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_SPREAD_FLOAT, false);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_SPREAD, InpSpreadPoints);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL, 0);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_SWAP_MODE, SYMBOL_SWAP_MODE_POINTS);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_SWAP_LONG, -50.0);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_SWAP_SHORT, -10.0);
   CustomSymbolSetInteger(InpSymbol, SYMBOL_SWAP_ROLLOVER3DAYS, WEDNESDAY);
   CustomSymbolSetDouble(InpSymbol, SYMBOL_MARGIN_INITIAL, 0.0);

   int fh = FileOpen(InpFile, FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
     {
      Print("cannot open ", InpFile, " ", GetLastError());
      return;
     }
   MqlRates buf[];
   ArrayResize(buf, 0, 100000);
   int n = 0, total = 0;
   while(!FileIsEnding(fh))
     {
      string ts = FileReadString(fh);
      if(ts == "")
         break;
      MqlRates r;
      ZeroMemory(r);
      r.time = StringToTime(ts);
      r.open = FileReadNumber(fh);
      r.high = FileReadNumber(fh);
      r.low = FileReadNumber(fh);
      r.close = FileReadNumber(fh);
      r.tick_volume = 10;
      r.spread = InpSpreadPoints;
      ArrayResize(buf, n + 1, 100000);
      buf[n++] = r;
      if(n >= 100000)
        {
         total += CustomRatesUpdate(InpSymbol, buf);
         n = 0;
         ArrayResize(buf, 0, 100000);
        }
     }
   if(n > 0)
      total += CustomRatesUpdate(InpSymbol, buf);
   FileClose(fh);
   SymbolSelect(InpSymbol, true);
   PrintFormat("ImportGold: %d M1 bars written to %s", total, InpSymbol);
  }
