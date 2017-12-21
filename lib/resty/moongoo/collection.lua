local cbson = require("cbson")
local generate_oid = require("resty.moongoo.utils").generate_oid
local cursor = require("resty.moongoo.cursor")

local _M = {}

local mt = { __index = _M }

function _M.new(name, db)
  return setmetatable({_db = db, name = name}, mt)
end

function _M._build_write_concern(self)
  return {
    j = self._db._moongoo.journal;
    w = tonumber(self._db._moongoo.w) and cbson.int(self._db._moongoo.w) or self._db._moongoo.w;
    wtimeout = cbson.int(self._db._moongoo.wtimeout);
  }
end

local function check_write_concern(doc, ...)
  -- even if write concern failed we may still have successful operation
  -- so we check for number of affected docs, and only warn if its > 0
  -- otherwise, we just return nil and error

  if doc.writeConcernError then
    if not doc.n then
      return nil, doc.writeConcernError.errmsg
    else
      print(doc.writeConcernError.errmsg)
    end
  end
  return ...
end

function _M._get_last_error(self)
  local write_concern = self:_build_write_concern()
  local cmd = { getLastError = cbson.int(1), j = write_concern.j, w = write_concern.w, wtimeout = write_concern.wtimeout  }

  local doc, err = self._db:cmd(cmd)
  if not doc then
    return nil, err
  end

  return doc
end

function _M._check_last_error(self, ...)
  local cmd, err = self:_get_last_error()

  if not cmd then
    return nil, err
  end

  if tostring(cmd.err) == "null" then
    return ...
  end

  return nil, tostring(cmd.err)
end

local function ensure_oids(docs)
  local docs = docs
  local ids = {}
  for k,v in ipairs(docs) do
    if not docs[k]._id then
      docs[k]._id = cbson.oid(generate_oid())
    end
    table.insert(ids, docs[k]._id)
  end
  return docs, ids
end

local function build_index_names(docs)
  local docs = docs
  for k,v in ipairs(docs) do
    if not v.name then
      local name = {}
      for n, d in pairs(v.key) do
        table.insert(name, n)
      end
      name = table.concat(name, '_')
      docs[k].name = name
    end
  end
  return docs
end

function _M.insert(self, docs)
  -- ensure we have oids
  if #docs == 0 then
    local newdocs = {}
    newdocs[1] = docs
    docs = newdocs
  end
  local docs, ids = ensure_oids(docs)

  self._db._moongoo:connect()

  local server_version = tonumber(string.sub(string.gsub(self._db._moongoo.version, "(%D)", ""), 1, 3))

  if server_version < 254 then
    self._db:insert(self:full_name(), docs)
    return self:_check_last_error(ids)
  else
    local doc, err = self._db:cmd(
      { insert = self.name },
      {
        documents = docs,
        ordered = true,
        writeConcern = self:_build_write_concern()
      }
    )

    if not doc then
      return nil, err
    end

    return check_write_concern(doc, ids, doc.n)
  end
end

function _M.create(self, params)
  local params = params or {}
  local doc, err = self._db:cmd(
    { create = self.name },
    params
  )
  if not doc then
    return nil, err
  end
  return true
end

function _M.drop(self)
  local doc, err = self._db:cmd(
    { drop = self.name },
    {}
  )
  if not doc then
    return nil, err
  end
  return true
end

function _M.drop_index(self, name)
  local doc, err = self._db:cmd(
    { dropIndexes = self.name },
    { index = name }
  )
  if not doc then
    return nil, err
  end
  return true
end

function _M.ensure_index(self, docs)
  docs = build_index_names(docs)

  local doc, err = self._db:cmd(
    { createIndexes = self.name },
    { indexes = docs }
  )
  if not doc then
    return nil, err
  end
  return true
end

function _M.full_name(self)
  return self._db.name .. "." .. self.name
end

function _M.options(self)
  local doc, err = self._db:cmd(
    "listCollections",
    {
      filter = { name = self.name }
    }
  )
  if not doc then
    return nil, err
  end
  return doc.cursor.firstBatch[1]
