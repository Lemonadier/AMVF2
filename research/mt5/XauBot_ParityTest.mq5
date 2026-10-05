//+------------------------------------------------------------------+
//| XauBot_ParityTest.mq5 - replays history through the EA's own      |
//| CMarket/CSignals code and writes every signal + the market        |
//| snapshot to MQL5\Files, to compare with research/xau_lib.py.      |
//+------------------------------------------------------------------+
#property script_show_inputs
#include "../../MQL5/Experts/XAUUSD_AI_Bot/Include/Common.mqh"
#include "../../MQL5/Experts/XAUUSD_AI_Bot/Include/Market.mqh"
#include "../../MQL5/Experts/XAUUSD_AI_Bot/Include/Signals.mqh"

input string   InpSymbol = "XAUUSD.sim";
input datetime InpFrom   = D'2023.03.01';
input bool     InpAllStrategies = true;
input ENUM_XB_GMT_MODE InpGMTMode = XB_GMT_NYCLOSE;   // server time zone of the symbol's data
input int      InpGMTOffset = 0;                      // hours, when mode = manual

void OnStart()
  {
   CClock clk;
   clk.Init(InpGMTMode, InpGMTOffset);
   CMarket m;
   if(!m.Init(InpSymbol, PERIOD_H1))
      return;
   XBSignalConfig sc;
   for(int k = 0; k < XB_NSTRAT; k++)
      sc.use[k] = InpAllStrategies || k == XB_TPB || k == XB_MOM;
   sc.tpR[XB_TPB] = 0; sc.tpR[XB_MOM] = 0; sc.tpR[XB_LBO] = 2; sc.tpR[XB_LSR] = 2; sc.tpR[XB_MR] = 1.5;
   sc.slMinATR = 0.8; sc.slMaxATR = 3.0; sc.d1Filter = XB_D1_EMA50;
   sc.lboBufferATR = 0.1; sc.lboMinRangeD1 = 0.25; sc.lboMaxRangeD1 = 1.2; sc.lsrWick = 0.5;
   sc.mrAdxMax = 20.0; sc.momAdxMin = 25.0; sc.momRangeATR = 1.2;
   CSignals sg;
   sg.Init(InpSymbol, 999, sc);
   sg.ResetState();

   // let the indicators finish calculating
   for(int w = 0; w < 120; w++)
     {
      if(m.Update(clk, 0))
         break;
      Sleep(500);
     }
   int start = iBarShift(InpSymbol, PERIOD_H1, InpFrom, false);
   string tag = (InpGMTMode == XB_GMT_MANUAL) ? StringFormat("_gmt%d", InpGMTOffset) : "";
   int fs = FileOpen("parity_signals" + tag + ".csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   int fc = FileOpen("parity_context" + tag + ".csv", FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   FileWrite(fs, "close_time", "strat", "dir", "sl_dist");
   FileWrite(fc, "close_time", "close", "atr", "ema21", "ema50", "rsi", "adx", "h1up", "h1dn", "d1close", "d1ema50",
             "asia_hi", "asia_lo", "pdh", "pdl", "d1atr", "lon_h", "ny_h");
   int nsig = 0, nbar = 0;
   XBSignal sig[];
   for(int s = start; s >= 0; s--)
     {
      if(!m.Update(clk, s))
         continue;
      nbar++;
      FileWrite(fc, TimeToString(m.barClose, TIME_DATE | TIME_MINUTES), m.c[1], m.atr[1], m.ema21[1], m.ema50[1], m.rsi[1],
                m.adx[1], (int)m.h1Up, (int)m.h1Dn, m.d1Close, m.d1Ema50, m.asiaValid ? m.asiaHi : 0.0,
                m.asiaValid ? m.asiaLo : 0.0, m.pdh, m.pdl, m.d1Atr, m.lonH, m.nyH);
      int n = sg.Generate(m, sig);
      for(int i = 0; i < n; i++)
        {
         FileWrite(fs, TimeToString(m.barClose, TIME_DATE | TIME_MINUTES), StrategyName(sig[i].strategy), sig[i].dir,
                   DoubleToString(sig[i].slDist, 4));
         nsig++;
        }
     }
   FileClose(fs);
   FileClose(fc);
   m.Release();
   PrintFormat("ParityTest: %d bars, %d signals", nbar, nsig);
   TerminalClose(0);
  }
