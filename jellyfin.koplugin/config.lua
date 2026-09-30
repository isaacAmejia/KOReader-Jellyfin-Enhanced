--[[--
Jellyfin plugin configuration management
@module koplugin.jellyfin.config
]]

local logger = require("logger")

local Config = {}

function Config:getServerUrl()
	return G_reader_settings:readSetting("jellyfin_server_url") or ""
end

function Config:setServerUrl(url)
	local previous = self:getServerUrl()
	G_reader_settings:saveSetting("jellyfin_server_url", url)

	-- Authentication tokens are server-specific. Avoid reusing credentials
	-- after the user points the plugin at a different Jellyfin server.
	if previous ~= url
			and (
				self:getUserId() ~= ""
				or self:getAccessToken() ~= ""
			)
	then
		self:clearAuth()
	elseif G_reader_settings.flush then
		G_reader_settings:flush()
	end
end

function Config:getUserId()
	return G_reader_settings:readSetting("jellyfin_user_id") or ""
end

function Config:setUserId(user_id)
	G_reader_settings:saveSetting("jellyfin_user_id", user_id)
end

function Config:getAccessToken()
	return G_reader_settings:readSetting("jellyfin_access_token") or ""
end

function Config:setAccessToken(token)
	G_reader_settings:saveSetting("jellyfin_access_token", token)
end

function Config:getDeviceId()
	return G_reader_settings:readSetting("jellyfin_device_id") or ""
end

function Config:setDeviceId(device_id)
	G_reader_settings:saveSetting("jellyfin_device_id", device_id)
end

function Config:clearAuth()
	G_reader_settings:delSetting("jellyfin_access_token")
	G_reader_settings:delSetting("jellyfin_user_id")
	if G_reader_settings.flush then
		G_reader_settings:flush()
	end
end

function Config:isLoggedIn()
	return self:getServerUrl() ~= ""
		and self:getUserId() ~= ""
		and self:getAccessToken() ~= ""
end

function Config:initialize()
	logger.info("Jellyfin Config: Initialising settings")

	if not G_reader_settings:readSetting("jellyfin_server_url") then
		G_reader_settings:saveSetting("jellyfin_server_url", "")
	end
	if not G_reader_settings:readSetting("jellyfin_user_id") then
		G_reader_settings:saveSetting("jellyfin_user_id", "")
	end
	if not G_reader_settings:readSetting("jellyfin_access_token") then
		G_reader_settings:saveSetting("jellyfin_access_token", "")
	end

	local jellyfin_device_id =
		G_reader_settings:readSetting("jellyfin_device_id")

	if not jellyfin_device_id or jellyfin_device_id == "" then
		-- KOReader itself maintains a stable random UUID in "device_id".
		-- Reuse it for new installs instead of generating a weaker timestamp ID.
		local device_id =
			G_reader_settings:readSetting("device_id")

		if not device_id or device_id == "" then
			device_id = require("random").uuid()
		end

		G_reader_settings:saveSetting(
			"jellyfin_device_id",
			device_id
		)
	end

	if G_reader_settings.flush then
		G_reader_settings:flush()
	end
end

return Config
