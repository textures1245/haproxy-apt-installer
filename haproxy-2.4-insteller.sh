#!/bin/bash
set -e

# 1. Install HAProxy, Lua, rsyslog, and dependencies
apt update
apt install -y \
    haproxy \
    lua5.3 \
    liblua5.3-dev \
    lua-cjson-dev \
    rsyslog \
    curl \
    wget \
    luarocks \
    build-essential

luarocks install lua-cjson

# 2. Setup logrotate for HAProxy
cat > /etc/logrotate.d/haproxy <<'EOF'
# HAProxy log rotation configuration
/var/log/haproxy/*.log {
    daily
    rotate 52
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    create 664 syslog syslog
    postrotate
        # Restart rsyslog to reopen log files
        /bin/systemctl reload rsyslog.service > /dev/null 2>&1 || true
        # Send USR1 to HAProxy to reopen log files (if using file-based logging)
        /bin/kill -USR1 `cat /var/run/haproxy.pid 2> /dev/null` 2> /dev/null || true
    endscript
}
EOF

# 3. Init log files and folder, set permissions for rsyslog
mkdir -p /var/log/haproxy
touch /var/log/haproxy/global.log
touch /var/log/haproxy/services_access.log
chown -R rsyslog:rsyslog /var/log/haproxy
chmod 755 /var/log/haproxy
chmod 664 /var/log/haproxy/*.log

# 4. Setup /etc/rsyslog.d/49-haproxy.conf
cat > /etc/rsyslog.d/49-haproxy.conf <<'EOF'
module(load="imudp")
input(type="imudp" address="127.0.0.1" port="514")

# Auto-create directories and files with proper permissions
$CreateDirs on
$FileOwner rsyslog
$FileGroup rsyslog
$FileCreateMode 0644
$DirCreateMode 0755

# Send HAProxy logs to the right file
local0.*    /var/log/haproxy/global.log
& stop

local1.*    /var/log/haproxy/services_access.log
& stop
EOF

# 5. Init folders in /etc/haproxy if not exist
mkdir -p /etc/haproxy/conf.d
mkdir -p /etc/haproxy/ssl
mkdir -p /etc/haproxy/errors
mkdir -p /etc/haproxy/metrics

# 6. Copy config templates into /etc/haproxy/conf.d (replace with your actual source path)
cp -r ./conf.d/* /etc/haproxy/conf.d/
cp ./metrics-aggregator.lua /etc/haproxy/metrics-aggregator.lua

# 7. Fix CONFIG variable in scripts/configs to use /etc/haproxy/conf.d/
find /etc/default/haproxy -type f -exec sed -i 's|CONFIG="/etc/haproxy/haproxy.cfg"|CONFIG="/etc/haproxy/conf.d/"|g' {} \;

# 8. Ensure all config files end with a newline (LF)
find /etc/haproxy/conf.d/ -type f -exec sed -i -e '$a\' {} \;

# 9. Reload/restart services and validate HAProxy config
systemctl daemon-reload
systemctl restart logrotate.service
systemctl restart rsyslog.service

haproxy -f /etc/haproxy/conf.d/ -c

echo "✅ HAProxy, logging, and config directories are set up!"