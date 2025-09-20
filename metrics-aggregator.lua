-- HAProxy Lua Metrics Aggregator (Production Version)
-- Uses lua-cjson library for reliable JSON handling

local cjson = require("cjson")

-- Configuration
local config = {
    domains = {
        "example.come", -- FIX: use actual domain names here
    },
    cache_ttl = 10, -- seconds (short cache for real-time monitoring)
    -- Persistence configuration
    persistence = {
        enabled = true,
        file_path = "/etc/haproxy/metrics/haproxy_metrics_persistence.json",
        backup_interval = 60, -- seconds
        restore_on_startup = true
    }
}

-- Cache
local metrics_cache = {
    data = nil,
    timestamp = 0
}

-- Persistent storage for cumulative metrics
local persistent_metrics = {
    data = {},
    last_backup = 0,
    startup_restored = false,
    first_save_done = false
}

-- Get current timestamp in ISO format
local function get_timestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- UUID-based user session tracking (domain-specific tables)
local function get_current_sessions_from_backend(domain)
    -- Map domain names to their respective backend names (stick tables are now in backends)
    local domain_backend_map = {
        ["example.come"] = "example.come", -- FIX: use actual domain names here
    }
    
    local backend_name = domain_backend_map[domain]
    if not backend_name then
        return 0
    end
    
    local success, result = pcall(function()
        local socket = core.tcp()
        if not socket then return 0 end

        local connect_result = socket:connect("/var/run/haproxy/admin.sock")
        if not connect_result then 
            socket:close()
            return 0 
        end

        socket:send("show table " .. backend_name .. "\n")
        local response = socket:receive("*a")
        socket:close()
        
        if response then
            -- Efficiently parse the 'used' count from the table's header line.
            -- Example: "# table: loadtest-urbrand.one.th, type: string, size:100000, used:5"
            local used_count_str = response:match("used:(%d+)")
            if used_count_str then
                return tonumber(used_count_str) or 0
            end
        end
        return 0
    end)
    
    return success and result or 0
end

-- Initialize persistent storage structure for each domain
local function init_persistent_storage()
    for _, domain in ipairs(config.domains) do
        if not persistent_metrics.data[domain] then
            persistent_metrics.data[domain] = {
                total_sessions_cumulative = 0,
                total_requests_cumulative = 0,
                total_bytes_in_cumulative = 0,
                total_bytes_out_cumulative = 0,
                total_connections_cumulative = 0,
                errors_connection_cumulative = 0,
                errors_response_cumulative = 0,
                session_rate_max_ever = 0,
                uptime_start = os.time(),
                last_reset = os.time()
            }
        end
    end
end

-- Save persistent metrics to file
local function save_persistent_metrics()
    if not config.persistence.enabled then
        return false
    end
    
    local success, err = pcall(function()
        local file = io.open(config.persistence.file_path, "w")
        if file then
            local data = {
                metrics = persistent_metrics.data,
                saved_at = os.time(),
                saved_timestamp = get_timestamp(),
                haproxy_restart_count = (persistent_metrics.data.global or {}).restart_count or 0
            }
            file:write(cjson.encode(data))
            file:close()
            return true
        else
            -- Log error if file can't be opened
            error("Cannot open file for writing: " .. config.persistence.file_path)
        end
        return false
    end)
    
    -- Force immediate save for testing
    if not success then
        -- Try alternative path if original fails
        local alt_path = "/tmp/haproxy_metrics_backup.json"
        local alt_success = pcall(function()
            local file = io.open(alt_path, "w")
            if file then
                local data = {
                    metrics = persistent_metrics.data,
                    saved_at = os.time(),
                    saved_timestamp = get_timestamp(),
                    haproxy_restart_count = (persistent_metrics.data.global or {}).restart_count or 0,
                    error_note = "Primary path failed, using backup location"
                }
                file:write(cjson.encode(data))
                file:close()
                return true
            end
            return false
        end)
        return alt_success
    end
    
    return success
end

