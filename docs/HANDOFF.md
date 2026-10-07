# Handoff — Gold EA (edge-first)

อัปเดต: 2026-10-07 · branch: `feature/edge-tester` · ผู้เขียนต่อ: Claude Code บนเครื่องที่มี MT5

## เป้าหมายของโปรเจกต์

สร้าง EA เทรดทอง (XAUUSD) บน MetaTrader 5 แบบ **edge-first**:
พิสูจน์ก่อนว่าสัญญาณเข้ามี edge ทางสถิติ (เทียบกับการเข้าแบบสุ่ม) แล้วจึงประกอบเป็น EA เต็มรูปแบบ
แผน 6 เฟสอยู่ใน `README.md`

## การตัดสินใจที่ทำไปแล้ว

- แพลตฟอร์ม: **MT5 / MQL5**
- สัญญาณตัวแรก: **Asian Range Breakout** (ทะลุกรอบเอเชียช่วงลอนดอนเปิด)
- สัญญาณถัดไปที่วางไว้: Trend Pullback (EMA200 กรองเทรนด์ + ย่อแตะ EMA20/RSI), Donchian 20 วัน เป็น baseline
- เครื่องมือวัด edge: EA แยกชื่อ **EdgeTester** — ล็อตคงที่, exit สมมาตร, log CSV หน่วย R/ATR, เทียบกับ random baseline โดย optimize seed
- งานอยู่บน branch แยก ยังไม่ merge เข้า `main` จนกว่าผู้ใช้ตรวจ

## สถานะปัจจุบัน

| รายการ | สถานะ |
|---|---|
| `MQL5/Experts/EdgeTester/EdgeTester.mq5` v1.00 | **คอมไพล์ผ่าน 0 error / 0 warning** (2026-10-07) |
| `compile.bat` | เสร็จ — คอมไพล์จาก command line |
| `README.md` (ภาษาไทย) | เสร็จ |
| ทดสอบใน Strategy Tester | ยังไม่ได้ทำ |
| เฟส 2 สคริปต์วิเคราะห์ CSV | ยังไม่เริ่ม |

คอมไพล์ครั้งแรกได้ 0 error, warning เดียวคือ `#property version "0.10"` (MQL5 Market ต้องการ major ≥ 1) → เปลี่ยนเป็น `"1.00"`
โค้ดยังไม่ได้แก้ logic ใดๆ จากที่เขียนใน cloud session

## งานถัดไป (ตามลำดับ)

1. ~~คอมไพล์และแก้ error~~ ✅ — คอมไพล์ซ้ำด้วย `compile.bat [file.mq5]`
   - ใช้ `/include:<MT5 Data Folder>\MQL5` จึงไม่ต้องย้ายไฟล์ไปไว้ใน Data Folder
   - log เขียนเป็น `<ชื่อไฟล์>.compile.log` (UTF-16) ข้างไฟล์ต้นทาง; `.ex5` / `*.log` อยู่ใน `.gitignore`
2. **ให้ผู้ใช้ตรวจโครงสร้าง EdgeTester** (กฎสัญญาณ, โหมด, input) ก่อนทำส่วนอื่น
3. รันทดสอบตามตารางรอบ A/B/C ใน `README.md` (M15, Every tick based on real ticks)
4. เฟส 2: สคริปต์ Python อ่าน CSV จาก `Terminal/Common/Files/` → win rate + binomial test, expectancy (R), MFE/MAE, percentile ของสัญญาณจริงเทียบการกระจายจาก random seeds
5. เพิ่มสัญญาณ Trend Pullback / Donchian ใน signal module

## จุดที่ควรตรวจในโค้ด (ยังไม่ได้ยืนยันจากการรันจริง)

- **เวลา server**: ทุกชั่วโมงเป็นเวลา server ของโบรก ค่า default สมมติ GMT+2/+3 ต้องยืนยันกับโบรกของผู้ใช้
- `BuildRange()` ใช้ `CopyRates(start, asiaEnd-1)` บน timeframe ของชาร์ต — ตรวจว่าได้แท่งครบช่วงเอเชีย โดยเฉพาะวันจันทร์ (ตลาดเพิ่งเปิด กรอบอาจไม่ครบ)
- `dayKey = now - now % 86400` อิงเวลา server — ถ้ากรอบเอเชียข้ามเที่ยงคืน (`start >= end`) ต้องทดสอบเคสนี้
- `SIGNAL_RANDOM_TIME` เรียก `MathRand()` ทุกแท่งในช่วงเทรด — ลำดับสุ่มจึงผูกกับจำนวนแท่ง (ยอมรับได้ แต่รู้ไว้)
- การหา position หลังส่งออเดอร์ใช้ `ResultDeal()` → `DEAL_POSITION_ID` แล้ว fallback ด้วย magic+symbol — ตรวจทั้งบัญชี hedging และ netting
- การปิดตามเวลาใช้ `PositionClose()` → บันทึก exit_reason เป็น `TIME` (มาจาก `DEAL_REASON_EXPERT`)
- `OnTester()` คืน avgR และคืน 0 ถ้าเทรดน้อยกว่า `InpMinTradesForScore` (30)

## สไตล์การทำงานของผู้ใช้

- ทำทีละส่วน: ส่งส่วนแรกเป็นแม่แบบให้ตรวจ แล้วรออนุมัติก่อนทำต่อ
- สื่อสารภาษาไทย
- ไม่ใช่คำแนะนำการลงทุน — ผลทดสอบเป็นข้อมูลเชิงสถิติเท่านั้น
