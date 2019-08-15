package = "lua-resty-moongoo"
version = "git-1"
source = {
    url = "https://github.com/isage/lua-resty-moongoo/archive/master.zip",
    dir = "lua-resty-moongoo-master"
}
description = {
    summary = "MongoDB library for OpenResty",
    homepage = "https://github.com/isage/lua-resty-moongoo",
    maintainer = "isage.dna@gmail.com",
    license = "WTFPL",
}
dependencies = {
-- "lua-cbson"
}
build = {
    type = "builtin",
    modules = {
        ["moongoo"]             = "lib/resty/moongoo.lua",
        ["moongoo.auth.cr"]     = "lib/resty/moongoo/auth/cr.lua",
        ["moongoo.auth.scram"]  = "lib/resty/moongoo/auth/scram.lua",
        ["moongoo.collection"]  = "lib/resty/moongoo/collection.lua",
        ["moongoo.connection"]  = "lib/resty/moongoo/connection.lua",
        ["moongoo.cursor"]      = "lib/resty/moongoo/cursor.lua",
        ["moongoo.database"]    = "lib/resty/moongoo/database.lua",
        ["moongoo.gridfs"]      = "lib/resty/moongoo/gridfs.lua",
        ["moongoo.gridfs.file"] = "lib/resty/moongoo/gridfs/file.lua",
        ["moongoo.utils"]       = "lib/resty/moongoo/utils.lua",
    }
}