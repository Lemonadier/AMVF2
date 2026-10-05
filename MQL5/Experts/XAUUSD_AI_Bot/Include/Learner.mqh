//+------------------------------------------------------------------+
//| Learner.mqh - online machine learning layer                       |
//|                                                                  |
//| * Online logistic regression (SGD + L2) estimating the chance     |
//|   that a signal reaches +LabelR before -1R.                       |
//| * Learns from "shadow trades": every signal, taken or not, gets   |
//|   a virtual bracket that is resolved on later M1 bars. This       |
//|   removes the bias of learning only from trades it allowed.       |
//| * Tracks its own calibration (predicted vs. realised) so you can  |
//|   see on the dashboard whether it actually knows anything.        |
//| * Model is saved in the terminal's Common\Files folder, so a      |
//|   model trained in the Strategy Tester can be used live.          |
//|                                                                  |
//| Research note (docs/RESEARCH.md): replayed walk-forward on        |
//| 2011-2026, this model did NOT improve the H1 trend strategies,   |
//| which is why the default mode is OBSERVE (learn + report only).   |
//+------------------------------------------------------------------+
#ifndef XAUBOT_LEARNER_MQH
#define XAUBOT_LEARNER_MQH

#include "Common.mqh"

#define XB_MODEL_MAGIC   0x58424C31   // "XBL1"
#define XB_MAX_SHADOWS   300

enum ENUM_XB_AI_MODE
  {
   XB_AI_OFF         = 0, // Off
   XB_AI_OBSERVE     = 1, // Observe: learn and report, never block
   XB_AI_FILTER      = 2, // Filter: skip signals below the minimum probability
   XB_AI_FILTER_SIZE = 3  // Filter + size positions by probability
  };

struct XBShadow
  {
   double            feat[XB_NFEAT];
   int               strat;
   int               dir;
   double            entry;
   double            sl;
   double            tp;
   double            R;
   double            prob;       // prediction made at entry (for calibration)
   bool              scored;     // the model was ready when it predicted
   datetime          expiry;
  };

