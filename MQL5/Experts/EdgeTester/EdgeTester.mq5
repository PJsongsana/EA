//+------------------------------------------------------------------+
//|                                                   EdgeTester.mq5 |
//|  Edge-testing harness for XAUUSD entry signals (Phase 1)         |
//|                                                                  |
//|  Purpose: measure whether an ENTRY SIGNAL has a statistical edge. |
//|  It is NOT a money-making EA. Exits are deliberately simple and  |
//|  symmetric, lot size is fixed, and every trade is logged to CSV  |
//|  in R / ATR units so results can be compared against random      |
//|  entries.                                                        |
//+------------------------------------------------------------------+
#property copyright "Jirayut"
#property version   "0.10"
#property description "Edge tester: Asian Range Breakout vs random baseline"

#include <Trade/Trade.mqh>

//--- modes ----------------------------------------------------------
enum ENUM_SIGNAL_MODE
  {
   SIGNAL_REAL             = 0, // Real signal (Asian Range Breakout)
   SIGNAL_RANDOM_DIRECTION = 1, // Same entry times, random direction
   SIGNAL_RANDOM_TIME      = 2  // Random time inside trade window, random direction
  };

enum ENUM_EXIT_MODE
  {
   EXIT_FIXED_BARS    = 0, // Close after N bars (no SL/TP)
   EXIT_ATR_SYMMETRIC = 1  // SL = TP = k * ATR (1:1)
  };

//--- inputs ---------------------------------------------------------
input group "=== Mode ==="
input ENUM_SIGNAL_MODE InpSignalMode     = SIGNAL_REAL;
input ENUM_EXIT_MODE   InpExitMode       = EXIT_ATR_SYMMETRIC;
input int              InpRandomSeed     = 1;     // Seed (optimize 1..N for random baseline)
input double           InpRandomTimeProb = 0.10;  // Entry probability per bar (RANDOM_TIME)

input group "=== Asian Range Breakout (BROKER SERVER TIME) ==="
input int    InpAsiaStartHour   = 1;    // Asia range start hour (server)
input int    InpAsiaEndHour     = 9;    // Asia range end hour, exclusive (server)
input int    InpTradeStartHour  = 9;    // Trade window start hour (server)
input int    InpTradeEndHour    = 13;   // Trade window end hour, exclusive (server)
input double InpBreakBufferAtr  = 0.10; // Close must exceed range by this * ATR
input double InpMinRangeAtr     = 0.5;  // Skip day if range < this * ATR
input double InpMaxRangeAtr     = 4.0;  // Skip day if range > this * ATR

input group "=== ATR ==="
input ENUM_TIMEFRAMES InpAtrTimeframe = PERIOD_H1;
input int             InpAtrPeriod    = 14;

input group "=== Exit ==="
input int    InpExitBars    = 8;   // EXIT_FIXED_BARS: bars to hold
input double InpSlTpAtr     = 1.0; // EXIT_ATR_SYMMETRIC: SL/TP distance in ATR
input int    InpMaxHoldBars = 48;  // EXIT_ATR_SYMMETRIC: safety time cap (bars)

input group "=== Execution ==="
input double InpLots            = 0.01;
input int    InpMaxSpreadPoints = 50;   // Skip entry if spread is wider (points)
input int    InpDeviationPoints = 30;
input ulong  InpMagic           = 260710;

input group "=== Logging ==="
input bool   InpWriteCsv  = true;
input string InpCsvPrefix = "EdgeTester";
input int    InpMinTradesForScore = 30; // OnTester returns 0 below this

//--- state ----------------------------------------------------------
struct DayState
  {
   datetime          key;          // 00:00 server time of the day
   bool              rangeDone;
   bool              rangeValid;
   double            hi;
   double            lo;
   bool              traded;
  };

struct TradeState
  {
   bool              active;
   ulong             ticket;
   long              posId;
   int               dir;          // +1 buy, -1 sell
   datetime          entryTime;
   double            entryPrice;
   double            atr;          // ATR at entry (price units)
   double            riskDist;     // 1R in price units
   double            spreadPts;
   double            mfe;          // max favourable excursion (price)
   double            mae;          // max adverse excursion (price, positive)
  };

CTrade     g_trade;
DayState   g_day;
TradeState g_tr;
int        g_atrHandle = INVALID_HANDLE;
int        g_csv       = INVALID_HANDLE;

