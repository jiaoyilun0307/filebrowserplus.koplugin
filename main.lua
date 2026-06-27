-- Portions of this code are derived from the original "filebrowser.koplugin"
-- for KOReader, licensed under the GNU AGPLv3.
-- Modifications and extensions © 2025 [Neeraj Patel].

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage") -- luacheck:ignore
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local path = DataStorage:getFullDataDir()
local config_path = path .. "/plugins/filebrowserplus.koplugin/config.json"
local db_path = path .. "/plugins/filebrowserplus.koplugin/filebrowser.db"
local plugin_path = path .. "/plugins/filebrowserplus.koplugin/filebrowser"
local silence_cmd = ""
-- uncomment below to prevent cmd output from cluttering up crash.log
--silence_cmd = " > /dev/null 2>&1"

local pid_path = "/tmp/filebrowserplus_koreader.pid"
local bin_path = plugin_path .. "/filebrowser"
local filebrowser_args = string.format("-d %s -c %s ", db_path, config_path)
local filebrowser_cmd = bin_path .. " " .. filebrowser_args
local log_path = plugin_path .. "/filebrowserplus.log"

-- ============================================================================
-- Diagnostic helpers: log + on-screen error reporting
-- ============================================================================

--- Write a message to the dedicated log file (always appended).
local function writeLogFile(level, msg)
    local f = io.open(log_path, "a")
    if f then
        local ts = os.date("%Y-%m-%d %H:%M:%S")
        f:write(string.format("[%s] [%s] %s\n", ts, level, msg))
        f:close()
    end
end

--- Log to crash.log AND the plugin log file simultaneously.
local function diagLog(level, fmt, ...)
    local msg = string.format(fmt, ...)
    -- KOReader logger (goes to crash.log)
    if level == "ERR" then
        logger.err("[FilebrowserPlus] " .. msg)
    elseif level == "WARN" then
        logger.warn("[FilebrowserPlus] " .. msg)
    else
        logger.info("[FilebrowserPlus] " .. msg)
    end
    -- Dedicated log file
    writeLogFile(level, msg)
end

--- Show an on-screen error message (non-blocking, auto-dismiss).
--- Also logs the message for later review.
local function showScreenError(text, timeout)
    diagLog("ERR", text)
    UIManager:show(InfoMessage:new{
        icon = "notice-warning",
        timeout = timeout or 20,
        text = text,
    })
end

--- Show an on-screen info message.
local function showScreenInfo(text, timeout)
    diagLog("INFO", text)
    UIManager:show(InfoMessage:new{
        timeout = timeout or 10,
        text = text,
    })
end

--- Execute a command and capture its stdout+stderr.
--- Returns: exit_code, combined_output (string)
local function executeWithOutput(cmd)
    -- Redirect stderr to stdout, write combined output to a temp file
    local tmp_out = "/tmp/filebrowserplus_cmd_out.txt"
    local full_cmd = cmd .. " > '" .. tmp_out .. "' 2>&1"
    local status = os.execute(full_cmd)
    local output = ""
    local f = io.open(tmp_out, "r")
    if f then
        output = f:read("*a")
        f:close()
        os.remove(tmp_out)
    end
    -- Normalize: trim whitespace
    output = output:gsub("^%s+", ""):gsub("%s+$", "")
    return status, output
end

-- ============================================================================
-- End diagnostic helpers
-- ============================================================================

if not util.pathExists(bin_path) then
    diagLog("ERR", "Binary missing at: %s", bin_path)
    diagLog("ERR", "Plugin disabled. Please ensure filebrowserplus.koplugin is correctly installed.")
    return {disabled = true}
elseif os.execute("test -x '" .. bin_path .. "'") ~= 0 then
    diagLog("WARN", "Binary not executable, attempting to fix permissions: %s", bin_path)
    local chmod_status = os.execute("chmod +x " .. bin_path)
    if chmod_status == 0 then
        diagLog("INFO", "Permissions fixed successfully.")
    else
        diagLog("ERR", "Failed to chmod +x on binary (status: %s). File system may be read-only.", tostring(chmod_status))
    end
end

local FilebrowserPlus = WidgetContainer:extend{
    name = "FilebrowserPlus",
    is_doc_only = false,
}

