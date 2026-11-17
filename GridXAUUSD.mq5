//+------------------------------------------------------------------+
//|                                                   GridXAUUSD.mq5 |
//|  Grid EA XAUUSD v2.10 - market-structure aware (MetaTrader 5).  |
//|                                                                  |
//|  PERINGATAN: Trading grid berisiko tinggi. Tidak ada jaminan     |
//|  profit. Uji dulu di Strategy Tester dan akun demo.               |
//+------------------------------------------------------------------+
#property copyright "GridXAUUSD"
#property version   "2.10"
#property description "Grid EA XAUUSD v2.1: struktur pasar (swing/BOS/CHoCH), step & TP adaptif ATR, lot dari risiko grid penuh, grid stop, filter berita, circuit breaker equity high-water mark."

#include <Trade/Trade.mqh>

enum ENUM_GRID_MODE
  {
   GRID_STRUCTURE = 0, // Hanya arah struktur pasar
   GRID_BOTH      = 1  // Buy dan sell (mode lama)
  };

//--- Struktur pasar
input group "=== Struktur Pasar ==="
input int    InpPivotLookback   = 5;     // Lookback pivot (swing)
input int    InpEMAFast         = 21;    // EMA fast
input int    InpEMASlow         = 55;    // EMA slow
input int    InpAtrPeriod       = 14;    // Periode ATR
input double InpRangeAtrFrac    = 0.30;  // Range jika |EMAfast-EMAslow| < ATR*ini

//--- Grid
input group "=== Grid ==="
input ENUM_GRID_MODE InpMode             = GRID_STRUCTURE; // Mode arah grid
input double InpLot                      = 0.01;  // Lot tetap (jika lot risiko mati)
input bool   InpUseRiskLot               = true;  // Lot dihitung dari risiko grid penuh
input double InpRiskPercent              = 1.0;   // Risiko grid penuh satu arah sampai grid stop (% equity)
input bool   InpUseGridStop              = true;  // SL bersama per arah, satu step di bawah/atas level terakhir
input double InpGridStepAtrMult          = 1.0;   // Step grid = ATR * ini
input double InpGridStepMin              = 1.0;   // Step minimum (harga)
input double InpGridStepMax              = 25.0;  // Step maksimum (harga)
input double InpTakeProfitAtrMult        = 1.5;   // TP = ATR * ini
input double InpTakeProfitMin            = 2.0;   // TP minimum (harga)
input int    InpMaxLevelsPerSide         = 5;     // Maks. posisi per arah
input int    InpMaxTotalPositions        = 8;     // Maks. total posisi EA

//--- Risiko
input group "=== Risiko ==="
input double InpMaxDrawdownPct        = 30.0; // Stop DD floating (% balance)
input double InpMaxEquityDrawdownPct  = 40.0; // Circuit breaker equity dari high-water mark (%)
input double InpBasketProfitPct       = 0.0;  // Tutup semua jika untung >= % balance (0 = mati)
input double InpMinMarginLevel        = 500.0;// Margin level minimum (%) setelah buka posisi
input double InpMaxSpread             = 0.50; // Spread maksimum (harga)
input bool   InpHaltAfterStop         = true; // Berhenti total setelah stop
input bool   InpResetHalt             = false;// true sekali untuk lanjut setelah berhenti
input int    InpCooldownAfterStopMin  = 60;   // Jeda (menit) sebelum grid baru setelah grid stop kena

//--- Berita
input group "=== Filter Berita (kalender MT5) ==="
input bool   InpUseNewsFilter         = true;  // Jangan buka posisi di sekitar rilis berita
input string InpNewsCurrency          = "USD"; // Mata uang berita yang dipantau
input bool   InpNewsHighOnly          = true;  // true = hanya berita high impact; false = juga moderate
input int    InpNewsMinutesBefore     = 30;    // Menit sebelum rilis
input int    InpNewsMinutesAfter      = 30;    // Menit sesudah rilis

//--- Sesi
input group "=== Sesi (waktu server broker) ==="
input bool   InpUseSession            = true;  // Hanya buka posisi pada sesi ini
input string InpSessionStart          = "07:00"; // Mulai sesi (HH:MM)
input string InpSessionEnd            = "21:00"; // Akhir sesi (HH:MM)

//--- Lain-lain
input group "=== Lain-lain ==="
input ulong  InpMagic                 = 20261117; // Magic number
input int    InpSlippagePoints        = 30;    // Slippage maksimum (points)
input bool   InpAllowNonXau           = false; // Izinkan simbol selain XAU
input int    InpMaxFailBeforeHalt     = 5;     // Hentikan setelah N kegagalan order beruntun

