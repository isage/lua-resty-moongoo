local cbson = require("cbson")
local generate_oid = require("resty.moongoo.utils").generate_oid


local _M = {}

local mt = { __index = _M }

function _M.new(gridfs, name, opts, safe, read_only)
  local read_only = read_only or false
  local safe = safe == nil and true or safe

  opts = opts or {}
  opts.filename = name
  opts.length = opts.length or cbson.uint(0)
  opts.chunkSize = opts.chunkSize or cbson.uint(261120)

  local write_only = true
  if not safe then
    write_only = false
  end

  return setmetatable(
    {
      _gridfs = gridfs,
      _meta = opts,
      _write_only = write_only,
      _read_only = read_only,
      _pos = 0,
      _chunks = {},
      _closed = false,
      _buffer = '',
      _n = 0
    },
  mt)
end

function _M.open(gridfs, id)
  -- try to fetch
  local doc, err = gridfs._files:find_one({ _id = id})
  if not doc then
    return nil, "No such file"
  else
    return _M.new(gridfs, doc.filename, doc, false, true)
  end
end

-- props

function _M.content_type(self)   return self._meta.contentType end
function _M.filename(self)       return self._meta.filename    end
function _M.md5(self)            return self._meta.md5         end
function _M.metadata(self)       return self._meta.metadata    end
function _M.raw_length(self)     return self._meta.length      end
function _M.raw_chunk_size(self) return self._meta.chunkSize   end
function _M.date(self)           return self._meta.uploadDate  end

function _M.length(self)         return tonumber(tostring(self._meta.length))      end
function _M.chunk_size(self)     return tonumber(tostring(self._meta.chunkSize))   end

-- reading

function _M.read(self)
  if self._write_only then
    return nil, "Can't read from write-only file"
  end

  if self._pos >= (self:length() or 0) then
    return nil, "EOF"
  end

  local n = math.modf(self._pos / self:chunk_size())
  local query  = {files_id = self._meta._id, n = n}
  local fields = {_id = false, data = true}

  local chunk = self._gridfs._chunks:find_one(query, fields)
  if not chunk then
    return nil, "EOF?"
  end

  return self:_slice(n, chunk.data)
end

function _M.seek(self, pos)
  self._pos = pos
  return self
end

function _M.tell(self)
  return self._pos
end

function _M.slurp(self)
  local data = {}
  local pos = self._pos
  self:seek(0)
  while true do
    local chunk = self:read()
    if not chunk then break end
    table.insert(data, chunk)
  end
  self:seek(pos)
  return table.concat(data)
end

-- writing

function _M.write(self, data)
  if self._read_only then
    return nil, "Can't write to read-only file"
  end

  if self._closed then
    return nil, "Can't write to closed file"
  end

  self._buffer = self._buffer .. data
  self._meta.length = self._meta.length + data:len()

  while self._buffer:len() >= self:chunk_size() do
    local r, res = self:_chunk()
    if not r then
      return nil, err
    end
  end
end

function _M.close(self)

  if self._closed then
    return nil, "File already closed"
  end
  self._closed = true

  self:_chunk()  -- enqueue/write last chunk of data

  if self._write_only then
    -- insert all collected chunks
    for k, v in ipairs(self._chunks) do
      local r, err = self._gridfs._chunks:insert(v)
      if not r then
        return nil, err
      end
    end
  end

  -- ensure indexes
  self._gridfs._files:ensure_index({{ key = {filename = true}}})
  self._gridfs._chunks:ensure_index({ { key = {files_id = 1, n = 1}, unique = true } });
  -- compute md5
  local file_md5 = self._gridfs._db:cmd({ filemd5 = self:_files_id(), root = self._gridfs._name }).md5
  -- insert metadata
  local ids, n = self._gridfs._files:insert(self:_metadata(file_md5))

  if not ids then
    return nil, n
  end
  -- return metadata
  return ids[1]
end

-- private

function _M._files_id(self)
  if not self._meta._id then
    self._meta._id = cbson.oid(generate_oid())
  end
  return self._meta._id
end

function _M._metadata(self, file_md5)
  local doc = {
    _id          = self:_files_id(),
    length       = self:raw_length(),
    chunkSize    = self:raw_chunk_size(),
    uploadDate   = cbson.date(os.time(os.date('!*t'))*1000),
    md5          = file_md5,
    filename     = self:filename() or nil,
    content_type = self:content_type() or nil,
    metadata     = self:metadata() or nil
  }

  return doc
end

function _M._slice(self, n, chunk)
  local offset = self._pos - (n * self:chunk_size())
  local chunk = chunk:raw()
  self._pos = self._pos + chunk:len()
  return chunk:sub(offset+1);
end

function _M._chunk(self)
  local chunk = self._buffer:sub(1,self:chunk_size())
  if not chunk then
    return
  end
  self._buffer = self._buffer:sub(self:chunk_size()+1)
  local n = self._n
  self._n = self._n+1
  local data = cbson.binary("")
  data:raw(chunk, chunk:len())
  if self._write_only then
    -- collect chunks for insert
    table.insert(self._chunks, {files_id = self:_files_id(), n = cbson.uint(n), data = data})
    return true
  else
    -- insert immidiately, so we can read back (ugh)
    return self._gridfs._chunks:insert({{files_id = self:_files_id(), n = cbson.uint(n), data = data}})
  end
end



return _M