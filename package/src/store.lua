local sqlite = require("lsqlite3complete")
local encode_json = require("lunajson.encoder")()
local decode_json = require("lunajson.decoder")()

local SCHEMA = [[
CREATE TABLE runs(
 id INTEGER PRIMARY KEY,
 request TEXT UNIQUE,
 actor TEXT NOT NULL,
 config TEXT NOT NULL CHECK(json_valid(config))
) STRICT;
CREATE TABLE branches(
 id INTEGER PRIMARY KEY,
 run INTEGER NOT NULL REFERENCES runs(id),
 caller INTEGER REFERENCES events(id),
 base INTEGER REFERENCES events(id),
 memory_start INTEGER REFERENCES events(id),
 memory_end INTEGER REFERENCES events(id),
 preset TEXT NOT NULL,
 CHECK((memory_start IS NULL AND memory_end IS NULL) OR
       (memory_start IS NOT NULL AND memory_end IS NOT NULL AND memory_start<=memory_end))
) STRICT;
CREATE UNIQUE INDEX root_branch_by_run ON branches(run) WHERE caller IS NULL;
CREATE INDEX branches_by_run ON branches(run,id);
CREATE TABLE events(
 id INTEGER PRIMARY KEY,
 run INTEGER NOT NULL REFERENCES runs(id),
 branch INTEGER REFERENCES branches(id),
 call INTEGER REFERENCES events(id),
 kind TEXT NOT NULL CHECK(kind IN (
  'user','response','call','result','context','summary','ambiguity',
  'completed','abort','error','quota_charge'
 )),
 created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 text TEXT NOT NULL DEFAULT '',
 data TEXT NOT NULL CHECK(json_valid(data)),
 estimated_tokens INTEGER NOT NULL DEFAULT 0 CHECK(estimated_tokens>=0)
) STRICT;
CREATE INDEX runs_by_actor ON runs(actor,id);
CREATE INDEX events_by_run ON events(run,id);
CREATE INDEX events_by_branch ON events(branch,id);
CREATE UNIQUE INDEX result_by_call ON events(call) WHERE kind='result';
CREATE UNIQUE INDEX ambiguity_by_call ON events(call) WHERE kind='ambiguity';
CREATE UNIQUE INDEX branch_completion ON events(branch) WHERE kind='completed';
CREATE UNIQUE INDEX run_abort ON events(run) WHERE kind='abort';
CREATE UNIQUE INDEX context_by_branch ON events(branch) WHERE kind='context';
CREATE INDEX summaries_by_range ON events(
 json_extract(data,'$.memory_range.start'),json_extract(data,'$.memory_range.end')
) WHERE kind='summary';
CREATE TABLE summary_children(
 child INTEGER PRIMARY KEY REFERENCES events(id),
 parent INTEGER NOT NULL REFERENCES events(id)
) STRICT;
CREATE VIRTUAL TABLE event_fts USING fts5(
 text,content='events',content_rowid='id',tokenize='unicode61 remove_diacritics 0'
);
CREATE TRIGGER event_fts_insert AFTER INSERT ON events
WHEN new.kind IN ('user','response','completed','result') AND length(new.text)>0 BEGIN
 INSERT INTO event_fts(rowid,text) VALUES(new.id,new.text);
END;
CREATE TABLE lexemes(
 id INTEGER PRIMARY KEY,actor TEXT NOT NULL,term TEXT NOT NULL,UNIQUE(actor,term)
) STRICT;
CREATE TABLE event_lexemes(
 event INTEGER NOT NULL REFERENCES events(id),lexeme INTEGER NOT NULL REFERENCES lexemes(id),
 PRIMARY KEY(event,lexeme)
) WITHOUT ROWID;
CREATE INDEX event_lexemes_by_lexeme ON event_lexemes(lexeme,event);
CREATE VIRTUAL TABLE lexeme_grams USING fts5(
 term,content='lexemes',content_rowid='id',tokenize='trigram',detail='none'
);
CREATE TRIGGER lexeme_grams_insert AFTER INSERT ON lexemes BEGIN
 INSERT INTO lexeme_grams(rowid,term) VALUES(new.id,new.term);
END;
CREATE TRIGGER immutable_events_update BEFORE UPDATE ON events BEGIN
 SELECT raise(ABORT,'events are immutable');
END;
CREATE TRIGGER immutable_events_delete BEFORE DELETE ON events BEGIN
 SELECT raise(ABORT,'events are immutable');
END;
]]
local RECORD = "SELECT e.* FROM events e JOIN runs r ON r.id=e.run "
local SCOPE = "r.actor=? AND e.id BETWEEN ? AND ? "
local MEMORY =
    "e.kind IN ('user','response','completed','call','result','ambiguity','abort','error') AND length(e.text)>0 AND EXISTS(SELECT 1 FROM branches b WHERE b.run=e.run) "

