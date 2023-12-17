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
--- @alias Config { cache_path: string, database: { update_interval: number, steam: Database } }

--- @type Config
local config = {
  cache_path = script_path() .. '/.cache',
  database = {
    update_interval = 60 * 60 * 24,
    steam = {
      name = 'steam',
      url = 'https://api.steampowered.com/ISteamApps/GetAppList/v2/',
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

    database_file:write(app.appid .. ' ' .. app.name .. '\n')

    ::continue::
  end

  database_file:close()

  return nil
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
end

main()
