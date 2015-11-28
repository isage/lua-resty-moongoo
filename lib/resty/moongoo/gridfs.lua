local cbson = require("cbson")
local gfsfile = require("resty.moongoo.gridfs.file")

local _M = {}

local mt = { __index = _M }

function _M.new(db, name)
  local name = name or 'fs'
  return setmetatable(
    {
      _db = db,
      _name = name,
      _files = db:collection(name .. '.files'),
      _chunks = db:collection(name .. '.chunks')
    },
  mt)
end

function _M.list(self)
  return self._files:find({}):distinct('filename')
end

function _M.remove(self, id)
  local r,err = self._files:remove({_id = cbson.oid(id)})
  if not r then
    return nil, "Failed to remove file metadata: "..err
  end
  r,err = self._chunks:remove({files_id = cbson.oid(id)});
  if not r then
    return nil, "Failed to remove file chunks: "..err
  end
  return r
end

function _M.find_version(self, name, version)

end

function _M.open(self, id)
  return gfsfile.open(self, id)
end


function _M.create(self, name, opts, safe)
  return gfsfile.new(self, name, opts, safe)
end

return _M

