local http = require("socket.http")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socket_url = require("socket.url")

local json
local ok = pcall(function() json = require("json") end)
if not ok then
	json = require("rapidjson")
end

local API = {}

local LOCAL_PROBE_TIMEOUT = 1.5
local SERVER_SELECTION_TTL = 30

function API:new(config)
	local o = {
		config = config,
		server_selection = nil,
	}
	setmetatable(o, self)
	self.__index = self
	return o
end

function API:resetServerSelection()
	self.server_selection = nil
end

function API:isServerReachable(server_url)
	if not server_url or server_url == "" then
		return false
	end

	local parsed = socket_url.parse(server_url)
	if not parsed or not parsed.host then
		return false
	end

	local scheme = (parsed.scheme or "http"):lower()
	local port = tonumber(parsed.port)
		or (scheme == "https" and 443 or 80)

	local tcp = socket.tcp()
	if not tcp then
		return false
	end

	tcp:settimeout(LOCAL_PROBE_TIMEOUT)
	local connected = tcp:connect(parsed.host, port)
	pcall(tcp.close, tcp)

	return connected and true or false
end

function API:getServerUrl()
	local now = socket.gettime and socket.gettime() or os.time()
	local cached = self.server_selection

	if cached
			and cached.url
			and cached.checked_at
			and now - cached.checked_at < SERVER_SELECTION_TTL
	then
		return cached.url
	end

	local local_url = self.config:getLocalServerUrl()
	local external_url = self.config:getServerUrl()
	local selected_url
	local selected_kind

	if local_url ~= "" and self:isServerReachable(local_url) then
		selected_url = local_url
		selected_kind = "local"
	else
		selected_url = external_url
		selected_kind = "external"
	end

	self.server_selection = {
		url = selected_url,
		kind = selected_kind,
		checked_at = now,
	}

	if not cached or cached.kind ~= selected_kind then
		logger.info(
			"Jellyfin API: Using",
			selected_kind,
			"server address"
		)
	end

	return selected_url
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
	local auth_url = self:getServerUrl() .. "/Users/AuthenticateByName"
	local auth_data = json.encode({
		Username = username,
		Pw = password,
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
		local response = json.decode(table.concat(response_body))
		return true, response
	else
		return false, code
	end
end

function API:initiateQuickConnect()
	local qc_url = self:getServerUrl() .. "/QuickConnect/Initiate"
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
		local response = json.decode(table.concat(response_body))
		return true, response
	else
		return false, code
	end
end

function API:checkQuickConnect(secret)
	local check_url = self:getServerUrl() .. "/QuickConnect/Connect?secret=" .. secret
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
		local response = json.decode(table.concat(response_body))
		return true, response
	else
		return false, code
	end
end

function API:authenticateWithQuickConnect(secret)
	local auth_url = self:getServerUrl() .. "/Users/AuthenticateWithQuickConnect"
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
		local response = json.decode(table.concat(response_body))
		return true, response
	else
		return false, code
	end
end

function API:getUserViews()
	local user_id = self.config:getUserId()
	local views_url = self:getServerUrl() .. "/Users/" .. user_id .. "/Views"
	local response_body = {}

	logger.info("Jellyfin API: Request URL:", views_url)

	local res, code = http.request {
		url = views_url,
		method = "GET",
		headers = {
			["Authorization"] = self:getAuthHeader(),
		},
		sink = ltn12.sink.table(response_body),
	}

	logger.info("Jellyfin API: Views response code:", code)

	if code == 200 then
		local ok, response = pcall(json.decode, table.concat(response_body))
		if ok then
			return true, response
		else
			return false, "parse_error"
		end
	else
		return false, code
	end
end


local function escape(value)
    return (tostring(value or ""):gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

function API:getItemsInLibrary(library_id, search_term, start_index, limit, include_total_count)
    local params =
        "ParentId=" .. escape(library_id) ..
        "&Recursive=true" ..
        "&Fields=People" ..
        "&IncludeItemTypes=Book,Audio,AudioBook" ..
        "&EnableUserData=true" ..
        "&EnableTotalRecordCount=" .. (include_total_count == false and "false" or "true") ..
        "&EnableImages=true" ..
        "&ImageTypeLimit=1" ..
        "&EnableImageTypes=Primary" ..
        "&SortBy=SortName" ..
        "&SortOrder=Ascending"

    if search_term and search_term ~= "" then
        params = params .. "&SearchTerm=" .. escape(search_term)
    end
    if start_index and start_index >= 0 then
        params = params .. "&StartIndex=" .. tostring(math.floor(start_index))
    end
    if limit and limit > 0 then
        params = params .. "&Limit=" .. tostring(math.floor(limit))
    end

    -- Keep the same user-scoped route style as the working upstream plugin.
    local items_url =
        self:getServerUrl() ..
        "/Users/" .. escape(self.config:getUserId()) ..
        "/Items?" .. params

    logger.info("Jellyfin API: Fetching items from:", items_url)
    local response_body = {}

    local res, code = http.request {
        url = items_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = ltn12.sink.table(response_body),
    }

    logger.info("Jellyfin API: Items response code:", code)

    if code == 200 then
        local ok_decode, response =
            pcall(json.decode, table.concat(response_body))
        if ok_decode then
            return true, response
        end
        return false, "parse_error"
    end
    return false, code
end

function API:getItemDetails(item_id)
    local item_url =
        self:getServerUrl() ..
        "/Users/" .. escape(self.config:getUserId()) ..
        "/Items/" .. escape(item_id)

    local response_body = {}
    local res, code = http.request {
        url = item_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = ltn12.sink.table(response_body),
    }

    if code == 200 then
        local ok_decode, response =
            pcall(json.decode, table.concat(response_body))
        if ok_decode then
            return true, response
        end
        return false, "parse_error"
    end
    return false, code
end

function API:downloadItem(item_id, filepath, progress_callback)
    local download_url =
        self:getServerUrl() ..
        "/Items/" .. escape(item_id) .. "/Download"
    local temp_path = filepath .. ".part"
    os.remove(temp_path)

    local file = io.open(temp_path, "wb")
    if not file then
        return false, "file_error", 0
    end

    local file_sink = ltn12.sink.file(file)
    local downloaded = 0
    local last_report = 0
    local step = 512 * 1024

    local sink = function(chunk, err)
        if chunk then
            downloaded = downloaded + #chunk
            if progress_callback and downloaded - last_report >= step then
                last_report = downloaded
                pcall(progress_callback, downloaded)
            end
        end
        return file_sink(chunk, err)
    end

    local res, code = http.request {
        url = download_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = sink,
    }

    if io.type(file) == "file" then
        file:close()
    end

    if code ~= 200 then
        os.remove(temp_path)
        return false, code, 0
    end

    if progress_callback and downloaded > last_report then
        pcall(progress_callback, downloaded)
    end

    local ok_rename, rename_err = os.rename(temp_path, filepath)
    if not ok_rename then
        logger.err("Jellyfin API: Failed to move downloaded file into place:", rename_err)
        os.remove(temp_path)
        return false, "file_error", downloaded
    end

    return true, nil, downloaded
end

function API:downloadBookCover(item_id, filepath)
    local cover_url =
        self:getServerUrl() ..
        "/Items/" .. escape(item_id) ..
        "/Images/Primary?maxWidth=320&format=Jpg"
    local temp_path = filepath .. ".part"
    os.remove(temp_path)

    local file = io.open(temp_path, "wb")
    if not file then
        return false, "file_error"
    end

    local res, code = http.request {
        url = cover_url,
        method = "GET",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
        },
        sink = ltn12.sink.file(file),
    }

    if io.type(file) == "file" then
        file:close()
    end

    if code ~= 200 then
        os.remove(temp_path)
        return false, code
    end

    local ok_rename, rename_err = os.rename(temp_path, filepath)
    if not ok_rename then
        logger.err("Jellyfin API: Failed to move cover into place:", rename_err)
        os.remove(temp_path)
        return false, "file_error"
    end
    return true
end

function API:setPlayedStatus(item_id, played)
    local endpoint = played and "PlayedItems" or "UnplayedItems"
    local status_url =
        self:getServerUrl() ..
        "/Users/" .. self.config:getUserId() ..
        "/" .. endpoint .. "/" .. item_id

    local res, code = http.request {
        url = status_url,
        method = "POST",
        headers = {
            ["Authorization"] = self:getAuthHeader(),
            ["Content-Length"] = "0",
        },
    }

    return code == 200, code
end

return API