-- Load persistent metrics from file
local function load_persistent_metrics()
    if not config.persistence.enabled or not config.persistence.restore_on_startup then
        return false
    end
    
    local success, result = pcall(function()
        local file = io.open(config.persistence.file_path, "r")
        if file then
            local content = file:read("*a")
            file:close()
            
            if content and content ~= "" then
                local data = cjson.decode(content)
                if data and data.metrics then
                    persistent_metrics.data = data.metrics
                    
                    -- Set base values from loaded backup for each domain
                    for domain, backup_data in pairs(persistent_metrics.data) do
                        if domain ~= "global" then
                            -- Use the saved cumulative values as the new base
                            backup_data.base_total_sessions = backup_data.total_sessions_cumulative or 0
                            backup_data.base_total_requests = backup_data.total_requests_cumulative or 0
                            backup_data.base_total_bytes_in = backup_data.total_bytes_in_cumulative or 0
                            backup_data.base_total_bytes_out = backup_data.total_bytes_out_cumulative or 0
                            backup_data.base_total_connections = backup_data.total_connections_cumulative or 0
                            backup_data.base_errors_connection = backup_data.errors_connection_cumulative or 0
                            backup_data.base_errors_response = backup_data.errors_response_cumulative or 0
                        end
                    end
                    
                    -- Increment restart counter
                    if not persistent_metrics.data.global then
                        persistent_metrics.data.global = {}
                    end
                    persistent_metrics.data.global.restart_count = (persistent_metrics.data.global.restart_count or 0) + 1
                    persistent_metrics.data.global.last_restart = os.time()
                    return true
                end
            end
        end
        return false
    end)
    
    return success
end

-- Update persistent metrics with current values and update server_info with cumulative values
local function update_persistent_metrics(domain, server_info)
    if not config.persistence.enabled then
        return server_info
    end
    
    local persistent = persistent_metrics.data[domain]
    if not persistent then
        return server_info
    end
    
    -- Get current HAProxy values (these reset when HAProxy restarts)
    local current_total_sessions = server_info.total_sessions or 0
    local current_requests = server_info.requests_total or 0
    local current_bytes_in = server_info.bytes_in or 0
    local current_bytes_out = server_info.bytes_out or 0
    local current_connections = server_info.connection_total or 0
    local current_errors_conn = server_info.errors_connection or 0
    local current_errors_resp = server_info.errors_response or 0
    
    -- Update cumulative values: backup_value + current_haproxy_value
    -- This way we always preserve the total count across restarts
    persistent.total_sessions_cumulative = (persistent.base_total_sessions or 0) + current_total_sessions
    persistent.total_requests_cumulative = (persistent.base_total_requests or 0) + current_requests
    persistent.total_bytes_in_cumulative = (persistent.base_total_bytes_in or 0) + current_bytes_in
    persistent.total_bytes_out_cumulative = (persistent.base_total_bytes_out or 0) + current_bytes_out
    persistent.total_connections_cumulative = (persistent.base_total_connections or 0) + current_connections
    persistent.errors_connection_cumulative = (persistent.base_errors_connection or 0) + current_errors_conn
    persistent.errors_response_cumulative = (persistent.base_errors_response or 0) + current_errors_resp
    
    -- Update max values
    if (server_info.session_rate_max or 0) > persistent.session_rate_max_ever then
        persistent.session_rate_max_ever = server_info.session_rate_max or 0
    end
    
    -- Store current values for debugging
    persistent.last_total_sessions = current_total_sessions
    persistent.last_requests = current_requests
    persistent.last_bytes_in = current_bytes_in
    persistent.last_bytes_out = current_bytes_out
    persistent.last_connections = current_connections
    persistent.last_errors_conn = current_errors_conn
    persistent.last_errors_resp = current_errors_resp
    persistent.last_update = os.time()
    
    -- UPDATE server_info with cumulative values instead of raw HAProxy values
    server_info.total_sessions = persistent.total_sessions_cumulative
    server_info.requests_total = persistent.total_requests_cumulative
    server_info.bytes_in = persistent.total_bytes_in_cumulative
    server_info.bytes_out = persistent.total_bytes_out_cumulative
    server_info.connection_total = persistent.total_connections_cumulative
    server_info.errors_connection = persistent.errors_connection_cumulative
    server_info.errors_response = persistent.errors_response_cumulative
    
    -- Update session_rate_max with the ever-recorded maximum
    if persistent.session_rate_max_ever > (server_info.session_rate_max or 0) then
        server_info.session_rate_max = persistent.session_rate_max_ever
    end
    
    return server_info
