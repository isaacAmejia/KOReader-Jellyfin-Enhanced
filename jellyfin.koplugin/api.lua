--[[--
Jellyfin API client
@module koplugin.jellyfin.api
]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local logger = require("logger")

-- JSON library with fallback.
local json
local ok = pcall(function() json = require("json") end)
if not ok then
    json = require("rapidjson")
end

local API = {}

local function isSuccess(code)
    return type(code) == "number" and code >= 200 and code < 300
end

local function decodeBody(response_body)
    local ok_decode, response = pcall(
        json.decode,
        table.concat(response_body or {})
    )

    if ok_decode and type(response) == "table" then
        return response
    end

    return nil
end

local function requestError(result, code, status)
    if code ~= nil then return code end
    if status ~= nil then return status end
    if result ~= nil then return result end
    return "network_error"
end

local function performRequest(request, is_file_transfer)
    local requester =
        request.url:match("^https://")
        and https
        or http

    if is_file_transfer then
        -- Large ebooks/audiobooks may legitimately take longer than a minute.
        -- Keep a per-block timeout, but do not impose a total transfer timeout.
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, -1)
    else
        socketutil:set_timeout(10, 30)
    end

    local ok_request, result, code, headers, status =
        pcall(requester.request, request)

    socketutil:reset_timeout()

    if not ok_request then
        logger.warn("Jellyfin API: request failed:", tostring(result))
        return nil, nil, nil, tostring(result)
    end

    return result, code, headers, status
end

function API:new(config)
    local o = {
        config = config,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function API:getAuthHeader()
    local header = string.format(
        'MediaBrowser Client="KOReader", Device="eReader", DeviceId="%s", Version="2.0.0"',
        self.config:getDeviceId()
    )

    local token = self.config:getAccessToken()
    if token and token ~= "" then
        header = header .. string.format(', Token="%s"', token)
    end

    return header
end

function API:authenticateByPassword(username, password)
    local auth_url =
        self.config:getServerUrl()
        .. "/Users/AuthenticateByName"

    local auth_data = json.encode({
        Username = username,
        Pw = password,
    })

    local response_body = {}

    local result, code, _, status = performRequest({
        url = auth_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#auth_data),
            ["Authorization"] = self:getAuthHeader(),
        },
        source = ltn12.source.string(auth_data),
        sink = socketutil.table_sink(response_body),
    })

    if isSuccess(code) then
        local response = decodeBody(response_body)
        if response
                and response.AccessToken
                and response.User
                and response.User.Id
        then
            return true, response
        end
        return false, "parse_error"
    end

    return false, requestError(result, code, status)
end

function API:initiateQuickConnect()
    local qc_url =
        self.config:getServerUrl()
        .. "/QuickConnect/Initiate"

    local response_body = {}

    local result, code, _, status = performRequest({
        url = qc_url,
        method = "POST",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
            ["Content-Length"] = "0",
        },
        sink = socketutil.table_sink(response_body),
    })

    if isSuccess(code) then
        local response = decodeBody(response_body)
        if response and response.Code and response.Secret then
            return true, response
        end
        return false, "parse_error"
    end

    return false, requestError(result, code, status)
end

function API:checkQuickConnect(secret)
    local check_url =
        self.config:getServerUrl()
        .. "/QuickConnect/Connect?secret="
        .. url.escape(secret or "")

    local response_body = {}

    local result, code, _, status = performRequest({
        url = check_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = socketutil.table_sink(response_body),
    })

    if isSuccess(code) then
        local response = decodeBody(response_body)
        if response then
            return true, response
        end
        return false, "parse_error"
    end

    return false, requestError(result, code, status)
end

function API:authenticateWithQuickConnect(secret)
    local auth_url =
        self.config:getServerUrl()
        .. "/Users/AuthenticateWithQuickConnect"

    local auth_data = json.encode({
        Secret = secret,
    })

    local response_body = {}

    local result, code, _, status = performRequest({
        url = auth_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#auth_data),
            ["Authorization"] = self:getAuthHeader(),
        },
        source = ltn12.source.string(auth_data),
        sink = socketutil.table_sink(response_body),
    })

    if isSuccess(code) then
        local response = decodeBody(response_body)
        if response
                and response.AccessToken
                and response.User
                and response.User.Id
        then
            return true, response
        end
        return false, "parse_error"
    end

    return false, requestError(result, code, status)
end

function API:getUserViews()
    local user_id = self.config:getUserId()

    local views_url =
        self.config:getServerUrl()
        .. "/Users/"
        .. url.escape(user_id)
        .. "/Views"

    local response_body = {}

    logger.info("Jellyfin API: Fetching user libraries")

    local result, code, _, status = performRequest({
        url = views_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = socketutil.table_sink(response_body),
    })

    logger.info("Jellyfin API: Views response code:", code)

    if isSuccess(code) then
        local response = decodeBody(response_body)
        if response and type(response.Items) == "table" then
            return true, response
        end
        return false, "parse_error"
    end

    return false, requestError(result, code, status)
