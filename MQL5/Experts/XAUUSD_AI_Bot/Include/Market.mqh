//+------------------------------------------------------------------+
//| Market.mqh - indicators and a snapshot of the market per bar      |
//|                                                                  |
//| All arrays are "as series": index 1 = last CLOSED bar of the      |
//| signal timeframe, 2 = the one before, etc. Index 0 (the forming   |
//| bar) is never used for decisions.                                 |
//+------------------------------------------------------------------+
#ifndef XAUBOT_MARKET_MQH
#define XAUBOT_MARKET_MQH

#include "Common.mqh"

#define XB_BARS     40      // bars of signal-TF data kept
#define XB_ATRHIST  220     // ATR history for the volatility percentile

class CMarket
  {
private:
   string            m_sym;
   ENUM_TIMEFRAMES   m_tf;
   int               hATR, hEMA21, hEMA50, hRSI, hADX, hBB;
   int               hH1EMA50, hH1EMA200, hH1ATR, hH1ADX, hH4EMA50, hD1EMA50, hD1EMA200;
   datetime          m_asiaDay;      // UTC day the cached Asian range belongs to
   datetime          m_nyDayStart;   // UTC start of the cached NY trading day
   double            m_dAtrCache;
   double            m_pdhCache, m_pdlCache;

   bool Copy(const int handle, const int buf, double &arr[], const int n, const int shift = 0)
     {
      ArraySetAsSeries(arr, true);
      return (CopyBuffer(handle, buf, shift, n, arr) == n);
     }

   // index of the last higher-timeframe bar that was COMPLETE at time t
   int DoneIndex(const ENUM_TIMEFRAMES tf, const datetime t)
     {
      int idx = iBarShift(m_sym, tf, t - 1, false);
      if(idx < 0)
         return -1;
      if(iTime(m_sym, tf, idx) + PeriodSeconds(tf) > t)
         idx++;
      return idx;
     }

   double One(const int handle, const int buf, const int shift)
     {
      double v[1];
      if(CopyBuffer(handle, buf, shift, 1, v) != 1)
         return EMPTY_VALUE;
      return v[0];
     }

public:
   string            lastError;      // why the last Update() returned false
   //--- signal timeframe series
   double            o[], h[], l[], c[];
   double            atr[], ema21[], ema50[], rsi[], adx[], bbUp[], bbLo[], bbMid[];
   double            atrHist[];
   //--- context of the last closed bar
   datetime          barOpen;        // server time, open of bar #1
   datetime          barClose;       // server time, close of bar #1
   double            h1Close, h1Ema50, h1Ema200, h1Ema50Prev, h1Atr, h1Adx;
   double            h4Close, h4Ema50;
   double            d1Close, d1Ema50, d1Ema200;
   double            d1Atr, pdh, pdl;
   double            asiaHi, asiaLo;
   bool              asiaValid;
   double            donHi1, donLo1, donHi2, donLo2;
   double            er, atrPct;
   double            utcH, lonH, nyH;
   int               dowUtc;
   datetime          utcDay;         // 00:00 UTC of the bar-close day
   bool              h1Up, h1Dn;

   bool Init(const string sym, const ENUM_TIMEFRAMES tf)
     {
      m_sym = sym;
      m_tf = tf;
      hATR      = iATR(sym, tf, 14);
      hEMA21    = iMA(sym, tf, 21, 0, MODE_EMA, PRICE_CLOSE);
      hEMA50    = iMA(sym, tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      hRSI      = iRSI(sym, tf, 14, PRICE_CLOSE);
      hADX      = iADX(sym, tf, 14);
      hBB       = iBands(sym, tf, 20, 0, 2.0, PRICE_CLOSE);
      hH1EMA50  = iMA(sym, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
      hH1EMA200 = iMA(sym, PERIOD_H1, 200, 0, MODE_EMA, PRICE_CLOSE);
      hH1ATR    = iATR(sym, PERIOD_H1, 14);
      hH1ADX    = iADX(sym, PERIOD_H1, 14);
      hH4EMA50  = iMA(sym, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
      hD1EMA50  = iMA(sym, PERIOD_D1, 50, 0, MODE_EMA, PRICE_CLOSE);
      hD1EMA200 = iMA(sym, PERIOD_D1, 200, 0, MODE_EMA, PRICE_CLOSE);
      m_asiaDay = 0;
      m_nyDayStart = 0;
      m_pdhCache = 0.0; m_pdlCache = 0.0; m_dAtrCache = 0.0;
      d1Atr = 0.0; pdh = 0.0; pdl = 0.0;
      asiaValid = false; asiaHi = 0.0; asiaLo = 0.0;
      h1Up = false; h1Dn = false;
      if(hATR == INVALID_HANDLE || hEMA21 == INVALID_HANDLE || hEMA50 == INVALID_HANDLE || hRSI == INVALID_HANDLE ||
         hADX == INVALID_HANDLE || hBB == INVALID_HANDLE || hH1EMA50 == INVALID_HANDLE || hH1EMA200 == INVALID_HANDLE ||
         hH1ATR == INVALID_HANDLE || hH1ADX == INVALID_HANDLE || hH4EMA50 == INVALID_HANDLE ||
         hD1EMA50 == INVALID_HANDLE || hD1EMA200 == INVALID_HANDLE)
        {
         Print("[XauBot] failed to create indicator handles, error ", GetLastError());
         return false;
        }
      return true;
     }

   void Release()
     {
      int hs[] = {hATR, hEMA21, hEMA50, hRSI, hADX, hBB, hH1EMA50, hH1EMA200, hH1ATR, hH1ADX, hH4EMA50, hD1EMA50, hD1EMA200};
      for(int i = 0; i < ArraySize(hs); i++)
         if(hs[i] != INVALID_HANDLE)
            IndicatorRelease(hs[i]);
     }

   //--- refresh everything for the bar that just closed. false = data not ready yet.
   //--- shift > 0 replays history: bar #1 becomes the bar 'shift' bars before the last closed one.
   bool Update(CClock &clk, const int shift = 0)
     {
      ArraySetAsSeries(o, true); ArraySetAsSeries(h, true); ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);
      lastError = "";
      if(CopyOpen(m_sym, m_tf, shift, XB_BARS, o) != XB_BARS || CopyHigh(m_sym, m_tf, shift, XB_BARS, h) != XB_BARS ||
         CopyLow(m_sym, m_tf, shift, XB_BARS, l) != XB_BARS || CopyClose(m_sym, m_tf, shift, XB_BARS, c) != XB_BARS)
        {
         lastError = StringFormat("price history not ready (%d)", GetLastError());
         return false;
        }
      if(!Copy(hATR, 0, atr, XB_BARS, shift) || !Copy(hEMA21, 0, ema21, XB_BARS, shift) || !Copy(hEMA50, 0, ema50, XB_BARS, shift) ||
         !Copy(hRSI, 0, rsi, XB_BARS, shift) || !Copy(hADX, 0, adx, XB_BARS, shift) || !Copy(hBB, 0, bbMid, XB_BARS, shift) ||
         !Copy(hBB, 1, bbUp, XB_BARS, shift) || !Copy(hBB, 2, bbLo, XB_BARS, shift) || !Copy(hATR, 0, atrHist, XB_ATRHIST, shift))
        {
         lastError = StringFormat("indicators still calculating (%d)", GetLastError());
         return false;
        }

      barOpen  = iTime(m_sym, m_tf, 1 + shift);
      barClose = barOpen + PeriodSeconds(m_tf);
      if(barOpen <= 0)
        {
         lastError = "no bar time";
         return false;
        }

      //--- higher timeframes: last bar that was complete when bar #1 closed
      int i1 = DoneIndex(PERIOD_H1, barClose);
      int i4 = DoneIndex(PERIOD_H4, barClose);
      int iD = DoneIndex(PERIOD_D1, barClose);
      if(i1 < 0 || i4 < 0 || iD < 0)
        {
         lastError = StringFormat("H1/H4/D1 history not ready (%d/%d/%d)", i1, i4, iD);
         return false;
        }
      h1Close     = iClose(m_sym, PERIOD_H1, i1);
      h1Ema50     = One(hH1EMA50, 0, i1);
      h1Ema200    = One(hH1EMA200, 0, i1);
      h1Ema50Prev = One(hH1EMA50, 0, i1 + 5);
      h1Atr       = One(hH1ATR, 0, i1);
      h1Adx       = One(hH1ADX, 0, i1);
      h4Close     = iClose(m_sym, PERIOD_H4, i4);
      h4Ema50     = One(hH4EMA50, 0, i4);
      d1Close     = iClose(m_sym, PERIOD_D1, iD);
      d1Ema50     = One(hD1EMA50, 0, iD);
      d1Ema200    = One(hD1EMA200, 0, iD);
      if(h1Ema50 == EMPTY_VALUE || h1Ema200 == EMPTY_VALUE || h1Ema50Prev == EMPTY_VALUE || h1Atr == EMPTY_VALUE ||
         h1Adx == EMPTY_VALUE || h4Ema50 == EMPTY_VALUE || h1Close <= 0 || h4Close <= 0 || d1Close <= 0 ||
         d1Ema50 == EMPTY_VALUE || d1Ema200 == EMPTY_VALUE)
        {
         lastError = "higher-timeframe indicators not ready";
         return false;
        }
      h1Up = (h1Close > h1Ema50 && h1Ema50 > h1Ema200 && h1Ema50 > h1Ema50Prev);
      h1Dn = (h1Close < h1Ema50 && h1Ema50 < h1Ema200 && h1Ema50 < h1Ema50Prev);

      //--- clocks at the close of bar #1
      datetime cu = clk.ToUTC(barClose);
      utcH = HourOf(cu);
      lonH = clk.LondonHour(barClose);
      nyH  = clk.NYHour(barClose);
      dowUtc = DayOfWeek(cu);
      utcDay = DayFloor(cu);

      //--- Donchian channel of the 20 bars before bar #1 and before bar #2
      donHi1 = h[ArrayMaximum(h, 2, 20)]; donLo1 = l[ArrayMinimum(l, 2, 20)];
      donHi2 = h[ArrayMaximum(h, 3, 20)]; donLo2 = l[ArrayMinimum(l, 3, 20)];

      //--- Kaufman efficiency ratio (20)
      double path = 0.0;
      for(int i = 1; i <= 20; i++)
         path += MathAbs(c[i] - c[i + 1]);
      er = SafeDiv(MathAbs(c[1] - c[21]), path, 0.0);

      //--- ATR percentile over the last 200 closed bars
      int below = 0, cnt = 0;
      for(int i = 1; i < MathMin(201, ArraySize(atrHist)); i++)
        {
         cnt++;
         if(atrHist[i] <= atrHist[1])
            below++;
        }
      atrPct = (cnt > 0) ? (double)below / cnt : 0.5;

      UpdateDaily(clk, cu);   // d1Atr/pdh/pdl stay 0 if daily history is missing; only LBO/LSR use them
      UpdateAsia(clk, cu);
      if(atr[1] <= 0)
         lastError = "ATR is zero";
      return (atr[1] > 0);
     }

   //--- previous New-York-close day high/low and a 14-day ATR on that calendar
   void UpdateDaily(CClock &clk, const datetime closeUtc)
     {
      // NY trading day starts 17:00 New York time
      datetime nyLocal = closeUtc - (IsUSDST(closeUtc) ? 4 : 5) * 3600;
      datetime dayStartUtc = DayFloor(nyLocal + 7 * 3600) - 7 * 3600 + (IsUSDST(closeUtc) ? 4 : 5) * 3600;
      if(dayStartUtc == m_nyDayStart && d1Atr > 0)
        {
         pdh = m_pdhCache; pdl = m_pdlCache;
         return;
        }
      MqlRates r[];
      ArraySetAsSeries(r, false);
      datetime fromSrv = clk.ToServer(dayStartUtc - 30 * 86400);
      datetime toSrv   = clk.ToServer(dayStartUtc) - 1;
      int n = CopyRates(m_sym, PERIOD_H1, fromSrv, toSrv, r);
      if(n < 48)
         return;
      // aggregate H1 bars into NY days
      double dh[], dl[], dc[];
      ArrayResize(dh, 0); ArrayResize(dl, 0); ArrayResize(dc, 0);
      datetime curKey = 0;
      int bars = 0, k = -1;
      int cntBars[];
      ArrayResize(cntBars, 0);
      for(int i = 0; i < n; i++)
        {
         datetime u = clk.ToUTC(r[i].time);
         datetime nl = u - (IsUSDST(u) ? 4 : 5) * 3600;
         datetime key = DayFloor(nl + 7 * 3600);
         if(key != curKey)
           {
            k++;
            ArrayResize(dh, k + 1); ArrayResize(dl, k + 1); ArrayResize(dc, k + 1); ArrayResize(cntBars, k + 1);
            dh[k] = r[i].high; dl[k] = r[i].low; dc[k] = r[i].close; cntBars[k] = 0;
            curKey = key;
           }
         dh[k] = MathMax(dh[k], r[i].high);
         dl[k] = MathMin(dl[k], r[i].low);
         dc[k] = r[i].close;
         cntBars[k]++;
        }
      // drop stub sessions (fewer than 2 hours of data)
      double H[], L[], C[];
      int m = 0;
      for(int i = 0; i <= k; i++)
        {
         if(cntBars[i] < 2)
            continue;
         ArrayResize(H, m + 1); ArrayResize(L, m + 1); ArrayResize(C, m + 1);
         H[m] = dh[i]; L[m] = dl[i]; C[m] = dc[i];
         m++;
        }
      if(m < 15)
         return;
      pdh = H[m - 1];
      pdl = L[m - 1];
      double sum = 0.0;
      for(int i = m - 14; i < m; i++)
         sum += MathMax(H[i] - L[i], MathMax(MathAbs(H[i] - C[i - 1]), MathAbs(L[i] - C[i - 1])));
      d1Atr = sum / 14.0;
      m_pdhCache = pdh; m_pdlCache = pdl;
      m_nyDayStart = dayStartUtc;
     }

   //--- Asian range = signal-TF bars opening 00:00-07:00 UTC of the current UTC day
   void UpdateAsia(CClock &clk, const datetime closeUtc)
     {
      datetime day = DayFloor(closeUtc);
      if(HourOf(closeUtc) < 7.0)
        {
         asiaValid = false;
         return;
        }
      if(day == m_asiaDay && asiaValid)
         return;
      MqlRates r[];
      datetime fromSrv = clk.ToServer(day);
      datetime toSrv   = clk.ToServer(day + 7 * 3600) - 1;
      int n = CopyRates(m_sym, m_tf, fromSrv, toSrv, r);
      asiaValid = false;
      if(n < 4)
         return;
      asiaHi = r[0].high;
      asiaLo = r[0].low;
      for(int i = 1; i < n; i++)
        {
         asiaHi = MathMax(asiaHi, r[i].high);
         asiaLo = MathMin(asiaLo, r[i].low);
        }
      asiaValid = true;
      m_asiaDay = day;
     }
  };

#endif
