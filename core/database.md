# Database

## Storage

| field       | value |
| ----------- | ----: |
| slice_bytes | 32768 |

## Recall

| field   | value |
| ------- | ----: |
| degrees |     2 |

```luau
local expected = require("@authority")
local system = require("@system")
local fs = require("@fs")
local sqlite = require("@sqlite")
local json = require("@json")

local sliceBytes = assert(tonumber(document.Storage.slice_bytes), "slice_bytes must be a number")
local degrees = assert(tonumber(document.Recall.degrees), "degrees must be a number")
if sliceBytes < 128 or sliceBytes ~= math.floor(sliceBytes) then error("slice_bytes must be an integer >= 128") end
if degrees < 0 or degrees > 8 or degrees ~= math.floor(degrees) then error("degrees must be an integer between 0 and 8") end

local function integer(value, label, minimum)
    if type(value) ~= "number" or value ~= math.floor(value) or value < minimum then
        error(label .. " must be an integer >= " .. tostring(minimum))
    end
    return value
end

local function text(value, label)
    if type(value) ~= "string" or value == "" then error(label .. " must be nonempty text") end
    return value
end

local schema = [[
PRAGMA foreign_keys=ON;
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS slices(
 idx INTEGER PRIMARY KEY,
 run INTEGER NOT NULL,
 actor TEXT NOT NULL,
 data TEXT NOT NULL,
 overflow TEXT
) STRICT;
CREATE INDEX IF NOT EXISTS slices_by_run ON slices(run,idx);
CREATE TABLE IF NOT EXISTS trails(
 head INTEGER NOT NULL REFERENCES slices(idx),
 position INTEGER NOT NULL,
 slice INTEGER NOT NULL REFERENCES slices(idx),
 PRIMARY KEY(head,position),
 UNIQUE(head,slice)
) WITHOUT ROWID;
CREATE VIRTUAL TABLE IF NOT EXISTS slice_words USING fts5(data,content='slices',content_rowid='idx',tokenize='porter unicode61');
CREATE VIRTUAL TABLE IF NOT EXISTS slice_trigrams USING fts5(data,content='slices',content_rowid='idx',tokenize='trigram');
CREATE TRIGGER IF NOT EXISTS slices_ai AFTER INSERT ON slices BEGIN
 INSERT INTO slice_words(rowid,data) VALUES(new.idx,new.data);
 INSERT INTO slice_trigrams(rowid,data) VALUES(new.idx,new.data);
END;
]]

local function checkedName(name)
    if type(name) ~= "string" or not string.match(name, "^[a-z0-9][a-z0-9-]*$") or
        string.find(name, "--", 1, true) or string.sub(name, -1) == "-" then
        error("agent name must use lowercase letters, digits, and single hyphens")
    end
    return name
end

local function remove(path)
    if fs.exists(path) then fs.remove(path) end
end

local function bounded(overflow, tail)
    return {overflow = overflow, tail = tail}
end

local function terms(query, minimum)
    local result, seen = {}, {}
    for term in string.gmatch(string.lower(query), "[%w_]+") do
        if #term >= minimum and not seen[term] and term ~= "not" and term ~= "no" and term ~= "never" then
            seen[term] = true
            table.insert(result, '"' .. term .. '"')
        end
    end
    return table.concat(result, " OR ")
end

local function open(path, temporary)
    local db = sqlite.open(path)
    db.exec(schema)
    local version = db.prepare("PRAGMA user_version").get().user_version
    if version == 0 then db.exec("PRAGMA user_version=1")
    elseif version ~= 1 then db.close() error("unsupported Database schema version: " .. tostring(version)) end
    local append = db.prepare("INSERT INTO slices(run,actor,data,overflow) VALUES(?,?,?,?)")
    local byRun = db.prepare("SELECT idx,run,actor,data,overflow FROM slices WHERE run=? ORDER BY idx")
    local byIdx = db.prepare("SELECT idx,run,actor,data,overflow FROM slices WHERE idx=?")
    local before = db.prepare("SELECT idx,run,actor,data,overflow FROM slices WHERE idx<? AND run<>? ORDER BY idx DESC")
    local maximum = db.prepare("SELECT coalesce(max(idx),0) AS value FROM slices")
    local maximumRun = db.prepare("SELECT coalesce(max(run),0) AS value FROM slices")
    local addTrail = db.prepare("INSERT INTO trails(head,position,slice) VALUES(?,?,?)")
    local trailHeads = db.prepare("SELECT head FROM trails WHERE slice=? AND head<? ORDER BY head")
    local trailSlices = db.prepare("SELECT slice FROM trails WHERE head=? ORDER BY position")
    local wordSearch = db.prepare([[SELECT s.idx FROM slice_words f JOIN slices s ON s.idx=f.rowid
WHERE slice_words MATCH ? AND s.idx<=? AND s.run<>? ORDER BY bm25(slice_words),s.idx DESC LIMIT ?]])
    local trigramSearch = db.prepare([[SELECT s.idx FROM slice_trigrams f JOIN slices s ON s.idx=f.rowid
WHERE slice_trigrams MATCH ? AND s.idx<=? AND s.run<>? ORDER BY bm25(slice_trigrams),s.idx DESC LIMIT ?]])
    local closed = false

    local function check()
        if closed then error("Database is closed") end
    end

    local function rowValue(row, exact)
        if row.overflow == json.null then return json.decode(row.data) end
        if not exact then return bounded(row.overflow, row.data) end
        if not fs.exists(row.overflow) then error("current continuation payload is unavailable") end
        return json.decode(fs.read(row.overflow))
    end

    local function appendSlice(run, actor, value)
        check()
        run = integer(run, "run", 1)
        actor = text(actor, "actor")
        local exact = json.encode(value)
        local overflow, data = nil, exact
        if #exact > sliceBytes then
            overflow = fs.temporary(exact)
            local empty = json.encode(bounded(overflow, ""))
            if #empty > sliceBytes then remove(overflow) error("overflow reference exceeds slice_bytes") end
            local first = math.max(1, #exact - sliceBytes + 1)
            while first <= #exact and utf8.len(string.sub(exact, first)) == nil do first += 1 end
            data = string.sub(exact, first)
            while #json.encode(bounded(overflow, data)) > sliceBytes do
                local next = utf8.offset(data, 2)
                data = next and string.sub(data, next) or ""
            end
        end
        local ok, result = pcall(append.run, {run, actor, data, overflow or json.null})
        if not ok then if overflow then remove(overflow) end error(result) end
        return tonumber(result.lastInsertRowid)
    end

    local function read(idx)
        check()
        idx = integer(idx, "slice", 1)
        local row = byIdx.get({idx})
        if row == json.null then return nil end
        return rowValue(row, true)
    end

    local function snapshot()
        check()
        return maximum.get().value
    end

    local function nextRun()
        check()
        return maximumRun.get().value + 1
    end

    local function runSlices(run)
        check()
        run = integer(run, "run", 1)
        local result = {}
        for _, row in ipairs(byRun.all({run})) do
            table.insert(result, {idx = row.idx, actor = row.actor, value = rowValue(row, true)})
        end
        return result
    end

    local function recent(snapshotValue, activeRun, bytes)
        check()
        snapshotValue = integer(snapshotValue, "snapshot", 0)
        activeRun = integer(activeRun, "active run", 1)
        bytes = integer(bytes, "recent bytes", 0)
        local rows = {}
        for _, row in ipairs(before.all({snapshotValue + 1, activeRun})) do
            local item = {idx = row.idx, actor = row.actor, value = rowValue(row, false)}
            table.insert(rows, 1, item)
            if #json.encode(rows) > bytes then table.remove(rows, 1) break end
        end
        return rows
    end

    local function seeds(query, snapshotValue, activeRun)
        local expression = terms(query, 1)
        if expression == "" then return {} end
        local rows = wordSearch.all({expression, snapshotValue, activeRun, sliceBytes})
        if #rows > 0 then return rows end
        expression = terms(query, 3)
        if expression == "" then return {} end
        return trigramSearch.all({expression, snapshotValue, activeRun, sliceBytes})
    end

    local function recall(query, snapshotValue, activeRun, excluded)
        check()
        if type(query) ~= "string" then error("recall query must be text") end
        snapshotValue = integer(snapshotValue, "snapshot", 0)
        activeRun = integer(activeRun, "active run", 1)
        if type(excluded) ~= "table" then error("excluded slices must be a table") end
        local scores, frontier = {}, {}
        for rank, row in ipairs(seeds(query, snapshotValue, activeRun)) do
            local score = 1 / rank + 1 / (snapshotValue - row.idx + 1)
            scores[row.idx], frontier[row.idx] = score, score
        end
        for _ = 1, degrees do
            local nextFrontier = {}
            for idx, score in pairs(frontier) do
                local heads = trailHeads.all({idx, snapshotValue + 1})
                for _, head in ipairs(heads) do
                    nextFrontier[head.head] = (nextFrontier[head.head] or 0) + score / (2 * #heads)
                end
                local members = trailSlices.all({idx})
                for _, member in ipairs(members) do
                    nextFrontier[member.slice] = (nextFrontier[member.slice] or 0) + score / (2 * #members)
                end
            end
            frontier = nextFrontier
            for idx, score in pairs(frontier) do scores[idx] = (scores[idx] or 0) + score end
        end
        local ranked = {}
        for idx, score in pairs(scores) do
            if not excluded[idx] then table.insert(ranked, {idx = idx, score = score}) end
        end
        table.sort(ranked, function(a, b) return a.score == b.score and a.idx > b.idx or a.score > b.score end)
        local result = {}
        for _, candidate in ipairs(ranked) do
            local row = byIdx.get({candidate.idx})
            if row ~= json.null then table.insert(result, {idx = row.idx, actor = row.actor, value = rowValue(row, false)}) end
        end
        return result
    end

    local function record(head, slices)
        check()
        head = integer(head, "trail head", 1)
        if type(slices) ~= "table" then error("trail slices must be an array") end
        db.exec("BEGIN IMMEDIATE")
        local ok, failure = pcall(function()
            local seen = {}
            for position, idx in ipairs(slices) do
                if not seen[idx] then addTrail.run({head, position, idx}) seen[idx] = true end
            end
        end)
        db.exec(ok and "COMMIT" or "ROLLBACK")
        if not ok then error(failure) end
    end

    local function close(keepOverflow)
        if closed then return end
        if temporary and not keepOverflow then
            for _, row in ipairs(db.prepare("SELECT overflow FROM slices WHERE overflow IS NOT NULL").all()) do remove(row.overflow) end
        end
        db.close()
        closed = true
        if temporary then remove(path) remove(path .. "-wal") remove(path .. "-shm") end
    end

    return table.freeze({
        append = appendSlice, read = read, snapshot = snapshot, nextRun = nextRun,
        run = runSlices, recent = recent, recall = recall, trail = record,
        close = close, path = path,
    })
end

local function quote(value) return "'" .. string.gsub(value, "'", "''") .. "'" end

return function(authority)
    if authority ~= expected then error("Database requires execution authority") end
    local home = system.getenv("HOME")
    if home == json.null or home == "" then error("HOME is required") end
    local root = fs.resolve(home, ".agents", "agents")
    fs.mkdir(root, true)

    local function permanent(name)
        name = checkedName(name)
        local directory = fs.resolve(root, name)
        fs.mkdir(directory, true)
        return open(fs.resolve(directory, name .. ".sqlite3"), false)
    end

    local function child()
        return open(fs.temporary(""), true)
    end

    local function merge(parent, childDatabase)
        local offset = parent.snapshot()
        local attached = "child_"
        local target = sqlite.open(parent.path)
        local runOffset = target.prepare("SELECT coalesce(max(run),0) AS value FROM slices").get().value
        target.exec("ATTACH " .. quote(childDatabase.path) .. " AS " .. attached .. "; BEGIN IMMEDIATE;")
        local ok, failure = pcall(target.exec, [[
INSERT INTO slices(idx,run,actor,data,overflow)
SELECT idx+]] .. offset .. [[,run+]] .. runOffset .. [[,actor,data,overflow FROM child_.slices ORDER BY idx;
INSERT INTO trails(head,position,slice)
SELECT head+]] .. offset .. [[,position,slice+]] .. offset .. [[ FROM child_.trails;
COMMIT; DETACH child_;
]])
        if not ok then pcall(target.exec, "ROLLBACK; DETACH child_;") target.close() error(failure) end
        target.close()
        childDatabase.close(true)
    end

    local function discard(childDatabase) childDatabase.close(false) end

    local function delete(name)
        name = checkedName(name)
        local directory = fs.resolve(root, name)
        local path = fs.resolve(directory, name .. ".sqlite3")
        if fs.exists(path) then
            local raw = sqlite.open(path)
            for _, row in ipairs(raw.prepare("SELECT overflow FROM slices WHERE overflow IS NOT NULL").all()) do remove(row.overflow) end
            raw.close()
            remove(path) remove(path .. "-wal") remove(path .. "-shm")
        end
    end

    return table.freeze({open = permanent, child = child, merge = merge, discard = discard, delete = delete})
end
```
