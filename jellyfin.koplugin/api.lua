--[[--
Jellyfin API client
@module koplugin.jellyfin.api
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
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

local function performRequest(request)
    -- Keep the actual transport identical to the original Jellyfin plugin:
    -- socket.http.request() handles both HTTP and HTTPS in KOReader.
    --
    -- Do not change KOReader's global socket timeouts here. On older/low-power
    -- Kindle builds, doing so caused otherwise-working Jellyfin requests to
    -- stall until the imposed timeout expired.
    local ok_request, result, code, headers, status =
        pcall(http.request, request)

    if not ok_request then
        logger.warn(
            "Jellyfin API: request failed:",
            tostring(result)
        )
        return nil, nil, nil, tostring(result)
    end

    return result, code, headers, status
end

function API:diagnoseConnection()
    local server = self.config:getServerUrl()
    if not server or server == "" then
        return {
            ok = false,
            lines = { "Server URL: not configured" },
        }
    end

    local socket = require("socket")
    local parsed = url.parse(server) or {}
    local scheme = (parsed.scheme or ""):lower()
    local host = parsed.host
    local port = tonumber(parsed.port)
        or (scheme == "https" and 443 or 80)

    local lines = {}
    local all_ok = true

    local function add(label, ok_value, detail)
        if not ok_value then
            all_ok = false
        end
        lines[#lines + 1] =
            label
            .. ": "
            .. (ok_value and "OK" or "FAIL")
            .. (detail and (" (" .. tostring(detail) .. ")") or "")
    end

    if not host or host == "" then
        add("URL parse", false, "missing hostname")
        return { ok = false, lines = lines }
    end

    add("URL parse", true, scheme .. " / port " .. tostring(port))

    -- 1) DNS resolution.
    local dns_started = socket.gettime and socket.gettime() or os.time()
    local ok_dns, ip_or_error =
        pcall(socket.dns.toip, host)
    local dns_elapsed =
        (socket.gettime and socket.gettime() or os.time())
        - dns_started

    local resolved_ip =
        ok_dns and ip_or_error or nil

    add(
        "DNS",
        resolved_ip ~= nil,
        resolved_ip
            and (tostring(resolved_ip) .. string.format(", %.1fs", dns_elapsed))
            or (tostring(ip_or_error) .. string.format(", %.1fs", dns_elapsed))
    )

    -- 2) Plain TCP reachability to the configured port.
    local tcp = socket.tcp()
    if tcp then
        tcp:settimeout(8)
        local tcp_started =
            socket.gettime and socket.gettime() or os.time()
        local ok_tcp, tcp_error =
            tcp:connect(host, port)
        local tcp_elapsed =
            (socket.gettime and socket.gettime() or os.time())
            - tcp_started
        pcall(tcp.close, tcp)

        add(
            "TCP",
            ok_tcp and true or false,
            ok_tcp
                and string.format("%.1fs", tcp_elapsed)
                or (tostring(tcp_error) .. string.format(", %.1fs", tcp_elapsed))
        )
    else
        add("TCP", false, "socket unavailable")
    end

    local public_url =
        server:gsub("/$", "")
        .. "/System/Info/Public"

    -- 3) Storefront-style scheme-specific request. This distinguishes a TLS
    -- issue from the plugin's historical socket.http transport behavior.
    local socketutil = require("socketutil")
    local direct_module = http
    if scheme == "https" then
        local ok_https, https =
            pcall(require, "ssl.https")
        if ok_https and https then
            direct_module = https
        else
            add("TLS module", false, "ssl.https unavailable")
            return { ok = false, lines = lines }
        end
    end

    socketutil:set_timeout(10, 20)
    local direct_body = {}
    local direct_started =
        socket.gettime and socket.gettime() or os.time()
    local ok_direct, direct_result, direct_code =
        pcall(
            direct_module.request,
            {
                url = public_url,
                method = "GET",
                headers = {
                    ["Accept"] = "application/json",
                    ["Connection"] = "close",
                },
                sink = ltn12.sink.table(direct_body),
            }
        )
    local direct_elapsed =
        (socket.gettime and socket.gettime() or os.time())
        - direct_started
    socketutil:reset_timeout()

    local direct_status =
        ok_direct and tonumber(direct_code) or nil
    add(
        scheme == "https" and "TLS/HTTPS" or "HTTP direct",
        direct_status ~= nil
            and direct_status >= 200
            and direct_status < 500,
        ok_direct
            and (tostring(direct_code) .. string.format(", %.1fs", direct_elapsed))
            or (tostring(direct_result) .. string.format(", %.1fs", direct_elapsed))
    )

    -- 4) The exact transport used by the Jellyfin plugin. Keep a temporary
    -- diagnostic timeout so this menu item cannot block for two minutes.
    socketutil:set_timeout(10, 20)
    local plugin_body = {}
    local plugin_started =
        socket.gettime and socket.gettime() or os.time()
    local plugin_result, plugin_code, _, plugin_status =
        performRequest({
            url = public_url,
            method = "GET",
            headers = {
                ["Accept"] = "application/json",
                ["Connection"] = "close",
            },
            sink = ltn12.sink.table(plugin_body),
        })
    local plugin_elapsed =
        (socket.gettime and socket.gettime() or os.time())
        - plugin_started
    socketutil:reset_timeout()

    local plugin_http_code = tonumber(plugin_code)
    add(
        "Jellyfin transport",
        plugin_http_code ~= nil
            and plugin_http_code >= 200
            and plugin_http_code < 500,
        plugin_http_code
            and (tostring(plugin_http_code) .. string.format(", %.1fs", plugin_elapsed))
            or (
                tostring(plugin_status or plugin_code or plugin_result)
                .. string.format(", %.1fs", plugin_elapsed)
            )
    )

    logger.info(
        "Jellyfin diagnostic:",
        table.concat(lines, " | ")
    )

    return {
        ok = all_ok,
        lines = lines,
    }
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
        'MediaBrowser Client="KOReader", Device="eReader", DeviceId="%s", Version="1.0.0"',
        self.config:getDeviceId()
    )

    local token = self.config:getAccessToken()
    if token and token ~= "" then
        header = header .. string.format(', Token="%s"', token)
    end

    return header
