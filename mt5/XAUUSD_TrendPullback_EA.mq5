//+------------------------------------------------------------------+
//|                                   XAUUSD_TrendPullback_EA.mq5    |
//|  Trend-following pullback EA for XAUUSD (Gold)                   |
//|                                                                  |
//|  Logic:                                                          |
//|   1. Higher-TF trend filter : EMA(200) on H1 + price side        |
//|   2. Entry TF pullback      : price pulls back to EMA(50) zone   |
//|   3. Momentum confirm       : RSI crosses back in trend direction|
//|   4. Risk                   : ATR based SL, TP = SL * RR         |
//|   5. Management             : break-even + ATR trailing stop     |
//|   6. Filters                : session, spread, max trades/day,   |
//|                               daily loss limit                   |
//|                                                                  |
//|  NOTE: No EA can guarantee a win rate. Backtest + forward test   |
//|  on demo before going live.                                      |
//+------------------------------------------------------------------+
#property copyright "micvps"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Inputs: general
input group "=== General ==="
input ulong           InpMagic            = 260810;        // Magic number
input ENUM_TIMEFRAMES InpEntryTF          = PERIOD_M15;    // Entry timeframe
input ENUM_TIMEFRAMES InpTrendTF          = PERIOD_H1;     // Trend timeframe

//--- Inputs: risk
input group "=== Risk ==="
input double          InpRiskPercent      = 1.0;           // Risk % per trade (0 = fixed lot)
input double          InpFixedLot         = 0.01;          // Fixed lot (if risk % = 0)
input double          InpSL_ATR_Mult      = 1.5;           // Stop loss = ATR * mult
input double          InpRR               = 1.0;           // Take profit = SL * RR (lower RR -> higher win rate)
input int             InpMaxSpreadPoints  = 350;           // Max spread (points)
input int             InpMaxTradesPerDay  = 3;             // Max trades per day
input double          InpMaxDailyLossPct  = 3.0;           // Stop trading after daily loss % (0 = off)

//--- Inputs: indicators
input group "=== Indicators ==="
input int             InpTrendEMA         = 200;           // Trend EMA (trend TF)
input int             InpFastEMA          = 21;            // Fast EMA (entry TF)
input int             InpSlowEMA          = 50;            // Slow EMA (entry TF)
input int             InpRSIPeriod        = 14;            // RSI period
input double          InpRSIBuyLevel      = 40.0;          // RSI buy trigger (cross up)
input double          InpRSISellLevel     = 60.0;          // RSI sell trigger (cross down)
input int             InpATRPeriod        = 14;            // ATR period
input int             InpADXPeriod        = 14;            // ADX period
input double          InpMinADX           = 20.0;          // Min ADX (trend strength)

//--- Inputs: trade management
input group "=== Trade Management ==="
input bool            InpUseBreakEven     = true;          // Use break-even
input double          InpBE_TriggerR      = 0.6;           // Move SL to BE at this R multiple
input double          InpBE_LockPoints    = 50;            // Points locked in at BE
input bool            InpUseTrailing      = true;          // Use ATR trailing
input double          InpTrail_StartR     = 0.8;           // Start trailing at this R multiple
input double          InpTrail_ATR_Mult   = 1.0;           // Trailing distance = ATR * mult

//--- Inputs: session (server time)
input group "=== Session (server time) ==="
input bool            InpUseSession       = true;          // Use session filter
input int             InpStartHour        = 8;             // Start hour (London)
input int             InpEndHour          = 20;            // End hour (NY)
input bool            InpCloseFriday      = true;          // Close all on Friday
input int             InpFridayCloseHour  = 20;            // Friday close hour

