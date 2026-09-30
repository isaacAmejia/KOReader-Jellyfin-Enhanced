--[[--
Enhanced Jellyfin plugin for KOReader.

Based on KOReader-Jellyfin-Plugin by Declan Chidlow (Vale).
This modified version adds an expanded library UI, search, audiobook downloads,
sidecar artwork, and Dispatcher integration while preserving the original
Jellyfin authentication and reading-status workflow.

@module koplugin.jellyfin
--]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local logger = require("logger")
local _ = require("gettext")

-- Load our own modules by absolute plugin-relative path instead of generic
-- require("config") / require("api") names. Third-party KOReader plugins share
-- Lua's module cache and search path, so generic names can collide.
local PLUGIN_DIR =
    (debug.getinfo(1, "S").source or ""):match("^@(.*/)") or "./"

-- Configuration is intentionally the only Jellyfin submodule loaded at
-- startup. Networking, authentication widgets, and the larger browser UI are
-- loaded on first use so simply enabling this plugin has a very small startup
-- and memory cost on low-end e-readers.
local Config = dofile(PLUGIN_DIR .. "config.lua")

local Jellyfin = WidgetContainer:extend {
    name = "jellyfin",
    is_doc_only = false,
}

function Jellyfin:getAPI()
    if not self.api then
        local API = dofile(PLUGIN_DIR .. "api.lua")
        self.api = API:new(Config)
    end
    return self.api
end

function Jellyfin:getAuth()
    if not self.auth then
        local Auth = dofile(PLUGIN_DIR .. "auth.lua")
        self.auth = Auth:new(
            Config,
            self:getAPI()
        )
    end
    return self.auth
end

function Jellyfin:getUI()
    if not self.ui_handler then
        local UI = dofile(PLUGIN_DIR .. "ui.lua")
        self.ui_handler = UI:new(
            Config,
            self:getAPI()
        )
    end
    return self.ui_handler
end

local function showInfo(text)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    UIManager:show(InfoMessage:new {
        text = text,
    })
end

function Jellyfin:onDispatcherRegisterActions()
    Dispatcher:registerAction(
        "jellyfin_browse_books",
        {
            category = "none",
            event = "JellyfinBrowseBooks",
            title = _("Jellyfin: Browse Books"),
            general = true,
        }
    )
end

function Jellyfin:init()
    logger.info("Jellyfin: Initialising plugin")
    Config:initialize()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    logger.info("Jellyfin: Plugin initialised")
end

function Jellyfin:onJellyfinBrowseBooks()
    if not Config:isLoggedIn() then
        showInfo(_(
            "Jellyfin is not logged in.\n\n"
            .. "Open Tools > Jellyfin Books, configure your server, and log in first."
        ))
        return
    end

    self:getUI():browseBooks()
end

function Jellyfin:addToMainMenu(menu_items)
    menu_items.jellyfin = {
        text = _("Jellyfin Books"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Configure Server"),
                keep_menu_open = true,
                callback = function()
                    self:getUI():configureServer()
                end,
            },
            {
                text = _("Login"),
                sub_item_table = {
                    {
                        text = _("Login with Password"),
                        callback = function()
                            self:getAuth():loginWithPassword()
                        end,
                    },
                    {
                        text = _("Login with Quick Connect"),
                        callback = function()
                            self:getAuth():loginWithQuickConnect()
                        end,
                    },
                },
            },
            {
                text = _("Browse Books"),
                enabled_func = function()
                    return Config:isLoggedIn()
                end,
                callback = function()
                    self:getUI():browseBooks()
                end,
            },
            {
                text = _("Logout"),
                enabled_func = function()
                    return Config:isLoggedIn()
                end,
                callback = function()
                    self:getAuth():logout()
                end,
            },
        },
    }
end

return Jellyfin
