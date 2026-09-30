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
    local server = self.config:getServerUrl()

    -- Jellyfin 12's current endpoint. Keep the legacy user-scoped route as
    -- a fallback for older servers.
    local urls = {
        server
            .. "/UserViews?userId="
            .. url.escape(user_id),
        server
            .. "/Users/"
            .. url.escape(user_id)
            .. "/Views",
    }

    logger.info("Jellyfin API: Fetching user libraries")

    local last_error = "network_error"

    for index, views_url in ipairs(urls) do
        local response_body = {}

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

        last_error = requestError(result, code, status)

        -- Only try the legacy endpoint when the current route is not present
        -- or not accepted. Authentication/permission failures should surface.
        if index == 1 and code ~= 404 and code ~= 405 then
            break
        end
    end

    return false, last_error
end

function API:getItemsInLibrary(library_id, search_term)
    local server = self.config:getServerUrl()
    local user_id = url.escape(self.config:getUserId())
    local params =
        "ParentId="
        .. url.escape(library_id or "")
        .. "&Recursive=true"
        .. "&Fields=People"
        .. "&IncludeItemTypes=Book,Audio,AudioBook"
        .. "&EnableUserData=true"
        .. "&EnableTotalRecordCount=true"
        .. "&EnableImages=true"
        .. "&ImageTypeLimit=1"
        .. "&EnableImageTypes=Primary"
        .. "&SortBy=SortName"
        .. "&SortOrder=Ascending"

    if search_term and search_term ~= "" then
        params =
            params
            .. "&SearchTerm="
            .. url.escape(search_term)
    end

    -- Jellyfin 12's current endpoint first, then the retained legacy route.
    local urls = {
        server
            .. "/Items?userId="
            .. user_id
            .. "&"
            .. params,
        server
            .. "/Users/"
            .. user_id
            .. "/Items?"
            .. params,
    }

    logger.info("Jellyfin API: Fetching library items")

    local last_error = "network_error"

    for index, items_url in ipairs(urls) do
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

        last_error = requestError(result, code, status)

        if index == 1 and code ~= 404 and code ~= 405 then
            break
        end
    end

    return false, last_error
end

function API:getItemDetails(item_id)
    local server = self.config:getServerUrl()
    local user_id = url.escape(self.config:getUserId())
    local escaped_item_id = url.escape(item_id or "")
    local fields = "Path,MediaSources,People,Overview"

    local urls = {
        server
            .. "/Items/"
            .. escaped_item_id
            .. "?userId="
            .. user_id
            .. "&Fields="
            .. fields,
        server
            .. "/Users/"
            .. user_id
            .. "/Items/"
            .. escaped_item_id,
    }

    local last_error = "network_error"

    for index, item_url in ipairs(urls) do
        local response_body = {}

        local result, code, _, status = performRequest({
            url = item_url,
            method = "GET",
            headers = {
                ["Authorization"] = self:getAuthHeader(),
            },
            sink = socketutil.table_sink(response_body),
        })

        if isSuccess(code) then
            local response = decodeBody(response_body)
            if response and response.Id then
                return true, response
            end
            return false, "parse_error"
        end

        last_error = requestError(result, code, status)

        if index == 1 and code ~= 404 and code ~= 405 then
            break
        end
    end

    return false, last_error
end

function API:downloadItem(item_id, filepath, progress_callback)
    local download_url =
        self.config:getServerUrl()
        .. "/Items/"
        .. url.escape(item_id or "")
        .. "/Download"

    -- Never expose an incomplete transfer under the final filename.
    local temp_path = filepath .. ".part"
    os.remove(temp_path)

    local file, file_error = io.open(temp_path, "wb")
    if not file then
        logger.warn(
            "Jellyfin API: Could not create temporary download file:",
            tostring(file_error)
        )
        return false, "file_error", 0
    end

    local file_sink = socketutil.file_sink(file)
    local downloaded_size = 0
    local last_progress_report = 0
    local progress_step = 512 * 1024

    -- Avoid running a Lua callback for every small network chunk. On slower
    -- e-readers that can become surprisingly expensive during large M4B
    -- transfers. Report at most once per 256 KiB plus a final update.
    local sink = function(chunk, err)
        if chunk then
            downloaded_size = downloaded_size + #chunk

            if progress_callback
                    and downloaded_size - last_progress_report >= progress_step
            then
                last_progress_report = downloaded_size
                local ok_progress, progress_error =
                    pcall(progress_callback, downloaded_size)

                if not ok_progress then
                    logger.warn(
                        "Jellyfin API: progress callback failed:",
                        tostring(progress_error)
                    )
                end
            end
        end

        return file_sink(chunk, err)
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

    if not isSuccess(code) then
        os.remove(temp_path)
        return false, requestError(result, code, status), 0
    end

    if progress_callback
            and downloaded_size > last_progress_report
    then
        pcall(progress_callback, downloaded_size)
    end

    -- On the Unix-like platforms supported by KOReader, rename is atomic
    -- when source and destination are on the same filesystem. The temp file
    -- lives beside the final file specifically to preserve that property.
    local renamed, rename_error =
        os.rename(temp_path, filepath)

    if not renamed then
        logger.warn(
            "Jellyfin API: Could not finalize download:",
            tostring(rename_error)
        )
        os.remove(temp_path)
        return false, "file_error", downloaded_size
    end

    return true, nil, downloaded_size
end

function API:downloadBookCover(item_id, filepath)
    local cover_url =
        self.config:getServerUrl()
        .. "/Items/"
        .. url.escape(item_id or "")
        .. "/Images/Primary?maxWidth=320&quality=85&format=Jpg"

    local temp_path = filepath .. ".part"
    os.remove(temp_path)

    local file, file_error = io.open(temp_path, "wb")
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
    })

    if io.type(file) == "file" then
        file:close()
    end

    if not isSuccess(code) then
        os.remove(temp_path)
        return false, requestError(result, code, status)
    end

    local renamed, rename_error =
        os.rename(temp_path, filepath)

    if not renamed then
        logger.warn(
            "Jellyfin API: Could not finalize cover:",
            tostring(rename_error)
        )
        os.remove(temp_path)
        return false, "file_error"
    end

    return true
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