end

function _M.remove(self, query, single)
  local query = query or {}

  if getmetatable(cbson.oid("000000000000000000000000")) == getmetatable(query) then
    query = { _id = query }
  end

  local doc, err = self._db:cmd(
    { delete = self.name },
    {
      deletes = {{q=query, limit = single and 1 or 0}},
      ordered = true,
      writeConcern = self:_build_write_concern()
    }
  )
  if not doc then
    return nil, err
  end

  return check_write_concern(doc, doc.n)
end

function _M.stats(self)
  local doc, err = self._db:cmd(
    {collstats = self.name},
    {}
  )
  if not doc then
    return nil, err
  end
  return doc
end

function _M.index_information(self)
  local doc, err = self._db:cmd(
    { listIndexes = self.name },
    { }
  )
  if not doc then
    return nil, err
  end
  return doc.cursor.firstBatch
end

function _M.rename(self, to_name, drop)
  local drop = drop or false
  -- rename
  local doc, err = self._db._moongoo:db("admin"):cmd(
    { renameCollection = self:full_name() },
    {
      to = to_name,
      dropTarget = drop
    }
  )
  if not doc then
    return nil, err
  end

  return self.new(to_name, self._db)
end

function _M.update(self, query, update, flags)
  local flags = flags or {}
  local query = query or {}

  if getmetatable(cbson.oid("000000000000000000000000")) == getmetatable(query) then
    query = { _id = query }
  end

  local update = {
    q = query,
    u = update,
    upsert = flags.upsert or false,
    multi = flags.multi or false
  }

  local doc, err = self._db:cmd(
    { update = self.name },
    {
      updates = { update },
      ordered = true,
      writeConcern = self:_build_write_concern()
    }
  )
  if not doc then
    return nil, err
  end

  return doc.nModified
end

function _M.save(self, doc)
  if not doc._id then
    doc._id = cbson.oid(generate_oid())
  end
  local r, err = self:update(doc._id, doc, {upsert = true});
  if not r then
    return nil, err
  end

  return doc._id
end

function _M.map_reduce(self, map, reduce, flags)
  local flags = flags or {}
  flags.map = cbson.code(map)
  flags.reduce = cbson.code(reduce)
  flags.out = flags.out or { inline = true }

  local doc, err = self._db:cmd(
    { mapReduce = self.name },
    flags
  )
  if not doc then
    return nil, err
  end

  if doc.results then
    return doc.results
  end

  return self.new(doc.result, self._db)
end

function _M.find(self, query, fields)
  local query = query or {}
  if getmetatable(cbson.oid("000000000000000000000000")) == getmetatable(query) then
    query = { _id = query }
  end
  return cursor.new(self, query, fields)
end

function _M.find_one(self, query, fields)
  local query = query or {}
  if getmetatable(cbson.oid("000000000000000000000000")) == getmetatable(query) then
    query = { _id = query }
  end

  return self:find(query, fields):limit(-1):next()
end

function _M.find_and_modify(self, query, opts)
  local query = query or {}
  if getmetatable(cbson.oid("000000000000000000000000")) == getmetatable(query) then
    query = { _id = query }
  end

  local opts = opts or {}
  opts.query = query

  local doc, err = self._db:cmd(
    { findAndModify = self.name },
    opts
  )
  if not doc then
    return nil, err
  end
  return doc.value
end

function _M.aggregate(self, pipeline, opts)
  local opts = opts or {}
  opts.pipeline = pipeline
  if not opts.explain then
    opts.cursor = {}
  end

  local doc, err = self._db:cmd(
    { aggregate = self.name },
    opts
  )
  if not doc then
    return nil, err
  end

  if opts.explain then
    return doc
  end

  -- collection
  if opts.pipeline[#opts.pipeline]['$out'] then
    return self.new(opts.pipeline[#opts.pipeline]['$out'], self._db)
  end

  -- cursor
  return cursor.new(self, {}, {}, false, doc.cursor.id):add_batch(doc.cursor.firstBatch)
end



return _M