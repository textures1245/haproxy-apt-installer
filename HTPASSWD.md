# คู่มือการใช้งาน htpasswd กับ HAProxy (ภาษาไทย)

## 1. การสร้าง htpasswd (Manual)

### 1.1 ติดตั้ง htpasswd (ถ้ายังไม่มี)
- Ubuntu/Debian:
  ```
  sudo apt install apache2-utils
  ```
- CentOS/RHEL:
  ```
  sudo yum install httpd-tools
  ```

### 1.2 สร้างรหัสผ่าน (แบบ manual)
- สร้างไฟล์ htpasswd ใหม่ (เช่น userlist.txt):
  ```
  htpasswd -nbB username password
  ```
- ตัวอย่างผลลัพธ์:
  ```
  username:$2y$05$... (hash)
  ```
- ให้นำบรรทัดนี้ไปใส่ในไฟล์ userlist ของ HAProxy (ดูหัวข้อถัดไป)

## 2. การสร้าง htpasswd ด้วยสคริปต์ (แนะนำ)

```bash
git clone  https://github.com/textures1245/haproxy-apt-installer.git
```

### 2.1 เตรียมไฟล์ users.csv (ตัวอย่าง)

```
user1,pass1
user2,pass2
```

### 2.2 ใช้สคริปต์ htpasswd-gen.sh
- แบบไฟล์ CSV:
  ```
  ./htpasswd-gen.sh users.csv > userlist.txt
  ```
- หรือแบบกรอกมือ (Paste CSV แล้วกด Ctrl+D):
  ```
  ./htpasswd-gen.sh > userlist.txt
  ```

## 3. การนำ htpasswd ไปใช้กับ HAProxy

### 3.1 สร้างไฟล์ 30-htpasswd-auth.cfg (ถ้ายังไม่มี)
- สร้างไฟล์ `/etc/haproxy/conf.d/30-htpasswd-auth.cfg` (หรือในโฟลเดอร์ conf.d ตามมาตรฐาน)
- ตัวอย่าง userlist:
  ```
  user user1 password $2y$05$...
  user user2 password $2y$05$...
  ```
- ตัวอย่างไฟล์ 30-htpasswd-auth.cfg:
  ```
  userlist AuthUsers
      user user1 password $2y$05$...
      user user2 password $2y$05$...
  ```

### 3.2 วิธีใช้ htpasswd ใน backend/frontend ของ HAProxy
- เพิ่มบรรทัดนี้ใน section ที่ต้องการ (เช่น frontend หรือ backend):
  ```
  acl AuthOkay http_auth(AuthUsers)
  http-request auth realm "Protected" unless AuthOkay
  ```
- ตัวอย่าง frontend:
  ```
  frontend myfrontend
      bind *:80
      acl AuthOkay http_auth(AuthUsers)
      http-request auth realm "Protected" unless AuthOkay
      default_backend mybackend
  ```

## 4. สรุปขั้นตอน
1. สร้าง userlist ด้วย htpasswd หรือสคริปต์ htpasswd-gen.sh
2. ใส่ userlist ลงในไฟล์ 30-htpasswd-auth.cfg (หรือชื่ออื่นที่เหมาะสมใน conf.d)
3. อ้างอิง userlist ใน frontend/backend ที่ต้องการป้องกันด้วย http_auth
4. ตรวจสอบ config:
   ```
   haproxy -f /etc/haproxy/conf.d -c
   ```
5. รีสตาร์ท HAProxy:
   ```
   systemctl restart haproxy
   ```

---

**หมายเหตุ:**
- สามารถเพิ่ม/ลบ user ได้โดยแก้ไขไฟล์ userlist แล้ว reload HAProxy
- อย่าลืมตรวจสอบสิทธิ์ไฟล์ userlist ให้ HAProxy อ่านได้
- userlist สามารถใช้ร่วมกับ ACL อื่น ๆ ได้ตามต้องการ
