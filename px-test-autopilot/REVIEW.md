# Review: px-test-autopilot.sh

## สรุปภาพรวม
สคริปต์ทำหน้าที่เป็น Dashboard monitor สำหรับ Portworx PVC, Autopilot rules และ Load generator ใช้งานได้ดี มีจุดที่ควรแก้เพื่อความแข็งแรงและเพิ่ม "Log ระดับ ARO" ตามที่ต้องการ

---

## จุดที่ควรแก้ (Bugs / Robustness)

### 1. **Input validation**
- **select_target**: ถ้า user กด Enter ว่าง หรือใส่ตัวเลขนอกช่วง (เช่น 99) จะได้ `pod_list[-1]` หรือ empty → ควรเช็ค `pod_choice` ว่าเป็นตัวเลขและอยู่ในช่วง `1..${#pod_list[@]}`
- **select_rules**: ถ้าใส่ "1 5" แต่มีแค่ 3 rules จะได้ element ว่างใน `SELECTED_RULES` → ควรกรองเฉพาะ index ที่ถูกต้อง
- **gen_load**: `LOAD_GB` ไม่มีการตรวจว่าเป็นตัวเลขหรือ > 0 → อาจทำให้ dd ผิดพลาด

### 2. **REPLICA_IPS ไม่ได้อัปเดตใน loop**
- `REPLICA_IPS` ถูกตั้งค่าแค่ใน `select_target` แต่ใน loop มีการ refresh `INSPECT_DATA` (ทุก 5 iterations) เพื่อ track replica/pool หลัง resize
- ถ้า volume ถูก resize/rebalance โหนด replica อาจเปลี่ยน แต่ [4. PX CLUSTER SUMMARY] ยังแสดง (REPLICA) ตามค่าเก่า → ควรคำนวณ `REPLICA_IPS` ใหม่ทุกครั้งที่ refresh `INSPECT_DATA`

### 3. **Temp files อาจชนกัน**
- ใช้ `/tmp/px_*` ถ้ามีหลายคนรันหรือรันหลาย instance จะเขียนทับกัน → ใช้ prefix แบบมี PID เช่น `/tmp/px_monitor_$$` และลบเฉพาะของตัวเอง

### 4. **Cleanup ตอน exit**
- ตอนนี้ trap แค่ `INT TERM` ถ้า exit ปกติ (กด q) ก็มีการ `rm -f /tmp/px_*` อยู่แล้ว แต่ถ้าเพิ่ม tmp prefix แบบมี PID ควร trap `EXIT` ด้วยเพื่อให้ลบไฟล์ของ process นี้เสมอ

### 5. **การ parse "Replica sets on nodes"**
- ใช้ `read next_line` หลายครั้งใน while ที่รับ input จาก pipe — ถ้ารูปแบบ output ของ `pxctl volume inspect` เปลี่ยน (เช่นมีบรรทัดเพิ่ม) ตำแหน่งจะเพี้ยน → พิจารณา parse ด้วย awk/sed แบบยืดหยุ่นขึ้นหรือ comment ระบุ format ที่รองรับ

---

## Enhancements ที่แนะนำ

### 1. **เพิ่ม [6] Autopilot Operator Log (ระดับ ARO)**
- ตอนนี้มีแค่ Events จาก `oc describe autopilotrule` (transition from ...)
- เพื่อ "เช็ค Log ระดับ ARO" ควรดึง log จริงจาก Autopilot controller/operator ใน namespace Portworx เช่น  
  `oc logs -n $PX_NS deployment/portworx-autopilot --tail=15`  
  หรือหา pod ที่มี label เกี่ยวกับ autopilot แล้ว tail log
- แสดงเป็น section [6] ใน Dashboard จะได้เห็นการ evaluate rule, resize, error จากฝั่ง operator ชัดเจน

### 2. **FS usage threshold ให้กำหนดได้**
- ตอนนี้ hardcode 50% สำหรับ RED_BLINK → ใช้ env เช่น `PX_FS_WARN_PCT=50` (default 50) จะยืดหยุ่นกว่า

### 3. **PX namespace discovery**
- สคริปต์อื่นในโปรเจกต์ (px-health-check, px-house-keeping, px-snapshot) มีการหา PX namespace แบบ fallback (portworx-tls2, portworx-cwdc, portworx, kube-system)
- ถ้าต้องการให้ใช้กับหลาย env ได้โดยไม่แก้โค้ด ให้ใช้ discovery แบบเดียวกัน แล้วค่อย override ด้วย env `PX_NS` ได้

### 4. **ปิด blink (optional)**
- `tput blink` บาง terminal ไม่รองรับ หรือทำให้อ่านยาก → ใช้แค่สีแดงเข้ม + bold แทน blink ได้ หรือให้ env `PX_NO_BLINK=1` เพื่อปิด

### 5. **แสดงข้อความเมื่อไม่มี AutopilotRule**
- ถ้า `rule_list` ว่าง ให้แจ้งใน Step 1 และไม่ต้องให้เลือก (หรือให้ข้าม step rules ได้)

---

## สิ่งที่ทำได้ดีอยู่แล้ว
- โครงสร้าง section [1]–[5] ชัดเจน อ่านง่าย
- ใช้สีและ tput เหมาะสม
- มี hotkey [t][r][l][c][q] ใช้งานสะดวก
- ดึงทั้ง PVC, FS, Autopilot events, pxctl inspect และ cluster status ครบ

---

## สรุปการปรับที่ทำในสคริปต์
1. เพิ่ม validation สำหรับ pod choice, rule choices และ LOAD_GB  
2. อัปเดต REPLICA_IPS ใน loop เมื่อ refresh INSPECT_DATA  
3. ใช้ tmp prefix แบบมี PID และ trap EXIT สำหรับ cleanup  
4. เพิ่ม section [6] Autopilot operator log (ดึงจาก deployment/pod ที่เกี่ยวข้องใน PX_NS)  
5. ใช้ env `PX_FS_WARN_PCT` (default 50) และ `PX_NO_BLINK` (optional)  
6. (Optional) PX_NS discovery แบบ fallback + override ด้วย env  

ถ้าต้องการให้โฟกัสเฉพาะ "Log ระดับ ARO" เพิ่มอย่างเดียว ก็สามารถเพิ่มแค่ [6] และเก็บส่วนอื่นไว้ก่อนได้