//--- Globals
CTrade   trade;
int      hTrendEMA, hFastEMA, hSlowEMA, hRSI, hATR, hADX;
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFillingBySymbol(_Symbol);

   hTrendEMA = iMA(_Symbol, InpTrendTF, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   hFastEMA  = iMA(_Symbol, InpEntryTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA  = iMA(_Symbol, InpEntryTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI      = iRSI(_Symbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   hATR      = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   hADX      = iADX(_Symbol, InpEntryTF, InpADXPeriod);

   if(hTrendEMA == INVALID_HANDLE || hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE ||
      hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE || hADX == INVALID_HANDLE)
   {
      Print("Indicator handle creation failed");
      return INIT_FAILED;
   }

   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("Warning: EA is designed for XAUUSD, attached to ", _Symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hTrendEMA);
   IndicatorRelease(hFastEMA);
   IndicatorRelease(hSlowEMA);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
   IndicatorRelease(hADX);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManagePositions();

   if(InpCloseFriday && IsFridayClose())
   {
      CloseAll();
      return;
   }

   // Run entry logic once per new bar on the entry timeframe
   datetime barTime = iTime(_Symbol, InpEntryTF, 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   if(CountPositions() > 0)            return;
   if(!InSession())                    return;
   if(!SpreadOK())                     return;
   if(TradesToday() >= InpMaxTradesPerDay) return;
   if(DailyLossHit())                  return;

   int signal = GetSignal();
   if(signal != 0)
      OpenTrade(signal);
}

//+------------------------------------------------------------------+
//| Signal: +1 buy, -1 sell, 0 none                                  |
//+------------------------------------------------------------------+
int GetSignal()
{
   double trendEMA[], fastEMA[], slowEMA[], rsi[], adx[];
   ArraySetAsSeries(trendEMA, true);
   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(adx, true);

   if(CopyBuffer(hTrendEMA, 0, 1, 2, trendEMA) < 2) return 0;
   if(CopyBuffer(hFastEMA,  0, 1, 3, fastEMA)  < 3) return 0;
   if(CopyBuffer(hSlowEMA,  0, 1, 3, slowEMA)  < 3) return 0;
   if(CopyBuffer(hRSI,      0, 1, 3, rsi)      < 3) return 0;
   if(CopyBuffer(hADX,      0, 1, 1, adx)      < 1) return 0;

   double trendClose = iClose(_Symbol, InpTrendTF, 1);
   double close1 = iClose(_Symbol, InpEntryTF, 1);
   double low1   = iLow(_Symbol,   InpEntryTF, 1);
   double low2   = iLow(_Symbol,   InpEntryTF, 2);
   double high1  = iHigh(_Symbol,  InpEntryTF, 1);
   double high2  = iHigh(_Symbol,  InpEntryTF, 2);
   double open1  = iOpen(_Symbol,  InpEntryTF, 1);

   if(adx[0] < InpMinADX)
      return 0;

   bool htfUp   = trendClose > trendEMA[0] && trendEMA[0] > trendEMA[1];
   bool htfDown = trendClose < trendEMA[0] && trendEMA[0] < trendEMA[1];

   // BUY: uptrend, EMAs stacked, price dipped into EMA zone, RSI crossing back up, bullish close
   if(htfUp && fastEMA[0] > slowEMA[0])
   {
      bool touchedZone = (MathMin(low1, low2) <= fastEMA[0]) && close1 > slowEMA[0];
      bool rsiCross    = rsi[1] < InpRSIBuyLevel + 10 && rsi[0] > rsi[1] && rsi[0] > InpRSIBuyLevel;
      bool bullBar     = close1 > open1 && close1 > fastEMA[0];
      if(touchedZone && rsiCross && bullBar)
         return 1;
   }

   // SELL: downtrend, EMAs stacked, price rallied into EMA zone, RSI crossing back down, bearish close
   if(htfDown && fastEMA[0] < slowEMA[0])
   {
      bool touchedZone = (MathMax(high1, high2) >= fastEMA[0]) && close1 < slowEMA[0];
      bool rsiCross    = rsi[1] > InpRSISellLevel - 10 && rsi[0] < rsi[1] && rsi[0] < InpRSISellLevel;
      bool bearBar     = close1 < open1 && close1 < fastEMA[0];
      if(touchedZone && rsiCross && bearBar)
         return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
void OpenTrade(int dir)
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;

   double slDist = atr[0] * InpSL_ATR_Mult;
   double tpDist = slDist * InpRR;

   // respect broker min stop level
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop + 10 * _Point;
   if(tpDist < minStop) tpDist = minStop + 10 * _Point;

   double lot = CalcLot(slDist);
   if(lot <= 0) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(dir > 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - slDist, digits);
      double tp  = NormalizeDouble(ask + tpDist, digits);
      if(!trade.Buy(lot, _Symbol, ask, sl, tp, "XAU Pullback BUY"))
         Print("Buy failed: ", trade.ResultRetcodeDescription());
   }
   else
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + slDist, digits);
      double tp  = NormalizeDouble(bid - tpDist, digits);
      if(!trade.Sell(lot, _Symbol, bid, sl, tp, "XAU Pullback SELL"))
         Print("Sell failed: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
double CalcLot(double slDist)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lot = InpFixedLot;
   if(InpRiskPercent > 0)
   {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue <= 0 || tickSize <= 0) return 0;

      double riskMoney   = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
      double lossPerLot  = (slDist / tickSize) * tickValue;
      if(lossPerLot <= 0) return 0;
      lot = riskMoney / lossPerLot;
   }

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Break-even + ATR trailing                                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
   if(!InpUseBreakEven && !InpUseTrailing) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double risk  = atr[0] * InpSL_ATR_Mult;   // approx initial R
      if(risk <= 0) continue;

      double newSL = sl;

      if(type == POSITION_TYPE_BUY)
      {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - open;

         if(InpUseBreakEven && profit >= risk * InpBE_TriggerR)
         {
            double be = open + InpBE_LockPoints * _Point;
            if(newSL < be) newSL = be;
         }
         if(InpUseTrailing && profit >= risk * InpTrail_StartR)
         {
            double trail = bid - atr[0] * InpTrail_ATR_Mult;
            if(trail > newSL) newSL = trail;
         }
         newSL = NormalizeDouble(newSL, digits);
         if(newSL > sl + _Point && newSL < bid)
            trade.PositionModify(ticket, newSL, tp);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = open - ask;

         if(InpUseBreakEven && profit >= risk * InpBE_TriggerR)
         {
            double be = open - InpBE_LockPoints * _Point;
            if(newSL == 0 || newSL > be) newSL = be;
         }
         if(InpUseTrailing && profit >= risk * InpTrail_StartR)
         {
            double trail = ask + atr[0] * InpTrail_ATR_Mult;
            if(newSL == 0 || trail < newSL) newSL = trail;
         }
         newSL = NormalizeDouble(newSL, digits);
         if((sl == 0 || newSL < sl - _Point) && newSL > ask)
            trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
void CloseAll()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
datetime DayStart()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   return StructToTime(t);
}

//+------------------------------------------------------------------+
int TradesToday()
{
   if(!HistorySelect(DayStart(), TimeCurrent())) return 0;
   int count = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol &&
         HistoryDealGetInteger(d, DEAL_MAGIC) == (long)InpMagic &&
         HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
bool DailyLossHit()
{
   if(InpMaxDailyLossPct <= 0) return false;
   if(!HistorySelect(DayStart(), TimeCurrent())) return false;

   double pnl = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong d = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d, DEAL_MAGIC) != (long)InpMagic) continue;
      pnl += HistoryDealGetDouble(d, DEAL_PROFIT)
           + HistoryDealGetDouble(d, DEAL_SWAP)
           + HistoryDealGetDouble(d, DEAL_COMMISSION);
   }
   double limit = AccountInfoDouble(ACCOUNT_BALANCE) * InpMaxDailyLossPct / 100.0;
   return pnl <= -limit;
}

//+------------------------------------------------------------------+
bool InSession()
{
   if(!InpUseSession) return true;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.day_of_week == 0 || t.day_of_week == 6) return false;
   if(InpStartHour <= InpEndHour)
      return t.hour >= InpStartHour && t.hour < InpEndHour;
   return t.hour >= InpStartHour || t.hour < InpEndHour;
}

//+------------------------------------------------------------------+
bool IsFridayClose()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.day_of_week == 5 && t.hour >= InpFridayCloseHour;
}

//+------------------------------------------------------------------+
bool SpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= InpMaxSpreadPoints;
}
//+------------------------------------------------------------------+
