--[[--
In-place updater for this KOReader plugin.

Checks the repository's latest GitHub Release, downloads that release's copy
of the plugin folder into a staging directory next to the installed plugin,
syntax-checks every Lua file, and then swaps the folders. The previous
version is restored if the swap fails. Plugin settings live in KOReader's
settings file, not in the plugin folder, so they survive updates.

Networking modules are loaded only when an update check runs, so this module
adds no work to KOReader startup.

The same file is shipped with every isaacAmejia KOReader plugin; only the
options passed to Updater:new() differ.
--]]

local logger = require("logger")
local _ = require("gettext")

local Updater = {}
Updater.__index = Updater

-- Directory containing this file, without the trailing slash.
local SELF_DIR = ((debug.getinfo(1, "S").source or ""):match("^@(.*)/") or ".")

---------------------------------------------------------------------------
-- Version helpers (pure Lua, unit-testable)
---------------------------------------------------------------------------

local function parseVersion(v)
    if type(v) ~= "string" then return nil end
    v = v:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^[vV]", "")
    local core, pre = v:match("^([%d%.]+)%-?([%w%.%-]*)")
    if not core or core == "" then return nil end
    local nums = {}
    for n in core:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end
    if #nums == 0 then return nil end
    local pre_ids = {}
    if pre and pre ~= "" then
        for id in pre:gmatch("[^%.]+") do pre_ids[#pre_ids + 1] = id end
    end
    return { nums = nums, pre = pre_ids }
end

--- Returns -1, 0 or 1 like a comparator, or nil if either side is unparsable.
-- Follows semver precedence: 2.0.0-alpha.3 < 2.0.0-beta < 2.0.0 < 2.0.1.
function Updater.compareVersions(a, b)
    local va, vb = parseVersion(a), parseVersion(b)
    if not va or not vb then return nil end
    for i = 1, math.max(#va.nums, #vb.nums) do
        local x, y = va.nums[i] or 0, vb.nums[i] or 0
        if x ~= y then return x < y and -1 or 1 end
    end
    local pa, pb = va.pre, vb.pre
    if #pa == 0 and #pb == 0 then return 0 end
    if #pa == 0 then return 1 end
    if #pb == 0 then return -1 end
    for i = 1, math.max(#pa, #pb) do
        local x, y = pa[i], pb[i]
        if x == nil then return -1 end
        if y == nil then return 1 end
        local nx, ny = tonumber(x), tonumber(y)
        if nx and ny then
            if nx ~= ny then return nx < ny and -1 or 1 end
        elseif nx then
            return -1
        elseif ny then
            return 1
        elseif x ~= y then
            return x < y and -1 or 1
        end
    end
    return 0
end

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

--- opts.repo   "owner/name" on GitHub
--- opts.folder plugin folder name inside the repository, e.g. "jellyfin.koplugin"
--- opts.title  human-readable plugin name for messages
function Updater:new(opts)
    local o = setmetatable({}, self)
    o.repo = assert(opts.repo, "repo required")
    o.folder = assert(opts.folder, "folder required")
    o.title = opts.title or opts.folder
    o.plugin_dir = SELF_DIR
    return o
end

function Updater:getInstalledVersion()
    if self._installed_version then return self._installed_version end
    local ok, meta = pcall(dofile, self.plugin_dir .. "/_meta.lua")
    self._installed_version = ok and type(meta) == "table" and meta.version or "0"
    return self._installed_version
end

---------------------------------------------------------------------------
-- Networking
---------------------------------------------------------------------------

local function decodeJson(text)
    local ok, json = pcall(require, "rapidjson")
    if not ok then
        ok, json = pcall(require, "json")
    end
    if not ok then return nil, "no JSON decoder" end
    local ok_decode, data = pcall(json.decode, text)
    if not ok_decode or type(data) ~= "table" then
        return nil, _("GitHub sent an unexpected response.")
    end
    return data
end

-- Performs a GET request. `sink` is an ltn12 sink; returns true or nil, err.
local function httpGet(url, sink, accept)
    local http = require("socket.http")
    local socket = require("socket")
    local socketutil = require("socketutil")

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request {
        url = url,
        method = "GET",
        sink = sink,
        headers = {
            ["User-Agent"] = socketutil.USER_AGENT or "KOReader",
            ["Accept"] = accept or "*/*",
        },
    })
    socketutil:reset_timeout()

    if code == 200 then return true end
    if code == 403 and headers and headers["x-ratelimit-remaining"] == "0" then
        return nil, _("GitHub's hourly request limit was reached. Please try again later.")
    end
    if code == 404 then
        return nil, _("Not found on GitHub."), 404
    end
    logger.warn("Updater: GET failed", code, status)
    return nil, tostring(status or code or _("network error"))
end

local function getJson(url)
    local ltn12 = require("ltn12")
    local chunks = {}
    local ok, err, code = httpGet(url, ltn12.sink.table(chunks), "application/vnd.github+json")
    if not ok then return nil, err, code end
    return decodeJson(table.concat(chunks))
end

local function urlEncodePath(s)
    return (s:gsub("[^%w%-%._~/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function Updater:fetchLatestRelease()
    local data, err, code = getJson("https://api.github.com/repos/" .. self.repo .. "/releases/latest")
    if code == 404 then return nil, _("No published release was found.") end
    if not data then return nil, err end
    if type(data.tag_name) ~= "string" then
        return nil, _("No published release was found.")
    end
    return {
        tag = data.tag_name,
        version = data.tag_name:gsub("^[vV]", ""),
        notes = type(data.body) == "string" and data.body or "",
    }
end

-- Returns the list of repository paths under the plugin folder at `tag`.
function Updater:fetchFileList(tag)
    local url = "https://api.github.com/repos/" .. self.repo
        .. "/git/trees/" .. urlEncodePath(tag) .. "?recursive=1"
    local data, err = getJson(url)
    if not data then return nil, err end
    if data.truncated then
        return nil, _("The release file list was too large to read.")
    end
    local prefix = self.folder .. "/"
    local files = {}
    for _i, entry in ipairs(data.tree or {}) do
        if entry.type == "blob" and entry.path:sub(1, #prefix) == prefix then
            files[#files + 1] = entry.path:sub(#prefix + 1)
        end
    end
    if #files == 0 then
        return nil, _("The release does not contain the plugin folder.")
    end
    return files
end

---------------------------------------------------------------------------
-- Install
---------------------------------------------------------------------------

local function dirExists(lfs, path)
    return lfs.attributes(path, "mode") == "directory"
end

local function purge(lfs, path)
    if lfs.attributes(path, "mode") then
        local ok, err = require("ffi/util").purgeDir(path)
        if not ok then return nil, err end
    end
    return true
end

function Updater:installRelease(release)
    local lfs = require("libs/libkoreader-lfs")
    local ltn12 = require("ltn12")
    local util = require("util")

    local files, err = self:fetchFileList(release.tag)
    if not files then return nil, err end

    local target = self.plugin_dir
    local staging = target .. ".update"
    local backup = target .. ".old"

    -- Staging sits next to the plugin so the final swap is a same-filesystem
    -- rename. Its name does not end in ".koplugin", so KOReader ignores it.
    local ok
    ok, err = purge(lfs, staging)
    if not ok then return nil, err end

    local raw_base = "https://raw.githubusercontent.com/" .. self.repo
        .. "/" .. urlEncodePath(release.tag) .. "/" .. urlEncodePath(self.folder) .. "/"

    for _i, rel in ipairs(files) do
        if rel:find("%.%.") then
            purge(lfs, staging)
            return nil, _("Unexpected file path in release.")
        end
        local dest = staging .. "/" .. rel
        local parent = dest:match("^(.*)/")
        if parent and not dirExists(lfs, parent) then
            util.makePath(parent)
        end
        local fh = io.open(dest, "wb")
        if not fh then
            purge(lfs, staging)
            return nil, _("Could not write to the plugins folder.")
        end
        ok, err = httpGet(raw_base .. urlEncodePath(rel), ltn12.sink.file(fh))
        -- ltn12.sink.file closes the handle when the transfer completes; close
        -- it here too in case the request failed before any data arrived.
        pcall(fh.close, fh)
        if not ok then
            purge(lfs, staging)
            return nil, err
        end
    end

    -- Refuse to install anything that will not load.
    if not lfs.attributes(staging .. "/main.lua", "mode")
            or not lfs.attributes(staging .. "/_meta.lua", "mode") then
        purge(lfs, staging)
        return nil, _("The downloaded release is incomplete.")
    end
    for _i, rel in ipairs(files) do
        if rel:match("%.lua$") then
            local chunk, perr = loadfile(staging .. "/" .. rel)
            if not chunk then
                logger.warn("Updater: downloaded file failed to parse", rel, perr)
                purge(lfs, staging)
                return nil, _("A downloaded file was damaged. Nothing was changed.")
            end
        end
    end

    -- Swap folders, rolling back if the second rename fails.
    purge(lfs, backup)
    ok, err = os.rename(target, backup)
    if not ok then
        purge(lfs, staging)
        return nil, err
    end
    ok, err = os.rename(staging, target)
    if not ok then
        os.rename(backup, target)
        purge(lfs, staging)
        return nil, err
    end
    purge(lfs, backup)
    self._installed_version = nil
    return true
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function showText(text, timeout)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new { text = text, timeout = timeout })
end

-- Shows a "please wait" message, runs fn, closes the message, returns fn's results.
local function withBusyMessage(text, fn)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local busy = InfoMessage:new { text = text }
    UIManager:show(busy)
    UIManager:forceRePaint()
    local results = { pcall(fn) }
    UIManager:close(busy)
    if not results[1] then
        logger.warn("Updater: unexpected error", results[2])
        return nil, tostring(results[2])
    end
    return results[2], results[3]
end

local function shortenNotes(notes)
    notes = notes:gsub("\r", ""):gsub("\n\n+", "\n\n")
    if #notes > 600 then
        notes = notes:sub(1, 600):gsub("[^\n]*$", "") .. "…"
    end
    return notes
end

function Updater:doInstall(release)
    local UIManager = require("ui/uimanager")
    local T = require("ffi/util").template
    local ok, err = withBusyMessage(_("Downloading update…"), function()
        return self:installRelease(release)
    end)
    if not ok then
        showText(T(_("Update failed: %1\n\nThe installed version was not changed."), tostring(err)))
        return
    end
    UIManager:askForRestart(T(
        _("%1 was updated to %2.\n\nRestart KOReader to finish."), self.title, release.version))
end

function Updater:checkForUpdates()
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        local T = require("ffi/util").template

        local release, err = withBusyMessage(_("Checking for updates…"), function()
            return self:fetchLatestRelease()
        end)
        if not release then
            showText(T(_("Could not check for updates: %1"), tostring(err)))
            return
        end

        local installed = self:getInstalledVersion()
        local cmp = Updater.compareVersions(release.version, installed)

        if cmp and cmp <= 0 then
            UIManager:show(ConfirmBox:new {
                text = T(_("%1 is up to date (%2)."), self.title, installed),
                ok_text = _("Reinstall"),
                cancel_text = _("Close"),
                ok_callback = function() self:doInstall(release) end,
            })
            return
        end

        local notes = shortenNotes(release.notes)
        UIManager:show(ConfirmBox:new {
            text = T(_("%1 %2 is available.\nInstalled: %3"), self.title, release.version, installed)
                .. (notes ~= "" and ("\n\n" .. notes) or ""),
            ok_text = _("Update"),
            ok_callback = function() self:doInstall(release) end,
        })
    end)
end

--- Menu entry to drop into a plugin's sub_item_table.
function Updater:getMenuItem()
    local T = require("ffi/util").template
    return {
        text_func = function()
            return T(_("Check for updates (installed: %1)"), self:getInstalledVersion())
        end,
        keep_menu_open = true,
        callback = function()
            self:checkForUpdates()
        end,
    }
end

return Updater
