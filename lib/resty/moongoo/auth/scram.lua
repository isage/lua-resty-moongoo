local Hi = require("resty.moongoo.utils").pbkdf2_hmac_sha1
local saslprep = require("resty.moongoo.utils").saslprep
local pass_digest = require("resty.moongoo.utils").pass_digest
local xor_bytestr = require("resty.moongoo.utils").xor_bytestr

local b64 = ngx and ngx.encode_base64 or require("mime").b64
local unb64 = ngx and ngx.decode_base64 or require("mime").unb64

local hmac_sha1 = ngx and ngx.hmac_sha1 or function(str, key) return require("crypto").hmac.digest("sha1", key, str, true) end
local sha1_bin = ngx and ngx.sha1_bin or function(str) return require("crypto").digest("sha1", str, true) end

local cbson = require("cbson")


local function auth(db, username, password)
  local username = saslprep(username)
  local c_nonce = b64(string.sub(tostring(math.random()), 3 , 14))

  local first_bare = "n="  .. username .. ",r="  .. c_nonce

  local sasl_start_payload = b64("n,," .. first_bare)
    
  r, err = db:_cmd("saslStart", {
    mechanism = "SCRAM-SHA-1" ;
    autoAuthorize = 1 ;
    payload =  cbson.binary(sasl_start_payload);
  })

  if not r then
    return nil, err
  end

    
  local conversationId = r['conversationId']
  local server_first = r['payload']:raw()

  local parsed_t = {}
  for k, v in string.gmatch(server_first, "(%w+)=([^,]*)") do
    parsed_t[k] = v
  end

  local iterations = tonumber(parsed_t['i'])
  local salt = parsed_t['s']
  local s_nonce = parsed_t['r']

  if not string.sub(s_nonce, 1, 12) == c_nonce then
    return nil, 'Server returned an invalid nonce.'
  end

  local without_proof = "c=biws,r=" .. s_nonce

  local pbkdf2_key = pass_digest ( username , password )
  local salted_pass = Hi(pbkdf2_key, iterations, unb64(salt), 20)

  local client_key = hmac_sha1(salted_pass, "Client Key")
  local stored_key = sha1_bin(client_key)
  local auth_msg = first_bare .. ',' .. server_first .. ',' .. without_proof
  local client_sig = hmac_sha1(stored_key, auth_msg)
  local client_key_xor_sig = xor_bytestr(client_key, client_sig)
  local client_proof = "p=" .. b64(client_key_xor_sig)
  local client_final = b64(without_proof .. ',' .. client_proof)
  local server_key = hmac_sha1(salted_pass, "Server Key")
  local server_sig = b64(hmac_sha1(server_key, auth_msg))
    
  r, err = db:_cmd("saslContinue",{
    conversationId = conversationId ;
    payload =  cbson.binary(client_final);
  })

  if not r then
    return nil, err
  end

  local parsed_s = r['payload']:raw()
  parsed_t = {}
  for k, v in string.gmatch(parsed_s, "(%w+)=([^,]*)") do
    parsed_t[k] = v
  end
  if parsed_t['v'] ~= server_sig then
    return nil, "Server returned an invalid signature."
  end
    
  if not r['done'] then
    r, err = db:_cmd("saslContinue", {
      conversationId = conversationId ;
      payload =  cbson.binary("") ;
    })

    if not r then
      return nil, err
    end

    if not r['done'] then
      return nil, 'SASL conversation failed to complete.'
    end

    return 1
  end

  return 1
end

return auth