function FilebrowserPlus:init()
    self.filebrowserplus_first_setup = false
    self.filebrowserplus_port = G_reader_settings:readSetting("FilebrowserPlus_port") or "80"
    self.allow_no_password = G_reader_settings:isTrue("FilebrowserPlus_allow_no_password")
    self.autostart = G_reader_settings:isTrue("FilebrowserPlus_autostart")
    self.filebrowserplus_dataPath = G_reader_settings:readSetting("FilebrowserPlus_dataPath") or "/"

    diagLog("INFO", "Plugin initialized. Port=%s, DataPath=%s, Autostart=%s, AllowNoPassword=%s",
        self.filebrowserplus_port, self.filebrowserplus_dataPath,
        tostring(self.autostart), tostring(self.allow_no_password))
    diagLog("INFO", "KOReader data dir: %s", path)
    diagLog("INFO", "Binary path: %s", bin_path)
    diagLog("INFO", "Config path: %s", config_path)
    diagLog("INFO", "DB path: %s", db_path)

    if self.autostart then
        diagLog("INFO", "Autostart enabled, starting server on port %s", self.filebrowserplus_port)
        self:start()
    end

    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

function FilebrowserPlus:config()
    diagLog("INFO", "Running first-time config setup...")

    -- Remove old config and db
    os.remove(config_path)
    os.remove(db_path)
    diagLog("INFO", "Removed old config and db files (if any).")

    -- Ensure plugin directory exists
    if not util.pathExists(plugin_path) then
        diagLog("ERR", "Plugin directory does not exist: %s", plugin_path)
        showScreenError(T(_("FilebrowserPlus Error:\n\nPlugin directory missing:\n%1\n\nCannot proceed with setup."), plugin_path))
        return false
    end

    -- Step 1: config init
    local init_cmd = filebrowser_cmd .. " config init"
    diagLog("INFO", "Running: %s", init_cmd)
    local status, output = executeWithOutput(init_cmd)
    diagLog("INFO", "config init exit status: %s", tostring(status))
    if output ~= "" then
        diagLog("INFO", "config init output: %s", output)
    end
    if status ~= 0 then
        local err_text = T(
            _("FilebrowserPlus config init failed!\n\nCommand: %1\nExit code: %2\nOutput: %3\n\nCheck the log file:\n%4"),
            init_cmd, tostring(status), output ~= "" and output or _("(empty)"), log_path)
        showScreenError(err_text, 30)
        return false
    end

    -- Step 2: create admin user
    local add_user_cmd = filebrowser_cmd .. "users add admin admin12345678 --perm.admin"
    diagLog("INFO", "Running: %s", add_user_cmd)
    status, output = executeWithOutput(add_user_cmd)
    diagLog("INFO", "users add exit status: %s", tostring(status))
    if output ~= "" then
        diagLog("INFO", "users add output: %s", output)
    end
    if status ~= 0 then
        local err_text = T(
            _("FilebrowserPlus user creation failed!\n\nCommand: %1\nExit code: %2\nOutput: %3\n\nCheck the log file:\n%4"),
            add_user_cmd, tostring(status), output ~= "" and output or _("(empty)"), log_path)
        showScreenError(err_text, 30)
        return false
    end

    diagLog("INFO", "First-time config setup completed successfully.")
    return true
end

function FilebrowserPlus:resetPassword()
    local username = "admin"
    local newPass = "admin12345678"
    local reset_passwd_cmd = string.format("%s -d %s -c %s users update %s --password=%s",
        bin_path, db_path, config_path, username, newPass)

    diagLog("INFO", "Resetting password. Running: %s", reset_passwd_cmd)
    local status, output = executeWithOutput(reset_passwd_cmd)
    diagLog("INFO", "reset password exit status: %s", tostring(status))
    if output ~= "" then
        diagLog("INFO", "reset password output: %s", output)
    end

    if status == 0 then
        local info = InfoMessage:new{
            timeout = 15,
            text = T(_("Password for user %1 is now set to %2\nYou can change it via the filebrowser web portal!"),
                username, newPass)
        }
        UIManager:show(info)
    else
        local err_text = T(
            _("Failed to reset password!\n\nExit code: %1\nOutput: %2\n\nLog: %3"),
            tostring(status), output ~= "" and output or _("(empty)"), log_path)
        showScreenError(err_text, 20)
    end
end

