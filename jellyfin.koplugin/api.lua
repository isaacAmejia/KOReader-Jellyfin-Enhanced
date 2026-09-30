--[[--
Jellyfin API client
@module koplugin.jellyfin.api
]]

local http = require("socket.http")
local ltn12 = require("ltn12")
local url = require("socket.url")
local logger = require("logger")

-- JSON library with fallback
local json
local ok = pcall(function() json = require("json") end)
if not ok then
	json = require("rapidjson")
end

local API = {}

function API:new(config)
	local o = {
		config = config
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
		local response = json.decode(table.concat(response_body))
		return true, response
	else
		return false, code
	end
end

function API:checkQuickConnect(secret)
	local check_url = self.config:getServerUrl() .. "/QuickConnect/Connect?secret=" .. secret
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
	local auth_url = self.config:getServerUrl() .. "/Users/AuthenticateWithQuickConnect"
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
	local views_url = self.config:getServerUrl() .. "/Users/" .. user_id .. "/Views"
	local response_body = {}

	logger.info("Jellyfin API: Fetching user libraries")

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

function API:getItemsInLibrary(library_id, search_term)
	local items_url = self.config:getServerUrl() .. "/Users/" .. self.config:getUserId() .. "/Items" ..
		"?ParentId=" .. library_id ..
		"&Recursive=true" ..
		"&Fields=Path,MediaSources,People,Overview" ..
		"&IncludeItemTypes=Book,Audio,AudioBook"

	if search_term and search_term ~= "" then
		items_url = items_url .. "&SearchTerm=" .. url.escape(search_term)
	end

	logger.info("Jellyfin API: Fetching library items")
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

function API:downloadItem(item_id, filepath, progress_callback)
	local download_url = self.config:getServerUrl() .. "/Items/" .. item_id .. "/Download"

	local file = io.open(filepath, "wb")
	if not file then
		return false, "file_error"
	end

	local file_sink = ltn12.sink.file(file)
	local downloaded = 0

	local sink = function(chunk, err)
		if chunk then
			downloaded = downloaded + #chunk
			if progress_callback then
				local ok_progress, progress_err = pcall(progress_callback, downloaded)
				if not ok_progress then
					logger.warn("Jellyfin API: progress callback failed:", progress_err)
				end
			end
		end
		return file_sink(chunk, err)
	end

	local _, code = http.request {
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

	if type(code) == "number" and code >= 200 and code < 300 then
		return true, nil, downloaded
	else
		os.remove(filepath)
		return false, code or "network_error", downloaded
	end
end

function API:downloadBookCover(item_id, filepath)
	local cover_url = self.config:getServerUrl() .. "/Items/" .. item_id ..
		"/Images/Primary?maxWidth=400&format=Jpg"

	local file = io.open(filepath, "wb")
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

	if code == 200 then
		return true
	else
		os.remove(filepath)
		return false, code
	end
end

function API:setPlayedStatus(item_id, played)
	local method = played and "POST" or "DELETE"

	-- Current Jellyfin route. The authenticated user is resolved from the
	-- access token, so no user ID needs to be embedded in the URL.
	local status_url = self.config:getServerUrl()
		.. "/UserPlayedItems/" .. item_id

	local _, code = http.request {
		url = status_url,
		method = method,
		headers = {
			["Authorization"] = self:getAuthHeader(),
			["Content-Length"] = "0",
		},
	}

	if type(code) == "number" and code >= 200 and code < 300 then
		return true, code
	end

	-- Older Jellyfin versions exposed the same operation under the
	-- user-scoped PlayedItems route. Keep this fallback for compatibility.
	if code == 404 or code == 405 then
		local legacy_url = self.config:getServerUrl()
			.. "/Users/" .. self.config:getUserId()
			.. "/PlayedItems/" .. item_id

		local _, legacy_code = http.request {
			url = legacy_url,
			method = method,
			headers = {
				["Authorization"] = self:getAuthHeader(),
				["Content-Length"] = "0",
			},
		}

		return type(legacy_code) == "number"
			and legacy_code >= 200
			and legacy_code < 300,
			legacy_code
	end

	return false, code
end

return API