return function(config, null)
    local db = assert(sqlite.open(config.store))
    db:busy_timeout(5000)
    local statements, store = {}, {}

    local function rows(sql, ...)
        local statement = statements[sql]
        if not statement then
            statement = assert(db:prepare(sql), db:errmsg())
            statements[sql] = statement
        end
        statement:reset()
        assert(statement:bind_values(...) == sqlite.OK, db:errmsg())
        local output = {}
        for row in statement:nrows() do
            if row.data then
                row.data = decode_json(row.data, 1, null)
            end
            output[#output + 1] = row
        end
        assert(db:errcode() == sqlite.OK or db:errcode() == sqlite.DONE, db:errmsg())
        return output
    end

    local function transaction(body)
        assert(db:exec("BEGIN IMMEDIATE") == sqlite.OK, db:errmsg())
        local result = table.pack(pcall(body))
        if result[1] then
            local committed = db:exec("COMMIT")
            if committed == sqlite.OK then
                return table.unpack(result, 2, result.n)
            end
        end
        local problem = result[1] and db:errmsg() or result[2]
        db:exec("ROLLBACK")
        error(problem, 0)
    end

    function store:close(original)
        local problem
        for _, statement in pairs(statements) do
            if statement:finalize() ~= sqlite.OK then
                problem = problem or db:errmsg()
            end
        end
        local closed = db:close()
        if original == nil then
            assert(not problem, problem)
            assert(closed == sqlite.OK, "failed to close Store")
        end
    end

    local opened, problem = pcall(function()
        assert(
            db:exec("PRAGMA trusted_schema=OFF; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON") == sqlite.OK,
            db:errmsg()
        )
        local version = rows("PRAGMA user_version")[1].user_version
        assert(version == 0 or version == 6, "unsupported Store format; use a fresh Store")
        assert(db:exec("PRAGMA journal_mode=WAL") == sqlite.OK, db:errmsg())
        if version == 0 then
            transaction(function()
                local current = rows("PRAGMA user_version")[1].user_version
                assert(current == 0 or current == 6, "unsupported Store format; use a fresh Store")
                if current == 0 then
                    assert(db:exec(SCHEMA .. "PRAGMA user_version=6") == sqlite.OK, db:errmsg())
                end
            end)
        end
        assert(db:exec([[
CREATE VIRTUAL TABLE temp.event_tokenizer USING fts5(text,tokenize='unicode61 remove_diacritics 0');
CREATE VIRTUAL TABLE temp.event_vocabulary USING fts5vocab(event_tokenizer,'row');
CREATE VIRTUAL TABLE temp.event_positions USING fts5vocab(event_tokenizer,'instance');
]]) == sqlite.OK, db:errmsg())
    end)
    if not opened then
        store:close(problem)
        error(problem, 0)
    end

    function store:run(reference, snapshot)
        local field = type(reference) == "string" and "request" or "id"
        local selected = snapshot and ",r.config" or ""
        local row = rows([[
SELECT r.id,json_extract(r.config,'$.run.tool_quota')-coalesce(sum(e.estimated_tokens),0) remaining,
coalesce(sum(e.estimated_tokens),0) used,
max(CASE WHEN e.kind='abort' OR e.kind='completed' AND b.id IS NOT NULL AND b.caller IS NULL THEN e.kind END) state
]] .. selected .. [[ FROM runs r LEFT JOIN events e ON e.run=r.id LEFT JOIN branches b ON b.id=e.branch
WHERE r.actor=? AND r.]] .. field .. "=? GROUP BY r.id", config.actor, reference)[1]
        if row then
            row.state = row.state or "unfinished"
            if snapshot then
                row.config = decode_json(row.config, 1, null)
            end
        end
        return row
    end

    function store:tokens(text, limit)
        assert(db:exec("DELETE FROM temp.event_tokenizer") == sqlite.OK, db:errmsg())
        rows("INSERT INTO temp.event_tokenizer(rowid,text) VALUES(1,?) RETURNING rowid", text)
        return rows("SELECT term FROM temp.event_positions WHERE doc=1 ORDER BY offset LIMIT ?", limit)
    end

    local function append(call, events)
        local output = {}
        for index, event in ipairs(events) do
            local text, amount = event.text or "", event.estimated_tokens or 0
            assert(type(text) == "string" and utf8.len(text), "invalid event text")
            if event.kind == "call" and call.persist then
                event.data.message = output[1].id
            end
            local row = event
            if call.persist or amount > 0 then
                row = rows(
                    [[
INSERT INTO events(run,branch,call,kind,text,data,estimated_tokens) VALUES(?,?,?,?,?,?,?) RETURNING *
]],
                    call.run,
                    call.persist and call.branch or nil,
                    event.call,
                    call.persist and event.kind or "quota_charge",
                    call.persist and text or "",
                    encode_json(call.persist and event.data or {}, null),
                    amount
                )[1]
                if not call.persist then
                    if event.kind == "call" then
                        event.id = row.id
                    end
                    row = event
                elseif
                    (
                        event.kind == "user"
                        or event.kind == "response"
                        or event.kind == "completed"
                        or event.kind == "result"
                    ) and text ~= ""
                then
                    store:tokens(text, 0)
                    rows(
                        [[
INSERT INTO lexemes(actor,term) SELECT ?,term FROM temp.event_vocabulary WHERE length(term)<=128
ON CONFLICT(actor,term) DO NOTHING
]],
                        config.actor
                    )
                    rows(
                        [[
INSERT INTO event_lexemes(event,lexeme) SELECT ?,l.id FROM temp.event_vocabulary v
JOIN lexemes l ON l.actor=? AND l.term=v.term WHERE length(v.term)<=128
]],
                        row.id,
                        config.actor
                    )
                end
            end
            output[index] = row
        end
        return output
    end

    function store:append(call, events)
        local inserted = transaction(function()
            local current = assert(self:run(call.run), "run is unavailable")
            local charge = 0
            for _, event in ipairs(events) do
                if event.kind == "response" or event.kind == "call" then
                    assert(current.state == "unfinished", "run is terminal")
                end
                if event.kind == "call" then
                    charge = charge + event.estimated_tokens
                end
            end
            assert(charge == 0 or charge <= current.remaining, "tool quota exhausted; no tools dispatched")
            if events[1].kind == "response" and not events[1].data.message.tool_calls then
                events[1].kind = "completed"
            end
            local last, produced = events[#events], 0
            for _, event in ipairs(events) do
                produced = produced + (event.estimated_tokens or 0)
            end
            if last.kind == "result" then
                last.data.message.content = last.text
                    .. "\n[tool_quota_remaining="
                    .. (current.remaining - produced)
                    .. "]"
            end
            return append(call, events)
        end)
        for _, event in ipairs(inserted) do
            call.events[#call.events + 1] = event
        end
        return inserted
    end

    function store:node(id)
        return assert(
            rows(
                [[
SELECT e.id,e.run,e.branch,e.call,e.kind,e.text,e.created_at,CASE WHEN e.kind='summary' THEN e.data ELSE '{}' END data
FROM events e JOIN runs r ON r.id=e.run WHERE r.actor=? AND e.id=?
]],
                config.actor,
                id
            )[1],
            "memory is unavailable"
        )
    end

    function store:start(value, caller, snapshot)
        return transaction(function()
            if value.persist and value.request then
                local existing = self:run(value.request)
                if existing then
                    return { existing = existing.id }
                end
            end
            local run = caller and caller.run
            if run then
                assert(self:run(run).state == "unfinished", "run is terminal")
            else
                local saved = value.persist and snapshot or { run = { tool_quota = snapshot.run.tool_quota } }
                run = rows(
                    "INSERT INTO runs(request,actor,config) VALUES(?,?,?) RETURNING id",
                    value.persist and value.request or nil,
                    config.actor,
                    encode_json(saved, null)
                )[1].id
            end
            local base = value.parent
            if value.automatic then
                local head =
                    rows(RECORD .. "WHERE r.actor=? AND e.kind='completed' ORDER BY e.id DESC LIMIT 1", config.actor)[1]
                base = head and head.id or nil
            end
            if base then
                self:node(base)
            end
            local range = value.memory_range
            if range.start == nil and range["end"] == nil then
                local first = rows(
                    RECORD .. "WHERE r.actor=? AND e.id<=? AND " .. MEMORY .. "ORDER BY e.id LIMIT 1",
                    config.actor,
                    base or 0
                )[1]
                range = { start = first and first.id or 0, ["end"] = base or 0 }
            end
            assert(
                range.start ~= nil
                    and range["end"] ~= nil
                    and range.start <= range["end"]
                    and (range.start == 0) == (range["end"] == 0),
                "invalid memory_range"
            )
            for _, id in ipairs({ range.start, range["end"] }) do
                if id ~= 0 then
                    self:node(id)
                end
            end
            local call = {
                run = run,
                persist = value.persist,
                preset_name = value.preset or config.preset,
                parent = base,
                memory_range = range,
                text = value.text,
                events = {},
                root = not caller,
            }
            if call.persist then
                call.branch = rows(
                    [[
INSERT INTO branches(run,caller,base,memory_start,memory_end,preset) VALUES(?,?,?,?,?,?) RETURNING id
]],
                    run,
                    caller and caller.call,
                    base,
                    range.start ~= 0 and range.start or nil,
                    range["end"] ~= 0 and range["end"] or nil,
                    call.preset_name
                )[1].id
            else
                call.branch = -(caller and caller.call * 2 + 1 or run * 2)
            end
            local content = value.text
            if value.images then
                content = { { type = "text", text = value.text } }
                for _, image in ipairs(value.images) do
                    content[#content + 1] =
                        { type = "image_url", image_url = { url = "data:" .. image.type .. ";base64," .. image.data } }
                end
            end
            local user = append(
                call,
                { { kind = "user", text = value.text, data = { message = { role = "user", content = content } } } }
            )[1]
            call.id, call.events[1] = user.id, user
            return call
        end)
    end

    function store:caller(caller)
        assert(
            rows(
                RECORD .. "WHERE r.actor=? AND e.id=? AND e.run=? AND e.kind IN ('call','quota_charge')",
                config.actor,
                caller.call,
                caller.run
            )[1],
            "caller is unavailable"
        )
        assert(self:run(caller.run).state == "unfinished", "run is terminal")
    end

    function store:context(range)
        return rows(
            [[
SELECT json_extract(e.data,'$.chronological') data,b.memory_end last FROM events e
JOIN branches b ON b.id=e.branch JOIN runs r ON r.id=e.run
WHERE r.actor=? AND e.kind='context' AND b.caller IS NULL
AND coalesce(b.memory_start,0)=? AND coalesce(b.memory_end,0)<=? ORDER BY e.id DESC LIMIT 1
]],
            config.actor,
            range.start,
            range["end"]
        )[1]
    end

    function store:pending()
        return rows(
            [[
SELECT r.id FROM runs r WHERE r.actor=? AND EXISTS(SELECT 1 FROM branches b WHERE b.run=r.id)
AND NOT EXISTS(SELECT 1 FROM events e LEFT JOIN branches b ON b.id=e.branch
 WHERE e.run=r.id AND (e.kind='abort' OR e.kind='completed' AND b.id IS NOT NULL AND b.caller IS NULL)) ORDER BY r.id
]],
            config.actor
        )
    end

    function store:resume(run)
        local saved = assert(self:run(run, true), "run is unavailable")
        local calls = rows(
            [[
SELECT b.run,b.id branch,b.caller,b.base parent,b.memory_start,b.memory_end,b.preset preset_name,u.id,u.text
FROM branches b JOIN events u ON u.branch=b.id AND u.kind='user' WHERE b.run=?
AND NOT EXISTS(SELECT 1 FROM events e WHERE e.branch=b.id
 AND (e.kind='completed' OR e.kind='error' AND b.caller IS NOT NULL)) ORDER BY b.id DESC
]],
            run
        )
        for _, call in ipairs(calls) do
            call.persist, call.root = true, call.caller == nil
            call.memory_range = { start = call.memory_start or 0, ["end"] = call.memory_end or 0 }
            call.events = rows("SELECT * FROM events WHERE branch=? ORDER BY id", call.branch)
        end
        return saved.config, calls
    end

    function store:recover(call)
        local notices = {}
        for _, event in
            ipairs(rows(
                [[
SELECT c.id,json_extract(m.data,'$.message.tool_calls['||(json_extract(c.data,'$.index')-1)||'].id') tool
FROM events c JOIN events m ON m.id=json_extract(c.data,'$.message') WHERE c.branch=? AND c.kind='call'
AND NOT EXISTS(SELECT 1 FROM events e WHERE e.call=c.id AND e.kind IN ('result','ambiguity')) ORDER BY c.id
]],
                call.branch
            ))
        do
            local text = "AMBIGUOUS / UNTRUSTED: call #"
                .. event.id
                .. " has no committed result. Effects may have happened. Do not replay its code; inspect or reconcile first."
            for _, child in
                ipairs(rows(
                    [[
SELECT b.id,substr(e.text,1,?) text FROM branches b JOIN events e ON e.branch=b.id
WHERE b.caller=? AND e.kind IN ('completed','error') ORDER BY b.id
]],
                    config.run.tool_result_tokens,
                    event.id
                ))
            do
                text = text
                    .. "\nCommitted subcall #"
                    .. child.id
                    .. " (does not resolve the enclosing call):\n"
                    .. child.text
            end
            notices[#notices + 1] = {
                kind = "ambiguity",
                call = event.id,
                text = text,
                data = { message = { role = "tool", tool_call_id = event.tool, content = text }, trusted = false },
            }
        end
        if #notices > 0 then
            self:append(call, notices)
        end
    end

    function store:events(run, after)
        return rows(RECORD .. "WHERE r.actor=? AND e.run=? AND e.id>? ORDER BY e.id", config.actor, run, after or 0)
    end

    function store:abort(reference, reason)
        return transaction(function()
            local run = self:run(reference)
            if not run and type(reference) == "string" then
                local id = rows(
                    "INSERT INTO runs(request,actor,config) VALUES(?,?,?) RETURNING id",
                    reference,
                    config.actor,
                    encode_json({ run = { tool_quota = config.run.tool_quota } }, null)
                )[1].id
                run = self:run(id)
            end
            assert(run, "run is unavailable")
            if run.state == "completed" then
                return { run = run.id, state = "completed" }
            end
            if run.state == "unfinished" then
                append({ run = run.id, persist = true }, {
                    {
                        kind = "abort",
                        text = "Run aborted: " .. reason .. ". Unresolved effects are unknown.",
                        data = { reason = reason },
                    },
                })
            end
            return { run = run.id, state = "aborted" }
        end)
    end

    function store:result(run)
        local current = assert(self:run(run), "run is unavailable")
        assert(current.state == "completed", "run is not completed")
        local result = rows(
            [[
SELECT final.id event,final.text,final.created_at,b.id branch,b.base parent,b.memory_start,b.memory_end,u.id start
FROM events final JOIN branches b ON b.id=final.branch JOIN events u ON u.branch=b.id AND u.kind='user'
WHERE final.run=? AND final.kind='completed' AND b.caller IS NULL
]],
            run
        )[1]
        result.run, result.parent, result.tool_usage = run, result.parent or 0, current.used
        result.memory_range = { start = result.memory_start or 0, ["end"] = result.memory_end or 0 }
        result.memory_start, result.memory_end = nil, nil
        return result
    end

    function store:search(range, terms, limit, covered)
        if #terms == 0 or range["end"] == 0 then
            return {}
        end
        local literals = {}
        for index, term in ipairs(terms) do
            literals[index] = '"' .. term:gsub('"', '""') .. '"'
        end
        return rows([[
SELECT e.id,e.call,e.kind,e.created_at,snippet(event_fts,0,'','',' … ',64) text
FROM event_fts JOIN events e ON e.id=event_fts.rowid JOIN runs r ON r.id=e.run
WHERE event_fts MATCH ? AND ]] .. SCOPE .. [[AND NOT EXISTS(
 SELECT 1 FROM json_each(?) bounds WHERE e.id BETWEEN json_extract(bounds.value,'$.start') AND json_extract(bounds.value,'$.end')
) ORDER BY bm25(event_fts),e.id LIMIT ?
]], table.concat(literals, " OR "), config.actor, range.start, range["end"], encode_json(covered, null), limit)
    end

    function store:lexemes(range, grams, limit)
        local exact = {}
        for _, row in
            ipairs(rows(
                [[
SELECT DISTINCT l.term FROM temp.event_positions input JOIN lexemes l ON l.term=input.term
WHERE input.offset<? AND l.actor=? AND EXISTS(
 SELECT 1 FROM event_lexemes link WHERE link.lexeme=l.id AND link.event BETWEEN ? AND ?
)
]],
                limit,
                config.actor,
                range.start,
                range["end"]
            ))
        do
            exact[row.term] = true
        end
        local near = {}
        if grams ~= "" then
            near = rows(
                [[
SELECT l.term FROM lexeme_grams JOIN lexemes l ON l.id=lexeme_grams.rowid
WHERE lexeme_grams MATCH ? AND l.actor=? AND EXISTS(
 SELECT 1 FROM event_lexemes link WHERE link.lexeme=l.id AND link.event BETWEEN ? AND ?
) ORDER BY bm25(lexeme_grams),l.id LIMIT ?
]],
                grams,
                config.actor,
                range.start,
                range["end"],
                limit
            )
        end
        return exact, near
    end

    function store:nodes(range)
        return rows([[
WITH memory_range AS (SELECT ? actor,? first,? last), roots AS (
 SELECT e.*,json_extract(e.data,'$.memory_range.start') first,json_extract(e.data,'$.memory_range.end') last
 FROM events e JOIN runs r ON r.id=e.run CROSS JOIN memory_range m
 WHERE r.actor=m.actor AND e.kind='summary'
 AND json_extract(e.data,'$.memory_range.start')>=m.first AND json_extract(e.data,'$.memory_range.end')<=m.last
 AND NOT EXISTS(
  SELECT 1 FROM summary_children link JOIN events parent ON parent.id=link.parent
  WHERE link.child=e.id AND json_extract(parent.data,'$.memory_range.start')>=m.first
  AND json_extract(parent.data,'$.memory_range.end')<=m.last
 )
)
SELECT id,run,branch,call,kind,text,data,created_at,first,last,1 boundary FROM roots UNION ALL
SELECT e.id,e.run,e.branch,e.call,e.kind,e.text,'{}',e.created_at,e.id,e.id,
 e.kind IN ('completed','abort','error','ambiguity','result') boundary
FROM events e JOIN runs r ON r.id=e.run CROSS JOIN memory_range m
WHERE r.actor=m.actor AND e.id BETWEEN m.first AND m.last AND ]] .. MEMORY .. [[
AND NOT EXISTS(SELECT 1 FROM roots s WHERE e.id BETWEEN s.first AND s.last) ORDER BY first
]], config.actor, range.start, range["end"])
    end

    function store:summary(run, range, children, text)
        return transaction(function()
            local existing = rows(RECORD .. [[WHERE r.actor=? AND e.kind='summary'
AND json_extract(e.data,'$.memory_range.start')=? AND json_extract(e.data,'$.memory_range.end')=? LIMIT 1
]], config.actor, range.start, range["end"])[1]
            if existing then
                return existing
            end
            local height = 0
            for _, id in ipairs(children) do
                local child = self:node(id)
                height = math.max(height, child.kind == "summary" and child.data.height or 0)
            end
            assert(self:run(run), "run is unavailable")
            local summary = append({ run = run, persist = true }, {
                {
                    kind = "summary",
                    text = text,
                    data = { memory_range = range, children = children, height = height + 1 },
                },
            })[1]
            for _, id in ipairs(children) do
                rows("INSERT INTO summary_children(child,parent) VALUES(?,?)", id, summary.id)
            end
            return summary
        end)
    end

    return setmetatable(store, { __close = store.close })
end
