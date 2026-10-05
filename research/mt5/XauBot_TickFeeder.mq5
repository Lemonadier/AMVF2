//+------------------------------------------------------------------+
//| XauBot_TickFeeder.mq5 - pushes synthetic live ticks into a custom |
//| symbol so an EA attached to it runs OnTick offline (smoke test).  |
//+------------------------------------------------------------------+
input string InpSymbol = "XAUUSD.live";
input int    InpSeconds = 60;

void OnStart()
  {
   double last = iClose(InpSymbol, PERIOD_M1, 0);
   if(last <= 0) last = 4500.0;
   MathSrand(7);
   for(int i = 0; i < InpSeconds * 2 && !IsStopped(); i++)
     {
      MqlTick t[1];
      ZeroMemory(t);
      last += (MathRand() / 32767.0 - 0.5) * 0.8;
      t[0].time = TimeGMT() + 2 * 3600;
      t[0].time_msc = (long)t[0].time * 1000;
      t[0].bid = NormalizeDouble(last, 2);
      t[0].ask = NormalizeDouble(last + 0.30, 2);
      t[0].last = t[0].bid;
      t[0].volume = 1;
      t[0].flags = TICK_FLAG_BID | TICK_FLAG_ASK;
      if(CustomTicksAdd(InpSymbol, t) < 0)
         Print("CustomTicksAdd failed ", GetLastError());
      Sleep(500);
     }
   Print("TickFeeder done");
   TerminalClose(0);
  }
