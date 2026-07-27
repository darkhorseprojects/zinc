# Database

## Storage

| field       | value |
| ----------- | ----: |
| slice_bytes | 32768 |

## Recall

| field   | value |
| ------- | ----: |
| degrees |     2 |

```teal
local authority = require("@authority")
local sqlite = authority:require("lsqlite3")
local json = authority:require("dkjson")
local io = authority.io
local circuitry = require("@circuitry")

local sliceBytes = assert(math.tointeger(tonumber(document.Storage.slice_bytes)), "slice_bytes must be an integer")
local degrees = assert(math.tointeger(tonumber(document.Recall.degrees)), "degrees must be an integer")
if sliceBytes < 128 then error("slice_bytes must be an integer >= 128") end
if degrees < 0 or degrees > 8 then error("degrees must be an integer between 0 and 8") end

local state = circuitry.agent("zinc").state
local separator = authority.package.config:sub(1, 1)
local path = state .. separator .. "database.sqlite3"
local database = assert(sqlite.open(path))
local version
for row in database:nrows("PRAGMA user_version") do version = row.user_version end
if version ~= 0 and version ~= 1 then database:close(); error("unsupported Database schema version: " .. version) end
local schema = [[
PRAGMA foreign_keys=ON;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS runs(id INTEGER PRIMARY KEY,parent INTEGER REFERENCES runs(id),actor TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN('active','complete','merged','discarded','failed')),result TEXT,created INTEGER NOT NULL DEFAULT(unixepoch())) STRICT;
CREATE TABLE IF NOT EXISTS slices(idx INTEGER PRIMARY KEY,run INTEGER NOT NULL REFERENCES runs(id),actor TEXT NOT NULL,data TEXT NOT NULL,overflow TEXT,search TEXT NOT NULL) STRICT;
CREATE INDEX IF NOT EXISTS slices_by_run ON slices(run,idx);
CREATE TABLE IF NOT EXISTS trails(head INTEGER NOT NULL REFERENCES slices(idx) ON DELETE CASCADE,position INTEGER NOT NULL,slice INTEGER NOT NULL REFERENCES slices(idx) ON DELETE CASCADE,PRIMARY KEY(head,position),UNIQUE(head,slice)) WITHOUT ROWID;
CREATE VIRTUAL TABLE IF NOT EXISTS slice_words USING fts5(search,content='slices',content_rowid='idx',tokenize='porter unicode61');
CREATE VIRTUAL TABLE IF NOT EXISTS slice_trigrams USING fts5(search,content='slices',content_rowid='idx',tokenize='trigram');
CREATE TRIGGER IF NOT EXISTS slices_ai AFTER INSERT ON slices BEGIN INSERT INTO slice_words(rowid,search) VALUES(new.idx,new.search); INSERT INTO slice_trigrams(rowid,search) VALUES(new.idx,new.search); END;
CREATE TRIGGER IF NOT EXISTS slices_ad AFTER DELETE ON slices BEGIN INSERT INTO slice_words(slice_words,rowid,search) VALUES('delete',old.idx,old.search); INSERT INTO slice_trigrams(slice_trigrams,rowid,search) VALUES('delete',old.idx,old.search); END;
PRAGMA user_version=1;
]]
if database:exec(schema) ~= sqlite.OK then error(database:errmsg()) end
if database:exec("CREATE TEMP TABLE IF NOT EXISTS recall_seeds(idx INTEGER PRIMARY KEY,score REAL NOT NULL) STRICT") ~= sqlite.OK then error(database:errmsg()) end

local function encode(value)
   local text, failure = json.encode(value)
   if not text then error(failure) end
   return text
end
local function decode(text)
   local value, _, failure = json.decode(text, 1, json.null)
   if failure then error(failure) end
   return value
end
local function statement(sql, ...)
   local query = assert(database:prepare(sql), database:errmsg())
   if query:bind_values(...) ~= sqlite.OK then local failure = database:errmsg(); query:finalize(); error(failure) end
   return query
end
local function rows(sql, ...)
   local query, result = statement(sql, ...), {}
   for row in query:nrows() do result[#result + 1] = row end
   query:finalize()
   return result
end
local function one(sql, ...)
   local result = rows(sql, ...)
   return result[1]
end
local function execute(sql, ...)
   local query = statement(sql, ...)
   local code = query:step()
   query:finalize()
   if code ~= sqlite.DONE then error(database:errmsg()) end
end
local function transaction(work)
   if database:exec("BEGIN IMMEDIATE") ~= sqlite.OK then error(database:errmsg()) end
   local result = table.pack(pcall(work))
   if database:exec(result[1] and "COMMIT" or "ROLLBACK") ~= sqlite.OK then error(database:errmsg()) end
   if not result[1] then error(result[2]) end
   return table.unpack(result, 2, result.n)
end
local function integer(value, label, minimum)
   if type(value) ~= "number" or value ~= math.floor(value) or value < minimum then error(label .. " must be an integer >= " .. minimum) end
   return value
end
local function remove(pathname)
   if pathname then authority.os.remove(pathname) end
end
local function write(pathname, value)
   local file, failure = io.open(pathname, "wb")
   if not file then error(failure) end
   local ok, message = file:write(value)
   local closed = file:close()
   if not ok or not closed then remove(pathname); error(message or "failed to write continuation") end
end
local function searchText(value)
   local values = {}
   local function visit(item)
      if type(item) == "string" then values[#values + 1] = item elseif type(item) == "table" then for _, child in pairs(item) do visit(child) end end
   end
   visit(value)
   local text = table.concat(values, "\n"):sub(1, sliceBytes)
   while utf8.len(text) == nil do text = text:sub(1, -2) end
   return text
end
local function stored(row, exact)
   if row.overflow == nil then return decode(row.data) end
   if not exact then return {overflow = row.overflow, tail = row.data} end
   local file = io.open(row.overflow, "rb")
   if not file then error("current continuation payload is unavailable") end
   local text = file:read("a"); file:close()
   return decode(text)
end
local function slice(row, exact)
   return {idx = row.idx, actor = row.actor, value = stored(row, exact)}
end

local api = {}
function api.newRun(parent, actor)
   if parent ~= nil then
      integer(parent, "parent Run", 1)
      local owner = one("SELECT status FROM runs WHERE id=?", parent)
      if not owner or owner.status ~= "active" then error("parent Run is not active") end
   end
   if type(actor) ~= "string" or actor == "" then error("actor must be nonempty text") end
   execute("INSERT INTO runs(parent,actor,status) VALUES(?,?,'active')", parent, actor)
   return database:last_insert_rowid()
end
function api.append(run, actor, value)
   run = integer(run, "Run", 1)
   local owner = one("SELECT status FROM runs WHERE id=?", run)
   if not owner or owner.status ~= "active" then error("Run is not active") end
   if type(actor) ~= "string" or actor == "" then error("Slice actor must be nonempty text") end
   local exact, searchable = encode(value), searchText(value)
   return transaction(function()
      local idx = one("SELECT coalesce(max(idx),0)+1 value FROM slices").value
      local overflow, data = nil, exact
      if #exact > sliceBytes then
         overflow = state .. separator .. "slice-" .. idx .. ".json"
         write(overflow, exact)
         data = exact:sub(-sliceBytes)
         while utf8.len(data) == nil do data = data:sub(2) end
      end
      local ok, failure = pcall(execute, "INSERT INTO slices(idx,run,actor,data,overflow,search) VALUES(?,?,?,?,?,?)", idx, run, actor, data, overflow, searchable)
      if not ok then remove(overflow); error(failure) end
      return idx
   end)
end
function api.read(idx)
   local row = one("SELECT idx,actor,data,overflow FROM slices WHERE idx=?", integer(idx, "Slice", 1))
   return row and stored(row, true) or nil
end
function api.snapshot()
   return one("SELECT coalesce(max(idx),0) value FROM slices").value
end
function api.run(run)
   local result = {}
   for _, row in ipairs(rows("SELECT idx,actor,data,overflow FROM slices WHERE run=? ORDER BY idx", integer(run, "Run", 1))) do result[#result + 1] = slice(row, true) end
   return result
end
function api.recent(snapshot, active, bytes)
   snapshot, active, bytes = integer(snapshot, "snapshot", 0), integer(active, "active Run", 1), integer(bytes, "recent bytes", 0)
   local result = {}
   for _, row in ipairs(rows("SELECT s.idx,s.actor,s.data,s.overflow FROM slices s JOIN runs r ON r.id=s.run WHERE s.idx<=? AND s.run<>? AND r.status<>'discarded' ORDER BY s.idx DESC", snapshot, active)) do
      table.insert(result, 1, slice(row, false))
      if #encode(result) > bytes then table.remove(result, 1); break end
   end
   return result
end
local function terms(text, minimum)
   local result, seen = {}, {}
   for term in text:lower():gmatch("[%w_]+") do
      if #term >= minimum and not seen[term] and term ~= "not" and term ~= "no" and term ~= "never" then seen[term] = true; result[#result + 1] = '"' .. term .. '"' end
   end
   return table.concat(result, " OR ")
end
local function candidates(query, snapshot)
   local expression = terms(query, 1)
   local result = expression ~= "" and rows("SELECT rowid idx FROM slice_words WHERE slice_words MATCH ? AND rowid<=? ORDER BY bm25(slice_words),rowid DESC LIMIT 64", expression, snapshot) or {}
   if #result == 0 then
      expression = terms(query, 3)
      result = expression ~= "" and rows("SELECT rowid idx FROM slice_trigrams WHERE slice_trigrams MATCH ? AND rowid<=? ORDER BY bm25(slice_trigrams),rowid DESC LIMIT 64", expression, snapshot) or {}
   end
   return result
end
function api.recall(query, snapshot, active, excluded)
   if type(query) ~= "string" or type(excluded) ~= "table" then error("recall requires text and an exclusion table") end
   snapshot, active = integer(snapshot, "snapshot", 0), integer(active, "active Run", 1)
   if database:exec("DELETE FROM recall_seeds") ~= sqlite.OK then error(database:errmsg()) end
   for rank, row in ipairs(candidates(query, snapshot)) do execute("INSERT INTO recall_seeds VALUES(?,?)", row.idx, 1 / rank + 1 / (snapshot - row.idx + 1)) end
   local graph = [[WITH RECURSIVE walk(idx,depth,weight) AS (SELECT idx,0,score FROM recall_seeds UNION ALL SELECT CASE WHEN t.head=w.idx THEN t.slice ELSE t.head END,w.depth+1,w.weight*0.5 FROM walk w JOIN trails t ON t.head=w.idx OR t.slice=w.idx WHERE w.depth<?), ranked AS (SELECT idx,sum(weight) score FROM walk GROUP BY idx) SELECT s.idx,s.actor,s.data,s.overflow FROM ranked x JOIN slices s ON s.idx=x.idx JOIN runs r ON r.id=s.run WHERE s.idx<=? AND s.run<>? AND r.status<>'discarded' ORDER BY x.score DESC,s.idx DESC LIMIT 128]]
   local result = {}
   for _, row in ipairs(rows(graph, degrees, snapshot, active)) do if not excluded[row.idx] then result[#result + 1] = slice(row, false) end end
   return result
end
function api.trail(head, selected)
   head = integer(head, "Trail head", 1)
   if type(selected) ~= "table" then error("Trail selection must be an array") end
   transaction(function()
      local seen = {}
      for position, idx in ipairs(selected) do if not seen[idx] and idx ~= head then execute("INSERT OR IGNORE INTO trails VALUES(?,?,?)", head, position, integer(idx, "Trail Slice", 1)); seen[idx] = true end end
   end)
end
function api.complete(run, result)
   execute("UPDATE runs SET status='complete',result=? WHERE id=? AND status='active'", encode(result), integer(run, "Run", 1))
end
function api.fail(run, failure)
   execute("UPDATE runs SET status='failed',result=? WHERE id=? AND status='active'", encode(tostring(failure)), integer(run, "Run", 1))
end
function api.result(run)
   local row = one("SELECT status,result,parent,actor FROM runs WHERE id=?", integer(run, "Run", 1))
   if not row or row.status == "discarded" then error("invalid Run reference") end
   return row.result and decode(row.result) or nil, row
end
function api.merge(child, parent)
   child, parent = integer(child, "child Run", 1), integer(parent, "parent Run", 1)
   local row = one("SELECT parent,status FROM runs WHERE id=?", child)
   if not row or row.parent ~= parent or row.status ~= "complete" then error("only a completed child Run can be merged") end
   execute("UPDATE runs SET status='merged' WHERE id=?", child)
   api.append(parent, "merge", {run = child})
end
function api.discard(child, parent)
   child, parent = integer(child, "child Run", 1), integer(parent, "parent Run", 1)
   local row = one("SELECT parent,status FROM runs WHERE id=?", child)
   if not row or row.parent ~= parent or row.status == "active" or row.status == "merged" or row.status == "discarded" then error("child Run cannot be discarded") end
   transaction(function()
      for _, item in ipairs(rows("SELECT overflow FROM slices WHERE run=? AND overflow IS NOT NULL", child)) do remove(item.overflow) end
      execute("DELETE FROM slices WHERE run=?", child)
      execute("UPDATE runs SET status='discarded',result=NULL WHERE id=?", child)
   end)
end
return function(token)
   if token ~= authority then error("Database authority is required") end
   return api
end
```
