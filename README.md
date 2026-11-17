# Griddy

# GridXAUUSD v2.10 — Grid EA untuk MetaTrader 5

Expert Advisor grid untuk XAUUSD yang membaca **struktur pasar** (swing, BOS/CHoCH),
langkah & take profit adaptif ATR, lot dari risiko grid penuh memakai nilai tick broker,
grid stop (SL bersama per arah), filter berita kalender MT5, serta circuit breaker
berbasis high-water mark equity.

> ⚠️ **Peringatan risiko.** Grid trading tidak menjamin profit. Saat emas bergerak satu
> arah dalam jangka panjang, posisi yang melawan tren menumpuk dan bisa memicu stop
> drawdown. Selalu uji dulu di Strategy Tester dan akun demo.

## Yang berubah di v2.10

- **Perbaikan bug BOS/CHoCH:** v2.00 membandingkan pivot terbaru dengan close bar *tertua*
  di jendela data (`g_clBuf[0]`), bukan bar tertutup terakhir. Sekarang memakai bar tertutup
  terakhir, jadi sinyal BOS/CHoCH dan entry BOS benar-benar mengikuti harga terkini.
- **Lot dari risiko grid penuh:** `InpRiskPercent` sekarang berarti rugi maksimum bila
  *seluruh* grid satu arah terisi lalu harga mencapai grid stop, bukan risiko per posisi.
  Bila lot hasil hitungan di bawah lot minimum broker, EA memakai lot minimum dan mencetak
  risiko sebenarnya di tab Experts.
- **Grid stop (`InpUseGridStop`):** posisi pertama tiap arah menetapkan SL bersama sejauh
  `n × step` dari entry (n = level maksimum). Semua level berikutnya memakai SL yang sama,
  jadi rugi satu siklus grid terbatas. Posisi tanpa SL akan dipasangi SL ini; bila harga sudah
  lewat, posisi ditutup. Setelah grid stop kena, EA menunggu `InpCooldownAfterStopMin` menit.
- **HWM first-run:** saat pertama jalan (atau setelah reset), high-water mark = maks(balance,
  equity) dan langsung disimpan, jadi rugi mengambang yang sudah ada tetap dihitung sebagai
  drawdown. EA juga memperingatkan bila ada posisi lama milik EA, posisi lain di akun, atau
  akun sedang rugi mengambang.
- **Filter berita:** memakai kalender ekonomi bawaan MT5. Tidak membuka posisi baru
  `InpNewsMinutesBefore` menit sebelum s/d `InpNewsMinutesAfter` menit sesudah rilis berita
  high impact (opsional juga moderate) untuk `InpNewsCurrency`. Posisi yang sudah terbuka tidak
  ditutup.

## Yang berubah dari v1

- **Struktur pasar:** deteksi swing high/low, BOS (break of structure), dan CHoCH
  (change of character). Mode `GRID_STRUCTURE` hanya membuka grid searah bias pasar.
- **Step & TP adaptif:** langkah grid = ATR × `InpGridStepAtrMult`, TP = ATR ×
  `InpTakeProfitAtrMult`, dibatasi oleh min/max yang bisa diatur.
- **Lot berbasis risiko:** memakai `SYMBOL_TRADE_TICK_VALUE`/`TICK_SIZE` broker, jadi
  tidak lagi mengandaikan 1 ons per lot. EA juga mencetak contract size, tick value,
  dan tick size saat init.
- **Circuit breaker equity:** drawdown dari high-water mark equity (tersimpan di
  GlobalVariable) menutup semua posisi dan menghentikan EA.
- **Filter sesi:** opsional, pakai waktu server broker.
- **Penanganan error bertingkat:** backoff bertahap, halt setelah N kegagalan beruntun,
  halt khusus saat `TRADE_RETCODE_NO_MONEY`.
- **Mode lama dipertahankan:** `GRID_BOTH` berperilaku seperti v1.

## Cara kerja

1. **Struktur:** EA mencari pivot (swing high/low) dengan lookback `InpPivotLookback`.
   Dari pivot terakhir dan pivot sebelumnya, EA menilai apakah tren naik (higher high +
   higher low) atau turun (lower high + lower low). EMA 21/55 dipakai sebagai konfirmasi
   dan filter range.
2. **Bias:** `BULLISH` bila EMA fast > EMA slow dan struktur naik; `BEARISH` bila sebaliknya;
   `RANGE` bila EMA berhimpit (|selisih| < ATR × `InpRangeAtrFrac`) — dalam mode struktur,
   EA menunggu dan tidak membuka posisi.