end

function API:authenticateByPassword(username, password)
    local auth_url = self.config:getServerUrl() .. "/Users/AuthenticateByName"
    local auth_data = json.encode({
        Username = username,
        Pw = password,
    })

    local response_body = {}

    -- Intentionally identical to the official KOReader Jellyfin plugin.
    local res, code = http.request {
        url = auth_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#auth_data),
            ["Authorization"] = self:getAuthHeader(),
        },
        source = ltn12.source.string(auth_data),
        sink = ltn12.sink.table(response_body),
    }

    if code == 200 then
        local ok_decode, response = pcall(
            json.decode,
            table.concat(response_body)
        )
        if ok_decode and response then
            return true, response
        end
        return false, "parse_error"
    end

    return false, code or res or "network_error"
end

function API:initiateQuickConnect()
    local qc_url = self.config:getServerUrl() .. "/QuickConnect/Initiate"
    local response_body = {}

    local res, code = http.request {
        url = qc_url,
        method = "POST",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = ltn12.sink.table(response_body),
    }

    if code == 200 then
        local ok_decode, response =
            pcall(json.decode, table.concat(response_body))
        if ok_decode and response then
            return true, response
        end
        return false, "parse_error"
    end
    return false, code or res or "network_error"
end

function API:checkQuickConnect(secret)
    local check_url =
        self.config:getServerUrl()
        .. "/QuickConnect/Connect?secret="
        .. tostring(secret or "")
    local response_body = {}

    local res, code = http.request {
        url = check_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = ltn12.sink.table(response_body),
    }

    if code == 200 then
        local ok_decode, response =
            pcall(json.decode, table.concat(response_body))
        if ok_decode and response then
            return true, response
        end
        return false, "parse_error"
    end
    return false, code or res or "network_error"
