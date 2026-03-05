# 🔗 Rank Math — Bulk Connect Account

> Bash script สำหรับ **เชื่อมต่อ Rank Math SEO Plugin** กับ rankmath.com account แบบ Bulk บนเซิร์ฟเวอร์ที่มีหลาย WordPress พร้อมกัน

---

## 📋 สิ่งที่ Script ทำ

```
1. ค้นหา WordPress ทุกเว็บบนเซิร์ฟเวอร์ (WHM / cPanel)
2. ตรวจว่า Rank Math Plugin ติดตั้งและ active อยู่หรือไม่
3. ตรวจสถานะการเชื่อมต่อ rankmath.com account
4. ถ้ายังไม่เชื่อมต่อ → Activate ผ่าน License Key
5. บันทึก log แยกตาม status ทุกเว็บ
```

---

## ⚙️ Requirements

| รายการ | รายละเอียด |
|--------|-----------|
| OS | Linux (CentOS / Ubuntu / AlmaLinux) |
| Server | cPanel / WHM |
| [WP-CLI](https://wp-cli.org) | ต้องติดตั้งก่อนใช้งาน |
| Rank Math Plugin | ต้องติดตั้งและ active ในแต่ละเว็บ |
| Rank Math License Key | สำหรับ Pro Plan (Free ไม่ต้องใช้) |

---

## 🚀 วิธีใช้งาน

### 1. Download Script

```bash
wget https://raw.githubusercontent.com/ufavision/rankmath/refs/heads/main/connect-account.sh
chmod +x connect-account.sh
```

### 2. ตั้งค่า License Key (เฉพาะ Pro Plan)

แก้ไขบรรทัดนี้ใน script:

```bash
RM_LICENSE_KEY="your-license-key-here"
```

> ถ้าใช้ **Rank Math Free** ให้เว้นว่างไว้ได้เลย

### 3. รัน Script

```bash
./connect-account.sh
```

---

## 🔧 ค่า Config ที่ปรับได้

```bash
MAX_JOBS=5       # จำนวน parallel jobs (แนะนำ 5)
WP_TIMEOUT=30    # timeout ต่อเว็บ (วินาที)
MAX_RETRY=3      # retry สูงสุดต่อเว็บ
RETRY_DELAY=5    # รอ (วินาที) ก่อน retry
RM_LICENSE_KEY="" # Rank Math Pro License Key
```

---

## 📊 สถานะผลลัพธ์

| Status | ความหมาย |
|--------|---------|
| ✅ `PASS` | Connect สำเร็จ บันทึกลง DB แล้ว |
| ✔️ `ALREADY` | เชื่อมต่ออยู่แล้ว ไม่ต้องทำซ้ำ |
| ❌ `FAIL` | API error หรือ timeout |
| 🔑 `NOKEY` | ไม่มี License Key ต้องตั้งค่าก่อน |
| ⏭ `NOPLUGIN` | Rank Math ไม่ได้ติดตั้งหรือไม่ active |

---

## 📁 Log Files

หลังรันสำเร็จ จะสร้าง log ไว้ที่:

```
/var/log/rankmath-connect.log         ← log รวมทุก event
/var/log/rankmath-connect-pass.log    ← เว็บที่ connect สำเร็จ
/var/log/rankmath-connect-already.log ← เว็บที่เชื่อมต่ออยู่แล้ว
/var/log/rankmath-connect-fail.log    ← เว็บที่ connect ล้มเหลว
/var/log/rankmath-connect-nokey.log   ← เว็บที่ไม่มี License Key
/var/log/rankmath-connect-noplugin.log← เว็บที่ไม่มี Rank Math
```

ดู log แบบ realtime:
```bash
tail -f /var/log/rankmath-connect.log
```

---

## 🖥️ ตัวอย่าง Output

```
======================================
 BULK RANK MATH CONNECT ACCOUNT
 เริ่มเวลา   : 2025-03-05 10:00:00
 Jobs        : 5 | Retry: 3x | RetryDelay: 5s
======================================
พบ WordPress : 42 เว็บ
======================================
✔️  ALREADY: [1/42] example.com | email=admin@example.com | plan=pro
✅ PASS:    [2/42] mysite.co.th | email=me@mysite.co.th | plan=free | attempt=1/3
⏭  SKIP:   [3/42] newsite.com  | Rank Math ไม่ได้ติดตั้ง
❌ FAIL:    [4/42] broken.com   | attempt=3/3 | error=http:500
======================================
 สรุปผลรวม
 รวมทั้งหมด              : 42 เว็บ
 ✅ Pass (connected ใหม่) : 35 เว็บ
 ✔️  Already connected    : 4 เว็บ
 ❌ Fail                  : 1 เว็บ
 🔑 No License Key        : 0 เว็บ
 ⏭  No Plugin             : 2 เว็บ
 เวลาที่ใช้               : 1 นาที 23 วินาที
======================================
```

---

## 🔍 วิธีค้นหา WordPress บนเซิร์ฟเวอร์

Script ค้นหาจาก 2 แหล่ง:

1. **WHM** — อ่านจาก `/etc/trueuserdomains` แล้ว scan หา `wp-config.php`
2. **Directory Scan** — ค้นใน `/home`, `/home2`, `/home3`, `/home4`, `/home5`, `/usr/home`

---

## ⚠️ หมายเหตุสำคัญ

- ต้องรันด้วยสิทธิ์ **root** หรือ user ที่มีสิทธิ์อ่าน `/home/*`
- Script ใช้ **WP-CLI** ในการ eval PHP โดยตรง ไม่ได้ login ผ่าน Browser
- Rank Math Free Plan ไม่ต้องการ License Key — script จะรายงาน `NOKEY` แต่ไม่ถือเป็น error
- Log จะถูก **ล้างทุกครั้ง** ที่รัน script ใหม่ เก็บเฉพาะ run ล่าสุด

---

## 📂 ไฟล์ในProject

```
rankmath/
├── connect-account.sh   ← script หลัก
└── README.md            ← เอกสารนี้
```

---

## 🔗 Related

- [Rank Math Official](https://rankmath.com)
- [WP-CLI Installation](https://wp-cli.org/#installing)
- [Rank Math License Dashboard](https://rankmath.com/dashboard/)
