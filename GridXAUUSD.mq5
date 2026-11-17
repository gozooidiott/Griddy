//+------------------------------------------------------------------+
//|                                                   GridXAUUSD.mq5 |
//|  Grid Expert Advisor untuk XAUUSD (MetaTrader 5, akun hedging).  |
//|  Dirancang untuk akun cent kecil (mis. 10 USD = 1000 USC) dengan  |
//|  lot tetap 0.01 dan pengaman risiko bawaan.                       |
//|                                                                  |
//|  PERINGATAN: Trading grid berisiko tinggi. Tidak ada jaminan     |
//|  profit. Uji dulu di Strategy Tester dan akun demo.               |
//+------------------------------------------------------------------+
#property copyright "GridXAUUSD"
#property version   "1.00"
#property description "Grid EA XAUUSD dengan batas level, stop drawdown, filter spread dan cek margin."

#include <Trade/Trade.mqh>

enum ENUM_GRID_MODE
  {
   GRID_BOTH      = 0, // Buy dan Sell
   GRID_BUY_ONLY  = 1, // Hanya Buy
   GRID_SELL_ONLY = 2  // Hanya Sell
  };

//--- Pengaturan grid
input group "=== Grid ==="
input ENUM_GRID_MODE InpMode             = GRID_BOTH; // Arah grid
input double         InpLot              = 0.01;      // Ukuran lot per posisi
input double         InpGridStep         = 5.0;       // Jarak antar level (dalam harga, USD per ons)
input double         InpTakeProfit       = 5.0;       // Take profit tiap posisi (dalam harga, USD per ons)
input int            InpMaxLevelsPerSide = 5;         // Maks. posisi terbuka per arah

//--- Pengaturan risiko
input group "=== Risiko ==="
input double InpMaxDrawdownPct   = 30.0;  // Tutup semua jika rugi mengambang >= % balance
input double InpBasketProfitPct  = 0.0;   // Tutup semua jika untung mengambang >= % balance (0 = mati)
input double InpMinMarginLevel   = 500.0; // Margin level minimum (%) setelah buka posisi baru
input double InpMaxSpread        = 0.50;  // Spread maksimum (dalam harga) untuk buka posisi baru
input bool   InpHaltAfterStop    = true;  // Berhenti total setelah stop drawdown
input bool   InpResetHalt        = false; // Set true sekali untuk melanjutkan setelah berhenti

//--- Lain-lain
input group "=== Lain-lain ==="
input ulong  InpMagic          = 20261117; // Magic number
input int    InpSlippagePoints = 30;       // Slippage maksimum (points)
input bool   InpAllowNonXau    = false;    // Izinkan dipasang di simbol selain XAU

//--- Variabel global
CTrade   g_trade;
double   g_lot          = 0.0;
string   g_haltVar      = "";
bool     g_halted       = false;
datetime g_nextTryTime  = 0;

