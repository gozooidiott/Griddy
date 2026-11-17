# Griddy

# GridXAUUSD: Grid EA untuk MetaTrader 5

Expert Advisor grid untuk XAUUSD, dirancang untuk **akun cent hedging** bermodal kecil
(misalnya 10 USD = 1.000 USC) dengan lot tetap **0.01**.

> ⚠️ **Peringatan risiko.** Grid trading tidak menjamin profit. Saat emas bergerak satu arah
> dalam jangka panjang, posisi yang melawan tren menumpuk dan bisa memicu stop drawdown,
> yaitu rugi yang benar-benar terealisasi. Selalu uji dulu di Strategy Tester dan akun demo.

## Cara kerja

- **Grid buy:** membuka buy pertama di harga pasar. Setiap kali harga turun sejauh `InpGridStep`
  di bawah buy terendah, EA membuka buy baru.
- **Grid sell:** kebalikannya. EA membuka sell baru setiap kali harga naik sejauh `InpGridStep`
  di atas sell tertinggi.
- Setiap posisi punya **take profit sendiri** sejauh `InpTakeProfit`. Saat semua posisi di satu arah
  sudah tertutup, grid arah itu dimulai lagi dari harga saat ini.
- Jumlah posisi per arah dibatasi oleh `InpMaxLevelsPerSide`.

## Pengaman bawaan

| Pengaman | Fungsi |
|---|---|
| Stop drawdown (`InpMaxDrawdownPct`) | Menutup **semua** posisi EA jika rugi mengambangnya mencapai X% dari balance, lalu EA berhenti (`InpHaltAfterStop`). |
| Batas level (`InpMaxLevelsPerSide`) | Jumlah posisi tidak bisa terus bertambah. |
| Cek margin (`InpMinMarginLevel`) | Posisi baru hanya dibuka jika margin level setelahnya tetap di atas batas. |
| Filter spread (`InpMaxSpread`) | Tidak membuka posisi saat spread melebar (misalnya saat rilis berita atau pasar baru buka). |
| Cek akun & simbol | Menolak berjalan di akun netting atau di simbol selain XAU. |
| TP darurat | Jika TP sebuah posisi gagal terpasang, EA memasangnya ulang. Jika harga sudah melewati level TP, posisi langsung ditutup. |
| Jeda saat error | Setelah order gagal, EA menunggu sebelum mencoba lagi supaya tidak membanjiri server broker dengan order. |

## Setelan default dan perhitungan risikonya (akun cent 1.000 USC)

Di akun cent, 0.01 lot XAUUSD bernilai sekitar **1 USC per pergerakan harga $1**.

| Input | Default |
|---|---|
| `InpLot` | 0.01 |
| `InpGridStep` | 5.0 ($5 per level) |
| `InpTakeProfit` | 5.0 |
| `InpMaxLevelsPerSide` | 5 |
| `InpMaxDrawdownPct` | 30 (= 300 USC dari 1.000 USC) |

Skenario terburuk untuk satu arah: kelima buy terbuka di P, P−5, P−10, P−15, dan P−20, lalu harga
terus turun. Stop drawdown 300 USC tercapai saat harga sekitar **$70 di bawah buy pertama**.
Di titik itu kerugiannya sekitar 300 USC (≈ $3), dan modal sisanya sekitar 700 USC (≈ $7).

Kalau EA dipakai di **akun standar** (bukan cent), semua angka kerugian di atas menjadi 100 kali lebih
besar. Modal $10 akan habis jauh sebelum grid sempat berjalan.

## Cara memasang

1. Di MT5, buka **File → Open Data Folder**, lalu masuk ke folder `MQL5/Experts/`.
2. Salin `GridXAUUSD.mq5` ke folder itu.
3. Buka file itu di **MetaEditor** (F4), lalu tekan **Compile** (F7). Pastikan hasilnya `0 errors`.
4. Kembali ke MT5 dan buka chart **XAUUSD** (nama simbolnya bisa berbeda, misalnya `XAUUSDc` di akun cent).
5. Seret **GridXAUUSD** ke chart, cek inputnya, lalu aktifkan tombol **Algo Trading**.

## Wajib diuji dulu

1. **Strategy Tester** (Ctrl+R): pilih model *Every tick based on real ticks*, periode minimal
   6–12 bulan, dan deposit 1.000 dengan mata uang akun cent. Perhatikan *Max drawdown* dan apakah
   stop drawdown pernah terpicu.
2. **Akun demo cent** selama 1–2 minggu sebelum memakai uang sungguhan.

## Melanjutkan setelah EA berhenti

Setelah stop drawdown terpicu, EA berhenti dan statusnya tetap tersimpan walaupun MT5 di-restart.
Untuk melanjutkan, pasang ulang EA dengan `InpResetHalt = true`, lalu kembalikan ke `false`.

## Catatan

- Kode ini belum di-compile di lingkungan pembuatnya karena MetaEditor tidak tersedia di sana.
  Compile di MetaEditor milikmu. Kalau muncul error, kirim pesan error-nya untuk diperbaiki.
- Gunakan magic number yang berbeda kalau kamu menjalankan beberapa EA di akun yang sama.
- Stop drawdown hanya menghitung posisi milik EA ini (simbol dan magic number yang sama).
