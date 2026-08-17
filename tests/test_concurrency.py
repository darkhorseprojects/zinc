import concurrent.futures
import sqlite3

from support import Package, success


def test_concurrent_requests_and_results_get_unique_ids_and_valid_starts():
    package = Package()
    try:
        entries = []
        for index in range(12):
            entry = f"_writer_{index}.lua"
            entries.append(entry)
            (package.package / entry).write_text(f'''
local store=require('src.store').open{{path='store',max_stored_record_bytes=4096}}
local request=store:begin('actor-{index}','request-{index}')
local result=store:append('actor-{index}',request.id,'assistant','result-{index}')
store:close()
coroutine.yield(tostring(request.id)..':'..tostring(result.id))
''')

        def write(entry):
            output = package.run(entry, authorize=(entry.removesuffix(".lua"), "src.store"), timeout=30)
            return tuple(map(int, success(output).stdout.decode().split(":")))

        with concurrent.futures.ThreadPoolExecutor(max_workers=len(entries)) as pool:
            pairs = list(pool.map(write, entries))
        ids = [value for pair in pairs for value in pair]
        assert len(set(ids)) == len(ids)

        connection = sqlite3.connect(package.home / ".agents/zinc/store/zinc.sqlite3")
        rows = connection.execute("SELECT id,actor,start,role,text FROM results ORDER BY id").fetchall()
        connection.close()
        assert len(rows) == 24
        by_id = {row[0]: row for row in rows}
        for request, result in pairs:
            assert by_id[request][2:4] == (request, "user")
            assert by_id[result][2:4] == (request, "assistant")
            assert by_id[request][1] == by_id[result][1]
    finally:
        package.close()
