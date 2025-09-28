# คู่มือการใช้งานสคริปต์ `haproxy-2-4-installer.sh`

```bash
git clone  https://github.com/textures1245/haproxy-apt-installer.git
```

## 1. สคริปต์นี้ทำอะไรบ้าง

สคริปต์นี้ช่วยติดตั้งและตั้งค่าระบบ HAProxy พร้อมระบบล็อก (rsyslog/logrotate) และ Metrics Addon สำหรับติดตาม session/domain แบบอัตโนมัติ เหมาะสำหรับการใช้งานใหม่หรือย้ายจาก Proxy เดิม เช่น NGINX

### รายละเอียดแต่ละขั้นตอน
- **ติดตั้งแพ็กเกจ:** ติดตั้ง HAProxy, Lua, rsyslog, curl, wget, luarocks, build-essential และ lua-cjson (สำหรับ Metrics)
- **ตั้งค่า logrotate:** สร้างไฟล์ `/etc/logrotate.d/haproxy` เพื่อหมุนเวียน log อัตโนมัติ
- **สร้างโฟลเดอร์ log:** สร้าง `/var/log/haproxy` และไฟล์ log ที่จำเป็น พร้อมกำหนดสิทธิ์ให้ rsyslog
- **ตั้งค่า rsyslog:** สร้างไฟล์ `/etc/rsyslog.d/49-haproxy.conf` เพื่อแยก log HAProxy ออกเป็น global log และ services_access log
- **สร้างโฟลเดอร์ config:** สร้างโฟลเดอร์ `/etc/haproxy/conf.d`, `/etc/haproxy/ssl`, `/etc/haproxy/errors`, `/etc/haproxy/metrics`
- **สร้าง SSL Self-signed:** ออกใบรับรอง SSL สำหรับทดสอบ (nginx-selfsigned.pem)
- **คัดลอก config:** เลือกคัดลอกไฟล์ config ตามโหมดที่เลือก (Fresh install/Migration, Enable Metrics Addon หรือไม่)
- **แก้ไขค่า CONFIG:** ปรับค่า CONFIG ใน `/etc/default/haproxy` ให้ใช้โฟลเดอร์ conf.d
- **ตรวจสอบและเติม newline:** ให้ทุกไฟล์ config ลงท้ายด้วย newline
- **Reload/Restart service:** โหลดค่าใหม่ให้ rsyslog/logrotate และตรวจสอบ config HAProxy

## 2. ส่วน Prompt/ถามผู้ใช้

### 2.1 Fresh Install หรือ Migration
- **Fresh Install (ตอบ y):**
  - ใช้พอร์ตมาตรฐาน (80/443)
  - เหมาะกับเครื่องใหม่ที่ยังไม่มี Proxy อื่น
- **Migration (ตอบ n):**
  - เปลี่ยนพอร์ต HTTP/HTTPS เป็น 4480/4443 เพื่อหลีกเลี่ยงชนกับ Proxy เดิม (เช่น NGINX)
  - เหมาะกับการย้ายจาก Proxy เดิม โดยยังไม่ต้องหยุด Proxy เดิมทันที

### 2.2 Enable User Session Monitoring (Metrics Addon)
- **ตอบ y:**
  - เปิดระบบ Metrics/Session Monitoring RESTAPI ไว้ใช้ในกรณที่ทีม Dev การดึงข้อมูล HAproxy Metrics
- **ตอบ n:**
  - ไม่เปิด REST API สำหรับดึง Metrics/Session

## 3. โครงสร้างไฟล์ config (conf.d) และแนวทางสร้าง domain ใหม่

- ทุกไฟล์ใน `/etc/haproxy/conf.d/` ควรขึ้นต้นด้วยเลข (เช่น 00-global-defaults.cfg, 10-backend-xxx.cfg, 20-fe-http-entrypoint.cfg) เพื่อควบคุมลำดับโหลด ในกรณี่ที่เพิ่ม Domain ควรใช้เป็นเลขหลักร้อย
- 1 domain = 1 backend block (แยกไฟล์ได้)
- ตัวอย่างไฟล์ใหม่:

```cfg
101-mynewdomain.com.cfg
--------------------------
backend mynewdomain.com
    mode http
    server srv1 10.0.0.1:8080 check
    # ... เพิ่มเติม ...
```

- เพิ่ม backend ใหม่ให้แก้ไขไฟล์ entrypoint (20-fe-http-entrypoint.cfg) เพื่อ map domain -> backend

## 4. หลังรันสคริปต์ควรทำอะไรต่อ

1. ตรวจสอบ/ปรับแต่งไฟล์ใน `/etc/haproxy/conf.d/*.cfg` ให้เหมาะสมกับแต่ละ domain/service
2. ในกรณีที่มี SSL cert (PEM) ใหม่ให้ไปไว้ที่ `/etc/haproxy/ssl/` แล้วไปแก้เพิ่มการใช้งาน PEM ที่ `/etc/haproxy/conf.d/20-fe-http-entrypoint.cfg`
3. ตรวจสอบ config HAProxy:
   ```
   haproxy -f /etc/haproxy/conf.d -c
   ```
4. เริ่ม/รีสตาร์ท HAProxy:
   ```
   systemctl restart haproxy
   ```
5. ทดสอบเข้าเว็บผ่านพอร์ตที่กำหนด (เช่น http://your-server-ip:{ตามด้วย port ที่ระบุใน 20-fe-http-entrypoint})
6. ตรวจสอบ log:
   - `tail -f /var/log/haproxy/services_access.log` (ดู log การเข้าแต่ละ domain)
   - `tail -f /var/log/haproxy/global.log` (ดู log ทั้งหมด)
7. (ถ้า Migration) เมื่อทดสอบผ่านแล้ว ให้หยุด Proxy เดิม เปลี่ยนพอร์ตกลับเป็น 80/443 แล้ว restart HAProxy อีกครั้ง

---

**หมายเหตุ:**
- หากต้องการเปิด Metrics Addon ภายหลัง ให้คัดลอกไฟล์ metrics-addon-conf.d ไปที่ /etc/haproxy/conf.d/ หรือไป uncommetned บรรทัดที่ระบุไว้ว่าให้เปิด Monitor 
- ทุกครั้งที่แก้ไข config ควรตรวจสอบ syntax ก่อน restart
- หากพบปัญหา log หรือ metrics ให้ตรวจสอบสิทธิ์ไฟล์/โฟลเดอร์ และสถานะ rsyslog/logrotate
- log /var/log/haproxy/ ควรเป็นสิทธ์ของ rsyslog
