local cbson = require("cbson")
local collection = require("resty.moongoo.collection")
local gridfs = require("resty.moongoo.gridfs")

local _M = {}

local mt = { __index = _M }

function _M.new(name, moongoo)
  return setmetatable({name = name, _moongoo = moongoo}, mt)
end

function _M.collection(self, name)
  return collection.new(name, self)
end

function _M.gridfs(self, name)
  return gridfs.new(self,name)
end

function _M.cmd(self, cmd, params)
  local r, err = self._moongoo:connect()
  if not r then
    return nil, err
  end
  return self:_cmd(cmd, params)
end

function _M._cmd(self, cmd, params)
  local params = params or {}
  if type(cmd) == "table" then
    local tmpcmd = ''
    for k,v in pairs(cmd) do
      params[k] = v
      tmpcmd = k
    end
    cmd = tmpcmd
  else
    params[cmd] = true
  end
  local cmd = cbson.encode_first(cmd, params)

  local _,_,_,_,docs = self._moongoo.connection:_query(self.name..".$cmd", cmd, 0, 1)

  if not docs[1] then
    return nil, "Empty reply from mongodb"
  end

  if not docs[1].ok or docs[1].ok == 0 then
    return nil, docs[1].errmsg
  end

  return docs[1]
end

function _M.insert(self, collection, docs)
  local r, err = self._moongoo:connect()
  if not r then
    return nil, err
  end
  return self:_insert(collection, docs)
end

function _M._insert(self, collection, docs)
  self._moongoo.connection:_insert(collection, docs)
  return
end


return _M