// stats
int    g_n = 0, g_wins = 0, g_skipSpread = 0, g_skipRange = 0;
double g_sumR = 0.0, g_sumR2 = 0.0;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpAsiaStartHour < 0 || InpAsiaStartHour > 23 || InpAsiaEndHour < 0 || InpAsiaEndHour > 23 ||
      InpTradeStartHour < 0 || InpTradeStartHour > 23 || InpTradeEndHour < 0 || InpTradeEndHour > 24)
     {
      Print("Invalid hour inputs");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpExitBars < 1 || InpSlTpAtr <= 0.0 || InpLots <= 0.0)
     {
      Print("Invalid exit / lot inputs");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_atrHandle = iATR(_Symbol, InpAtrTimeframe, InpAtrPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle, err=", GetLastError());
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   MathSrand(InpRandomSeed);
   ZeroMemory(g_day);
   ZeroMemory(g_tr);

   if(InpWriteCsv)
      OpenCsv();

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   PrintSummary();
   if(g_csv != INVALID_HANDLE)
     {
      FileClose(g_csv);
      g_csv = INVALID_HANDLE;
     }
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_tr.active)
     {
      if(PositionSelectByTicket(g_tr.ticket))
         UpdateExcursion();
      else
         FinalizeTrade();
     }

   if(!IsNewBar())
      return;

   ApplyTimeExit();
   OnNewBar();
  }

//+------------------------------------------------------------------+
//| Custom optimisation criterion: average result in R.              |
//| Optimising InpRandomSeed over 1..N in a random mode gives the    |
//| random-baseline distribution directly in the Optimizer table.    |
//+------------------------------------------------------------------+
double OnTester()
  {
   if(g_n < InpMinTradesForScore)
      return(0.0);
   return(g_sumR / g_n);
  }

//====================================================================
// Bar / day handling
//====================================================================
bool IsNewBar()
  {
   static datetime last = 0;
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0 || t == last)
      return(false);
   last = t;
   return(true);
  }

bool InHourWindow(const int hour, const int startH, const int endH)
  {
   if(startH < endH)
      return(hour >= startH && hour < endH);
   return(hour >= startH || hour < endH); // window crosses midnight
  }

void OnNewBar()
  {
   datetime now    = iTime(_Symbol, _Period, 0);
   datetime dayKey = now - (now % 86400);

   if(dayKey != g_day.key)
     {
      ZeroMemory(g_day);
      g_day.key = dayKey;
     }

   double atr = GetAtr();
   if(atr <= 0.0)
      return;

   // build today's Asian range once the Asia session has ended
   datetime asiaStart = dayKey + InpAsiaStartHour * 3600;
   datetime asiaEnd   = dayKey + InpAsiaEndHour * 3600;
   if(InpAsiaStartHour >= InpAsiaEndHour)
      asiaStart -= 86400;

   if(!g_day.rangeDone && now >= asiaEnd)
      BuildRange(asiaStart, asiaEnd, atr);

   if(g_tr.active || g_day.traded)
      return;

   // evaluate the bar that just closed
   datetime barTime = iTime(_Symbol, _Period, 1);
   if(barTime < asiaEnd)
      return;
   MqlDateTime dt;
   TimeToStruct(barTime, dt);
   if(!InHourWindow(dt.hour, InpTradeStartHour, InpTradeEndHour))
      return;

   int dir = GetEntryDirection(atr);
   if(dir != 0)
      OpenTrade(dir, atr);
  }

void BuildRange(const datetime asiaStart, const datetime asiaEnd, const double atr)
  {
   g_day.rangeDone = true;

   MqlRates rates[];
   int n = CopyRates(_Symbol, _Period, asiaStart, asiaEnd - 1, rates);
   if(n <= 0)
      return;

   double hi = rates[0].high, lo = rates[0].low;
   for(int i = 1; i < n; i++)
     {
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }

   double width = hi - lo;
   if(width < InpMinRangeAtr * atr || width > InpMaxRangeAtr * atr)
     {
      g_skipRange++;
      return;
     }

   g_day.hi = hi;
   g_day.lo = lo;
   g_day.rangeValid = true;
  }

double GetAtr()
  {
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1)
      return(0.0);
   return(buf[0]);
  }