end

-- Get combined metrics (current + persistent)
local function get_combined_metrics(domain, current_stats)
    -- Always return only the basic server_info structure
    -- Persistence works in background but doesn't affect API response
    return current_stats
end

-- Check if cache is valid
local function is_cache_valid()
    local current_time = os.time()
    return metrics_cache.data and (current_time - metrics_cache.timestamp) < config.cache_ttl
end

-- Get real HAProxy stats data using stats socket
local function get_haproxy_stats()
    -- Initialize persistent storage on first run
    if not persistent_metrics.startup_restored and config.persistence.restore_on_startup then
        load_persistent_metrics()
        persistent_metrics.startup_restored = true
    end
    init_persistent_storage()
    
    -- Force initial save to create the file
    if config.persistence.enabled and not persistent_metrics.first_save_done then
        save_persistent_metrics()
        persistent_metrics.first_save_done = true
    end
    
    local stats = {}
    
    -- Get stats for each configured domain
    for _, domain in ipairs(config.domains) do
        local backend_name = domain  -- Use full domain name as backend name
        
        -- Initialize with default values
        local server_info = {
            domain = domain,
            current_sessions = 0,  -- Current active user sessions (scur) - ACTUAL USERS CURRENTLY USING DOMAIN
            max_sessions = 0,  -- Configured session limit (slim)
            total_sessions = 0,
            session_rate = 0,  -- Current sessions per second
            session_rate_max = 0,  -- Max sessions per second
            connection_rate = 0,  -- Current connections per second
            connection_total = 0,  -- Total connections
            requests_total = 0,  -- Total HTTP requests
            bytes_in = 0,
            bytes_out = 0,
            status = "UNKNOWN",
            backend_name = backend_name,
            response_time = 0,
            queue_current = 0,
            errors_connection = 0,
            errors_response = 0
        }
        
        -- ALWAYS get current sessions from backend stats
        server_info.current_sessions = get_current_sessions_from_backend(domain)
        
        -- Try to get stats using HAProxy stats socket
        local socket_path = "/var/run/haproxy/admin.sock"
        local success, result = pcall(function()
            -- Connect to HAProxy stats socket
            local socket = core.tcp()
            if socket then
                local connect_result = socket:connect(socket_path)
                if connect_result then
                    -- Send stats command
                    socket:send("show stat\n")
                    local response = socket:receive("*a")
                    socket:close()
                    
                    if response then
                        -- Parse CSV stats output
                        local lines = {}
                        for line in response:gmatch("[^\r\n]+") do
                            table.insert(lines, line)
                        end
                        
                        -- Look for our backend in the stats
                        for i, line in ipairs(lines) do
                            local fields = {}
                            for field in line:gmatch("([^,]*)") do
                                table.insert(fields, field)
                            end
                            
                            -- Check if this line matches our backend
                            if fields[1] and (fields[1] == backend_name or fields[1]:find(domain:gsub("%..*", ""))) then
                                -- Keep other HAProxy metrics
                                server_info.active_sessions = tonumber(fields[5]) or 0  -- HAProxy's internal estimation
                                
                                -- จำนวน session ทั้งหมดที่เคยใช้งาน
                                server_info.total_sessions = tonumber(fields[8]) or 0
                                -- จำนวนข้อมูลที่รับเข้ามา (ไบต์)
                                server_info.bytes_in = tonumber(fields[9]) or 0
                                -- จำนวนข้อมูลที่ส่งออกไป (ไบต์)
                                server_info.bytes_out = tonumber(fields[10]) or 0
                                -- จำนวนคิวที่รออยู่ในปัจจุบัน
                                server_info.queue_current = tonumber(fields[3]) or 0
                                -- เวลาตอบสนอง (มิลลิวินาที)
                                server_info.response_time = tonumber(fields[61]) or 0
                                -- จำนวนข้อผิดพลาดในการเชื่อมต่อ
                                server_info.errors_connection = tonumber(fields[14]) or 0
                                -- จำนวนข้อผิดพลาดในการตอบสนอง
                                server_info.errors_response = tonumber(fields[15]) or 0
                                -- Session and connection metrics
                                server_info.max_sessions = tonumber(fields[6]) or 0  -- slim field (configured session limit)
                                
                                -- Traffic metrics for better user monitoring
                                server_info.session_rate = tonumber(fields[34]) or 0  -- Current sessions per second
                                server_info.session_rate_max = tonumber(fields[36]) or 0  -- Max sessions per second ever reached
                                server_info.connection_rate = tonumber(fields[78]) or 0  -- Current connections per second  
                                server_info.connection_total = tonumber(fields[80]) or 0  -- Total connections since start
                                
                                -- Request metrics (better for user activity monitoring)
                                server_info.requests_total = tonumber(fields[49]) or 0  -- Total HTTP requests
                            
        
                                -- Determine status (field 18 in HAProxy stats)
                                local status_field = fields[18] or "UNKNOWN"
                                if status_field == "UP" or status_field == "OPEN" then
                                    server_info.status = "UP"
                                elseif status_field == "DOWN" or status_field == "MAINT" then
                                    server_info.status = "DOWN"
                                else
                                    server_info.status = status_field
                                end
                                break
                            end
                        end
                    end
                end
            end
        end)
        
        -- If socket method fails, try alternative approach with simple status check
        if not success then
            -- Fallback: just check if we can resolve basic info
            server_info.status = "ACTIVE"  -- Assume active if script is running
            server_info.last_error = "Stats socket unavailable"
        end
        
        -- Update persistent metrics for this domain and get cumulative values
        server_info = update_persistent_metrics(domain, server_info)
        
        -- Get combined metrics (current + persistent) - now just returns server_info as-is
        server_info = get_combined_metrics(domain, server_info)
        
        stats[domain] = server_info
    end
    
    -- Periodic backup of persistent data
    local current_time = os.time()
    if config.persistence.enabled and 
       (current_time - persistent_metrics.last_backup) >= config.persistence.backup_interval then
        save_persistent_metrics()
        persistent_metrics.last_backup = current_time
    end
    
    return stats
