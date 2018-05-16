local bit = require("bit")
local cbson = require("cbson")

local md5 = ngx and ngx.md5 or function(str) return require("crypto").digest("md5", str) end
local hmac_sha1 = ngx and ngx.hmac_sha1 or function(str, key) return require("crypto").hmac.digest("sha1", key, str, true) end
local hasposix , posix = pcall(require, "posix")

local machineid
if hasposix then
  machineid = posix.uname("%n")
else
  machineid = assert(io.popen("uname -n")):read("*l")
end
machineid = md5(machineid):sub(1, 6)

local function uint_to_hex(num, len, be)
  local len = len or 4
  local be = be or 0
  local num = cbson.uint(num)
  local raw = cbson.uint_to_raw(num, len, be)
  local out = ''
  for i = 1, #raw do
    out = out .. string.format("%02x", raw:byte(i,i))
  end
  return out
end

local counter = 0

if not ngx then
  math.randomseed(os.time())
  counter = math.random(100)
else
  local resty_random = require "resty.random"
  local resty_string = require "resty.string"
  local strong_random = resty_random.bytes(4,true)
  while strong_random == nil do
    strong_random = resty_random.bytes(4,true)
  end
  counter = tonumber(resty_string.to_hex(strong_random), 16)
end

local function generate_oid()
  local pid = ngx and ngx.worker.pid() or nil
  if not pid then
    if hasposix then
      pid = posix.getpid("pid")
    else
      pid = 1
    end
  end

  pid = uint_to_hex(pid,2)

  counter = counter + 1
  local time = os.time()

  return uint_to_hex(time, 4, 1) .. machineid .. pid .. uint_to_hex(counter, 4, 1):sub(3,8)
end

local function print_r(t, indent)
  local indent=indent or ''
  if #indent > 5 then return end
  if type(t) ~= "table" then
    print(t)
    return
  end
  for key,value in pairs(t) do
    io.write(indent,'[',tostring(key),']') 
    if type(value)=="table" then io.write(':\n') print_r(value,indent..'\t')
    else io.write(' = ',tostring(value),'\n') end
  end
end

local function parse_uri(url)
    -- initialize default parameters
    local parsed = {}
    -- empty url is parsed to nil
    if not url or url == "" then return nil, "invalid url" end
    -- remove whitespace
    url = string.gsub(url, "%s", "")
    -- get fragment
    url = string.gsub(url, "#(.*)$", function(f)
        parsed.fragment = f
        return ""
    end)
    -- get scheme
    url = string.gsub(url, "^([%w][%w%+%-%.]*)%:",
        function(s) parsed.scheme = s; return "" end)

    -- get authority
    local location
    url = string.gsub(url, "^//([^/]*)", function(n)
        location = n
        return ""
    end)

    -- get query stringing
    url = string.gsub(url, "%?(.*)", function(q)
        parsed.query_string = q
        return ""
    end)
    -- get params
    url = string.gsub(url, "%;(.*)", function(p)
        parsed.params = p
        return ""
    end)
    -- path is whatever was left
    if url ~= "" then parsed.database = string.gsub(url,"^/([^/]*).*","%1") end
    if not parsed.database or #parsed.database == 0 then parsed.database = "admin" end

    if not location then return parsed end

    location = string.gsub(location,"^([^@]*)@",
        function(u) parsed.userinfo = u; return "" end)

    parsed.hosts = {}
    string.gsub(location, "([^,]+)", function(u)
      local pr = { host = "localhost", port = 27017 }
      u = string.gsub(u, ":([^:]*)$",
        function(p) pr.port = p; return "" end)
      if u ~= "" then pr.host = u end
     table.insert(parsed.hosts, pr)
    end)
    if #parsed.hosts == 0 then parsed.hosts = {{ host = "localhost", port = 27017 }} end

    parsed.query = {}
    if parsed.query_string then
      string.gsub(parsed.query_string, "([^&]+)", function(u)
        u = string.gsub(u, "([^=]*)=([^=]*)$",
          function(k,v) parsed.query[k] = v; return "" end)
      end)
    end

    local userinfo = parsed.userinfo
    if not userinfo then return parsed end
    userinfo = string.gsub(userinfo, ":([^:]*)$",
        function(p) parsed.password = p; return "" end)
    parsed.user = userinfo
    return parsed
end

local function xor_bytestr( a, b )
    local res = ""    
    for i=1,#a do
        res = res .. string.char(bit.bxor(string.byte(a,i,i), string.byte(b, i, i)))
    end
    return res
end

local function xor_bytestr( a, b )
    local res = ""    
    for i=1,#a do
        res = res .. string.char(bit.bxor(string.byte(a,i,i), string.byte(b, i, i)))
    end
    return res
end

-- A simple implementation of PBKDF2_HMAC_SHA1
local function pbkdf2_hmac_sha1( pbkdf2_key, iterations, salt, len )
    local u1 = hmac_sha1(pbkdf2_key, salt .. "\0\0\0\1")
    local ui = u1
    for i=1,iterations-1 do
        u1 = hmac_sha1(pbkdf2_key, u1)
        ui = xor_bytestr(ui, u1)
    end
    if #ui < len then
        for i=1,len-(#ui) do
            ui = string.char(0) .. ui
        end
    end
    return ui
end

-- not full implementation, but oh well
local function saslprep(username)
  return string.gsub(string.gsub(username, '=', '=3D'), ',' , '=2C')
end

local function pass_digest ( username , password )
    return md5(username .. ":mongo:" .. password)
end

return {
  parse_uri = parse_uri;
  print_r = print_r;
  pbkdf2_hmac_sha1 = pbkdf2_hmac_sha1;
  saslprep = saslprep;
  pass_digest = pass_digest;
  xor_bytestr = xor_bytestr;
  generate_oid = generate_oid;
}