//====================================================================
// Signal module — swap / extend here for other strategies
//====================================================================
int SignalAsianBreakout(const double atr)
  {
   if(!g_day.rangeValid)
      return(0);
   double close1 = iClose(_Symbol, _Period, 1);
   double buf    = InpBreakBufferAtr * atr;
   if(close1 > g_day.hi + buf) return(+1);
   if(close1 < g_day.lo - buf) return(-1);
   return(0);
  }

int RandomDirection()
  {
   return((MathRand() % 2 == 0) ? +1 : -1);
  }

int GetEntryDirection(const double atr)
  {
   switch(InpSignalMode)
     {
      case SIGNAL_REAL:
         return(SignalAsianBreakout(atr));

      case SIGNAL_RANDOM_DIRECTION:
         // fire exactly when the real signal fires, flip a coin for direction
         if(SignalAsianBreakout(atr) != 0)
            return(RandomDirection());
         return(0);

      case SIGNAL_RANDOM_TIME:
         if(MathRand() / 32767.0 < InpRandomTimeProb)
            return(RandomDirection());
         return(0);
     }
   return(0);
  }

//====================================================================
// Execution
//====================================================================
void OpenTrade(const int dir, const double atr)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPts = (ask - bid) / _Point;

   if(spreadPts > InpMaxSpreadPoints)
     {
      g_skipSpread++;
      return;
     }

   double sl = 0.0, tp = 0.0;
   double riskDist = atr; // in fixed-bars mode results are reported in ATR units

   if(InpExitMode == EXIT_ATR_SYMMETRIC)
     {
      riskDist = InpSlTpAtr * atr;
      double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      if(riskDist <= minDist)
        {
         Print("SL/TP distance below broker stops level, skip");
         return;
        }
      if(dir > 0) { sl = ask - riskDist; tp = ask + riskDist; }
      else        { sl = bid + riskDist; tp = bid - riskDist; }
      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);
     }

   string comment = "ET_" + IntegerToString((int)InpSignalMode);
   bool ok = (dir > 0) ? g_trade.Buy(InpLots, _Symbol, 0.0, sl, tp, comment)
                       : g_trade.Sell(InpLots, _Symbol, 0.0, sl, tp, comment);
   if(!ok || (g_trade.ResultRetcode() != TRADE_RETCODE_DONE && g_trade.ResultRetcode() != TRADE_RETCODE_PLACED))
     {
      Print("Order failed: ", g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription());
      return;
     }

   // locate the resulting position
   long posId = 0;
   ulong deal = g_trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      posId = HistoryDealGetInteger(deal, DEAL_POSITION_ID);

   ulong ticket = FindPositionTicket(posId);
   if(ticket == 0)
     {
      Print("Could not locate opened position");
      return;
     }

   ZeroMemory(g_tr);
   g_tr.active     = true;
   g_tr.ticket     = ticket;
   g_tr.posId      = PositionGetInteger(POSITION_IDENTIFIER);
   g_tr.dir        = dir;
   g_tr.entryTime  = (datetime)PositionGetInteger(POSITION_TIME);
   g_tr.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   g_tr.atr        = atr;
   g_tr.riskDist   = riskDist;
   g_tr.spreadPts  = spreadPts;

   g_day.traded = true;
  }

ulong FindPositionTicket(const long posId)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(posId != 0 && PositionGetInteger(POSITION_IDENTIFIER) != posId)
         continue;
      return(t); // leaves this position selected
     }
   return(0);
  }

