local socket = ngx and ngx.socket.tcp or require("socket").tcp
local cbson = require("cbson")

local opcodes = {
  OP_REPLY = 1;
  OP_MSG = 1000;
  OP_UPDATE = 2001;
  OP_INSERT = 2002;
  RESERVED = 2003;
  OP_QUERY = 2004;
  OP_GET_MORE = 2005;
  OP_DELETE = 2006;
  OP_KILL_CURSORS = 2007;
}

local _M = {}

local mt = { __index = _M }

function _M.new(host, port, timeout)
  local sock = socket()
  if timeout then
    sock:settimeout(timeout)
  end

  return setmetatable({
    sock = sock;
    host = host;
    port = port;
    _id = 0;
  }, mt)
end

function _M.connect(self, host, port)
  self.host = host or self.host
  self.port = port or self.port
  return self.sock:connect(self.host, self.port)
end

function _M.handshake(self)
  if ngx then
    self.sock:sslhandshake()
  else
    local ssl = require("ssl")
    self.sock = ssl.wrap(self.sock, {mode = "client", protocol = "tlsv1_2"})
    assert(self.sock)
    self.sock:dohandshake()
  end
end

function _M.close(self)
  if ngx then
    self.sock:setkeepalive()
  else
    self.sock:close()
  end
end

function _M.get_reused_times(self)
  if not self.sock then
    return nil, "not initialized"
  end

  return self.sock:getreusedtimes()
end

function _M.settimeout(self, ms)
  self.sock:settimeout(ms)
end

function _M.send(self, data)
  return self.sock:send(data)
end

function _M.receive(self, pat)
  return self.sock:receive(pat)
end

function _M._handle_reply(self)
    local header = assert ( self.sock:receive ( 16 ) )

    local length = cbson.raw_to_uint( string.sub(header , 1 , 4 ))
    local r_id = cbson.raw_to_uint( string.sub(header , 5 , 8 ))
    local r_to = cbson.raw_to_uint( string.sub(header , 9 , 12 ))
    local opcode = cbson.raw_to_uint( string.sub(header , 13 , 16 ))

    assert ( opcode == cbson.uint(opcodes.OP_REPLY ) )
    assert ( r_to == cbson.uint(self._id) )

    local data = assert ( self.sock:receive ( tostring(length-16 ) ) )

    local flags = cbson.raw_to_uint( string.sub(data , 1 , 4 ))
    local cursor_id = cbson.raw_to_uint( string.sub(data , 5 , 12 ))
    local from = cbson.raw_to_uint( string.sub(data , 13 , 16 ))
    local number = tonumber(tostring(cbson.raw_to_uint( string.sub(data , 17 , 20 ))))

    local docs = string.sub(data , 21)

    local pos = 1
    local index = 0
    local r_docs = {}
    while index < number do
      local bson_size = tonumber(tostring(cbson.raw_to_uint(docs:sub(pos, pos+3))))

      local dt = docs:sub(pos,pos+bson_size-1)  -- get bson data according to size

      table.insert(r_docs, cbson.decode(dt))

      pos = pos + bson_size
      index = index + 1
    end

    return flags, cursor_id, from, number, r_docs
end

function _M._build_header(self, op, payload_size)
  local size = cbson.uint_to_raw(cbson.uint(payload_size+16), 4)
  local op = cbson.uint_to_raw(cbson.uint(op), 4)
  self._id = self._id+1
  local id = cbson.uint_to_raw(cbson.uint(self._id), 4)
  local reply_to = "\0\0\0\0"
  return size .. id .. reply_to .. op
end

function _M._query(self, collection, query, to_skip, to_return, selector, flags)
  local flags = {
    tailable = flags and flags.tailable and 1 or 0,
    slaveok = flags and flags.slaveok and 1 or 0,
    notimeout = flags and flags.notimeout and 1 or 0,
    await = flags and flags.await and 1 or 0,
    exhaust = flags and flags.exhaust and 1 or 0,
    partial = flags and flags.partial and 1 or 0
  }

  local flagset = cbson.int_to_raw(
    cbson.int(
      2   * flags["tailable"] +
      2^2 * flags["slaveok"] +
      2^4 * flags["notimeout"] +
      2^5 * flags["await"] +
      2^6 * flags["exhaust"] +
      2^7 * flags["partial"]
    ),
  4)

  local selector = selector and #selector and cbson.encode(selector) or ""

  local to_skip = cbson.int_to_raw(cbson.int(to_skip), 4)
  local to_return = cbson.int_to_raw(cbson.int(to_return), 4)

  local size = 4 + #collection + 1 + 4 + 4 + #query + #selector

  local header = self:_build_header(opcodes["OP_QUERY"], size)

  local data = header .. flagset .. collection .. "\0" .. to_skip .. to_return .. query .. selector

  assert(self:send(data))
  return self:_handle_reply()
end

function _M._insert(self, collection, docs, flags)
  local encoded_docs = {}
  for k, doc in ipairs(docs) do
    encoded_docs[k] = cbson.encode(doc)
  end
  string_docs = table.concat(encoded_docs)

  local flags = {
    continue_on_error = flags and flags.continue_on_error and 1 or 0
  }

  local flagset = cbson.int_to_raw(
    cbson.int(
      2 * flags["continue_on_error"]
    ),
  4)

  local size = 4 + 1 + #collection + #string_docs
  local header = self:_build_header(opcodes["OP_INSERT"], size)

  local data = header .. flagset .. collection .. "\0" .. string_docs

  assert(self:send(data))

  return true -- Mongo doesn't send a reply
end

function _M._kill_cursors(self, id)
  local id = cbson.uint_to_raw(id, 8)
  local num = cbson.int_to_raw(cbson.int(1), 4)
  local zero = cbson.int_to_raw(cbson.int(0), 4)
  local size = 8+4+4
  local header = self:_build_header(opcodes["OP_KILL_CURSORS"], size)
  local data = header .. zero .. num .. id
  assert(self:send(data))
  return true -- Mongo doesn't send a reply
end

function _M._get_more(self, collection, number, cursor)
  local num = cbson.int_to_raw(cbson.int(number), 4)
  local zero = cbson.int_to_raw(cbson.int(0), 4)
  local cursor = cbson.uint_to_raw(cursor, 8)
  local size = 4+#collection+1+4+8
  local header = self:_build_header(opcodes["OP_GET_MORE"], size)
  local data = header .. zero .. collection .. '\0' .. num  .. cursor
  assert(self:send(data))
  return self:_handle_reply()
end

return _M