end

function API:authenticateWithQuickConnect(secret)
    local auth_url =
        self.config:getServerUrl()
        .. "/Users/AuthenticateWithQuickConnect"
    local auth_data = json.encode({
        Secret = secret,
    })
    local response_body = {}

    local res, code = http.request {
        url = auth_url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#auth_data),
            ["Authorization"] = self:getAuthHeader(),
        },
        source = ltn12.source.string(auth_data),
        sink = ltn12.sink.table(response_body),
    }

    if code == 200 then
        local ok_decode, response =
            pcall(json.decode, table.concat(response_body))
        if ok_decode and response then
            return true, response
        end
        return false, "parse_error"
    end
    return false, code or res or "network_error"
end

function API:getUserViews()
    local user_id = self.config:getUserId()
    local server = self.config:getServerUrl()

    -- Use the exact route used by the official plugin first. Jellyfin 12 still
    -- supports it, and this is the path proven on the target Kindle.
    local legacy_url =
        server
        .. "/Users/"
        .. url.escape(user_id or "")
        .. "/Views"

    local response_body = {}
    logger.info("Jellyfin API: Request URL:", legacy_url)

    local res, code = http.request {
        url = legacy_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = ltn12.sink.table(response_body),
    }

    logger.info("Jellyfin API: Views response code:", code)

    if code == 200 then
        local response = decodeBody(response_body)
        if response and type(response.Items) == "table" then
            return true, response
        end
        return false, "parse_error"
    end

    -- Only use Jellyfin 12's newer route as a compatibility fallback.
    if code == 404 or code == 405 then
        local current_url =
            server
            .. "/UserViews?userId="
            .. url.escape(user_id or "")
        local current_body = {}

        local result, current_code, _, status =
            performRequest({
                url = current_url,
                method = "GET",
                headers = {
                    ["Authorization"] = self:getAuthHeader(),
                },
                sink = ltn12.sink.table(current_body),
            })

        if isSuccess(current_code) then
            local response = decodeBody(current_body)
            if response and type(response.Items) == "table" then
                return true, response
            end
            return false, "parse_error"
        end

        return false,
            requestError(result, current_code, status)
    end

    return false, code or res or "network_error"
end

function API:getItemsInLibrary(library_id, search_term, start_index, limit, include_total_count)
    local server = self.config:getServerUrl()
    local user_id = url.escape(self.config:getUserId())
    local params =
        "ParentId="
        .. url.escape(library_id or "")
        .. "&Recursive=true"
        .. "&Fields=People"
        .. "&IncludeItemTypes=Book,Audio,AudioBook"
        .. "&EnableUserData=true"
        .. "&EnableTotalRecordCount="
        .. (include_total_count == false and "false" or "true")
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

    if start_index and start_index >= 0 then
        params =
            params
            .. "&StartIndex="
            .. tostring(math.floor(start_index))
    end

    if limit and limit > 0 then
        params =
            params
            .. "&Limit="
            .. tostring(math.floor(limit))
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
            sink = ltn12.sink.table(response_body),
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
            sink = ltn12.sink.table(response_body),
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

    local file_sink = ltn12.sink.file(file)
    local downloaded_size = 0
    local last_progress_report = 0
    local progress_step = 512 * 1024

    -- Avoid running a Lua callback for every small network chunk. On slower
    -- e-readers that can become surprisingly expensive during large M4B
    -- transfers. Report at most once per 512 KiB plus a final update.
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
    })

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
        sink = ltn12.sink.file(file),
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
        sink = ltn12.sink.table({}),
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
                sink = ltn12.sink.table({}),
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
