//+------------------------------------------------------------------+
//| Executor.mqh - broker-safe order execution                        |
//|  * picks a filling mode the broker supports                       |
//|  * respects stops level / freeze level / volume step / max lot    |
//|  * retries requotes and price changes                             |
//|  * falls back to "open then set SL/TP" for brokers that reject    |
//|    stops on market orders                                         |
//+------------------------------------------------------------------+
#ifndef XAUBOT_EXECUTOR_MQH
#define XAUBOT_EXECUTOR_MQH

#include "Common.mqh"

class CExecutor
  {
private:
   string            m_sym;
   long              m_magic;
   int               m_slippage;
   ENUM_ORDER_TYPE_FILLING m_fill;
   int               m_digits;
   double            m_point;
   double            m_maxLotUser;
   bool              m_verbose;

   ENUM_ORDER_TYPE_FILLING DetectFilling()
     {
      long modes = SymbolInfoInteger(m_sym, SYMBOL_FILLING_MODE);
      long exe = SymbolInfoInteger(m_sym, SYMBOL_TRADE_EXEMODE);
      if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
         return ORDER_FILLING_FOK;
      if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
         return ORDER_FILLING_IOC;
      if(exe == SYMBOL_TRADE_EXECUTION_MARKET)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }

   bool Retryable(const uint rc)
     {
      return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF ||
              rc == TRADE_RETCODE_TIMEOUT || rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TOO_MANY_REQUESTS);
     }

   bool Ok(const uint rc)
     {
      return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
     }

