#LUA-RESTY-MOONGOO

Adding some lua moondust to the mongo goo

##What is it?

Lua mongodb driver, highly inspired by perl-mango.  
Also, möngö is mongolian currency, and mungu is god in Swahili.

##Table of Contents

* [Requirements](#requirements)
* [Installation](#installation)
* [Usage](#usage)
  * [Moongoo methods](#moongoo-methods)
  * [Database methods](#database-methods)
  * [Collection methods](#collection-methods)
  * [Cursor methods](#cursor-methods)
  * [GridFS methods](#gridfs-methods)
  * [GridFS file methods](#gridfs-file-methods)
* [Authors](#authors)
* [Copyright and License](#copyright-and-license)

##Requirements

* LuaJit or Lua with [BitOp](http://bitop.luajit.org/)
* [lua-libbson](https://github.com/isage/lua-cbson)
* lua-posix

To use outside of OpenResty you'll also need:  
* LuaSocket
* LuaCrypto

##Usage

###Synopsis

```lua
local moongoo = require("resty.moongoo")
local cbson = require("cbson")

local mg, err = moongoo.new("mongodb://user:password@hostname/?w=2")
if not mg then
  error(err)
end

local col = mg:db("test"):collection("test")

-- Insert document
local ids, err = col:insert({ foo = "bar"})

-- Find document
local doc, err = col:find_one({ foo = "bar"})
print(doc.foo)

-- Update document
local doc, err = col:update({ foo = "bar"}, { baz = "yada"})

-- Remove document
local status, err = col:remove({ baz = "yada"})

-- Close connection or put in OpenResty connection pool

mg:close()

```

####NOTE
You **should** use cbson datatypes for anything other than strings, floats and bools.  
All lua numbers are stored as floats.  
Empty arrays are treated and stored as empty documents (may be changed in future).  
nil values are ignored and not stored, due to nature of lua (may be changed in future).  



###Moongoo methods
####`<moongoo_obj>mgobj, <string>error = moongoo.new(<string>connection_string)`
Creates new Moongoo instance  
Refer to [Connection String URI Format](https://docs.mongodb.org/manual/reference/connection-string/)  
Currently supported options are:
* w - default is 0
* wtimeoutMS - default is 1000
* journal - default is false
* authMechanism - default depends on mongodb version
* socketTimeoutMS - default is nil. It controls **both** connect and read/write timeout.  
  It's set to nil by default so you can control connect and read/write separately  
  with OpenResty lua_socket_connect_timeout, lua_socket_send_timeout and lua_socket_read_timeout.

Moongoo tries really hard to be smart, and opens connection only when needed,  
searches for master node in replicaset, and uses relevant to mongodb version auth mechanism.  
Downside is: you can't currently issue queries to slave nodes.

####`mgobj:close()`
Closes mongodb connection (LuaSocket) or puts it in connection pool (OpenResty)  
Issuing new read/write commands after will reopen connection.

####`<database>dbobj = mgobj:db(<string>name)`
Selects database to use.


###Database methods
####`<collection>colobj = dbobj:collection(<string>name)`
Returns new collection object to use.

####`<gridfs>gridfsobj = dbobj:gridfs(<optional string>prefix)`
Returns new gridfs object to use.  
Default prefix id 'fs'.

####`<document>result, <string>error = dbobj:cmd(<string or table>command, <table>params)`
Runs database commans.  
command is either string with command name, or table { command = value }.  
Params are command parameters.
For example, given [distinct](https://docs.mongodb.org/manual/reference/command/distinct/) mongodb command:
```lua
  local result, error = dbobj:cmd( { distinct = "some.collection" }, { key = "somekey } )
```

###Collection methods
####`<collection>new_colobj, <string>error = colobj:create(<string>name)`
Creates new collection and returns new collection object for it.

####`<bool>result, <string>error = colobj:drop()`
Drops collection.

####`<collection>new_colobj, <string>error = colobj:rename(<string>newname, <bool>drop)`
Renames collection, optionally dropping target collection if it exists.

####`<document>result, <string>error = colobj:options()`
Retuns collection options.

####`<string>result = colobj:full_name()`
Returns full collection namespace (e.g. database.collection).

####`<document>result, <string>error = colobj:stats()`
Returns collection statistics.

####`<document>result, <string>error = colobj:index_information()`
Returns info about current indexes.

####`<bool>result, <string>error = colobj:ensure_index(<array>indexes)`
Creates new index.  
indexes **should** be an array, even if it has 1 value..
Refer to [mongo docs](https://docs.mongodb.org/manual/reference/command/createIndexes/) for index format.  
Note, that in moongoo, index names are optional, moongoo will create them for you based on keys.

####`<bool>result, <string>error = colobj:drop_index(<string>index)`
Drops named index from collection.  
Refer to [mongo docs](https://docs.mongodb.org/manual/reference/command/dropIndexes/) for index format.

####`<cursor>cursorobj = colobj:find(<table or cbson.oid>query, <table>fields)`
Returns new cusor object for query.  

####`<document>doc, <string>error = colobj:find_one(<table or cbson.oid>query, <table>fields)`
Returns first document conforming to query.

####`<document>doc, <string>error = colobj:find_and_modify(<table or cbson.oid>query, <table>opts)`
Modifies document, according to [opts](https://docs.mongodb.org/manual/reference/command/findAndModify/)  
and returns (by default) old document.

####`<array>ids, <string or cbson.uint>error_or_number = colobj:insert(<array or table>docs)`
Inserts new document(s) and returns their id's and number of inserted documents.

####`<cbson.uint>number, <string>error = colobj:update(<table  or cbson.oid>query, <table>update, <table>flags)`
Updates document, according to query and flags.  
Supported flags are:
* multi - update multiple documents (default - false)
* upsert - insert document, if not exists (default - false)

Returns number of updated documents

####`<cbson.uint>number, <string>error = colobj:remove(<table  or cbson.oid>queryquery, <bool>single)`
Removes document(s) from database.  
Returns number of removed documents.

####`<cbson.oid>id = colobj:save(<table>document)`
Saves document to collection.  
Basically, this performs update with upsert = true, generating id if it not exist.  
See [here](https://docs.mongodb.org/v3.0/reference/method/db.collection.save/) for explanation.

####`<document>doc, <string>error = colobj:map_reduce(<string>map, <string>reduce, <table>flags)`
####`<collection>new_colobj, <string>error = colobj:map_reduce(<string>map, <string>reduce, <table>flags)`
Performs map-reduce operation and returns either document with results,  
or new collection object (if map-reduce `out` flag set to collection name).

####`<document>explain, <string>error = colobj:aggregate(<array>pipeline, <table>opts)`
####`<collection>new_colobj, <string>error = colobj:aggregate(<array>pipeline, <table>opts)`
####`<cursor>cursor, <string>error = colobj:aggregate(<array>pipeline, <table>opts)`
Performs aggregation operation according to pipeline commands.  
Returns document, if opts.explain set to true.  
Returns collection object, if pipeline has `$out` command as last stage.  
Returns new cursor object otherwise.

###Cursor methods

Note: you can chain-call property/options functions.

####`<cursor>new_cursorobj = cursorobj:clone(<bool>explain)`
Clones cursor query, optionally setting `explain` flag.

####`<cursor>cursorobj = cursorobj:tailable(<bool>tailable)`
####`<cursor>cursorobj = cursorobj:await(<bool>wait)`
####`<cursor>cursorobj = cursorobj:comment(<string>comment)`
####`<cursor>cursorobj = cursorobj:hint(<table>hint)`
####`<cursor>cursorobj = cursorobj:max_scan(<cbson.uint>max_scan)`
####`<cursor>cursorobj = cursorobj:max_time_ms(<cbson.uint>max_time_ms)`
####`<cursor>cursorobj = cursorobj:read_preference(<string>read_preference)`
####`<cursor>cursorobj = cursorobj:snapshot(<bool>snapshot)`
Sets relevant query options.

####`<cursor>cursorobj = cursorobj:sort(<table>sort)`
####`<cursor>cursorobj = cursorobj:skip(<cbson.uint>skip)`
####`<cursor>cursorobj = cursorobj:limit(<cbson.uint>limit)`
Sets sort, skip and limit options.

####`<document>doc, <string>error = cursorobj:next()`
Returns next document, found by query.

####`<cursor>cursorobj = cursorobj:rewind()`
Resets cursor position.

####`<array>documents, <string>error = cursorobj:all()`
Returns array, containing all documents found by query.


####`<cbsin.uint>number = cursorobj:count()`
Returns number of documents, conforming to query.

####`<document>doc, <string>error = cursorobj:explain()`
Returns document with query plan explanation.

####`<document>doc, <string>error = cursorobj:distinct(<string>key)`
Finds the distinct values for a specified field, according to query.


###GridFS methods
####`<document>doc = gridfsobj:list()`
Returns array, containing unique filenames.

####`<cbson.uint>num, <string>err = gridfsobj:remove(<cbson.oid>id)`
Removes file from GridFS.  
Returns number of chunks removed.

####`<cbson.oid>id, <string>err = gridfsobj:find_version(<string>name, <number>version)`
_Not implemented yet_

####`<string>gridfsfile, <string>err = gridfsobj:open(<cbson.oid>id)`
Opens GridFS file for reading.

####`<string>gridfsfile = gridfsobj:create(<string>filename, <table>opts, <bool>safe)`
Creates new GridFS file for writing.  
If `safe` is true (default), all chunks will be inserted only when you call gridfsfile:close().  
If `safe` is false, chunks will be inserted into db with every gridfsfile:write(...),  
last chunk will be inserted on close.  
You **must** call gridfsfile:close(), or you'll end up with orphaned chunks.  
Safe mode is good for small files, however, as it stores entire file in memory, it's bad for big files.  
Non-safe mode uses maximum of (chunkSize*2-1) bytes for any file.  
As a side effect, you can :read() or :slurp() file (except for last chunk).  


###GridFS file methods
####`<string>val = gridfsfile:content_type()`
####`<string>val = gridfsfile:filename()`
####`<string>val = gridfsfile:md5()`
####`<document>val = gridfsfile:metadata()`
####`<cbson.date>val = gridfsfile:date()`
####`<number>val = gridfsfile:length()`
####`<number>val = gridfsfile:chunk_size()`
Returns relevant file properties.

####`<gridfsfile>gridfsfile = gridfsfile:seek(<number>pos)`
Sets offset for reading.

####`<number>pos = gridfsfile:tell()`
Returns current reading position.

####`<string>val, <string>error = gridfsfile:read()`
Returns file data from GridFS, starting from current position and until the end of matching chunk.

####`<string>val, <string>error = gridfsfile:slurp()`
Returns full file contents.

####`<bool>result, <string>error = gridfsfile:write(data)`
Writes data to GridFS file.

####`<cbson.oid>id, <string>error = gridfsfile:close()`
Finalizes file by writing queued chunks and metadata.

##Authors

Epifanov Ivan <isage.dna@gmail.com>

[Back to TOC](#table-of-contents)

##Copyright and License

This module is licensed under the WTFPL license.  
(See LICENSE)