void UpdateExcursion()
  {
   double fav = (g_tr.dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - g_tr.entryPrice
                               : g_tr.entryPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(fav  > g_tr.mfe) g_tr.mfe = fav;
   if(-fav > g_tr.mae) g_tr.mae = -fav;
  }

void ApplyTimeExit()
  {
   if(!g_tr.active || !PositionSelectByTicket(g_tr.ticket))
      return;

   int barsHeld = iBarShift(_Symbol, _Period, g_tr.entryTime);
   int limit    = (InpExitMode == EXIT_FIXED_BARS) ? InpExitBars : InpMaxHoldBars;
   if(barsHeld >= limit)
      g_trade.PositionClose(g_tr.ticket);
  }

//====================================================================
// Trade finalisation + logging
//====================================================================
void FinalizeTrade()
  {
   g_tr.active = false;

   if(!HistorySelectByPosition(g_tr.posId))
     {
      Print("HistorySelectByPosition failed for ", g_tr.posId);
      return;
     }

   double   exitPrice = 0.0, money = 0.0;
   datetime exitTime  = 0;
   string   reason    = "UNKNOWN";

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      money += HistoryDealGetDouble(d, DEAL_PROFIT)
             + HistoryDealGetDouble(d, DEAL_COMMISSION)
             + HistoryDealGetDouble(d, DEAL_SWAP);

      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
        {
         exitPrice = HistoryDealGetDouble(d, DEAL_PRICE);
         exitTime  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         reason    = ReasonToString(HistoryDealGetInteger(d, DEAL_REASON));
        }
     }

   if(exitTime == 0)
      return;

   double move     = (exitPrice - g_tr.entryPrice) * g_tr.dir;
   double resAtr   = move / g_tr.atr;
   double resR     = move / g_tr.riskDist;
   int    barsHeld = iBarShift(_Symbol, _Period, g_tr.entryTime) - iBarShift(_Symbol, _Period, exitTime);

   g_n++;
   if(resR > 0.0) g_wins++;
   g_sumR  += resR;
   g_sumR2 += resR * resR;

   if(g_csv != INVALID_HANDLE)
     {
      FileWrite(g_csv,
                TimeToString(g_tr.entryTime, TIME_DATE | TIME_MINUTES),
                g_tr.dir,
                DoubleToString(g_tr.entryPrice, _Digits),
                TimeToString(exitTime, TIME_DATE | TIME_MINUTES),
                DoubleToString(exitPrice, _Digits),
                reason,
                DoubleToString(g_tr.atr, _Digits),
                DoubleToString(g_tr.riskDist, _Digits),
                DoubleToString(g_tr.spreadPts, 1),
                DoubleToString(g_tr.mfe / g_tr.atr, 3),
                DoubleToString(g_tr.mae / g_tr.atr, 3),
                DoubleToString(resAtr, 3),
                DoubleToString(resR, 3),
                barsHeld,
                DoubleToString(money, 2),
                EnumToString(InpSignalMode),
                InpRandomSeed);
      FileFlush(g_csv);
     }
  }

string ReasonToString(const long r)
  {
   switch((int)r)
     {
      case DEAL_REASON_SL:     return("SL");
      case DEAL_REASON_TP:     return("TP");
      case DEAL_REASON_EXPERT: return("TIME");
      case DEAL_REASON_SO:     return("STOPOUT");
     }
   return("OTHER");
  }

void OpenCsv()
  {
   string name = StringFormat("%s_%s_%s_%s_seed%d.csv",
                              InpCsvPrefix, _Symbol,
                              EnumToString(InpSignalMode),
                              EnumToString(InpExitMode),
                              InpRandomSeed);
   // FILE_COMMON: every optimisation pass writes to Terminal/Common/Files
   g_csv = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(g_csv == INVALID_HANDLE)
     {
      Print("Cannot open CSV ", name, " err=", GetLastError());
      return;
     }
   FileWrite(g_csv, "entry_time", "dir", "entry_price", "exit_time", "exit_price", "exit_reason",
             "atr", "risk_dist", "spread_pts", "mfe_atr", "mae_atr", "result_atr", "result_r",
             "bars_held", "profit", "signal_mode", "seed");
  }

void PrintSummary()
  {
   if(g_n == 0)
     {
      PrintFormat("EdgeTester: no trades (skipped: range=%d spread=%d)", g_skipRange, g_skipSpread);
      return;
     }
   double avgR    = g_sumR / g_n;
   double var     = (g_n > 1) ? (g_sumR2 - g_n * avgR * avgR) / (g_n - 1) : 0.0;
   double sd      = (var > 0.0) ? MathSqrt(var) : 0.0;
   double tStat   = (sd > 0.0) ? avgR / (sd / MathSqrt(g_n)) : 0.0;
   double winRate = (double)g_wins / g_n;
   double zWin    = (g_wins - g_n * 0.5) / MathSqrt(g_n * 0.25); // vs 50% (meaningful in 1:1 mode)

   PrintFormat("EdgeTester [%s | %s | seed %d] trades=%d win=%.1f%% avgR=%.3f sdR=%.3f t=%.2f zWin=%.2f skipped(range=%d spread=%d)",
               EnumToString(InpSignalMode), EnumToString(InpExitMode), InpRandomSeed,
               g_n, winRate * 100.0, avgR, sd, tStat, zWin, g_skipRange, g_skipSpread);
  }
//+------------------------------------------------------------------+
