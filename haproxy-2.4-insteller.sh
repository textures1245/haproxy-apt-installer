#!/bin/bash
set -e

USED_MONITOR_ADDON=false
MIGRATED_TO_HAPROXY=false

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
chown -R syslog:syslog /var/log/haproxy
chmod 755 /var/log/haproxy
chmod 664 /var/log/haproxy/*.log

# 4. Setup /etc/rsyslog.d/49-haproxy.conf
cat > /etc/rsyslog.d/49-haproxy.conf <<'EOF'
module(load="imudp")
input(type="imudp" address="127.0.0.1" port="514")

# Auto-create directories and files with proper permissions
$CreateDirs on
$FileOwner syslog
$FileGroup syslog
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



openssl req -x509 -newkey rsa:4096 -keyout /etc/haproxy/ssl/nginx-selfsigned.key -out /etc/haproxy/ssl/nginx-selfsigned.crt -days 365 -nodes
cat /etc/haproxy/ssl/nginx-selfsigned.key /etc/haproxy/ssl/nginx-selfsigned.crt > /etc/haproxy/ssl/nginx-selfsigned.pem

read -p "This is a fresh install or migration from other proxy to HAproxy? (y/n): " is_migration
if [[ "$is_migration" =~ ^[Yy]$ ]]; then
    MIGRATED_TO_HAPROXY=true
    echo "Migration mode: ON. Change http entry ports of to avoid conflict. (http 80 -> 4480, https 443 -> 4443)"
else
    echo "Fresh install mode: OFF. Using standard ports (http 80, https 443)."
fi

read -p "Do you want to enable User Session Monitoring with Metrics Addon? (y/n): " enable_monitoring
if [[ "$enable_monitoring" =~ ^[Yy]$ ]]; then
    USED_MONITOR_ADDON=true
    echo "User Session Monitoring with Metrics Addon will be enabled."
else
    echo "User Session Monitoring with Metrics Addon will NOT be enabled."
    echo "You can enable it later by uncommenting the relevant lines in the config files."
fi

if [ "$USED_MONITOR_ADDON" = true ]; then
    cp -r ./metrics-addon-conf.d/* /etc/haproxy/conf.d/
    sed -i -E 's|# ?bind \*:80|bind *:4480|g' /etc/haproxy/conf.d/20-fe-http-entrypoint.cfg
    sed -i -E 's|# ?bind \*:443|bind *:4443|g' /etc/haproxy/conf.d/20-fe-http-entrypoint.cfg

    VM_NAME=$(hostname)
    sed -i -E "s|VM_NAME|$VM_NAME|g" /etc/haproxy/conf.d/00-global-defaults.cfg
else
    cp -r ./conf.d/* /etc/haproxy/conf.d/
fi


cp ./metrics-aggregator.lua /etc/haproxy/metrics-aggregator.lua

# 7. Fix CONFIG variable in scripts/configs to use /etc/haproxy/conf.d/
find /etc/default/haproxy -type f -exec sed -i -E 's|# ?CONFIG="/etc/haproxy/haproxy.cfg"|CONFIG="/etc/haproxy/conf.d/"|g' {} \;

# 8. Ensure all config files end with a newline (LF)
find /etc/haproxy/conf.d/ -type f -exec sed -i -e '$a\' {} \;

# 9. Reload/restart services and validate HAProxy config
systemctl daemon-reload
systemctl restart logrotate.service
systemctl restart rsyslog.service

haproxy -f /etc/haproxy/conf.d -c

echo "✅ HAProxy, logging, and config directories are set up!"


echo """
----- Next Steps -----
1. Review and customize /etc/haproxy/conf.d/*.cfg files as needed (separate backend block for each domain/service. all files should start with number for load order)
2. Place your SSL certs in /etc/haproxy/ssl/ (haproxy using PEM format)
3. Check HAProxy config: haproxy -f /etc/haproxy/conf.d -c to do syntax validate 
4. Start/restart HAProxy: systemctl restart haproxy (IF EVERYTHING IS OK)
"""

if [ "$MIGRATED_TO_HAPROXY" = true ]; then
   echo """
   -----  Migration Hint -----
    We had changed http entry ports in /etc/haproxy/conf.d/20-fe-http-entrypoint.cfg to avoid conflict with existing services (e.g., Nginx, Apache)
    Please ensure:
    1. Ensure no port conflicts with existing services (e.g., Nginx, Apache)
    2. Restart current testing HAProxy config (http 4480, https 4443)
    3. Testing by visiting http://your-server-ip:4480 and https://your-server-ip:4443 first to confirm HAProxy is working
    
    If everything looks good, 
    1. Stop your old existing proxy services (e.g., Nginx, Apache)
    2. Change ports back to standard (http 80, https 443) in /etc/haproxy/conf.d/20-fe-http-entrypoint.cfg
    3. Check HAproxy config, then restart HAProxy: systemctl restart haproxy
    4. Finally, test by visiting http://your-domain and https://your-domain
   """
else
    echo "Starting HAProxy for the first time..."
    systemctl start haproxy.service
fi

echo """
----- Monitor ----
1. tail -f /var/log/haproxy/services_access.log for see only domain access logs
2. tail -f /var/log/haproxy/global.log for see all HAProxy logs

3. Check rsyslog status: systemctl status rsyslog --no-pager -l
4. Check logrotate status: systemctl status logrotate --no-pager -l
"""
echo """
---- Config Reference ----
1. Logrotate config: /etc/logrotate.d/haproxy
2. Rsyslog config: /etc/rsyslog.d/49-haproxy
3. Systemd haproxy initialize: /etc/default/haproxy
4. HAProxy main config dir: /etc/haproxy/conf.d/
5. Metrics Lua script: /etc/haproxy/metrics-aggregator.lua
"""