//+------------------------------------------------------------------+
//| Bulatkan lot sesuai aturan broker                                 |
//+------------------------------------------------------------------+
double NormalizeLot(const double lot)
  {
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = vmin;
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
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double tp     = (type == POSITION_TYPE_BUY) ? openPrice + InpTakeProfit : openPrice - InpTakeProfit;
   tp = NormalizeDouble(tp, digits);

   //--- Jika harga sudah melewati level TP, tutup langsung (untung) daripada memasang TP yang ditolak
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
//| Buka satu posisi grid dengan semua pengecekan                     |
//+------------------------------------------------------------------+
bool OpenPosition(const ENUM_ORDER_TYPE type, const MqlTick &tick)
  {
   int    digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   bool   isBuy      = (type == ORDER_TYPE_BUY);

   double price = isBuy ? tick.ask : tick.bid;
   double tp    = isBuy ? price + InpTakeProfit : price - InpTakeProfit;
   tp = NormalizeDouble(tp, digits);

   //--- TP harus lebih jauh dari stops level broker
   double tpDistance = isBuy ? (tp - tick.bid) : (tick.ask - tp);
   if(tpDistance <= stopsLevel * point)
     {
      PrintFormat("TP terlalu dekat (jarak %.2f, stops level %.2f). Perbesar InpTakeProfit.",
                  tpDistance, stopsLevel * point);
      g_nextTryTime = TimeCurrent() + 60;
      return false;
     }

   //--- Cek margin
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, g_lot, price, margin))
     {
      Print("OrderCalcMargin gagal, error ", GetLastError());
      g_nextTryTime = TimeCurrent() + 15;
      return false;
     }
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > 0.0 && margin >= freeMargin)
     {
      g_nextTryTime = TimeCurrent() + 30;
      return false;
     }
   double marginAfter = usedMargin + margin;
   if(marginAfter > 0.0 && (equity / marginAfter) * 100.0 < InpMinMarginLevel)
     {
      g_nextTryTime = TimeCurrent() + 30;
      return false;
     }

   //--- Kirim order
   bool sent = isBuy ? g_trade.Buy(g_lot, _Symbol, price, 0.0, tp, "grid")
                     : g_trade.Sell(g_lot, _Symbol, price, 0.0, tp, "grid");
   uint rc = g_trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("Order %s gagal: retcode %u (%s)", isBuy ? "BUY" : "SELL", rc,
                  g_trade.ResultRetcodeDescription());
      g_nextTryTime = TimeCurrent() + 15;
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Inisialisasi                                                      |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpLot <= 0.0 || InpGridStep <= 0.0 || InpTakeProfit <= 0.0 || InpMaxLevelsPerSide < 1 ||
      InpMaxDrawdownPct <= 0.0 || InpMaxDrawdownPct >= 100.0 || InpBasketProfitPct < 0.0 ||
      InpMinMarginLevel < 0.0 || InpMaxSpread <= 0.0)
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
   if(InpResetHalt)
      GlobalVariableDel(g_haltVar);
   g_halted = GlobalVariableCheck(g_haltVar) && GlobalVariableGet(g_haltVar) > 0.0;
   if(g_halted)
      Comment("GridXAUUSD BERHENTI (stop drawdown sebelumnya).\nPasang ulang EA dengan InpResetHalt = true untuk melanjutkan.");

   PrintFormat("GridXAUUSD aktif: %s, lot %.2f, step %.2f, TP %.2f, maks %d level/arah, stop DD %.1f%%",
               _Symbol, g_lot, InpGridStep, InpTakeProfit, InpMaxLevelsPerSide, InpMaxDrawdownPct);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Deinisialisasi                                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
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

   //--- Kumpulkan posisi milik EA ini
   int    buyCount = 0, sellCount = 0;
   double lowestBuy = DBL_MAX, highestSell = -DBL_MAX;
   double floating = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;

      long   type      = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double tp        = PositionGetDouble(POSITION_TP);
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(type == POSITION_TYPE_BUY)
        {
         buyCount++;
         if(openPrice < lowestBuy)
            lowestBuy = openPrice;
        }
      else
         if(type == POSITION_TYPE_SELL)
           {
            sellCount++;
            if(openPrice > highestSell)
               highestSell = openPrice;
           }

      EnsureTakeProfit(ticket, type, openPrice, tp);
     }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   //--- Pengaman 1: stop drawdown
   if(balance > 0.0 && floating <= -balance * InpMaxDrawdownPct / 100.0)
     {
      bool closed = CloseAll(StringFormat("rugi mengambang %.2f mencapai batas %.1f%% balance", floating, InpMaxDrawdownPct));
      if(InpHaltAfterStop && closed)
         Halt("stop drawdown tercapai");
      return;
     }

   //--- Pengaman 2: ambil untung keranjang (opsional)
   if(InpBasketProfitPct > 0.0 && balance > 0.0 && floating >= balance * InpBasketProfitPct / 100.0)
     {
      CloseAll(StringFormat("untung mengambang %.2f mencapai target %.1f%% balance", floating, InpBasketProfitPct));
      return;
     }

   Comment(StringFormat("GridXAUUSD | Buy: %d  Sell: %d  (maks %d/arah)\nMengambang: %.2f | Batas rugi: -%.2f\nSpread: %.2f (maks %.2f)",
                        buyCount, sellCount, InpMaxLevelsPerSide, floating,
                        balance * InpMaxDrawdownPct / 100.0, tick.ask - tick.bid, InpMaxSpread));

   //--- Syarat untuk membuka posisi baru
   if(TimeCurrent() < g_nextTryTime)
      return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return;
   if(tick.ask - tick.bid > InpMaxSpread)
      return;

   //--- Grid buy: buka pertama kali, atau saat harga turun satu step di bawah buy terendah
   if(InpMode != GRID_SELL_ONLY && buyCount < InpMaxLevelsPerSide)
     {
      if(buyCount == 0 || tick.ask <= lowestBuy - InpGridStep)
        {
         OpenPosition(ORDER_TYPE_BUY, tick);
         return; // satu order per tick, data dihitung ulang di tick berikutnya
        }
     }

   //--- Grid sell: buka pertama kali, atau saat harga naik satu step di atas sell tertinggi
   if(InpMode != GRID_BUY_ONLY && sellCount < InpMaxLevelsPerSide)
     {
      if(sellCount == 0 || tick.bid >= highestSell + InpGridStep)
        {
         OpenPosition(ORDER_TYPE_SELL, tick);
         return;
        }
     }
  }
//+------------------------------------------------------------------+
