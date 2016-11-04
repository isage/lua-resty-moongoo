local cbson = require("cbson")
local bit = require("bit")


local function check_bit(num, bitnum)
  return bit.band(num,math.pow(2,bitnum)) ~= 0 -- and true or false
end

local _M = {}

local mt = { __index = _M }

function _M.new(collection, query, fields, explain, id)
  return setmetatable(
    {
      _collection = collection,
      _query = query,
      _fields = fields,
      _id = id or cbson.uint(0),
      _skip = 0,
      _limit = 0,
      _docs = {},
      _started = false,
      _cnt = 0,
      _comment = nil,
      _hint = nil,
      _max_scan = nil ,
      _max_time_ms = nil,
      _read_preference = nil,
      _snapshot = nil,
      _sort = nil,
      _await = false,
      _tailable = false,
      _explain = explain or false
    },
  mt)
end

function _M.tailable(self, tailable)
  self._tailable = tailable
  return self
end

function _M.await(self, await)
  self._await = await
  return self
end


function _M.comment(self, comment)
  self._comment = comment
  return self
end

function _M.hint(self, hint)
  self._hint = hint
  return self
end

function _M.max_scan(self, max_scan)
  self._max_scan = max_scan
  return self
end

function _M.max_time_ms(self, max_time_ms)
  self._max_time_ms = max_time_ms
  return self
end

function _M.read_preference(self, read_preference)
  self._read_preference = read_preference
  return self
end

function _M.snapshot(self, snapshot)
  self._snapshot = snapshot
  return self
end

function _M.sort(self, sort)
  self._sort = sort
  return self
end


function _M.clone(self, explain)
  local clone = self.new(self._collection, self._query, self._fields, explain)
  clone:limit(self._limit)
  clone:skip(self._skip)

  clone:comment(self._comment)
  clone:hint(self._hint)
  clone:max_scan(self._max_scan)
  clone:max_time_ms(self._max_time_ms)
  clone:read_preference(self._read_preference)
  clone:snapshot(self._snapshot)
  clone:sort(self._sort)

  return clone
end

function _M.skip(self, skip)
  if self._started then
    print("Can's set skip after starting cursor")
  else
    self._skip = skip
  end
  return self
end

function _M.limit(self, limit)
  if self._started then
    print("Can's set limit after starting cursor")
  else
    self._limit = limit
  end
  return self
end

function _M._build_query(self)
  local ext = {}
  if self._comment then ext['$comment'] = self._comment end
  if self._explain then ext['$explain'] = true end


  if self._hint then ext['$hint'] = self._hint end
  if self._max_scan then ext['$maxScan'] = self._max_scan end
  if self._max_time_ms then ext['$maxTimeMS'] = self._max_time_ms end
  if self._read_preference then ext['$readPreference'] = self._read_preference end
  if self._snapshot then ext['$snapshot'] = true end
  if self._sort then ext['$orderby'] = self._sort end

  ext['$query'] = self._query

  return cbson.encode(ext)
end

function _M.next(self)
  local moongoo, err = self._collection._db._moongoo:connect()
  if not moongoo then
    return nil, err
  end

  if self:_finished() then
    if self._id ~= cbson.uint(0) then
      self._collection._db._moongoo.connection:_kill_cursors(self._id)
      self._id = cbson.uint(0)
    end
    return nil, "no more data"
  end

  if (not self._started) and (self._id == cbson.uint(0)) then

    -- query and add id and batch
    local flags, id, from, number, docs = self._collection._db._moongoo.connection:_query(self._collection:full_name(), self:_build_query(), self._skip, self._limit, self._fields, {tailable = self._tailable, await = self._await})

    flags = tonumber(tostring(flags)) -- bitop can't work with cbson.int, so...

    if check_bit(flags, 1) then -- QueryFailure
      return nil, docs[1]['$err'] -- why is this $err and not errmsg, like others??
    end
    self._id = id
    self:add_batch(docs)
  elseif #self._docs == 0 and self._id ~= cbson.uint(0) then
    -- we have something to fetch - get_more and add_batch
    local flags, id, from, number, docs = self._collection._db._moongoo.connection:_get_more(self._collection:full_name(), self._limit, self._id)

    flags = tonumber(tostring(flags)) -- bitop can't work with cbson.int, so...

    if check_bit(flags, 0) then -- QueryFailure
      return nil, "wrong cursor id"
    end
    self:add_batch(docs)
    self._id = id

  elseif #self._docs == 0 then--or self._id == cbson.uint(0) then
    return nil, "no more data"
  end
  self._cnt = self._cnt+1
  return table.remove(self._docs, 1) or nil, 'No more data'
end

function _M.all(self)
  local docs = {}
  while true do
    local doc = self:next()
    if doc == nil then break end
    table.insert(docs, doc)
  end
  return docs
end

function _M.rewind(self)
  self._started = false
  self._docs = {}
  self._collection._db._moongoo.connection:_kill_cursors(self._id)
  self._id = cbson.uint(0)
  return self
end

function _M.count(self)
  local doc, err = self._collection._db:cmd(
    { count = self._collection.name },
    {
      query = self._query,
      skip = self._skip,
      limit = self._limit
    }
  )
  if not doc then
    return nil, err
  end

  return doc and doc.n or 0
end

function _M.distinct(self, key)
  local doc, err = self._collection._db:cmd(
    { distinct = self._collection.name },
    {
      query = self._query,
      key = key
    }
  )
  if not doc then
    return nil, err
  end

  return doc and doc.values or {}
end

function _M.explain(self)
  return self:clone(true):sort(nil):next()
end

function _M.add_batch(self, docs)
  self._started = true
  for k,v in ipairs(docs) do
    table.insert(self._docs, v)
  end
  return self
end

function _M._finished(self)
  if self._limit == 0 then
    return false
  else
    if self._cnt >= math.abs(self._limit) then
      return true
    else
      return false
    end
  end
end

return _M
