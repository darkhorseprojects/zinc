import sqlite3

from support import Package


def test_results_are_flat_immediate_actor_isolated_and_utf8_bounded():
    package = Package()
    try:
        value = package.lua(r'''
local store=require('src.store').open{path='store',max_stored_record_bytes=5}
local first=store:begin('actor','old 😀 request')
local assistant=store:append('actor',first.start,'assistant','assistant 😀')
local tool=store:append('actor',first.start,'tool','tool 😀')
local current=store:begin('actor','current')
local other=store:begin('other','hidden')
local read=store:read('actor',current.start,assistant.id)
local hidden_actor=store:read('other',other.start,assistant.id)
local hidden_current=store:read('actor',first.start,assistant.id)
local recent={};store:before('actor',current.start,function(record)recent[#recent+1]=record end)
local around=store:around('actor',current.start,assistant.id)
store:close()
return{first=first,assistant=assistant,tool=tool,current=current,other=other,read=read,
 hidden_actor=hidden_actor,hidden_current=hidden_current,recent=recent,around=around}
''', ("src.store",))
        assert value["first"]["id"] == value["first"]["start"]
        assert value["current"]["id"] == value["current"]["start"]
        assert value["assistant"]["start"] == value["first"]["id"]
        assert value["tool"]["role"] == "tool"
        for record in (value["first"], value["assistant"], value["tool"]):
            assert len(record["text"].encode()) <= 5
            record["text"].encode("utf-8")
        assert value["read"]["id"] == value["assistant"]["id"]
        assert value.get("hidden_actor") is None
        assert value.get("hidden_current") is None
        assert [record["id"] for record in value["recent"]] == [
            value["tool"]["id"], value["assistant"]["id"], value["first"]["id"]
        ]
        assert value["around"]["previous"]["id"] == value["first"]["id"]
        assert value["around"]["next"]["id"] == value["tool"]["id"]

        connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
        columns = [row[1] for row in connection.execute("PRAGMA table_info(results)")]
        names = {row[0] for row in connection.execute("SELECT name FROM sqlite_master")}
        fts_columns = [row[1] for row in connection.execute("PRAGMA table_info(result_fts)")]
        version = connection.execute("PRAGMA user_version").fetchone()[0]
        connection.close()
        assert columns == ["id", "actor", "start", "role", "text"]
        assert "result_fts" in names and "runs" not in names and "run_vec" not in names
        assert fts_columns == ["actor", "text"]
        assert version == 1
    finally:
        package.close()


def test_fts_searches_all_terms_once_without_corpus_frequency_filtering():
    package = Package()
    try:
        value = package.lua(r'''
local store=require('src.store').open{path='store',max_stored_record_bytes=1000}
local ids={}
ids[#ids+1]=store:begin('actor','common alpha').id
ids[#ids+1]=store:begin('actor','common beta').id
ids[#ids+1]=store:begin('actor','common gamma').id
ids[#ids+1]=store:begin('actor','rare delta').id
store:begin('other','rare hidden')
local current=store:begin('actor','now')
local found=store:search('actor',current.start,{'common','rare','absent'},100)
local only_common=store:search('actor',current.start,{'common'},2)
local hidden=store:search('other',current.start,{'rare'},100)
store:close();return{ids=ids,found=found,only_common=only_common,hidden=hidden}
''', ("src.store",))
        assert {record["id"] for record in value["found"]} == set(value["ids"])
        assert [record["id"] for record in value["only_common"]] == value["ids"][:2]
        assert len(value["hidden"]) == 1 and value["hidden"][0]["actor"] == "other"
    finally:
        package.close()


def test_fts_preserves_diacritics_and_identifier_literals():
    package = Package()
    try:
        value = package.lua(r'''
local store=require('src.store').open{path='store',max_stored_record_bytes=1000}
local accented=store:begin('actor','automóvil sqlite3_open_v2').id
local plain=store:begin('actor','automovil unrelated').id
local current=store:begin('actor','current')
local first=store:search('actor',current.id,{'automóvil','sqlite3_open_v2'},100)
local second=store:search('actor',current.id,{'automovil'},100)
store:close();return{accented=accented,plain=plain,first=first,second=second}
''', ("src.store",))
        assert {record["id"] for record in value["first"]} == {value["accented"]}
        assert {record["id"] for record in value["second"]} == {value["plain"]}
    finally:
        package.close()


def test_impossible_byte_budget_and_unknown_schema_are_rejected():
    package = Package()
    try:
        root = package.home / ".agents" / "zinc" / "old"
        root.mkdir(parents=True)
        connection = sqlite3.connect(root / "zinc.sqlite3")
        connection.execute("CREATE TABLE runs(id INTEGER PRIMARY KEY)")
        connection.commit()
        connection.close()
        value = package.lua(r'''
local store=require('src.store')
local small,small_failure=pcall(store.open,{path='small',max_stored_record_bytes=3})
local old,old_failure=pcall(store.open,{path='old',max_stored_record_bytes=1000})
return{small=small,small_failure=tostring(small_failure),old=old,old_failure=tostring(old_failure)}
''', ("src.store",))
        assert value["small"] is False and "at least four" in value["small_failure"]
        assert value["old"] is False and "application ID" in value["old_failure"]
    finally:
        package.close()


def test_before_stops_early_and_finalizes_after_callback_failure():
    package = Package()
    try:
        value = package.lua(r'''
local store=require('src.store').open{path='store',max_stored_record_bytes=1000}
local first=store:begin('actor','first');local second=store:begin('actor','second');local current=store:begin('actor','current')
local visited={};store:before('actor',current.id,function(record)visited[#visited+1]=record.id;return false end)
local ok,failure=pcall(store.before,store,'actor',current.id,function()error('visitor failed')end)
local after=store:begin('actor','after');store:close()
return{first=first.id,second=second.id,visited=visited,ok=ok,failure=tostring(failure),after=after.id}
''', ("src.store",))
        assert value["visited"] == [value["second"]]
        assert value["ok"] is False and "visitor failed" in value["failure"]
        assert value["after"] > value["second"]
    finally:
        package.close()


def test_invalid_append_does_not_leave_canonical_or_fts_state():
    package = Package()
    try:
        value = package.lua(r'''
local store=require('src.store').open{path='store',max_stored_record_bytes=1000}
local root=store:begin('actor','root')
local missing=pcall(store.append,store,'actor',999,'tool','not stored')
local empty=pcall(store.append,store,'actor',root.id,'tool','')
local current=store:begin('actor','current')
local records={};store:before('actor',current.id,function(record)records[#records+1]=record end)
local indexed=store:search('actor',current.id,{'stored'},100)
store:close();return{missing=missing,empty=empty,records=records,indexed=indexed}
''', ("src.store",))
        assert value["missing"] is False and value["empty"] is False
        assert len(value["records"]) == 1 and value["records"][0]["text"] == "root"
        assert value["indexed"] == []
    finally:
        package.close()
