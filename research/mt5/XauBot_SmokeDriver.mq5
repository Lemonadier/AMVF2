//+------------------------------------------------------------------+
//| XauBot_SmokeDriver.mq5 - test-only wrapper around the real EA.    |
//| An offline terminal does not call OnTick for custom-symbol ticks, |
//| so this calls the EA's OnTick() from a 1-second timer. After the  |
//| first processed bar it injects synthetic signals through the EA's |
//| own feature / AI / pre-trade / sizing code.                       |
//+------------------------------------------------------------------+
#include "../../MQL5/Experts/XAUUSD_AI_Bot/XAUUSD_AI_Bot.mq5"

class CSmokeTimer
  {
public:
                     CSmokeTimer() { EventSetTimer(1); }
  };
CSmokeTimer g_smokeTimer;
int g_smokeCalls = 0;

void InjectSignal(const int dir)
  {
   XBSignal s;
   s.strategy = XB_TPB;
   s.dir = dir;
   s.slDist = 0.8;          // tiny bracket so the random-walk feed resolves it quickly
   s.tpR = 0.0;
   s.riskMult = 1.0;
   s.note = "smoke";
   g_signals.Features(g_market, s);
   s.prob = g_ai.Predict(s.feat);
   MqlTick tk;
   SymbolInfoTick(_Symbol, tk);
   g_ai.AddShadow(s, dir > 0 ? tk.ask : tk.bid, TimeTradeServer());
   string why = "";
   bool ok = CanTrade(s, TimeTradeServer(), why);
   string info = "";
   bool done = ok ? Execute(s, info) : false;
   PrintFormat("[Smoke] injected %s p=%.3f feat[1..4]=%.2f %.2f %.2f %.2f | CanTrade=%s %s | Execute=%s %s | shadows=%d",
               dir > 0 ? "BUY" : "SELL", s.prob, s.feat[1], s.feat[2], s.feat[3], s.feat[4],
               ok ? "yes" : "no", why, done ? "yes" : "no", info, g_ai.OpenShadows());
  }

void OnTimer()
  {
   OnTick();
   g_smokeCalls++;
   if(g_lastSignalBar > 0 && (g_smokeCalls == 5 || g_smokeCalls == 6 || g_smokeCalls == 30 || g_smokeCalls == 31))
      InjectSignal(g_smokeCalls % 2 == 1 ? 1 : -1);
   if(g_smokeCalls % 60 == 0)
      PrintFormat("[Smoke] t=%ds learned samples=%I64d open shadows=%d calN=%I64d meanP=%.3f meanY=%.3f | guard: base %.2f net %.2f stopped=%s room %.2f",
                  g_smokeCalls, g_ai.Samples(), g_ai.OpenShadows(), g_ai.CalN(), g_ai.CalMeanP(), g_ai.CalMeanY(),
                  g_guard.Base(), g_guard.DayNet(), g_guard.Stopped() ? "yes" : "no", g_guard.Room());
   if(g_smokeCalls == 90)
      PrintFormat("[Smoke] account lock: since %s base %.2f net %.2f peak %.2f armed=%s stopped=%s", TimeToString(g_guard.AccountStart()), g_guard.AccountBase(), g_guard.AccountNet(), g_guard.AccountPeak(), g_guard.AccountArmed() ? "yes" : "no", g_guard.AccountStopped() ? "yes" : "no");
  }