end

function API:getItemsInLibrary(library_id, search_term)
    local items_url =
        self.config:getServerUrl()
        .. "/Users/"
        .. url.escape(self.config:getUserId())
        .. "/Items"
        .. "?ParentId="
        .. url.escape(library_id or "")
        .. "&Recursive=true"
        .. "&Fields=Path,MediaSources,People,Overview"
        .. "&IncludeItemTypes=Book,Audio,AudioBook"

    if search_term and search_term ~= "" then
        items_url =
            items_url
            .. "&SearchTerm="
            .. url.escape(search_term)
    end

    logger.info("Jellyfin API: Fetching library items")

    local response_body = {}

    local result, code, _, status = performRequest({
        url = items_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = socketutil.table_sink(response_body),
    })

    logger.info("Jellyfin API: Items response code:", code)

    if isSuccess(code) then
        local response = decodeBody(response_body)
        if response and type(response.Items) == "table" then
            return true, response
        end
        return false, "parse_error"
    end

    return false, requestError(result, code, status)
end

function API:downloadItem(item_id, filepath, progress_callback)
    local download_url =
        self.config:getServerUrl()
        .. "/Items/"
        .. url.escape(item_id or "")
        .. "/Download"

    local file, file_error = io.open(filepath, "wb")
    if not file then
        logger.warn(
            "Jellyfin API: Could not create download file:",
            tostring(file_error)
        )
        return false, "file_error", 0
    end

    local file_sink = socketutil.file_sink(file)
    local sink = file_sink

    if progress_callback then
        sink = socketutil.chainSinkWithProgressCallback(
            file_sink,
            function(downloaded)
                local ok_progress, progress_error =
                    pcall(progress_callback, downloaded)

                if not ok_progress then
                    logger.warn(
                        "Jellyfin API: progress callback failed:",
                        tostring(progress_error)
                    )
                end
            end
        )
    end

    local result, code, _, status = performRequest({
        url = download_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
            ["Accept-Encoding"] = "identity",
        },
        sink = sink,
    }, true)

    if io.type(file) == "file" then
        file:close()
    end

    if isSuccess(code) then
        local size = 0
        local reopened = io.open(filepath, "rb")
        if reopened then
            size = reopened:seek("end") or 0
            reopened:close()
        end
        return true, nil, size
    end

    os.remove(filepath)
    return false, requestError(result, code, status), 0
end

function API:downloadBookCover(item_id, filepath)
    local cover_url =
        self.config:getServerUrl()
        .. "/Items/"
        .. url.escape(item_id or "")
        .. "/Images/Primary?maxWidth=400&format=Jpg"

    local file, file_error = io.open(filepath, "wb")
    if not file then
        logger.warn(
            "Jellyfin API: Could not create cover file:",
            tostring(file_error)
        )
        return false, "file_error"
    end

    local result, code, _, status = performRequest({
        url = cover_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
            ["Accept-Encoding"] = "identity",
        },
        sink = socketutil.file_sink(file),
    }, true)

    if io.type(file) == "file" then
        file:close()
    end

    if isSuccess(code) then
        return true
    end

    os.remove(filepath)
    return false, requestError(result, code, status)
end

function API:setPlayedStatus(item_id, played)
    local method = played and "POST" or "DELETE"

    -- Current Jellyfin route.
    local status_url =
        self.config:getServerUrl()
        .. "/UserPlayedItems/"
        .. url.escape(item_id or "")

    local result, code, _, status = performRequest({
        url = status_url,
        method = method,
        headers = {
            ["Authorization"] = self:getAuthHeader(),
            ["Content-Length"] = "0",
        },
        sink = socketutil.table_sink({}),
    })

    if isSuccess(code) then
        return true, code
    end

    -- Older Jellyfin versions expose the same operation under the
    -- user-scoped PlayedItems route.
    if code == 404 or code == 405 then
        local legacy_url =
            self.config:getServerUrl()
            .. "/Users/"
            .. url.escape(self.config:getUserId())
            .. "/PlayedItems/"
            .. url.escape(item_id or "")

        local legacy_result, legacy_code, _, legacy_status =
            performRequest({
                url = legacy_url,
                method = method,
                headers = {
                    ["Authorization"] = self:getAuthHeader(),
                    ["Content-Length"] = "0",
                },
                sink = socketutil.table_sink({}),
            })

        return isSuccess(legacy_code),
            requestError(
                legacy_result,
                legacy_code,
                legacy_status
            )
    end

    return false, requestError(result, code, status)
end

return API