//--- Variabel global
CTrade   g_trade;
int      g_atrHandle     = INVALID_HANDLE;
int      g_emaFastHandle = INVALID_HANDLE;
int      g_emaSlowHandle = INVALID_HANDLE;
double   g_atrBuf[];
double   g_emaFastBuf[];
double   g_emaSlowBuf[];
double   g_hiBuf[];
double   g_loBuf[];
double   g_clBuf[];

double   g_lot    = 0.0;
double   g_step   = 0.0;
double   g_tp     = 0.0;
double   g_bias   = 0.0;
double   g_lastSH = 0.0, g_prevSH = 0.0;
double   g_lastSL = 0.0, g_prevSL = 0.0;
bool     g_bullBOS   = false;
bool     g_bearBOS   = false;
bool     g_bullCHoCH = false;
bool     g_bearCHoCH = false;
bool     g_ready     = false;

datetime g_nextTryTime = 0;
int      g_failCount   = 0;
bool     g_halted      = false;
string   g_haltVar     = "";
string   g_hwmVar      = "";
double   g_hwmEquity   = 0.0;
bool     g_warnedMinLot = false;

datetime g_newsTimes[];
datetime g_newsNextRefresh = 0;
bool     g_newsAvailable   = true;

//+------------------------------------------------------------------+
//| Bulaskan lot sesuai aturan broker                                |
//+------------------------------------------------------------------+
double NormalizeLot(const double lot)
  {
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = vmin;
   if(vstep <= 0.0)
      return lot;
   double v = MathFloor(lot / vstep + 1e-9) * vstep;
   if(v < vmin)
      v = vmin;
   if(v > vmax)
      v = vmax;
   int digits = (int)MathMax(0.0, MathCeil(-MathLog10(vstep) - 1e-9));
   return NormalizeDouble(v, digits);
  }

