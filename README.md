# EA — Gold (XAUUSD) Edge-First Development

พัฒนา EA สำหรับทองแบบ **edge-first**: พิสูจน์ก่อนว่าสัญญาณเข้ามี edge ทางสถิติจริง แล้วจึงประกอบเป็น EA เต็มรูปแบบ

| เฟส | งาน | สถานะ |
|---|---|---|
| 0 | ตั้งสมมติฐานสัญญาณ | Asian Range Breakout (ตัวแรก) |
| 1 | **EdgeTester** — EA สำหรับวัด edge | ✅ v1.10 คอมไพล์ผ่าน (รอทดสอบ) |
| 2 | สคริปต์วิเคราะห์ CSV + เทียบ random baseline | ยังไม่เริ่ม |
| 3 | ทดสอบความทนทาน (พารามิเตอร์ / รายปี / spread) | ยังไม่เริ่ม |
| 4 | เกณฑ์ผ่าน/ไม่ผ่าน | ยังไม่เริ่ม |
| 5 | ประกอบ EA จริง + walk-forward + demo | ยังไม่เริ่ม |

## โครงสร้าง

```
MQL5/Experts/EdgeTester/EdgeTester.mq5   EA ทดสอบ edge (เฟส 1)
compile.bat                              คอมไพล์จาก command line
```

## EdgeTester ทำอะไร

EA ตัวนี้ **ไม่ได้มีไว้ทำกำไร** แต่มีไว้วัดว่าสัญญาณเข้ามีพลังทำนายหรือไม่

- **Signal mode**
  - `SIGNAL_REAL` — สัญญาณจริง: Asian Range Breakout
  - `SIGNAL_RANDOM_DIRECTION` — เข้า *เวลาเดียวกับสัญญาณจริง* แต่สุ่มทิศ → ทดสอบว่าการเลือกทิศมี edge ไหม
  - `SIGNAL_RANDOM_TIME` — เฉพาะวันที่กรอบเอเชียผ่านตัวกรอง (วันเดียวกับที่สัญญาณจริงพิจารณา) สุ่ม 1 แท่งแบบ uniform ในช่วงเทรด + สุ่มทิศ → ทดสอบว่า *จังหวะเวลา* ของ breakout มี edge ไหม
- **Exit mode**
  - `EXIT_ATR_SYMMETRIC` — SL = TP = k×ATR (1:1) → win rate อ่านได้ตรงๆ (> 50% = มี edge)
  - `EXIT_FIXED_BARS` — ปิดหลัง N แท่ง ไม่มี SL/TP → ดูผลเฉลี่ยหน่วย ATR
- ล็อตคงที่, เทรดไม่เกินวันละ 1 ไม้, ข้ามเมื่อ spread กว้างเกินกำหนด
- บันทึกทุกเทรดลง CSV (หน่วย R / ATR, MFE, MAE, spread ตอนเข้า)
- `OnTester()` คืนค่า **avgR** (ผลเฉลี่ยต่อเทรดหน่วย R) เป็น custom criterion — คืน 0 ถ้าเทรดน้อยกว่า `InpMinTradesForScore` (ตัด seed เหล่านี้ออกก่อนคิด percentile)

### Asian Range Breakout (กฎ)

1. หา High/Low ของช่วงเอเชีย (`InpAsiaStartHour`–`InpAsiaEndHour`)
2. ข้ามวันที่กรอบแคบหรือกว้างผิดปกติ (`InpMinRangeAtr`–`InpMaxRangeAtr` × ATR)
3. ในช่วงเทรด (`InpTradeStartHour`–`InpTradeEndHour`) ถ้าแท่งปิดเหนือ High + buffer → Buy, ต่ำกว่า Low − buffer → Sell

> ⚠️ **ชั่วโมงทั้งหมดเป็นเวลา Server ของโบรกเกอร์** ไม่ใช่เวลาไทย
> โบรกส่วนใหญ่ใช้ GMT+2 (ฤดูหนาว) / GMT+3 (ฤดูร้อน) ค่า default (เอเชีย 01–09, เทรด 09–13) ตั้งไว้สำหรับแบบนี้ — ลอนดอนเปิดราว 09:00–10:00 server ถ้าโบรกของคุณต่างออกไปให้ปรับ

## วิธีใช้

1. คัดลอก `MQL5/Experts/EdgeTester/` ไปไว้ที่ `<MT5 Data Folder>/MQL5/Experts/`
   (เปิดได้จาก MT5: File → Open Data Folder)
2. เปิดใน MetaEditor แล้วกด Compile (F7)
   หรือรัน `compile.bat` จากโฟลเดอร์ repo (หา MetaEditor + Data Folder ให้เอง, override ได้ด้วย env `METAEDITOR` / `MQL5_INCLUDE`)
3. Strategy Tester: Symbol `XAUUSD`, Timeframe **M15**, Modelling **Every tick based on real ticks**

### ขั้นตอนทดสอบ edge

| รอบ | ตั้งค่า | ดูอะไร |
|---|---|---|
| A. สัญญาณจริง | `SIGNAL_REAL` + `EXIT_ATR_SYMMETRIC` | win rate, avgR, t, zWin ใน Journal |
| B. Baseline ทิศสุ่ม | `SIGNAL_RANDOM_DIRECTION`, Optimize `InpRandomSeed` = 1→200, criterion = **Custom max** | การกระจายของ avgR จาก 200 seed |
| C. Baseline สุ่มล้วน | `SIGNAL_RANDOM_TIME` เหมือนรอบ B | เทียบเพิ่มเติม |

**อ่านผล:** avgR ของรอบ A ควรสูงกว่า percentile ที่ 95 ของรอบ B ถ้าไม่ถึง แปลว่ายังแยกไม่ออกจากการสุ่ม

ไฟล์ CSV อยู่ที่ `Terminal/Common/Files/` (MT5: File → Open Data Folder → ย้อนขึ้นไปที่โฟลเดอร์ `Common`)
ชื่อไฟล์: `EdgeTester_<symbol>_<signal>_<exit>_seed<N>.csv`

> ตอน optimize ให้เปลี่ยนเฉพาะ `InpRandomSeed` เพราะชื่อไฟล์แยกกันด้วย seed เท่านั้น

---

*เครื่องมือนี้ใช้เพื่อการทดสอบเชิงสถิติ ไม่ใช่คำแนะนำการลงทุน ผล backtest ไม่รับประกันผลในอนาคต*
