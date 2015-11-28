local pass_digest = require("resty.moongoo.utils").pass_digest

local b64 = ngx and ngx.encode_base64 or require("mime").b64
local unb64 = ngx and ngx.decode_base64 or require("mime").unb64

local md5 = ngx and ngx.md5 or function(str) return require("crypto").digest("md5", str) end

local cbson = require("cbson")


local function auth(db, username, password)
  local r, err = db:_cmd("getnonce", {})
  if not r then
      return nil, err
  end

  local digest = md5( r.nonce .. username .. pass_digest ( username , password ) )

  r, err = db:_cmd("authenticate", {
    user = username ;
    nonce = r.nonce ;
    key = digest ;
  })

  if not r then
    return nil, err
  end

  return 1
end

return auth