class CLearner
  {
private:
   double            m_w[XB_NFEAT];
   long              m_n;
   double            m_lr, m_l2, m_labelR;
   int               m_horizonSec;
   int               m_minSamples;
   string            m_file;
   bool              m_tester;
   // calibration of scored predictions
   long              m_calN;
   double            m_calSumP, m_calSumY, m_calBrier, m_calBaseBrier;
   // per strategy shadow performance
   double            m_ewma[XB_NSTRAT];
   long              m_cnt[XB_NSTRAT];
   double            m_sumR[XB_NSTRAT];
   XBShadow          m_sh[];
   int               m_dirtyUpdates;

   double Dot(const double &x[])
     {
      double z = 0.0;
      for(int i = 0; i < XB_NFEAT; i++)
         z += m_w[i] * x[i];
      return z;
     }

   void Learn(const double &x[], const double y)
     {
      double p = Sigmoid(Dot(x));
      for(int i = 0; i < XB_NFEAT; i++)
        {
         double reg = (i == 0) ? 0.0 : m_l2 * m_w[i];
         m_w[i] += m_lr * ((y - p) * x[i] - reg);
        }
      m_n++;
      m_dirtyUpdates++;
     }

   void Finish(const int k, const double y, const double r)
     {
      Learn(m_sh[k].feat, y);
      int s = m_sh[k].strat;
      if(s >= 0 && s < XB_NSTRAT)
        {
         m_ewma[s] = 0.95 * m_ewma[s] + 0.05 * r;
         m_cnt[s]++;
         m_sumR[s] += r;
        }
      if(m_sh[k].scored)
        {
         m_calN++;
         m_calSumP += m_sh[k].prob;
         m_calSumY += y;
         m_calBrier += (m_sh[k].prob - y) * (m_sh[k].prob - y);
         double base = m_calSumY / m_calN;
         m_calBaseBrier += (base - y) * (base - y);
        }
      // remove (swap with last)
      int last = ArraySize(m_sh) - 1;
      if(k != last)
         m_sh[k] = m_sh[last];
      ArrayResize(m_sh, last);
     }

public:
   static double Sigmoid(const double z)
     {
      double zz = Clip(z, -30.0, 30.0);
      return 1.0 / (1.0 + MathExp(-zz));
     }

   void Init(const string name, const long magic, const double lr, const double l2, const double labelR,
             const int horizonSec, const int minSamples, const bool loadModel, const bool reset)
     {
      m_lr = lr; m_l2 = l2; m_labelR = labelR;
      m_horizonSec = horizonSec;
      m_minSamples = minSamples;
      m_tester = (bool)MQLInfoInteger(MQL_TESTER);
      m_file = StringFormat("%s_%I64d_model.bin", name, magic);
      ArrayResize(m_sh, 0);
      ResetModel();
      if(!reset && loadModel)
         Load();
     }

   void ResetModel()
     {
      ArrayInitialize(m_w, 0.0);
      m_w[0] = -0.7;                 // prior: ~33% chance of +2R before -1R
      m_n = 0;
      m_calN = 0; m_calSumP = 0; m_calSumY = 0; m_calBrier = 0; m_calBaseBrier = 0;
      ArrayInitialize(m_ewma, 0.0);
      ArrayInitialize(m_cnt, 0);
      ArrayInitialize(m_sumR, 0.0);
      m_dirtyUpdates = 0;
     }

   bool   Ready()            { return m_n >= m_minSamples; }
   long   Samples()          { return m_n; }
   double Predict(const double &x[]) { return Sigmoid(Dot(x)); }
   int    OpenShadows()      { return ArraySize(m_sh); }
   double StrategyEwma(const int s) { return m_ewma[s]; }
   long   StrategyCount(const int s) { return m_cnt[s]; }
   double StrategyAvgR(const int s) { return m_cnt[s] > 0 ? m_sumR[s] / m_cnt[s] : 0.0; }
   long   CalN()             { return m_calN; }
   double CalMeanP()         { return m_calN > 0 ? m_calSumP / m_calN : 0.0; }
   double CalMeanY()         { return m_calN > 0 ? m_calSumY / m_calN : 0.0; }
   // > 0 means the model predicts better than always guessing the base rate
   double Skill()            { return (m_calN > 20 && m_calBaseBrier > 0) ? 1.0 - m_calBrier / m_calBaseBrier : 0.0; }

   //--- expected value in R of a signal with a +labelR / -1R bracket
   double EdgeR(const double p) { return p * m_labelR - (1.0 - p); }

   void AddShadow(const XBSignal &s, const double entry, const datetime now)
     {
      if(ArraySize(m_sh) >= XB_MAX_SHADOWS)
         return;
      int n = ArraySize(m_sh);
      ArrayResize(m_sh, n + 1);
      for(int i = 0; i < XB_NFEAT; i++)
         m_sh[n].feat[i] = s.feat[i];
      m_sh[n].strat = s.strategy;
      m_sh[n].dir = s.dir;
      m_sh[n].entry = entry;
      m_sh[n].R = s.slDist;
      m_sh[n].sl = entry - s.dir * s.slDist;
      m_sh[n].tp = entry + s.dir * m_labelR * s.slDist;
      m_sh[n].prob = s.prob;
      m_sh[n].scored = Ready();
      m_sh[n].expiry = now + m_horizonSec;
     }

   //--- resolve shadows on a closed M1 bar (bid prices) + current spread
   void Resolve(const double barHigh, const double barLow, const double spread,
                const double bid, const double ask, const datetime now)
     {
      for(int k = ArraySize(m_sh) - 1; k >= 0; k--)
        {
         int d = m_sh[k].dir;
         double hi = (d > 0) ? barHigh : barHigh + spread;
         double lo = (d > 0) ? barLow : barLow + spread;
         bool slHit = (d > 0) ? (lo <= m_sh[k].sl) : (hi >= m_sh[k].sl);
         bool tpHit = (d > 0) ? (hi >= m_sh[k].tp) : (lo <= m_sh[k].tp);
         if(slHit)                                  // conservative: stop first
            Finish(k, 0.0, -1.0);
         else
            if(tpHit)
               Finish(k, 1.0, m_labelR);
            else
               if(now >= m_sh[k].expiry)
                 {
                  double px = (d > 0) ? bid : ask;
                  double r = d * (px - m_sh[k].entry) / m_sh[k].R;
                  Finish(k, Clip((r + 1.0) / (m_labelR + 1.0), 0.0, 1.0), r);
                 }
        }
      if(m_dirtyUpdates >= 25 && !m_tester)
         Save();
     }

   //--- persistence in Common\Files (shared by all terminals and the tester)
   bool Save()
     {
      int fh = FileOpen(m_file, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(fh == INVALID_HANDLE)
         return false;
      FileWriteInteger(fh, XB_MODEL_MAGIC);
      FileWriteInteger(fh, XB_NFEAT);
      FileWriteLong(fh, m_n);
      for(int i = 0; i < XB_NFEAT; i++)
         FileWriteDouble(fh, m_w[i]);
      for(int s = 0; s < XB_NSTRAT; s++)
        {
         FileWriteDouble(fh, m_ewma[s]);
         FileWriteLong(fh, m_cnt[s]);
         FileWriteDouble(fh, m_sumR[s]);
        }
      FileWriteLong(fh, m_calN);
      FileWriteDouble(fh, m_calSumP);
      FileWriteDouble(fh, m_calSumY);
      FileWriteDouble(fh, m_calBrier);
      FileWriteDouble(fh, m_calBaseBrier);
      FileClose(fh);
      m_dirtyUpdates = 0;
      return true;
     }

   bool Load()
     {
      if(!FileIsExist(m_file, FILE_COMMON))
         return false;
      int fh = FileOpen(m_file, FILE_READ | FILE_BIN | FILE_COMMON);
      if(fh == INVALID_HANDLE)
         return false;
      bool ok = false;
      if(FileReadInteger(fh) == XB_MODEL_MAGIC && FileReadInteger(fh) == XB_NFEAT)
        {
         m_n = FileReadLong(fh);
         for(int i = 0; i < XB_NFEAT; i++)
            m_w[i] = FileReadDouble(fh);
         for(int s = 0; s < XB_NSTRAT; s++)
           {
            m_ewma[s] = FileReadDouble(fh);
            m_cnt[s] = FileReadLong(fh);
            m_sumR[s] = FileReadDouble(fh);
           }
         m_calN = FileReadLong(fh);
         m_calSumP = FileReadDouble(fh);
         m_calSumY = FileReadDouble(fh);
         m_calBrier = FileReadDouble(fh);
         m_calBaseBrier = FileReadDouble(fh);
         ok = true;
        }
      FileClose(fh);
      if(ok)
         PrintFormat("[XauBot] AI model loaded from Common\\Files\\%s (%I64d samples)", m_file, m_n);
      else
         ResetModel();
      return ok;
     }

   string FileName() { return m_file; }
  };

#endif