3. **Entry:** posisi pertama hanya dibuka saat bias cocok dan harga berada di zona pullback
   EMA fast, atau saat ada BOS. Posisi berikutnya ditambah saat harga bergerak melawan sejauh
   satu step grid.
4. **Take profit:** setiap posisi punya TP sendiri. Bila TP gagal terpasang, EA memasang
   ulang; bila harga sudah melewati level TP, posisi langsung ditutup.
5. **Reset grid:** bila semua posisi satu arah tertutup, grid arah itu mulai lagi dari harga
   saat ini.

## Input

### Struktur pasar

| Input | Default | Fungsi |
|---|---|---|
| `InpPivotLookback` | 5 | Lookback pivot (swing) |
| `InpEMAFast` | 21 | EMA fast |
| `InpEMASlow` | 55 | EMA slow |
| `InpAtrPeriod` | 14 | Periode ATR |
| `InpRangeAtrFrac` | 0.30 | Range bila \|EMAfast−EMAslow\| < ATR×ini |

### Grid

| Input | Default | Fungsi |
|---|---|---|
| `InpMode` | `GRID_STRUCTURE` | `GRID_STRUCTURE` = searah struktur; `GRID_BOTH` = buy+sell |
| `InpLot` | 0.01 | Lot tetap (dipakai bila lot risiko mati) |
| `InpUseRiskLot` | true | Lot dihitung dari risiko grid penuh |
| `InpRiskPercent` | 1.0 | Rugi grid penuh satu arah sampai grid stop (% equity) |
| `InpUseGridStop` | true | SL bersama per arah, satu step setelah level terakhir |
| `InpGridStepAtrMult` | 1.0 | Step grid = ATR × ini |
| `InpGridStepMin` / `InpGridStepMax` | 1.0 / 25.0 | Batas step (harga) |
| `InpTakeProfitAtrMult` | 1.5 | TP = ATR × ini |
| `InpTakeProfitMin` | 2.0 | TP minimum (harga) |
| `InpMaxLevelsPerSide` | 5 | Maks. posisi per arah |
| `InpMaxTotalPositions` | 8 | Maks. total posisi EA |

### Risiko

| Input | Default | Fungsi |
|---|---|---|
| `InpMaxDrawdownPct` | 30.0 | Stop DD floating (% balance) |
| `InpMaxEquityDrawdownPct` | 40.0 | Circuit breaker equity dari high-water mark (%) |
| `InpBasketProfitPct` | 0.0 | Tutup semua bila untung ≥ % balance (0 = mati) |
| `InpMinMarginLevel` | 500.0 | Margin level minimum (%) setelah buka posisi |
| `InpMaxSpread` | 0.50 | Spread maksimum (harga) |
| `InpHaltAfterStop` | true | Berhenti total setelah stop |
| `InpResetHalt` | false | true sekali untuk lanjut setelah berhenti |
| `InpCooldownAfterStopMin` | 60 | Jeda (menit) sebelum grid baru setelah grid stop kena |

### Filter berita

| Input | Default | Fungsi |
|---|---|---|
| `InpUseNewsFilter` | true | Jangan buka posisi di sekitar rilis berita |
| `InpNewsCurrency` | USD | Mata uang berita yang dipantau |
| `InpNewsHighOnly` | true | true = high impact saja; false = juga moderate |
| `InpNewsMinutesBefore` | 30 | Menit sebelum rilis |
| `InpNewsMinutesAfter` | 30 | Menit sesudah rilis |

### Sesi & lain-lain

| Input | Default | Fungsi |
|---|---|---|
| `InpUseSession` | true | Hanya buka posisi pada sesi ini |
| `InpSessionStart` / `InpSessionEnd` | 07:00 / 21:00 | Sesi (waktu server broker, HH:MM) |
| `InpMagic` | 20261117 | Magic number |
| `InpSlippagePoints` | 30 | Slippage maksimum (points) |
| `InpAllowNonXau` | false | Izinkan simbol selain XAU |
| `InpMaxFailBeforeHalt` | 5 | Hentikan setelah N kegagalan order beruntun |

## Perhitungan lot berbasis risiko

```
n          = min(InpMaxLevelsPerSide, InpMaxTotalPositions)
jarakTotal = step × n(n+1)/2        // level k berjarak (n−k) step ke grid stop
rugiPerLot = jarakTotal / SYMBOL_TRADE_TICK_SIZE × SYMBOL_TRADE_TICK_VALUE
lot        = equity × InpRiskPercent / 100 / rugiPerLot
```

