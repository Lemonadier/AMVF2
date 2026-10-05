//+------------------------------------------------------------------+
//| Dashboard.mqh - on-chart status panel                             |
//+------------------------------------------------------------------+
#ifndef XAUBOT_DASHBOARD_MQH
#define XAUBOT_DASHBOARD_MQH

#define XB_DASH_PREFIX "XBDash_"
#define XB_DASH_LINES  18

class CDashboard
  {
private:
   bool              m_on;
   int               m_x, m_y;

   void Label(const int i, const string text, const color clr)
     {
      string n = XB_DASH_PREFIX + IntegerToString(i);
      if(ObjectFind(0, n) < 0)
        {
         ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, n, OBJPROP_XDISTANCE, m_x + 8);
         ObjectSetInteger(0, n, OBJPROP_YDISTANCE, m_y + 6 + i * 16);
         ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
        }
      ObjectSetString(0, n, OBJPROP_TEXT, text);
      ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
     }

public:
   void Init(const bool on)
     {
      m_on = on;
      m_x = 10;
      m_y = 20;
      if(!m_on)
         return;
      string bg = XB_DASH_PREFIX + "bg";
      ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, m_x);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, m_y);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 430);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, 12 + XB_DASH_LINES * 16);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,24,32');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,80,100');
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }

   void Set(const int i, const string text, const color clr = C'220,225,235')
     {
      if(m_on && i < XB_DASH_LINES)
         Label(i, text, clr);
     }

   void Remove()
     {
      ObjectsDeleteAll(0, XB_DASH_PREFIX);
      ChartRedraw(0);
     }

   bool On() { return m_on; }
  };

#endif