//+------------------------------------------------------------------+
//| Cek apakah posisi yang sedang terpilih milik EA ini               |
//+------------------------------------------------------------------+
bool IsOurSelectedPosition()
  {
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Jadwalkan percobaan ulang                                         |
//+------------------------------------------------------------------+
void ScheduleRetry(const int seconds)
  {
   g_nextTryTime = TimeCurrent() + seconds;
  }

//+------------------------------------------------------------------+
//| Hentikan EA dan simpan statusnya                                  |
//+------------------------------------------------------------------+
void Halt(const string reason)
  {
   g_halted = true;
   GlobalVariableSet(g_haltVar, 1.0);
   PrintFormat("GridXAUUSD BERHENTI: %s. Untuk melanjutkan, pasang ulang EA dengan InpResetHalt = true.", reason);
   Comment("GridXAUUSD BERHENTI: ", reason, "\nPasang ulang EA dengan InpResetHalt = true untuk melanjutkan.");
  }

//+------------------------------------------------------------------+
//| Tutup semua posisi milik EA ini. Return true jika semua tertutup  |
//+------------------------------------------------------------------+
bool CloseAll(const string reason)
  {
   PrintFormat("GridXAUUSD menutup semua posisi: %s", reason);
   for(int attempt = 0; attempt < 3; attempt++)
     {
      int remaining = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !IsOurSelectedPosition())
            continue;
         if(!g_trade.PositionClose(ticket, InpSlippagePoints))
           {
            PrintFormat("Gagal menutup #%I64u: retcode %u (%s)", ticket,
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
            remaining++;
           }
        }
      if(remaining == 0)
         return true;
      Sleep(500);
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Pastikan setiap posisi punya TP (jika sempat gagal terpasang)     |
//+------------------------------------------------------------------+
void EnsureTakeProfit(const ulong ticket, const long type, const double openPrice, const double currentTp)
  {
   if(currentTp > 0.0)
      return;
   if(g_tp <= 0.0)
      return;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp     = (type == POSITION_TYPE_BUY) ? openPrice + g_tp : openPrice - g_tp;
   tp = NormalizeDouble(tp, digits);

   //--- Jika harga sudah melewati level TP, tutup langsung (untung)
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if((type == POSITION_TYPE_BUY && bid >= tp) || (type == POSITION_TYPE_SELL && ask <= tp))
     {
      if(!g_trade.PositionClose(ticket, InpSlippagePoints))
         PrintFormat("Gagal menutup #%I64u di level TP: retcode %u (%s)", ticket,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return;
     }

   double sl = PositionGetDouble(POSITION_SL);
   if(!g_trade.PositionModify(ticket, sl, tp))
      PrintFormat("Gagal memasang TP untuk #%I64u: retcode %u (%s)", ticket,
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Jumlah level maksimum yang bisa terisi di satu arah               |
//+------------------------------------------------------------------+
int GridLevels()
  {
   return MathMax(1, MathMin(InpMaxLevelsPerSide, InpMaxTotalPositions));
  }

//+------------------------------------------------------------------+
//| Jarak harga total jika grid satu arah terisi penuh lalu harga     |
//| mencapai grid stop (satu step setelah level terakhir).            |
//| Level k (0..n-1) berjarak (n-k) step ke stop -> step*n(n+1)/2.    |
//+------------------------------------------------------------------+
double FullGridDistance()
  {
   int n = GridLevels();
   return g_step * (double)(n * (n + 1)) / 2.0;
  }

//+------------------------------------------------------------------+
//| Lot dari risiko GRID PENUH (bukan per posisi)                     |
//+------------------------------------------------------------------+
double CalcRiskLot()
  {
   if(!InpUseRiskLot || InpRiskPercent <= 0.0)
      return g_lot;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0 || g_step <= 0.0)
      return g_lot;

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   double lossPerLot = (FullGridDistance() / tickSize) * tickValue; // rugi grid penuh untuk 1.00 lot
   if(lossPerLot <= 0.0 || riskMoney <= 0.0)
      return g_lot;

   double lot  = riskMoney / lossPerLot;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lot < vmin)
     {
      if(!g_warnedMinLot && equity > 0.0)
        {
         PrintFormat("PERINGATAN: lot risiko %.4f < lot minimum %.2f. Dengan lot minimum, risiko grid penuh = %.2f%% equity (target %.2f%%).",
                     lot, vmin, lossPerLot * vmin / equity * 100.0, InpRiskPercent);
         g_warnedMinLot = true;
        }
      return NormalizeLot(vmin);
     }
   g_warnedMinLot = false;
   return NormalizeLot(lot);
  }

//+------------------------------------------------------------------+
//| Filter berita: ambil jadwal rilis dari kalender ekonomi MT5       |
//| (waktu kalender = waktu server, TimeTradeServer).                 |
//| Kalender tidak tersedia di Strategy Tester -> filter tidak aktif. |
//+------------------------------------------------------------------+
void RefreshNews()
  {
   if(!InpUseNewsFilter)
      return;
   datetime now = TimeTradeServer();
   if(now < g_newsNextRefresh)
      return;
   g_newsNextRefresh = now + 300;

   ArrayResize(g_newsTimes, 0);
   MqlCalendarValue values[];
   ResetLastError();
   bool calOk = CalendarValueHistory(values, now - InpNewsMinutesAfter * 60, now + 24 * 3600, NULL, InpNewsCurrency);
   int  err   = GetLastError();
   int  n     = ArraySize(values);
   if(!calOk || n <= 0)
     {
      if(err != 0 && g_newsAvailable)
        {
         PrintFormat("Kalender ekonomi tidak tersedia (error %d) - filter berita tidak aktif untuk sementara.", err);
         g_newsAvailable = false;
        }
      return;
     }
   g_newsAvailable = true;

   for(int i = 0; i < n; i++)
     {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;
      bool relevant = (ev.importance == CALENDAR_IMPORTANCE_HIGH) ||
                      (!InpNewsHighOnly && ev.importance == CALENDAR_IMPORTANCE_MODERATE);
      if(!relevant)
         continue;
      int sz = ArraySize(g_newsTimes);
      ArrayResize(g_newsTimes, sz + 1);
      g_newsTimes[sz] = values[i].time;
     }
  }

bool InNewsWindow()
  {
   if(!InpUseNewsFilter)
      return false;
   datetime now = TimeTradeServer();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
     {
      if(now >= g_newsTimes[i] - InpNewsMinutesBefore * 60 &&
         now <= g_newsTimes[i] + InpNewsMinutesAfter * 60)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Grid stop: pasang SL bersama pada posisi yang belum punya SL.     |
//| Bila harga sudah melewati level stop, posisi ditutup.             |
//+------------------------------------------------------------------+
void EnsureGridStops(const double buySL, const double sellSL,
                     const double firstBuy, const double firstSell)
  {
   if(!InpUseGridStop || g_step <= 0.0)
      return;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int    n      = GridLevels();
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;
      if(PositionGetDouble(POSITION_SL) > 0.0)
         continue;

      long   type   = PositionGetInteger(POSITION_TYPE);
      bool   isBuy  = (type == POSITION_TYPE_BUY);
      double target = 0.0;
      if(isBuy)
         target = (buySL > 0.0) ? buySL : firstBuy - g_step * n;
      else
         target = (sellSL > 0.0) ? sellSL : firstSell + g_step * n;
      if(target <= 0.0)
         continue;
      target = NormalizeDouble(target, digits);

      if((isBuy && bid <= target) || (!isBuy && ask >= target))
        {
         if(!g_trade.PositionClose(ticket, InpSlippagePoints))
            PrintFormat("Gagal menutup #%I64u di level grid stop: retcode %u (%s)", ticket,
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         continue;
        }
      if(!g_trade.PositionModify(ticket, target, PositionGetDouble(POSITION_TP)))
         PrintFormat("Gagal memasang grid stop untuk #%I64u: retcode %u (%s)", ticket,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Baca struktur pasar: pivot, BOS/CHoCH, bias, step & TP adaptif    |
//+------------------------------------------------------------------+
bool ComputeStructure()
  {
   g_ready      = false;
   g_bias       = 0.0;
   g_bullBOS    = false;
   g_bearBOS    = false;
   g_bullCHoCH  = false;
   g_bearCHoCH  = false;

   int need = MathMax(InpPivotLookback * 4, MathMax(InpEMAFast, InpEMASlow) + InpAtrPeriod) + 10;
   if(Bars(_Symbol, PERIOD_CURRENT) < need)
      return false;
   if(BarsCalculated(g_atrHandle) < 3 || BarsCalculated(g_emaFastHandle) < 3 || BarsCalculated(g_emaSlowHandle) < 3)
      return false;

   ArraySetAsSeries(g_atrBuf, true);
   ArraySetAsSeries(g_emaFastBuf, true);
   ArraySetAsSeries(g_emaSlowBuf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 3, g_atrBuf) < 3)
      return false;
   if(CopyBuffer(g_emaFastHandle, 0, 0, 3, g_emaFastBuf) < 3)
      return false;
   if(CopyBuffer(g_emaSlowHandle, 0, 0, 3, g_emaSlowBuf) < 3)
      return false;

   double atr = g_atrBuf[1];
   if(atr <= 0.0)
      return false;

   //--- Salin bar tertutup (bar 1 = bar tertutup terakhir)
   ArrayResize(g_hiBuf, need);
   ArrayResize(g_loBuf, need);
   ArrayResize(g_clBuf, need);
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, need, g_hiBuf) < need)
      return false;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 1, need, g_loBuf) < need)
      return false;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 1, need, g_clBuf) < need)
      return false;

   //--- Deteksi pivot: swing high/low dengan lookback L
   int    L  = InpPivotLookback;
   double sh = 0.0, sl = 0.0, psh = 0.0, psl = 0.0;
   for(int s = 1 + L; s <= need - L; s++)
     {
      int  j   = s - 1;
      bool isH = true, isL = true;
      for(int k = 1; k <= L; k++)
        {
         if(g_hiBuf[j] <= g_hiBuf[j - k] || g_hiBuf[j] <= g_hiBuf[j + k])
            isH = false;
         if(g_loBuf[j] >= g_loBuf[j - k] || g_loBuf[j] >= g_loBuf[j + k])
            isL = false;
         if(!isH && !isL)
            break;
        }
      if(isH)
        {
         psh = sh;
         sh  = g_hiBuf[j];
        }
      if(isL)
        {
         psl = sl;
         sl  = g_loBuf[j];
        }
     }

   g_lastSH = sh;
   g_prevSH = psh;
   g_lastSL = sl;
   g_prevSL = psl;

   //--- Array tidak di-set series: indeks need-1 = bar tertutup terakhir, indeks 0 = bar tertua
   double closeLast = g_clBuf[need - 1];
   double emaF      = g_emaFastBuf[1];
   double emaS      = g_emaSlowBuf[1];

   bool trendUp   = (psh > 0.0 && sh > psh && psl > 0.0 && sl > psl);
   bool trendDown = (psh > 0.0 && sh < psh && psl > 0.0 && sl < psl);
   bool range     = (MathAbs(emaF - emaS) < atr * InpRangeAtrFrac);

   g_bullBOS   = (sh > 0.0 && closeLast > sh && trendUp);
   g_bearBOS   = (sl > 0.0 && closeLast < sl && trendDown);
   g_bearCHoCH = (sl > 0.0 && closeLast < sl && trendUp);
   g_bullCHoCH = (sh > 0.0 && closeLast > sh && trendDown);

   if(!range && emaF > emaS && trendUp)
      g_bias = 1.0;
   else
      if(!range && emaF < emaS && trendDown)
         g_bias = -1.0;
      else
         g_bias = 0.0;

   g_step = MathMin(InpGridStepMax, MathMax(InpGridStepMin, atr * InpGridStepAtrMult));
   g_tp   = MathMax(InpTakeProfitMin, atr * InpTakeProfitAtrMult);

   g_ready = true;
   return true;
  }

//+------------------------------------------------------------------+
//| Pemicu entry yang searah struktur                                |
//+------------------------------------------------------------------+
bool CanEnterBuy(const MqlTick &tick)
  {
   if(g_bias <= 0.0)
      return false;
   double emaF = g_emaFastBuf[1];
   double atr  = g_atrBuf[1];
   if(tick.ask <= emaF + atr * 1.5 && tick.ask >= emaF - atr * 2.0)
      return true;
   if(g_bullBOS)
      return true;
   return false;
  }

bool CanEnterSell(const MqlTick &tick)
  {
   if(g_bias >= 0.0)
      return false;
   double emaF = g_emaFastBuf[1];
   double atr  = g_atrBuf[1];
   if(tick.bid >= emaF - atr * 1.5 && tick.bid <= emaF + atr * 2.0)
      return true;
   if(g_bearBOS)
      return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Sesi trading                                                      |
//+------------------------------------------------------------------+
int ParseTimeToMinutes(const string s)
  {
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   int colon = StringFind(t, ":");
   if(colon < 0)
      return -1;
   int hh = (int)StringToInteger(StringSubstr(t, 0, colon));
   int mm = (int)StringToInteger(StringSubstr(t, colon + 1));
   if(hh < 0 || hh > 23 || mm < 0 || mm > 59)
      return -1;
   return hh * 60 + mm;
  }

bool InSession()
  {
   int a = ParseTimeToMinutes(InpSessionStart);
   int b = ParseTimeToMinutes(InpSessionEnd);
   if(a < 0 || b < 0)
      return true;
   if(a == b)
      return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int cur = dt.hour * 60 + dt.min;
   if(a < b)
      return (cur >= a && cur < b);
   return (cur >= a || cur < b); // sesi lewat tengah malam
  }

//+------------------------------------------------------------------+
//| Komentar status                                                   |
//+------------------------------------------------------------------+
void UpdateComment(const int buyCount, const int sellCount, const int totalPos,
                   const double floating, const double equity, const double atr)
  {
   string dir = (g_bias > 0.0) ? "BULLISH" : ((g_bias < 0.0) ? "BEARISH" : "RANGE");
   Comment(StringFormat(
      "GridXAUUSD v2 | %s\n"
      "Buy: %d  Sell: %d  (maks %d/arah, total %d/%d)\n"
      "ATR: %.2f | Step: %.2f | TP: %.2f\n"
      "Mengambang: %.2f | Equity: %.2f | HWM: %.2f\n"
      "Struktur: SH %.2f / SL %.2f%s%s%s%s\n"
      "Spread: %.2f (maks %.2f)%s%s",
      dir, buyCount, sellCount, InpMaxLevelsPerSide, totalPos, InpMaxTotalPositions,
      atr, g_step, g_tp, floating, equity, g_hwmEquity,
      g_lastSH, g_lastSL,
      g_bullBOS   ? " [BOS+]"   : "",
      g_bearBOS   ? " [BOS-]"   : "",
      g_bullCHoCH ? " [CHoCH+]" : "",
      g_bearCHoCH ? " [CHoCH-]" : "",
      SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID),
      InpMaxSpread,
      (InpUseSession && !InSession()) ? " | LUAR SESI" : "",
      InNewsWindow() ? " | JEDA BERITA" : ""));
  }

//+------------------------------------------------------------------+
//| Buka satu posisi grid dengan semua pengecekan                     |
//+------------------------------------------------------------------+
bool OpenPosition(const ENUM_ORDER_TYPE type, const MqlTick &tick, const double sideSL)
  {
   int    digits      = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   bool   isBuy       = (type == ORDER_TYPE_BUY);

   double price = isBuy ? tick.ask : tick.bid;
   double tp    = isBuy ? price + g_tp : price - g_tp;
   tp = NormalizeDouble(tp, digits);

   //--- TP harus lebih jauh dari stops/freeze level broker
   double tpDistance = isBuy ? (tp - tick.bid) : (tick.ask - tp);
   double minDist    = MathMax(stopsLevel, freezeLevel) * point;
   if(tpDistance <= minDist)
     {
      PrintFormat("TP terlalu dekat (jarak %.2f, min %.2f). Naikkan InpTakeProfitAtrMult/InpTakeProfitMin.",
                  tpDistance, minDist);
      ScheduleRetry(60);
      return false;
     }

   //--- Grid stop: posisi pertama menetapkan SL bersama (n step dari entry),
   //--- level berikutnya memakai SL yang sama.
   double sl = 0.0;
   if(InpUseGridStop)
     {
      if(sideSL > 0.0)
         sl = sideSL;
      else
         sl = isBuy ? price - g_step * GridLevels() : price + g_step * GridLevels();
      sl = NormalizeDouble(sl, digits);
      double slDistance = isBuy ? (tick.bid - sl) : (sl - tick.ask);
      if(sl <= 0.0 || slDistance <= minDist)
        {
         //--- Level baru akan berada di/terlalu dekat grid stop (mis. ATR melebar): jangan buka.
         ScheduleRetry(60);
         return false;
        }
     }

   //--- Lot berbasis risiko
   double lot = CalcRiskLot();
   if(lot <= 0.0)
     {
      ScheduleRetry(30);
      return false;
     }

   //--- Cek margin
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lot, price, margin))
     {
      Print("OrderCalcMargin gagal, error ", GetLastError());
      ScheduleRetry(15);
      return false;
     }
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > 0.0 && margin >= freeMargin)
     {
      ScheduleRetry(30);
      return false;
     }
   double marginAfter = usedMargin + margin;
   if(marginAfter > 0.0 && (equity / marginAfter) * 100.0 < InpMinMarginLevel)
     {
      ScheduleRetry(30);
      return false;
     }

   //--- Kirim order
   bool sent = isBuy ? g_trade.Buy(lot, _Symbol, price, sl, tp, "grid")
                     : g_trade.Sell(lot, _Symbol, price, sl, tp, "grid");
   uint rc = g_trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("Order %s gagal: retcode %u (%s)", isBuy ? "BUY" : "SELL", rc,
                  g_trade.ResultRetcodeDescription());
      g_failCount++;
      if(rc == TRADE_RETCODE_NO_MONEY)
        {
         Print("Margin tidak cukup - EA dihentikan.");
         Halt("no money");
         return false;
        }
      if(g_failCount >= InpMaxFailBeforeHalt)
        {
         Halt(StringFormat("%d kegagalan order beruntun", g_failCount));
         return false;
        }
      ScheduleRetry(MathMin(60 * g_failCount, 300));
      return false;
     }

   g_failCount = 0;
   return true;
  }

