#!/usr/bin/env lua

local function script_path()
  local str = debug.getinfo(2, "S").source:sub(2)
  return str:match("(.*/)")
end


package.path = package.path .. ';' .. script_path() .. '?.lua'


--- @type { encode: fun(value: any): string; decode: fun(value: string): table }
local json = require 'deps.json'


--- @alias Error string


-- Steam database contains data from public Steam API.
-- Custom database contains manually maintained list of apps such as Proton
-- which are not available from public API but can be found on SteamDB.
--
-- Database Layout:
-- First line is last update unix timestamp in seconds.
-- All other lines are <appId> <appName> where appId is numeric id, appName is a string:
--
-- 1702678915
-- 400 Portal
-- 620 Portal 2

--- @alias Database { name: string, url: string }
--- @alias Config { cache_path: string, database: { update_interval: number, steam: Database, custom: { local_name: string } } }
--- @alias AppId string
--- @alias AppName string

--- @type Config
local config = {
  cache_path = script_path() .. '/.cache',
  database = {
    update_interval = 60 * 60 * 24,
    steam = {
      name = 'steam',
      url = 'https://api.steampowered.com/ISteamApps/GetAppList/v2/',
    },
    custom = {
      local_name = 'custom_database'
    }
  },
}

--- @alias LogFn fun(message: string): nil
--- @type { debug: LogFn, log: LogFn, warn: LogFn, error: LogFn }
local logger = {
  debug = function(message)
    print('Debug: ' .. message)
  end,
  log = function(message)
    print(message)
  end,
  warn = function(message)
    print('Warning: ' .. message)
  end,
  error = function(message)
    print('Error: ' .. message)
  end,
}

--- @param str string
--- @return string
local function trim(str)
  return str:match("^%s*(.-)%s*$")
end

--- @param path string
--- @return boolean
local function file_exists(path)
  local file = io.open(path, 'r')

  if file == nil then
    return false
  end

  file:close()

  return true
end

--- @param path string
--- @return boolean
local function is_directory(path)
  if os.execute('test -d ' .. path) then
    return true
  else
    return false
  end
end

