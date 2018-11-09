local cbson = require("cbson")
local connection = require("resty.moongoo.connection")
local database = require("resty.moongoo.database")
local parse_uri = require("resty.moongoo.utils").parse_uri
local auth_scram = require("resty.moongoo.auth.scram")
local auth_cr = require("resty.moongoo.auth.cr")


local _M = {}

_M._VERSION = '0.1'
_M.NAME = 'Moongoo'


local mt = { __index = _M }

function _M.new(uri)
  local conninfo = parse_uri(uri)

  if not conninfo.scheme or conninfo.scheme ~= "mongodb" then
    return nil, "Wrong scheme in connection uri"
  end

  local auth_algo = conninfo.query and conninfo.query.authMechanism or "SCRAM-SHA-1"
  local w = conninfo.query and conninfo.query.w or 1
  local wtimeout = conninfo.query and conninfo.query.wtimeoutMS or 1000
  local journal = conninfo.query and conninfo.query.journal or false
  local ssl = conninfo.query and conninfo.query.ssl or false

  local stimeout = conninfo.query.socketTimeoutMS and conninfo.query.socketTimeoutMS or nil

  return setmetatable({
    connection = nil;
    w = w;
    wtimeout = wtimeout;
    journal = journal;
    stimeout = stimeout;
    hosts = conninfo.hosts;
    default_db = conninfo.database;
    user = conninfo.user or nil;
    password = conninfo.password or "";
    auth_algo = auth_algo,
    ssl = ssl,
    version = nil
  }, mt)
end

function _M._auth(self, protocol)
 if not self.user then return 1 end

 if not protocol or protocol < cbson.int(3) or self.auth_algo == "MONGODB-CR" then
   return auth_cr(self:db(self.default_db), self.user, self.password)
 else
   return auth_scram(self:db(self.default_db), self.user, self.password)
 end

end

function _M.connect(self)
  if self.connection then return self end

  -- foreach host
  for k, v in ipairs(self.hosts) do
    -- connect
    self.connection, err = connection.new(v.host, v.port, self.stimeout)
    if not self.connection then
      return nil, err
    end
    local status, err = self.connection:connect()
    if status then
      if self.ssl then
        self.connection:handshake()
      end
      if not self.version then
        query = self:db(self.default_db):_cmd({ buildInfo = 1 })
        if query then
          self.version = query.version
        end
      end

      local ismaster = self:db("admin"):_cmd("ismaster")
      if ismaster and ismaster.ismaster then
        -- auth
        local r, err = self:_auth(ismaster.maxWireVersion)
        if not r then
          return nil, err
        end
        return self
      else
        -- try to connect to master
        if ismaster.primary then
          local mhost, mport
          string.gsub(ismaster.primary, "([^:]+):([^:]+)", function(host,port) mhost=host; mport=port end)
          self.connection:close()
          self.connection = nil
          self.connection, err = connection.new(mhost, mport, self.stimeout)
          if not self.connection then
            return nil, err
          end
          local status, err = self.connection:connect()
          if not status then
            return nil, err
          end
          if self.ssl then
            self.connection:handshake()
          end
          if not self.version then
            query = self:db(self.default_db):_cmd({ buildInfo = 1 })
            if query then
              self.version = query.version
            end
          end
          local ismaster = self:db("admin"):_cmd("ismaster")
          if ismaster and ismaster.ismaster then
            -- auth
            local r, err = self:_auth(ismaster.maxWireVersion)
            if not r then
              return nil, err
            end
            return self
          else
            return nil, "Can't connect to master server"
          end
        end
      end
    end
  end
  return nil, "Can't connect to any of servers"
end

function _M.close(self)
  if self.connection then
    self.connection:close()
    self.connection = nil
  end
end

function _M.get_reused_times(self)
  return self.connection:get_reused_times()
end

function _M.db(self, dbname)
  return database.new(dbname, self)
end

return _M