public:
   void Init(const string sym, const long magic, const int slippagePoints, const double maxLotUser, const bool verbose)
     {
      m_sym = sym;
      m_magic = magic;
      m_slippage = slippagePoints;
      m_maxLotUser = maxLotUser;
      m_verbose = verbose;
      m_digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      m_point = SymbolInfoDouble(sym, SYMBOL_POINT);
      m_fill = DetectFilling();
     }

   double Norm(const double price) { return NormalizeDouble(price, m_digits); }

   double MinStopDistance()
     {
      long lvl = SymbolInfoInteger(m_sym, SYMBOL_TRADE_STOPS_LEVEL);
      double spread = SymbolInfoDouble(m_sym, SYMBOL_ASK) - SymbolInfoDouble(m_sym, SYMBOL_BID);
      return MathMax(lvl * m_point, 0.0) + spread;
     }

   double FreezeDistance()
     {
      return SymbolInfoInteger(m_sym, SYMBOL_TRADE_FREEZE_LEVEL) * m_point;
     }

   //--- volume helpers
   double NormalizeLots(const double lots)
     {
      double step = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_STEP);
      double vmin = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MIN);
      double vmax = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MAX);
      double vlim = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_LIMIT);
      if(m_maxLotUser > 0)
         vmax = MathMin(vmax, m_maxLotUser);
      if(vlim > 0)
         vmax = MathMin(vmax, vlim);
      if(step <= 0)
         step = 0.01;
      double v = MathFloor(lots / step + 1e-9) * step;
      if(v < vmin)
         return 0.0;
      v = MathMin(v, vmax);
      int dec = (int)MathMax(0, MathCeil(-MathLog10(step)));
      return NormalizeDouble(v, dec);
     }

   double MinLot() { return SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MIN); }

   //--- money lost by 1.0 lot if price goes from entry to sl (positive number), incl. commission
   double LossPerLot(const int dir, const double entry, const double sl, const double commissionPerLot)
     {
      double pnl = 0.0;
      ENUM_ORDER_TYPE t = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      if(!OrderCalcProfit(t, m_sym, 1.0, entry, sl, pnl))
        {
         // fallback with tick value
         double tv = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
         double ts = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
         if(tv <= 0 || ts <= 0)
            return 0.0;
         pnl = -MathAbs(entry - sl) / ts * tv;
        }
      return MathAbs(MathMin(pnl, 0.0)) + MathMax(commissionPerLot, 0.0);
     }

   double MarginFor(const int dir, const double lots, const double price)
     {
      double m = 0.0;
      if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, m_sym, lots, price, m))
         return -1.0;
      return m;
     }

   //--- market order with SL/TP. Returns position ticket or 0.
   ulong Open(const int dir, const double lots, double sl, double tp, const string comment)
     {
      for(int attempt = 0; attempt < 4; attempt++)
        {
         MqlTick tick;
         if(!SymbolInfoTick(m_sym, tick))
            return 0;
         double price = (dir > 0) ? tick.ask : tick.bid;
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action = TRADE_ACTION_DEAL;
         req.symbol = m_sym;
         req.volume = lots;
         req.type = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         req.price = Norm(price);
         req.sl = (sl > 0) ? Norm(sl) : 0.0;
         req.tp = (tp > 0) ? Norm(tp) : 0.0;
         req.deviation = (ulong)m_slippage;
         req.magic = (ulong)m_magic;
         req.comment = comment;
         req.type_filling = m_fill;
         req.type_time = ORDER_TIME_GTC;
         ResetLastError();
         bool sent = OrderSend(req, res);
         if(sent && Ok(res.retcode))
           {
            ulong pos = FindPositionByDeal(res.deal, res.order);
            PrintFormat("[XauBot] OPEN %s %.2f lots @ %.2f SL %.2f TP %.2f (%s) ticket %I64u",
                        dir > 0 ? "BUY" : "SELL", lots, res.price, req.sl, req.tp, comment, pos);
            return pos;
           }
         if(res.retcode == TRADE_RETCODE_INVALID_STOPS && (req.sl > 0 || req.tp > 0))
           {
            // some brokers want the position first, stops afterwards
            ulong pos = Open(dir, lots, 0.0, 0.0, comment);
            if(pos > 0)
               Modify(pos, sl, tp);
            return pos;
           }
         if(res.retcode == TRADE_RETCODE_INVALID_FILL)
           {
            m_fill = (m_fill == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC :
                     (m_fill == ORDER_FILLING_IOC ? ORDER_FILLING_RETURN : ORDER_FILLING_FOK);
            continue;
           }
         PrintFormat("[XauBot] order failed: retcode %u (%s), error %d", res.retcode, res.comment, GetLastError());
         if(!Retryable(res.retcode))
            return 0;
         Sleep(300);
        }
      return 0;
     }

   ulong FindPositionByDeal(const ulong deal, const ulong order)
     {
      if(deal > 0 && HistoryDealSelect(deal))
        {
         long pid = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         if(pid > 0)
            return (ulong)pid;
        }
      // fallback: newest position with our magic
      ulong best = 0;
      datetime bt = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong tk = PositionGetTicket(i);
         if(tk == 0 || PositionGetInteger(POSITION_MAGIC) != m_magic || PositionGetString(POSITION_SYMBOL) != m_sym)
            continue;
         datetime t = (datetime)PositionGetInteger(POSITION_TIME);
         if(t >= bt)
           {
            bt = t;
            best = tk;
           }
        }
      return best;
     }

   bool Modify(const ulong ticket, const double sl, const double tp)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.symbol = m_sym;
      req.sl = (sl > 0) ? Norm(sl) : 0.0;
      req.tp = (tp > 0) ? Norm(tp) : 0.0;
      req.magic = (ulong)m_magic;
      if(!OrderSend(req, res) || !Ok(res.retcode))
        {
         if(m_verbose)
            PrintFormat("[XauBot] modify #%I64u failed: %u %s", ticket, res.retcode, res.comment);
         return false;
        }
      return true;
     }

   bool Close(const ulong ticket, const double volume, const string why)
     {
      for(int attempt = 0; attempt < 4; attempt++)
        {
         if(!PositionSelectByTicket(ticket))
            return true;
         long type = PositionGetInteger(POSITION_TYPE);
         double vol = (volume > 0) ? volume : PositionGetDouble(POSITION_VOLUME);
         MqlTick tick;
         if(!SymbolInfoTick(m_sym, tick))
            return false;
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);
         req.action = TRADE_ACTION_DEAL;
         req.position = ticket;
         req.symbol = m_sym;
         req.volume = vol;
         req.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         req.price = Norm(type == POSITION_TYPE_BUY ? tick.bid : tick.ask);
         req.deviation = (ulong)m_slippage;
         req.magic = (ulong)m_magic;
         req.type_filling = m_fill;
         req.comment = why;
         bool sent = OrderSend(req, res);
         if(sent && Ok(res.retcode))
           {
            PrintFormat("[XauBot] CLOSE #%I64u %.2f lots @ %.2f (%s)", ticket, vol, res.price, why);
            return true;
           }
         if(res.retcode == TRADE_RETCODE_INVALID_FILL)
           {
            m_fill = (m_fill == ORDER_FILLING_FOK) ? ORDER_FILLING_IOC :
                     (m_fill == ORDER_FILLING_IOC ? ORDER_FILLING_RETURN : ORDER_FILLING_FOK);
            continue;
           }
         PrintFormat("[XauBot] close #%I64u failed: %u %s", ticket, res.retcode, res.comment);
         if(!Retryable(res.retcode))
            return false;
         Sleep(300);
        }
      return false;
     }
  };

#endif