end

-- Get all domain metrics
local function get_domain_metrics()
    if is_cache_valid() then
        return metrics_cache.data
    end
    
    local stats = get_haproxy_stats()
    local result = {
        timestamp = get_timestamp(),
        total_domains = #config.domains,
        domains = stats
    }
    
    -- Update cache
    metrics_cache.data = result
    metrics_cache.timestamp = os.time()
    
    return result
end

-- Get specific domain metrics
local function get_single_domain_metrics(domain_name)
    local all_metrics = get_domain_metrics()
    local domain_data = all_metrics.domains[domain_name]
    
    if not domain_data then
        return {
            error = "Domain not found",
            domain = domain_name,
            timestamp = get_timestamp(),
            available_domains = config.domains
        }
    end
    
    return {
        timestamp = all_metrics.timestamp,
        domain = domain_name,
        data = domain_data
    }
end

-- Health check
local function health_check()
    local restart_count = 0
    local last_restart = "never"
    
    if persistent_metrics.data.global then
        restart_count = persistent_metrics.data.global.restart_count or 0
        if persistent_metrics.data.global.last_restart then
            last_restart = os.date("!%Y-%m-%dT%H:%M:%SZ", persistent_metrics.data.global.last_restart)
        end
    end
    
    return {
        status = "healthy",
        timestamp = get_timestamp(),
        lua_version = _VERSION,
        haproxy_version = "2.4.x",
        domains_configured = #config.domains,
        cache_ttl = config.cache_ttl,
        configured_domains = config.domains,
        persistence = {
            enabled = config.persistence.enabled,
            file_path = config.persistence.file_path,
            backup_interval = config.persistence.backup_interval,
            haproxy_restart_count = restart_count,
            last_restart = last_restart,
            startup_restored = persistent_metrics.startup_restored
        }
    }