//+------------------------------------------------------------------+
//| Inisialisasi                                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpPivotLookback < 1 || InpEMAFast < 1 || InpEMASlow < 1 || InpAtrPeriod < 1 ||
      InpLot <= 0.0 || InpRiskPercent < 0.0 ||
      InpGridStepMin <= 0.0 || InpGridStepMax < InpGridStepMin ||
      InpTakeProfitMin <= 0.0 || InpMaxLevelsPerSide < 1 || InpMaxTotalPositions < 1 ||
      InpMaxDrawdownPct <= 0.0 || InpMaxDrawdownPct >= 100.0 ||
      InpMaxEquityDrawdownPct < 0.0 || InpMaxEquityDrawdownPct >= 100.0 ||
      InpBasketProfitPct < 0.0 || InpMinMarginLevel < 0.0 || InpMaxSpread <= 0.0 ||
      InpMaxFailBeforeHalt < 1 || InpCooldownAfterStopMin < 0 ||
      InpNewsMinutesBefore < 0 || InpNewsMinutesAfter < 0)
     {
      Print("Parameter tidak valid. Periksa kembali input EA.");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(!InpAllowNonXau && StringFind(_Symbol, "XAU") < 0)
     {
      PrintFormat("Simbol %s bukan XAU. Pasang di chart XAUUSD, atau set InpAllowNonXau = true.", _Symbol);
      return INIT_PARAMETERS_INCORRECT;
     }

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("EA ini butuh akun HEDGING (bukan netting). Buat akun MT5 dengan mode hedging.");
      return INIT_FAILED;
     }

   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double tickValue    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   PrintFormat("Info broker: contract size %.4f, tick value %.4f, tick size %.4f, point %.5f",
               contractSize, tickValue, tickSize, SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   if(contractSize <= 0.0)
      Print("PERINGATAN: contract size 0 - periksa simbol di broker.");

   g_atrHandle     = iATR(_Symbol, PERIOD_CURRENT, InpAtrPeriod);
   g_emaFastHandle = iMA(_Symbol, PERIOD_CURRENT, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, PERIOD_CURRENT, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   if(g_atrHandle == INVALID_HANDLE || g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE)
     {
      Print("Gagal membuat handle indikator, error ", GetLastError());
      return INIT_FAILED;
     }

   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(InpLot < vmin - 1e-9 || InpLot > vmax + 1e-9)
     {
      PrintFormat("Lot %.2f di luar batas broker (min %.2f, maks %.2f).", InpLot, vmin, vmax);
      return INIT_PARAMETERS_INCORRECT;
     }
   g_lot = NormalizeLot(InpLot);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_haltVar = "GridXAUUSD_Halt_" + _Symbol + "_" + IntegerToString((long)InpMagic);
   g_hwmVar  = "GridXAUUSD_HWM_"  + _Symbol + "_" + IntegerToString((long)InpMagic);

   if(InpResetHalt)
     {
      GlobalVariableDel(g_haltVar);
      GlobalVariableDel(g_hwmVar);
      g_hwmEquity = 0.0;
     }

   g_halted = GlobalVariableCheck(g_haltVar) && GlobalVariableGet(g_haltVar) > 0.0;

   //--- High-water mark. Saat first-run (atau setelah reset), pakai MAKS(balance, equity):
   //--- jika akun sudah punya rugi mengambang, rugi itu ikut terhitung sebagai drawdown,
   //--- bukan diam-diam dijadikan titik nol baru.
   double initBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double initEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GlobalVariableCheck(g_hwmVar))
      g_hwmEquity = GlobalVariableGet(g_hwmVar);
   else
     {
      g_hwmEquity = MathMax(initBalance, initEquity);
      GlobalVariableSet(g_hwmVar, g_hwmEquity);
      PrintFormat("HWM awal = %.2f (maks balance %.2f / equity %.2f).", g_hwmEquity, initBalance, initEquity);
     }

   //--- Periksa posisi yang sudah ada di akun
   int    ourPos = 0, otherPos = 0;
   double ourFloating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(IsOurSelectedPosition())
        {
         ourPos++;
         ourFloating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      else
         otherPos++;
     }
   if(ourPos > 0)
     {
      PrintFormat("PERINGATAN: ada %d posisi EA ini dari sesi sebelumnya (mengambang %.2f). EA akan terus mengelolanya (TP, grid stop, stop DD).",
                  ourPos, ourFloating);
      if(initBalance > 0.0 && ourFloating <= -initBalance * InpMaxDrawdownPct / 100.0)
         Print("PERINGATAN: rugi posisi itu sudah melewati batas stop DD - posisi akan langsung ditutup pada tick pertama.");
     }
   if(otherPos > 0)
      PrintFormat("PERINGATAN: ada %d posisi lain (manual/EA lain) di akun ini. Circuit breaker equity memakai equity SELURUH akun, jadi posisi itu ikut memengaruhinya.",
                  otherPos);
   if(initEquity < initBalance)
      PrintFormat("PERINGATAN: equity %.2f di bawah balance %.2f - akun sedang rugi mengambang %.2f.",
                  initEquity, initBalance, initBalance - initEquity);

   if(g_halted)
      Comment("GridXAUUSD BERHENTI (stop sebelumnya).\nPasang ulang EA dengan InpResetHalt = true.");

   PrintFormat("GridXAUUSD v2.1 aktif: %s, mode %s, lot %.2f (risiko grid %.2f%%), step ATR x%.2f, TP ATR x%.2f, maks %d/arah, total maks %d, grid stop %s, filter berita %s",
               _Symbol, (InpMode == GRID_STRUCTURE ? "STRUCTURE" : "BOTH"),
               g_lot, InpRiskPercent, InpGridStepAtrMult, InpTakeProfitAtrMult,
               InpMaxLevelsPerSide, InpMaxTotalPositions,
               InpUseGridStop ? "ON" : "OFF", InpUseNewsFilter ? InpNewsCurrency : "OFF");
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinisialisasi                                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
      IndicatorRelease(g_atrHandle);
   if(g_emaFastHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE)
      IndicatorRelease(g_emaSlowHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Deteksi grid stop kena -> jeda sebelum grid baru                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
      return;
   if((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_REASON) != DEAL_REASON_SL)
      return;

   if(InpCooldownAfterStopMin > 0)
     {
      datetime until = TimeCurrent() + InpCooldownAfterStopMin * 60;
      if(until > g_nextTryTime)
         g_nextTryTime = until;
      PrintFormat("Grid stop kena (deal #%I64u). Grid baru ditunda %d menit.", trans.deal, InpCooldownAfterStopMin);
     }
  }

//+------------------------------------------------------------------+
//| Setiap tick                                                       |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_halted)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   ComputeStructure();
   RefreshNews();

   //--- Kumpulkan posisi milik EA ini
   int    buyCount = 0, sellCount = 0;
   double lowestBuy = DBL_MAX, highestSell = -DBL_MAX;
   double firstBuy = 0.0, firstSell = DBL_MAX;  // buy tertinggi / sell terendah = level pertama
   double buySL = 0.0, sellSL = 0.0;            // SL bersama yang sudah terpasang
   double floating = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp        = PositionGetDouble(POSITION_TP);
      floating += PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);

      double posSL = PositionGetDouble(POSITION_SL);
      if(type == POSITION_TYPE_BUY)
        {
         buyCount++;
         if(openPrice < lowestBuy)
            lowestBuy = openPrice;
         if(openPrice > firstBuy)
            firstBuy = openPrice;
         if(posSL > 0.0 && buySL <= 0.0)
            buySL = posSL;
        }
      else
         if(type == POSITION_TYPE_SELL)
           {
            sellCount++;
            if(openPrice > highestSell)
               highestSell = openPrice;
            if(openPrice < firstSell)
               firstSell = openPrice;
            if(posSL > 0.0 && sellSL <= 0.0)
               sellSL = posSL;
           }

      EnsureTakeProfit(ticket, type, openPrice, tp);
     }

   EnsureGridStops(buySL, sellSL, firstBuy, (firstSell < DBL_MAX) ? firstSell : 0.0);

   int    totalPos = buyCount + sellCount;
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double atr      = (ArraySize(g_atrBuf) > 1) ? g_atrBuf[1] : 0.0;

   //--- High-water mark equity
   if(g_hwmEquity <= 0.0)
      g_hwmEquity = equity;
   if(equity > g_hwmEquity)
     {
      g_hwmEquity = equity;
      GlobalVariableSet(g_hwmVar, g_hwmEquity);
     }

   //--- Pengaman 1: circuit breaker equity (realized + floating)
   if(InpMaxEquityDrawdownPct > 0.0 && g_hwmEquity > 0.0)
     {
      double eqDD = (g_hwmEquity - equity) / g_hwmEquity * 100.0;
      if(eqDD >= InpMaxEquityDrawdownPct)
        {
         bool closed = CloseAll(StringFormat("circuit breaker equity DD %.2f%% (HWM %.2f)", eqDD, g_hwmEquity));
         if(InpHaltAfterStop && closed)
            Halt("circuit breaker equity drawdown");
         return;
        }
     }

   //--- Pengaman 2: stop drawdown floating
   if(balance > 0.0 && floating <= -balance * InpMaxDrawdownPct / 100.0)
     {
      bool closed = CloseAll(StringFormat("rugi mengambang %.2f mencapai batas %.1f%% balance", floating, InpMaxDrawdownPct));
      if(InpHaltAfterStop && closed)
         Halt("stop drawdown tercapai");
      return;
     }

   //--- Pengaman 3: ambil untung keranjang (opsional)
   if(InpBasketProfitPct > 0.0 && balance > 0.0 && floating >= balance * InpBasketProfitPct / 100.0)
     {
      CloseAll(StringFormat("untung mengambang %.2f mencapai target %.1f%% balance", floating, InpBasketProfitPct));
      return;
     }

   UpdateComment(buyCount, sellCount, totalPos, floating, equity, atr);

   //--- Syarat membuka posisi baru
   if(!g_ready)
      return;
   if(TimeCurrent() < g_nextTryTime)
      return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return;
   if(tick.ask - tick.bid > InpMaxSpread)
      return;
   if(InpUseSession && !InSession())
      return;
   if(InNewsWindow())
      return;
   if(totalPos >= InpMaxTotalPositions)
      return;

   //--- Mode struktur: hanya searah bias
   if(InpMode == GRID_STRUCTURE)
     {
      if(g_bias > 0.0)
        {
         if(buyCount == 0)
           {
            if(CanEnterBuy(tick))
              {
               OpenPosition(ORDER_TYPE_BUY, tick, buySL);
               return;
              }
           }
         else
            if(buyCount < InpMaxLevelsPerSide && tick.ask <= lowestBuy - g_step)
              {
               OpenPosition(ORDER_TYPE_BUY, tick, buySL);
               return;
              }
        }
      else
         if(g_bias < 0.0)
           {
            if(sellCount == 0)
              {
               if(CanEnterSell(tick))
                 {
                  OpenPosition(ORDER_TYPE_SELL, tick, sellSL);
                  return;
                 }
              }
            else
               if(sellCount < InpMaxLevelsPerSide && tick.bid >= highestSell + g_step)
                 {
                  OpenPosition(ORDER_TYPE_SELL, tick, sellSL);
                  return;
                 }
           }
      return;
     }

   //--- Mode BOTH (perilaku lama)
   if(buyCount < InpMaxLevelsPerSide &&
      (buyCount == 0 || tick.ask <= lowestBuy - g_step))
     {
      OpenPosition(ORDER_TYPE_BUY, tick, buySL);
      return;
     }

   if(sellCount < InpMaxLevelsPerSide &&
      (sellCount == 0 || tick.bid >= highestSell + g_step))
     {
      OpenPosition(ORDER_TYPE_SELL, tick, sellSL);
      return;
     }
  }
//+------------------------------------------------------------------+
