# รายงานผลการตรวจสอบความปลอดภัย (Security Review & Audit Report)

- **โครงการ:** macrdp
- **วิธีการตรวจสอบ:** Static Code Analysis / Read-Only Source Code Review (ไม่มีการรัน Script หรือคำสั่งใดๆ)
- **วันที่บันทึก:** 2026-08-25

---

## 1. บทสรุปผู้บริหาร (Executive Summary)

จากการตรวจสอบโครงสร้างและโค้ดของ **macrdp** โดยรวมมีความปลอดภัยในระดับ **ดีมาก (Strong Security Posture)** เมื่อเทียบกับมาตรฐาน RDP Server ทั่วไป โครงการมีการออกแบบและปฏิบัติตามแนวทางความปลอดภัยสำคัญ ได้แก่:
- การยืนยันตัวตนระดับ Network Level Authentication (NLA / CredSSP) และ PAM
- การป้องกันการโจมตีแบบ Brute-force และ Rate Limiting ต่อ Source IP
- การล้างหน่วยความจำรหัสผ่านหลังใช้งานทันท่วงที (`zeroize`)
- การกำหนดค่าเริ่มต้นให้ผูกกับ Localhost (`127.0.0.1:3390`) เพื่อความปลอดภัย
- การบังคับสิทธิ์ของไฟล์ TLS Private Key (`0600`)
- มีกระบวนการ CI/CD ที่เข้มงวดพร้อม Egress Network Firewall และ Daily Dependency Vulnerability Scanning

อย่างไรก็ตาม พบจุดสังเกตและประเด็นที่ควรปรับปรุงเพื่อเพิ่มความปลอดภัย (Hardening) จำนวน 4 จุด ดังนี้:

---

## 2. รายละเอียดข้อตรวจพบและคำแนะนำ (Findings & Recommendations)