end

-- SPA Heartbeat endpoint for session renewal
local function heartbeat_response()
    return {
        status = "ok",
    }
end

-- Get persistence information and management
local function get_persistence_info()
    if not config.persistence.enabled then
        return {
            error = "Persistence is disabled",
            timestamp = get_timestamp()
        }
    end
    
    local persistence_data = {
        timestamp = get_timestamp(),
        persistence_enabled = config.persistence.enabled,
        file_path = config.persistence.file_path,
        backup_interval = config.persistence.backup_interval,
        last_backup = persistent_metrics.last_backup,
        startup_restored = persistent_metrics.startup_restored,
        domains_data = {}
    }
    
    -- Add summary of persistent data for each domain
    for domain, data in pairs(persistent_metrics.data) do
        if domain ~= "global" then
            persistence_data.domains_data[domain] = {
                total_sessions_cumulative = data.total_sessions_cumulative or 0,
                total_requests_cumulative = data.total_requests_cumulative or 0,
                total_bytes_in_cumulative = data.total_bytes_in_cumulative or 0,
                total_bytes_out_cumulative = data.total_bytes_out_cumulative or 0,
                session_rate_max_ever = data.session_rate_max_ever or 0,
                uptime_start = data.uptime_start,
                last_reset = data.last_reset,
                last_update = data.last_update
            }
        end
    end
    
    -- Add global info
    if persistent_metrics.data.global then
        persistence_data.global = persistent_metrics.data.global
    end
    
    return persistence_data
end

-- Reset persistence data
local function reset_persistence()
    if not config.persistence.enabled then
        return {
            error = "Persistence is disabled",
            timestamp = get_timestamp()
        }
    end
    
    -- Clear all persistent data
    persistent_metrics.data = {}
    init_persistent_storage()
    
    -- Save empty state
    save_persistent_metrics()
    
    return {
        status = "success",
        message = "Persistence data has been reset",
        timestamp = get_timestamp()
    }
end

-- Main API router
function metrics_api(applet)
    local path = applet.path
    local method = applet.method
    
    -- Only GET requests
    if method ~= "GET" then
        local error_response = cjson.encode({
            error = "Method not allowed",
            method = method,
            allowed = {"GET"},
            timestamp = get_timestamp()
        })
        
        applet:set_status(405)
        applet:add_header("content-type", "application/json")
        applet:start_response()
        applet:send(error_response)
        return
    end
    
    local response_data
    local status = 200
    
    -- Route requests
    if path == "/api/heartbeat" then
        response_data = heartbeat_response()
    elseif path == "/api/health" then
        response_data = health_check()
    elseif path == "/api/metrics/domains" then
        response_data = get_domain_metrics()
        
    elseif path == "/api/metrics/persistence" then
        response_data = get_persistence_info()
        
    elseif path == "/api/metrics/persistence/reset" then
        response_data = reset_persistence()
        
    elseif path:match("^/api/metrics/domain/") then
        local domain_name = path:match("/api/metrics/domain/([^/?]+)")
        if domain_name then
            response_data = get_single_domain_metrics(domain_name)
            if response_data.error then
                status = 404
            end
        else
            response_data = {
                error = "Domain name required",
                path = path,
                usage = "/api/metrics/domain/{domain_name}",
                available_domains = config.domains,
                timestamp = get_timestamp()
            }
            status = 400
        end
        
    else
        response_data = {
            error = "Endpoint not found",
            path = path,
            available_endpoints = {
                "/api/heartbeat",             
                "/api/health",
                "/api/metrics/domains", 
                "/api/metrics/persistence",
                "/api/metrics/persistence/reset",
                "/api/metrics/domain/{domain_name}"
            },
            timestamp = get_timestamp()
        }
        status = 404
    end
    
    -- Encode JSON response
    local json_response = cjson.encode(response_data)
    
    -- Send response
    applet:set_status(status)
    applet:add_header("content-type", "application/json")
    applet:add_header("cache-control", "no-cache")
    applet:start_response()
    applet:send(json_response)
end

-- Register service
core.register_service("metrics_api", "http", metrics_api)
