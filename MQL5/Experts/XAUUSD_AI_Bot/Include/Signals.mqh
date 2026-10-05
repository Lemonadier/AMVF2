//+------------------------------------------------------------------+
//| Signals.mqh - the five strategy modules                           |
//|                                                                  |
//| Mirrors research/xau_lib.py::gen_signals bar for bar. Research    |
//| on 2011-2026 M1 data (see docs/RESEARCH.md): on H1, Trend         |
//| Pullback (TPB) and Momentum (MOM) were profitable in both the     |
//| 2011-18 bear market and the 2019-26 bull market; London Breakout, |
//| Liquidity Sweep and Mean Reversion lost money and are OFF by      |
//| default.                                                          |
//+------------------------------------------------------------------+
#ifndef XAUBOT_SIGNALS_MQH
#define XAUBOT_SIGNALS_MQH

#include "Common.mqh"
#include "Market.mqh"

enum ENUM_XB_D1_FILTER
  {
   XB_D1_NONE     = 0, // No daily filter
   XB_D1_EMA50    = 1, // Buy only above daily EMA50, sell only below
   XB_D1_EMA50_200= 2  // Daily EMA50 above/below EMA200
  };

struct XBSignalConfig
  {
   bool              use[XB_NSTRAT];
   double            tpR[XB_NSTRAT];
   double            slMinATR;
   double            slMaxATR;
   ENUM_XB_D1_FILTER d1Filter;
   double            lboBufferATR;
   double            lboMinRangeD1;
   double            lboMaxRangeD1;
   double            lsrWick;
   double            mrAdxMax;
   double            momAdxMin;
   double            momRangeATR;
  };

class CSignals
  {
private:
   XBSignalConfig    m_cfg;
   string            m_sym;
   datetime          m_lboDay;       // UTC day of the last London breakout
   datetime          m_lsrBar;       // bar time of the last sweep signal
   long              m_magic;

   bool D1Allows(CMarket &m, const int dir)
     {
      if(m_cfg.d1Filter == XB_D1_EMA50)
         return (dir > 0) ? (m.d1Close > m.d1Ema50) : (m.d1Close < m.d1Ema50);
      if(m_cfg.d1Filter == XB_D1_EMA50_200)
         return (dir > 0) ? (m.d1Ema50 > m.d1Ema200) : (m.d1Ema50 < m.d1Ema200);
      return true;
     }

   void Add(CMarket &m, const int strat, const int dir, const double slPrice, XBSignal &out[], const string note)
     {
      if(!D1Allows(m, dir))
         return;
      double a = m.atr[1];
      double dist = (m.c[1] - slPrice) * dir;
      if(!MathIsValidNumber(dist) || dist > m_cfg.slMaxATR * a)
         return;                                // structure too far away
      dist = MathMax(dist, m_cfg.slMinATR * a);
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n].strategy = strat;
      out[n].dir = dir;
      out[n].slDist = dist;
      out[n].tpR = m_cfg.tpR[strat];
      out[n].prob = 0.0;
      out[n].edgeR = 0.0;
      out[n].riskMult = 1.0;
      out[n].note = note;
      ArrayInitialize(out[n].feat, 0.0);
     }