### ⚠️ ข้อที่ 1: ความเสี่ยง Path Traversal ในการสร้างจุด Mount สำหรับ Drive Redirection
* **ระดับความรุนแรง:** ปานกลาง (Medium)
* **ไฟล์ที่เกี่ยวข้อง:** [`src/rdpdr/surface.rs`](../src/rdpdr/surface.rs#L814-L831)
* **ฟังก์ชัน:** `sanitize_label()` และ `prepare_mountpoint()`
* **รายละเอียด:**
  ฟังก์ชัน `sanitize_label` กรองเฉพาะอักขระ `/`, `\`, `:` และ control characters แต่ไม่ได้ป้องกันกรณีที่ Client ส่ง Label ที่มีค่าเป็น `.` หรือ `..`
  ```rust
  fn sanitize_label(label: &str) -> String {
      let trimmed = label.trim().trim_end_matches(':');
      let cleaned: String = trimmed
          .chars()
          .map(|c| {
              if c == '/' || c == '\\' || c == ':' || c.is_control() {
                  '_'
              } else {
                  c
              }
          })
          .collect();
      if cleaned.is_empty() {
          "drive".to_owned()
      } else {
          cleaned
      }
  }
  ```
  หาก Client ส่ง `drive_label` เป็น `".."`:
  1. `prepare_mountpoint` พยายามสร้าง `/Volumes/..` ซึ่งจะล้มเหลวเนื่องจากติดสิทธิ์ root
  2. โปรแกรมจะ fall back ไปยัง `$TMPDIR/macrdp-rdpdr-<pid>/..` ซึ่งจะชี้กลับมายังโฟลเดอร์ `$TMPDIR` โดยตรง
  3. คำสั่ง `mount_nfs` จะ Mount ไดรฟ์ของ Client ทับ `$TMPDIR` และเมื่อตัดการเชื่อมต่อ `unmount_at` อาจพยายาม unmount และลบไดเรกทอรีดังกล่าว
* **แนวทางแก้ไข:**
  เพิ่มการตรวจสอบใน `sanitize_label`: หาก `cleaned` เป็น `.` หรือ `..` หรือประกอบด้วยจุดล้วน ให้แทนที่ด้วยชื่อปลอดภัย เช่น `"drive"`

---

### ⚠️ ข้อที่ 2: ความเสี่ยง Symlink Attack จาก Log File ในโฟลเดอร์ `/tmp` (CWE-59)
* **ระดับความรุนแรง:** ต่ำ-ปานกลาง (Low-Medium)
* **ไฟล์ที่เกี่ยวข้อง:** [`dist/com.user.macrdp.plist.template`](../dist/com.user.macrdp.plist.template#L26-L28) และ [`dist/install.sh`](../dist/install.sh#L59)
* **รายละเอียด:**
  Template ของ LaunchAgent ในโฟลเดอร์ `dist/` กำหนดให้เขียน Log ลงใน `/tmp`:
  ```xml
  <key>StandardOutPath</key>
  <string>/tmp/macrdp.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/macrdp.err.log</string>
  ```
  บนระบบ macOS ที่มีผู้ใช้หลายคน (Multi-user system) โฟลเดอร์ `/tmp` สามารถเขียนได้โดยผู้ใช้ทุกคน ผู้ไม่หวังดีอาจสร้าง Symlink หลอกไว้ล่วงหน้าเพื่อเขียนทับไฟล์สำคัญ
* **แนวทางแก้ไข:**
  เปลี่ยนพาธบันทึก Log ให้เป็น `~/Library/Logs/macrdp.out.log` และ `~/Library/Logs/macrdp.err.log` (เช่นเดียวกับที่ไฟล์ `packaging/launchagent.plist.template` ใช้อยู่)

---

### ⚠️ ข้อที่ 3: การส่งรหัสผ่านผ่าน Command-Line Arguments สู่ `security` CLI
* **ระดับความรุนแรง:** ต่ำ (Low)
* **ไฟล์ที่เกี่ยวข้อง:** [`gui/Sources/macrdptray/main.swift`](../gui/Sources/macrdptray/main.swift#L322-L325) และ [`dist/install.sh`](../dist/install.sh#L40)
* **รายละเอียด:**
  การเก็บรหัสผ่านลงใน macOS Keychain มีการเรียกใช้คำสั่งภายนอก:
  ```swift
  run("/usr/bin/security", ["add-generic-password", "-U", "-s", "macrdp", "-a", NSUserName(), "-w", field.stringValue])
  ```
  บนระบบ Unix/macOS ข้อมูลอาร์กิวเมนต์ที่ส่งผ่าน command-line (`argv`) อาจปรากฏในตารางโปรเซส (`ps aux` หรือ `sysctl`) ชั่วขณะ ซึ่งโปรเซสอื่นของผู้ใช้คนเดียวกันสามารถอ่านได้
* **แนวทางแก้ไข:**
  ในแอปพลิเคชัน Swift ให้เปลี่ยนไปเรียกใช้งาน macOS Native Security Framework API (`SecItemAdd` / `SecKeychainAddGenericPassword`) โดยตรง แทนการ Spawn Subprocess `security` CLI

---

### ℹ️ ข้อที่ 4: การเชื่อมต่อ Loopback IPC สำหรับ Smart Card Redirection ไม่มีการยืนยันตัวตน
* **ระดับความรุนแรง:** ข้อมูลเตือนเชิงสถาปัตยกรรม (Informational)
* **ไฟล์ที่เกี่ยวข้อง:** [`src/rdpdr/smartcard.rs`](../src/rdpdr/smartcard.rs#L48-L53)
* **รายละเอียด:**
  ตัวบริดจ์ Smart Card เปิด TCP Listener ที่ `127.0.0.1:40242` เพื่อสื่อสารกับ `ifd-macrdp.bundle` โดยไม่มีการทำ Authentication บน Localhost ทำให้โปรเซสอื่นในเครื่องเดียวกันสามารถส่ง APDU ไปยัง Smart Card ของ Client ขณะเชื่อมต่อได้ (ทั้งนี้ มีการกำหนด `MAX_APDU_LEN = 65,544` เพื่อป้องกัน DoS/Buffer Overflow ไว้แล้ว)

---

## 3. สรุปจุดแข็งด้านความปลอดภัยที่ตรวจพบ (Key Security Strengths)

1. **การจัดการรหัสผ่านและ Authentication:**
   - ใช้ PAM (`checkpw` service) ยืนยันตัวตนกับ macOS account
   - ใช้ `zeroize::Zeroizing` ล้างหน่วยความจำรหัสผ่านทิ้งทันที
   - ปฏิเสธการรัน `--skip-auth` บน Non-loopback IP
2. **การป้องกัน Brute-Force และ DoS:**
   - มี `AuthGuardCore` ที่ทำ Sliding Window Rate Limiting และ Exponential Backoff Lockout
   - กำหนดขนาดตาราง IP ติดตามสูงสุด `50,000` รายการ เพื่อป้องกัน Memory Exhaustion
   - มี Audit Log Schema มาตรฐานสำหรับส่งเข้า SIEM
3. **การจัดการกุญแจและเข้ารหัส TLS:**
   - บังคับให้ไฟล์ Private Key มีสิทธิ์ไม่เกิน `0600`
   - ใช้ Rustls และ CSPRNG (`getrandom`) สร้าง Session Cookies
4. **การคัดลอกไฟล์ผ่าน Clipboard:**
   - มีฟังก์ชัน `resolve_dest` ใน `src/file_promise.rs` ที่ตรวจเช็คและปฏิเสธ Path Traversal (`..`, `.`, `/`) อย่างรัดกุม
5. **Supply Chain & CI/CD Hardening:**
   - มี Daily Scheduled Cargo Deny Scan สำหรับตรวจเช็คช่องโหว่ของ Dependencies
   - ใช้ Harden Runner พร้อม Egress Network Filtering ใน GitHub Actions