--- @param str string
--- @param len number
--- @param char string?
local function pad_start(str, len, char)
  if char == nil then char = ' ' end
  return string.rep(char, len - #str) .. str
end

--- @param str string
--- @param len number
--- @param char string?
local function pad_end(str, len, char)
  if char == nil then char = ' ' end
  return str .. string.rep(char, len - #str)
end

--- @return Error?
local function init_file_system()
  local cache_path = config.cache_path

  if not os.execute('mkdir -p ' .. cache_path) then
    return 'Failed to create cache directory at ' .. cache_path
  end

  return nil
end

--- @param database Database
--- @return boolean
local function is_database_up_to_date(database)
  local database_path = config.cache_path .. '/' .. database.name
  local database_file = io.open(database_path, 'r')

  if database_file == nil then
    return false
  end

  local last_update = database_file:read('*line')
  database_file:close()

  local current_time = os.time()
  local last_update_time = tonumber(last_update)
  local is_up_to_date = current_time - last_update_time < config.database.update_interval

  return is_up_to_date
end

--- @param database Database
--- @return Error?
local function update_steam_database(database)
  local response = io.popen('curl -s ' .. database.url)

  if response == nil then
    return 'Failed to fetch ' .. database.url
  end

  local json_data = response:read('*all')
  response:close()
  local data = json.decode(json_data)
  json_data = nil

  if data == nil then
    return 'Failed to decode json data'
  end

  local apps = data.applist.apps

  if apps == nil then
    return 'Failed to find apps in json data'
  end

  local database_path = config.cache_path .. '/' .. database.name
  local database_file = io.open(database_path, 'w')

  if database_file == nil then
    return 'Failed to open file ' .. database_path
  end

  local current_time = os.time()

  database_file:write(current_time .. '\n')

  for _, app in ipairs(apps) do
    if app.appid == nil or app.name == nil then
      logger.debug('Invalid app data\n' .. json.encode(app))
      goto continue
    end

    local app_id = trim(tostring(app.appid))
    local app_name = trim(app.name)

    if app_id == '' or app_name == '' then
      logger.debug('Invalid app data\n' .. json.encode(app))
      goto continue
    end

    database_file:write(app_id .. ' ' .. app_name .. '\n')

    ::continue::
  end

  database_file:close()

  return nil
end

--- @return string[]?, Error?
local function get_data_locations()
  -- known locations are steamapp directories,
  -- they contain compatdata, shadercache and downloading directories.
  --
  -- known locations:
  -- $HOME/.steam/steam/steamapps
  -- /run/media/DEVICE/steamapps
  --
  -- $HOME should be read from env
  -- DEVICE count is unknown. find it by checking available. ignore "deck" device.

  local known_locations = {
    'shadercache',
    -- TODO: I believe apps in common are already named?
    -- 'common',
    'compatdata',
    'downloading',
  }

  --- @type string[]
  local data_locations = {}

  local steam_home = os.getenv('HOME') .. '/.steam/steam/steamapps'

  for _, location in ipairs(known_locations) do
    local location_path = steam_home .. '/' .. location

    if is_directory(location_path) then
      table.insert(data_locations, location_path)
    end
  end

  local media_path = '/run/media'

  if not is_directory(media_path) then
    return data_locations
  end

  local ls_result = io.popen('ls ' .. media_path)

  if ls_result == nil then
    logger.error('Failed to list mounted devices in ' .. media_path)
  else
    local external_device_names = {}

    for device_name in ls_result:lines() do
      if device_name ~= 'deck' then
        table.insert(external_device_names, device_name)
      end
    end

    if #external_device_names > 0 then
      for _, device_name in ipairs(external_device_names) do
        local steamapps_path = media_path .. '/' .. device_name .. '/steamapps'

        if is_directory(steamapps_path) then
          for _, location in ipairs(known_locations) do
            local location_path = steamapps_path .. '/' .. location

            if is_directory(location_path) then
              table.insert(data_locations, location_path)
            end
          end
        end
      end
    end

    ls_result:close()
  end

  return data_locations
end

-- TODO: search database faster, without iterating over the whole file?
--- @alias Entry { app_id: AppId, app_name: AppName }
--- @param app_ids AppId[]
--- @param database Database
--- @return Entry[]?, Error?
local function find_apps_in_database(app_ids, database)
  if #app_ids == 0 then
    return {}
  end

  --- @type Entry[]
  local apps = {}

  --- @type table<AppId, AppId>
  local lookup_app_id_table = {}

  -- create lookup table for faster checking.
  -- if app_id is 10 characters long it's not a Steam App, we can set it to unknown.
  -- TODO: search for non steam apps, Steam shortcuts might have them.
  -- It's also a good idea to save them because shortcut will be removed after
  -- removing app from Steam.
  -- refer to https://github.com/Matoking/protontricks/blob/master/src/protontricks/steam.py#L1159
  for _, app_id in ipairs(app_ids) do
    if #app_id == 10 then
      table.insert(apps, { app_id = app_id, app_name = "Non-Steam App" })
    else
      lookup_app_id_table[app_id] = app_id
    end
  end

  -- search custom database first, it's way smaller.
  local custom_local_database_path = script_path() .. '/' .. config.database.custom.local_name
  local custom_local_database_file = io.open(custom_local_database_path, 'r')

  if custom_local_database_file == nil then
    logger.warn('Failed to open custom database at ' .. custom_local_database_path)
  else
    for line in custom_local_database_file:lines() do
      if not next(lookup_app_id_table) then
        break
      end

      local app_id, app_name = line:match('(%d+) (.+)')

      if app_id == nil or app_name == nil then
        logger.debug('Invalid database entry: "' .. (line or "nil") .. '"')
      elseif lookup_app_id_table[app_id] then
        table.insert(apps, { app_id = app_id, app_name = app_name })
        lookup_app_id_table[app_id] = nil
      end
    end

    custom_local_database_file:close()
  end

  if not next(lookup_app_id_table) then
    logger.debug('Found all apps in database, exit early.')
    return apps
  end

  local database_path = config.cache_path .. '/' .. database.name
  local database_file = io.open(database_path, 'r')

  if database_file == nil then
    return nil, 'Failed to open file ' .. database_path
  end

  -- skip first line since it's update timestamp.
  _ = database_file:read('*line')

  for line in database_file:lines() do
    if not next(lookup_app_id_table) then
      break
    end

    local app_id, app_name = line:match('(%d+) (.+)')

    if app_id == nil or app_name == nil then
      logger.debug('Invalid database entry: "' .. (line or "nil") .. '"')
    elseif lookup_app_id_table[app_id] then
      table.insert(apps, { app_id = app_id, app_name = app_name })
      lookup_app_id_table[app_id] = nil
    end
  end

  database_file:close()

  if not next(lookup_app_id_table) then
    logger.debug('Found all apps in database, exit early.')
    return apps
  end

  -- fill up rest of the values with UNKNOWN
  for app_id in pairs(lookup_app_id_table) do
    table.insert(apps, { app_id = app_id, app_name = 'UNKNOWN' })
  end

  return apps
end


--- @param path string
--- @return string?, Error?
local function get_directory_size(path)
  local du_result = io.popen('du -sh ' .. path)

  if du_result == nil then
    return nil, 'Failed to get directory size for ' .. path
  end

  local size = du_result:read('*line'):match('^(.+)\t')
  du_result:close()

  return size
end

--- @param path string
--- @return AppId[]?, Error?
local function list_apps_in_path(path)
  local app_ids = {}

  local ls_result = io.popen('ls ' .. path)

  if ls_result == nil then
    return nil, 'Failed to list apps in ' .. path
  end

  for app_id in ls_result:lines() do
    -- validate if app name consists of numbers only
    if app_id ~= " " and app_id:match('^%d+$') then
      table.insert(app_ids, app_id)
    end
  end

  ls_result:close()

  return app_ids
end


local function main()
  local err

  err = init_file_system()
  if err then
    logger.error(err)
    os.exit(1)
  end

  if not is_database_up_to_date(config.database.steam) then
    logger.debug('Database is outdated. Updating...')
    err = update_steam_database(config.database.steam)
    if err then
      logger.error(err)
      os.exit(1)
    end
  else
    logger.debug('Database up to date.')
  end

  local data_locations
  data_locations, err = get_data_locations()
  if err then
    logger.error(err)
    os.exit(1)
  end

  if data_locations == nil then
    logger.error('Error: Failed to find data locations.')
    os.exit(1)
  end

  if #data_locations == 0 then
    logger.log('No data locations found.')
    os.exit(0)
  end


  for _, location in ipairs(data_locations) do
    local location_app_ids
    location_app_ids, err = list_apps_in_path(location)

    if err then
      logger.error(err)
      os.exit(1)
    end

    if location_app_ids ~= nil and #location_app_ids > 0 then
      local apps
      apps, err = find_apps_in_database(location_app_ids, config.database.steam)

      if err then
        logger.error(err)
        os.exit(1)
      end

      if apps ~= nil and next(apps) then
        logger.log('---\nFound ' .. #apps .. ' apps in ' .. location)
        for _, entry in pairs(apps) do
          local size = get_directory_size(location .. '/' .. entry.app_id)
          logger.log(pad_end((size or '??'), 5) .. ' ' .. pad_end(entry.app_id, 11) .. ' ' .. entry.app_name)
        end
      end
    else
      logger.log('---\nNo apps found in ' .. location)
    end
  end
end

main()