public:
   bool Init(const string sym, const long magic, const XBSignalConfig &cfg)
     {
      m_sym = sym;
      m_magic = magic;
      m_cfg = cfg;
      m_lboDay = (datetime)GVGet(GVName(magic, "lboday"), 0);
      m_lsrBar = 0;
      return true;
     }

   void Release() {}

   //--- forget per-day state (used by the history replay test)
   void ResetState() { m_lboDay = 0; m_lsrBar = 0; }

   //--- entry window shared by all strategies
   bool TimeAllowed(CMarket &m)
     {
      if(m.nyH >= 16.75 && m.nyH < 18.5)          // NY close rollover: wide spreads
         return false;
      if(m.dowUtc == 5 && m.utcH >= 18.0)         // late Friday: weekend gap risk
         return false;
      if(m.dowUtc == 1 && m.utcH < 1.0)           // Monday open gaps
         return false;
      if(m.dowUtc == 6 || m.dowUtc == 0)
         return false;
      return true;
     }

   //--- all signals of the bar that just closed
   int Generate(CMarket &m, XBSignal &out[])
     {
      ArrayResize(out, 0);
      if(!TimeAllowed(m))
         return 0;
      double a = m.atr[1];
      if(a <= 0)
         return 0;
      double o1 = m.o[1], h1 = m.h[1], l1 = m.l[1], c1 = m.c[1];
      double rng = h1 - l1;

      //--- 1) Trend pullback: H1 trend, pullback to EMA21, momentum close
      if(m_cfg.use[XB_TPB])
        {
         double lo5 = l1, hi5 = h1;
         for(int i = 2; i <= 5; i++)
           {
            lo5 = MathMin(lo5, m.l[i]);
            hi5 = MathMax(hi5, m.h[i]);
           }
         if(m.h1Up && lo5 <= m.ema21[1] + 0.1 * a && lo5 > m.ema50[1] - 1.0 * a &&
            c1 > o1 && c1 > m.ema21[1] && c1 > m.h[2] && m.rsi[1] >= 45 && m.rsi[1] <= 70)
            Add(m, XB_TPB, +1, lo5 - 0.3 * a, out, "pullback long");
         if(m.h1Dn && hi5 >= m.ema21[1] - 0.1 * a && hi5 < m.ema50[1] + 1.0 * a &&
            c1 < o1 && c1 < m.ema21[1] && c1 < m.l[2] && m.rsi[1] >= 30 && m.rsi[1] <= 55)
            Add(m, XB_TPB, -1, hi5 + 0.3 * a, out, "pullback short");
        }

      //--- 2) London breakout of the Asian range (07:00-10:30 London time)
      if(m_cfg.use[XB_LBO] && m.lonH >= 7.0 && m.lonH <= 10.5 && m.asiaValid && m.d1Atr > 0)
        {
         double ar = m.asiaHi - m.asiaLo;
         datetime today = m.utcDay;
         if(ar >= m_cfg.lboMinRangeD1 * m.d1Atr && ar <= m_cfg.lboMaxRangeD1 * m.d1Atr && m_lboDay != today)
           {
            double buf = m_cfg.lboBufferATR * a;
            double mid = (m.asiaHi + m.asiaLo) / 2.0;
            int before = ArraySize(out);
            if(c1 > m.asiaHi + buf && m.c[2] <= m.asiaHi + buf && !m.h1Dn)
               Add(m, XB_LBO, +1, mid, out, "asia breakout long");
            else
               if(c1 < m.asiaLo - buf && m.c[2] >= m.asiaLo - buf && !m.h1Up)
                  Add(m, XB_LBO, -1, mid, out, "asia breakout short");
            if(ArraySize(out) > before)
              {
               m_lboDay = today;
               GVSet(GVName(m_magic, "lboday"), (double)m_lboDay);
              }
           }
        }

      //--- 3) Liquidity sweep reversal at previous-day / Asian extremes
      if(m_cfg.use[XB_LSR] && m.lonH >= 7.0 && m.nyH <= 12.0 && rng > 0 &&
         (m_lsrBar == 0 || m.barOpen - m_lsrBar > 4 * (m.barClose - m.barOpen)))
        {
         bool done = false;
         double lvH[2];
         lvH[0] = (m.pdh > 0) ? m.pdh : 0.0;
         lvH[1] = m.asiaValid ? m.asiaHi : 0.0;
         for(int k = 0; k < 2 && !done; k++)
           {
            double lvl = lvH[k];
            if(lvl <= 0)
               continue;
            if(h1 > lvl + 0.1 * a && c1 < lvl && (h1 - MathMax(o1, c1)) >= m_cfg.lsrWick * rng && m.rsi[1] > 55)
              {
               Add(m, XB_LSR, -1, h1 + 0.2 * a, out, "sweep of high");
               done = true;
              }
           }
         double lvL[2];
         lvL[0] = m.pdl;
         lvL[1] = m.asiaValid ? m.asiaLo : 0.0;
         for(int k = 0; k < 2 && !done; k++)
           {
            double lvl = lvL[k];
            if(lvl <= 0)
               continue;
            if(l1 < lvl - 0.1 * a && c1 > lvl && (MathMin(o1, c1) - l1) >= m_cfg.lsrWick * rng && m.rsi[1] < 45)
              {
               Add(m, XB_LSR, +1, l1 - 0.2 * a, out, "sweep of low");
               done = true;
              }
           }
         if(done)
            m_lsrBar = m.barOpen;
        }

      //--- 4) Mean reversion inside a range regime
      if(m_cfg.use[XB_MR] && m.adx[1] < m_cfg.mrAdxMax && m.h1Adx < 25)
        {
         if(m.c[2] < m.bbLo[2] && m.rsi[2] < 30 && c1 > m.bbLo[1] && c1 > o1)
            Add(m, XB_MR, +1, MathMin(l1, m.l[2]) - 0.3 * a, out, "band re-entry long");
         else
            if(m.c[2] > m.bbUp[2] && m.rsi[2] > 70 && c1 < m.bbUp[1] && c1 < o1)
               Add(m, XB_MR, -1, MathMax(h1, m.h[2]) + 0.3 * a, out, "band re-entry short");
        }

      //--- 5) Momentum: Donchian breakout with range expansion in a trend
      if(m_cfg.use[XB_MOM] && m.adx[1] > m_cfg.momAdxMin && m.adx[1] > m.adx[2] && rng >= m_cfg.momRangeATR * a)
        {
         if(m.h1Up && c1 > m.donHi1 && m.c[2] <= m.donHi2)
            Add(m, XB_MOM, +1, c1 - 1.5 * a, out, "donchian breakout long");
         else
            if(m.h1Dn && c1 < m.donLo1 && m.c[2] >= m.donLo2)
               Add(m, XB_MOM, -1, c1 + 1.5 * a, out, "donchian breakout short");
        }
      return ArraySize(out);
     }

   //--- feature vector for the online learner (same order as research/xau_lib.py FEATURES)
   void Features(CMarket &m, XBSignal &s)
     {
      double d = s.dir;
      double h1a = MathMax(m.h1Atr, 1e-9);
      double a = MathMax(m.atr[1], 1e-9);
      s.feat[0]  = 1.0;
      s.feat[1]  = Clip1((m.h1Ema50 - m.h1Ema200) / h1a / 3.0 * d);
      s.feat[2]  = Clip1((m.h1Ema50 - m.h1Ema50Prev) / h1a * d);
      s.feat[3]  = Clip1((m.h4Close - m.h4Ema50) / h1a / 4.0 * d);
      s.feat[4]  = Clip1((m.c[1] - m.ema50[1]) / a / 3.0 * d);
      s.feat[5]  = Clip1(m.adx[1] / 50.0);
      s.feat[6]  = Clip1(m.er);
      s.feat[7]  = Clip1((m.rsi[1] - 50.0) / 50.0 * d);
      s.feat[8]  = Clip1(m.atrPct - 0.5);
      double rng = m.h[1] - m.l[1];
      s.feat[9]  = (rng > 0) ? Clip1((m.c[1] - m.o[1]) / rng * d) : 0.0;
      double bw = m.bbUp[1] - m.bbLo[1];
      s.feat[10] = (bw > 0) ? Clip1((m.c[1] - m.bbMid[1]) / bw * 2.0 * d) : 0.0;
      s.feat[11] = (m.utcH < 7.0) ? 1.0 : 0.0;
      s.feat[12] = (m.utcH >= 7.0 && m.utcH < 12.0) ? 1.0 : 0.0;
      s.feat[13] = (m.utcH >= 12.0 && m.utcH < 16.0) ? 1.0 : 0.0;
      s.feat[14] = (m.utcH >= 16.0) ? 1.0 : 0.0;
      for(int k = 0; k < XB_NSTRAT; k++)
         s.feat[15 + k] = (s.strategy == k) ? 1.0 : 0.0;
     }
  };

#endif