function FilebrowserPlus:start()
    diagLog("INFO", "=== Starting FilebrowserPlus server ===")

    -- Kindle-specific: iptables rules
    if Device:isKindle() then
        diagLog("INFO", "Kindle detected, adding iptables rules for port %s", self.filebrowserplus_port)
        os.execute(string.format("%s %s %s", "iptables -A INPUT -p tcp --dport", self.filebrowserplus_port,
            "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        os.execute(string.format("%s %s %s", "iptables -A OUTPUT -p tcp --sport", self.filebrowserplus_port,
            "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
    end

    -- Check if already running
    if self:isRunning() then
        diagLog("WARN", "Server already running, skipping start.")
        return
    end

    -- Pre-flight checks: binary
    if not util.pathExists(bin_path) then
        showScreenError(T(
            _("FilebrowserPlus cannot start!\n\nBinary not found:\n%1\n\nPlease reinstall the plugin."),
            bin_path), 20)
        return
    end

    -- Pre-flight checks: binary executable
    local test_exec_cmd = "test -x '" .. bin_path .. "'"
    if os.execute(test_exec_cmd) ~= 0 then
        diagLog("WARN", "Binary not executable, trying chmod +x...")
        local chmod_status = os.execute("chmod +x " .. bin_path)
        if chmod_status ~= 0 then
            showScreenError(T(
                _("FilebrowserPlus cannot start!\n\nBinary is not executable and chmod failed:\n%1\n\nExit code: %2\n\nThe file system may be read-only."),
                bin_path, tostring(chmod_status)), 20)
            return
        end
        diagLog("INFO", "chmod +x succeeded.")
    end

    -- Pre-flight checks: binary can actually run (test with "version" command)
    diagLog("INFO", "Testing binary execution with 'version' command...")
    local test_status, test_output = executeWithOutput(bin_path .. " version")
    diagLog("INFO", "Binary test exit status: %s, output: %s", tostring(test_status), test_output)
    if test_status ~= 0 then
        local arch_info = ""
        local f = io.popen("uname -m 2>/dev/null")
        if f then
            arch_info = f:read("*l") or _("unknown")
            f:close()
        end
        showScreenError(T(
            _("FilebrowserPlus cannot start!\n\nThe filebrowser binary failed to execute.\n\nExit code: %1\nOutput: %2\n\nDevice architecture: %3\n\nThe binary may be incompatible with your device.\nTry replacing it with the correct architecture from:\nhttps://github.com/filebrowser/filebrowser/releases\n\nLog: %4"),
            tostring(test_status),
            test_output ~= "" and test_output or _("(empty - binary may be missing or corrupt)"),
            arch_info,
            log_path), 30)
        return
    end

    -- First-time setup: config + user
    if not util.fileExists(db_path) then
        self.filebrowserplus_first_setup = true
        diagLog("INFO", "DB file not found, running first-time setup...")
        local config_ok = self:config()
        if not config_ok then
            return -- config() already showed the error
        end
    else
        self.filebrowserplus_first_setup = false
        diagLog("INFO", "DB file exists, skipping first-time setup.")
    end

    -- Check data path
    if not util.pathExists(self.filebrowserplus_dataPath) then
        diagLog("WARN", "Data path does not exist, creating: %s", self.filebrowserplus_dataPath)
        os.execute(string.format("mkdir -p %q", self.filebrowserplus_dataPath))
        if util.pathExists(self.filebrowserplus_dataPath) then
            diagLog("INFO", "Created missing data path successfully.")
        else
            showScreenError(T(
                _("FilebrowserPlus cannot start!\n\nFailed to create data directory:\n%1\n\nPlease check the path or permissions.\n\nNote: On Kindle, only locations under /mnt/us are writable.\nOn Kobo, only locations under /mnt/onboard are writable.\nOn Android, try /sdcard or a subdirectory."),
                self.filebrowserplus_dataPath), 20)
            return
        end
    end

    -- Configure auth method
    if self.allow_no_password then
        local disable_auth_cmd = string.format("%s -d %s -c %s config set --auth.method=noauth",
            bin_path, db_path, config_path)
        diagLog("INFO", "Disabling auth. Running: %s", disable_auth_cmd)
        local auth_status, auth_output = executeWithOutput(disable_auth_cmd)
        diagLog("INFO", "config set noauth status: %s, output: %s", tostring(auth_status), auth_output)
    else
        local enable_auth_cmd = string.format("%s -d %s -c %s config set --auth.method=json",
            bin_path, db_path, config_path)
        diagLog("INFO", "Enabling json auth. Running: %s", enable_auth_cmd)
        local auth_status, auth_output = executeWithOutput(enable_auth_cmd)
        diagLog("INFO", "config set json auth status: %s, output: %s", tostring(auth_status), auth_output)
    end

    -- Build and execute the launch command
    local cmd = string.format("nohup %q -a 0.0.0.0 -r %q -p %s -l %q %s & echo $! > %q",
        bin_path, self.filebrowserplus_dataPath, self.filebrowserplus_port,
        log_path, filebrowser_args, pid_path)
    diagLog("INFO", "Launching filebrowser with command: %s", cmd)

    local status = os.execute(cmd)
    diagLog("INFO", "Launch command exit status: %s", tostring(status))

    if status == 0 then
        -- Verify the process actually started (not just the shell command)
        ffiutil.sleep(1)
        if not self:isRunning() then
            diagLog("ERR", "Server process not found after launch. It may have crashed immediately.")
            -- Check the log file for clues
            local lf = io.open(log_path, "r")
            local log_tail = ""
            if lf then
                -- Read last 500 chars of log
                lf:seek("end", -500)
                log_tail = lf:read("*a") or ""
                lf:close()
            end
            showScreenError(T(
                _("FilebrowserPlus server exited immediately after launch!\n\nThe process may have crashed on startup.\n\nCheck the filebrowser log:\n%1\n\nLog tail:\n%2"),
                log_path, log_tail ~= "" and log_tail or _("(empty)")), 25)
            return
        end

        -- Get IP address
        local ip_info = ""
        if Device.retrieveNetworkInfo then
            local net_info = Device:retrieveNetworkInfo()
            if type(net_info) == "table" and net_info.ip then
                ip_info = net_info.ip
            elseif type(net_info) == "string" then
                ip_info = net_info:match("(%d+%.%d+%.%d+%.%d+)") or _("Unknown IP")
            else
                ip_info = _("Unknown IP")
            end
        else
            ip_info = _("Could not retrieve IP address.")
        end

        -- Add default credentials if first setup
        local extra_info = ""
        if self.filebrowserplus_first_setup then
            extra_info = _("\n\nDefault username: admin\nDefault password: admin12345678")
        end

        diagLog("INFO", "Server started successfully on port %s, IP: %s", self.filebrowserplus_port, ip_info)
        showScreenInfo(T(
            _("FilebrowserPlus server started.\n\nPort: %1\nIP Address: %2%3\n\nVisit http://%2:%1 from another device."),
            self.filebrowserplus_port, ip_info, extra_info), 15)
    else
        showScreenError(T(
            _("Failed to start FilebrowserPlus server.\n\nExit code: %1\nPort: %2\nData path: %3\n\nThe port may be in use or require elevated privileges.\nTry a different port (e.g. 8080).\n\nLog: %4"),
            tostring(status), self.filebrowserplus_port, self.filebrowserplus_dataPath, log_path), 25)
    end
end

function FilebrowserPlus:isRunning()
    if not util.pathExists(pid_path) then
        return false
    end
    local f = io.open(pid_path, "r")
    if not f then
        return false
    end
    local pid = f:read("*n")
    f:close()
    if not pid then
        os.remove(pid_path)
        return false
    end
    -- Check if process with this PID exists
    local check_cmd = string.format("kill -0 %d 2>/dev/null", pid)
    local status = os.execute(check_cmd)
    if status == 0 then
        return true
    else
        -- Cleanup stale PID file
        os.remove(pid_path)
        return false
    end
end

function FilebrowserPlus:stop()
    local cmd = string.format("if [ -f '%s' ]; then kill $(cat '%s') 2>/dev/null; rm -f '%s'; fi",
        pid_path, pid_path, pid_path)
    diagLog("INFO", "Stopping Filebrowser. Running: %s", cmd)
    local status = os.execute(cmd)
    if status == 0 then
        diagLog("INFO", "Filebrowser stopped successfully.")
        UIManager:show(InfoMessage:new{
            text = _("FilebrowserPlus server stopped."),
            timeout = 2
        })
        if Device:isKindle() then
            os.execute(string.format("%s %s %s", "iptables -D INPUT -p tcp --dport", self.filebrowserplus_port,
                "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
            os.execute(string.format("%s %s %s", "iptables -D OUTPUT -p tcp --sport", self.filebrowserplus_port,
                "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
        end
    else
        diagLog("ERR", "Failed to stop Filebrowser, status: %s", tostring(status))
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = _("Failed to stop Filebrowser.")
        })
    end
end

function FilebrowserPlus:onToggleFilebrowserPlusServer()
    if self:isRunning() then
        self:stop()
    else
        self:start()
    end
end

function FilebrowserPlus:show_port_dialog(touchmenu_instance)
    self.port_dialog = InputDialog:new{
        title = _("Choose FilebrowserPlus port"),
        input = self.filebrowserplus_port,
        input_type = "number",
        input_hint = self.filebrowserplus_port,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.port_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = tonumber(self.port_dialog:getInputText())
                        if value and value >= 0 then
                            self.filebrowserplus_port = value
                            G_reader_settings:saveSetting("FilebrowserPlus_port", self.filebrowserplus_port)
                            UIManager:close(self.port_dialog)
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.port_dialog)
    self.port_dialog:onShowKeyboard()
end

function FilebrowserPlus:show_dataPath_dialog(touchmenu_instance)
    self.dataPath_dialog = InputDialog:new{
        title = _("Enter FilebrowserPlus Data Path"),
        input = self.filebrowserplus_dataPath,
        input_type = "text",
        input_hint = "/mnt/us/koreader/books",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.dataPath_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = self.dataPath_dialog:getInputText()
                        if value then
                            self.filebrowserplus_dataPath = value
                            G_reader_settings:saveSetting("FilebrowserPlus_dataPath", value)
                            UIManager:close(self.dataPath_dialog)
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.dataPath_dialog)
    self.dataPath_dialog:onShowKeyboard()
end

function FilebrowserPlus:addToMainMenu(menu_items)
    menu_items.filebrowserplus = {
        text = _("FilebrowserPlus"),
        sorting_hint = "network",
        keep_menu_open = true,
        sub_item_table = {
            {
                text = _("FilebrowserPlus server"),
                checked_func = function()
                    return self:isRunning()
                end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:onToggleFilebrowserPlusServer()
                    -- sleeping might not be needed, but it gives the feeling
                    -- something has been done and feedback is accurate
                    ffiutil.sleep(1)
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text_func = function()
                    return T(_("FilebrowserPlus port (%1)"), self.filebrowserplus_port)
                end,
                keep_menu_open = true,
                enabled_func = function()
                    return not self:isRunning()
                end,
                callback = function(touchmenu_instance)
                    self:show_port_dialog(touchmenu_instance)
                end,
            },
            {
                text_func = function()
                    return T(_("FilebrowserPlus Data Path (%1)"), self.filebrowserplus_dataPath)
                end,
                keep_menu_open = true,
                enabled_func = function()
                    return not self:isRunning()
                end,
                callback = function(touchmenu_instance)
                    self:show_dataPath_dialog(touchmenu_instance)
                end,
            },
            {
                text = _("Reset Admin User Password"),
                keep_menu_open = true,
                enabled_func = function()
                    return not self:isRunning()
                end,
                callback = function(touchmenu_instance)
                    self:resetPassword()
                end,
            },
            {
                text = _("Login without password (DANGEROUS)"),
                checked_func = function()
                    return self.allow_no_password
                end,
                enabled_func = function()
                    return not self:isRunning()
                end,
                callback = function()
                    self.allow_no_password = not self.allow_no_password
                    G_reader_settings:flipNilOrFalse("FilebrowserPlus_allow_no_password")
                end,
            },
            {
                text = _("Start FilebrowserPlus server with KOReader"),
                checked_func = function()
                    return self.autostart
                end,
                enabled_func = function()
                    return not self:isRunning()
                end,
                callback = function()
                    self.autostart = not self.autostart
                    G_reader_settings:flipNilOrFalse("FilebrowserPlus_autostart")
                end,
            },
            {
                text = _("View diagnostic log"),
                keep_menu_open = true,
                callback = function()
                    local log_content = ""
                    local f = io.open(log_path, "r")
                    if f then
                        log_content = f:read("*a")
                        f:close()
                    end
                    if log_content == "" then
                        log_content = _("(log is empty)")
                    end
                    local InfoMsg = require("ui/widget/infomessage")
                    UIManager:show(InfoMsg:new{
                        text = log_content,
                        timeout = 30,
                    })
                end,
            },
        },
    }
end

function FilebrowserPlus:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_filebrowserplus_server", {
        category = "none",
        event = "ToggleFilebrowserPlusServer",
        title = _("Toggle FilebrowserPlus server"),
        general = true,
    })
end

return FilebrowserPlus
