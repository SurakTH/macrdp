# รายงานการตรวจสอบและแก้ไขความปลอดภัย

โครงการ: macrdp 0.9.6 working tree · อัปเดต: 2026-10-07

รายงานเดิมวันที่ 2026-08-25 เป็น static review เท่านั้น การอัปเดตนี้ตรวจโค้ด
และเพิ่ม regression tests โดยไม่ติดตั้ง driver, เปลี่ยน login Keychain หรือ
อ้างว่าทดสอบ client/session จริงแล้ว

## ข้อค้นพบและการแก้ไข

| ประเด็น | การแก้ไขใน working tree |
|---|---|
| Drive label `.` / `..` หลุดจาก mount root | sanitize ชื่อจุดล้วน, ตรวจ single normal path component, สร้าง fallback mountpoint ใหม่, ปฏิเสธ parent symlink/owner หรือ permissions ที่ไม่ปลอดภัย |
| Disconnect ระหว่าง mount | สถานะ cancellation และ lock ร่วมกัน ทำให้ cleanup รอ mount ที่กำลังทำอยู่ และ mount ที่สำเร็จหลัง cancellation ถูก unmount ก่อน publish; mount subprocess มี deadline |
| VideoToolbox failure ทำให้ slot ค้าง | ทุก picture ที่รับเข้า encoder มี success/drop outcome; คืน slot และขอ IDR โดย AVC444 คืนหนึ่ง slot ต่อคู่ และ deduplicate synchronous-drop/callback |
| Password อยู่ใน argv ของ GUI | เขียนผ่าน Security.framework และกำหนด ACL ให้ `/usr/bin/security` ที่ server ใช้อ่านแบบ headless; legacy installer รับ password ทาง stdin |
| Smart-card TCP IPC ไม่มี authentication | เปลี่ยนทั้ง server/IFD เป็น Unix socket, ตรวจ kernel peer UID, จำกัด 8 sessions, กำหนด idle/command/connect timeouts; installer pin server UID ในไฟล์ root-owned |
| Legacy log อยู่ใน `/tmp` ชื่อคงที่ | ย้ายไป `~/Library/Logs` และสร้าง plist ด้วย XML-aware serialization |

Smart-card server รับคำสั่งเฉพาะ root หรือบัญชีระบบ `_ctkd`; ordinary local
user processes ไม่สามารถเรียก APDU ผ่าน bridge ได้ Driver ตรวจ owner ของ
socket directory และ peer กับ UID ที่ installer บันทึกไว้ ต้องอัปเดต server
และ reinstall IFD driver พร้อมกัน ไม่มี fallback ไป TCP แบบเก่า

## ขอบเขตและข้อจำกัดที่ยังมีอยู่

- PAM ตรวจรหัสผ่านตอน startup; CredSSP ใช้ credential ที่ server เก็บไว้ภายหลัง
  การเปลี่ยนรหัสผ่าน macOS ต้องอัปเดต credential และ restart server
- `Zeroizing<String>` ล้างเฉพาะ allocation ที่มันเป็นเจ้าของ สำเนา credential
  แบบ `String` ใน IronRDP ยังไม่ได้รับประกันการล้าง ห้ามอ้างว่าล้างทุกสำเนาแล้ว
- TLS/CredSSP, IP allowlist, auth guard และ payload caps มีอยู่ แต่ unit tests
  ไม่ใช่หลักฐานว่าไม่มีช่องโหว่หรือ dependency advisory ใหม่
- Root และบัญชีเจ้าของ server ที่ถูกยึดควบคุมอยู่นอก local isolation guarantee
  Loopback IPC ของ NFS/HUD/shield ยังมี trust model เดิม ดู `macos-gotchas.md`
- Health watchdog ตรวจ runtime responsiveness ไม่ได้ยืนยันว่า client แสดงภาพ
  Video diagnostics ก็ไม่ใช่ presentation acknowledgement
- Native Keychain add/update และการอ่านผ่าน `/usr/bin/security` ผ่านการทดสอบ
  ด้วย disposable Keychain แล้ว (`scripts/test-keychain.sh`); onboarding กับ signed app
  และ smart-card migration ต้องทดสอบจริงกับ slotd/client ก่อน release
- ยังต้องทำ soak 48–72 ชั่วโมงบน build ที่รวมการแก้ไขเหล่านี้

## การตรวจสอบ

Regression coverage ครอบคลุม mount traversal/symlink/cancellation, encoder
callback failures, AVC420/AVC444 retirement และ Keychain add/update failure
โดยใช้ fake backend และ disposable Keychain ที่ไม่ใช้รหัสผ่านจริง รวมถึง kernel peer identity
และ Unix-socket path permissions การรันทดสอบต้องอยู่นอก sandbox สำหรับ
hardware encoding และ networking ของ macOS