Contoh: step $3, n = 5 → jarak total $45. Di akun cent (≈ 1 USC per $1 untuk 0.01 lot),
rugi grid penuh dengan 0.01 lot ≈ 45 USC = 4,5% dari 1.000 USC. Dengan `InpRiskPercent = 1`
lot hasil hitungan jatuh di bawah 0.01, jadi EA memakai 0.01 dan mencetak risiko sebenarnya
(≈ 4,5%). Turunkan `InpMaxLevelsPerSide` bila angka itu terlalu besar.

Rumus ini mengandaikan grid stop aktif. Bila `InpUseGridStop = false`, angka ini hanya rugi
saat harga satu step melewati level terakhir; rugi bisa terus bertambah sampai stop DD.

## Pengaman bawaan

| Pengaman | Fungsi |
|---|---|
| Grid stop | SL bersama per arah; rugi satu siklus grid terbatas, lalu jeda `InpCooldownAfterStopMin` |
| Filter berita | Tidak buka posisi di sekitar rilis berita high impact (kalender MT5) |
| Circuit breaker equity | Drawdown dari high-water mark equity ≥ `InpMaxEquityDrawdownPct` → tutup semua + halt |
| Stop DD floating | Rugi mengambang ≥ `InpMaxDrawdownPct` dari balance → tutup semua + halt |
| Batas level & total posisi | Posisi tidak bisa bertambah tanpa batas |
| Cek margin | Posisi baru hanya bila margin level setelahnya ≥ `InpMinMarginLevel` |
| Filter spread | Tidak buka posisi saat spread melebar |
| Filter sesi | Tidak buka posisi di luar sesi |
| Filter struktur | Mode struktur hanya entry searah bias; range = menunggu |
| TP darurat | TP dipasang ulang bila gagal; ditutup langsung bila harga sudah lewat TP |
| Error backoff | Jeda bertahap setelah order gagal; halt setelah N kegagalan beruntun / no money |
| Cek akun & simbol | Menolak akun netting atau simbol selain XAU |

## Cara memasang

1. Di MT5, buka **File → Open Data Folder**, lalu masuk ke `MQL5/Experts/`.
2. Salin `GridXAUUSD.mq5` ke folder itu.
3. Buka file itu di **MetaEditor** (F4), lalu tekan **Compile** (F7). Target: `0 errors`.
4. Kembali ke MT5, buka chart **XAUUSD** (nama simbol bisa berbeda, mis. `XAUUSDc`).
5. Seret **GridXAUUSD** ke chart, cek inputnya, lalu aktifkan **Algo Trading**.

## Wajib diuji dulu

1. **Strategy Tester** (Ctrl+R): model *Every tick based on real ticks*, periode minimal
   6–12 bulan, deposit sesuai akun cent. Perhatikan *Max drawdown* dan seberapa sering
   stop/circuit breaker terpicu.
2. **Akun demo cent** selama 1–2 minggu sebelum memakai uang sungguhan.

## Melanjutkan setelah EA berhenti

Setelah stop terpicu, EA berhenti dan statusnya tersimpan di GlobalVariable walaupun MT5
di-restart. Untuk melanjutkan, pasang ulang EA dengan `InpResetHalt = true` (ini juga
mereset high-water mark), lalu kembalikan ke `false`.

## Catatan

- v2.00 sudah dikompile dengan MetaEditor (0 errors, 0 warnings). **v2.10 belum dikompile** —
  compile ulang di MetaEditor; kirim pesan error bila ada.
- Filter berita butuh kalender ekonomi MT5, yang **tidak tersedia di Strategy Tester**: saat
  backtest filter ini otomatis tidak aktif (EA mencetak pesan sekali). Jadi hasil backtest
  tidak mencerminkan efek filter berita.
- Upgrade dari v2.00 dengan posisi masih terbuka: posisi lama belum punya SL, dan v2.10 akan
  memasang grid stop pada posisi itu (atau menutupnya bila harga sudah melewati level stop).
  Paling aman upgrade saat tidak ada posisi terbuka.
- Saat init, EA mencetak `contract size`, `tick value`, `tick size`, dan `point` di tab
  Experts — periksa angka itu cocok dengan brokermu.
- Gunakan magic number berbeda bila menjalankan beberapa EA di akun yang sama.
- Stop DD floating hanya menghitung posisi milik EA ini (simbol + magic sama). Circuit
  breaker equity memakai equity **seluruh akun**, jadi posisi manual/EA lain ikut memengaruhinya.
- Komisi posisi tidak dimasukkan ke perhitungan rugi mengambang (swap sudah dimasukkan).
