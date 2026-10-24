(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)
(import ./schema)
(import spork/path :as path)

(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn query [s statement &opt parameters] (sql/eval (s :db) statement (or parameters [])))

(defmacro transact [s & body]
  (def db (gensym))
  ~(let [,db (,s :db)]
     (if (= ,db (dyn :zinc/transaction)) (do ,;body)
       (do
         (,sql/eval ,db "BEGIN IMMEDIATE")
         (try
           (let [result (with-dyns [:zinc/transaction ,db] ,;body)] (,sql/eval ,db "COMMIT") result)
           ([err] (,sql/eval ,db "ROLLBACK") (error err)))))))

(defn open [config &opt temporary]
  (def s @{:db (sql/open (config :store)) :journal (if temporary "journal" "main")
           :source (config :source) :config config :temporary temporary :profiles @{}})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA temp_store=MEMORY;")
      (unless (= 1 (((query s "PRAGMA user_version") 0) :user_version))
        (transact s
                  (def version (((query s "PRAGMA user_version") 0) :user_version))
                  (assert (index-of version [0 1]) "unsupported Zinc database; preserve it and provision a fresh database")
                  (when (= version 0) (query s (schema/database)))))
      (assert (first (query s "SELECT name FROM main.sqlite_schema WHERE name='memory_records' AND instr(sql,'$.error.message')>0 AND instr(sql,'branch_world')>0")) "incompatible Zinc layout; preserve it and provision a fresh database")
      (when temporary
        (query s "ATTACH DATABASE ':memory:' AS journal; PRAGMA foreign_keys=OFF;")
        (query s (string "PRAGMA journal.max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA journal.page_size") 0) :page_size)))))
        (query s (schema/database true))
        (put s :archive-last (get-in config [:snapshot :archive-last] (((query s "SELECT coalesce(max(id),0) n FROM main.events") 0) :n)))
        (transact s
                  (query s `CREATE TEMP TABLE selected AS SELECT e.id FROM main.events e LEFT JOIN main.call_payloads c ON c.id=e.call
            WHERE e.source=? AND e.id<=? AND (coalesce(c.world,json_extract(e.data,'$.world'))=?
            OR coalesce(c.world,json_extract(e.data,'$.world')) IN (SELECT value FROM json_each(?)))`
                         [(s :source) (s :archive-last) (config :world) (string (json/encode (config :visibility)))])
                  (query s `WITH RECURSIVE included(id) AS (
            SELECT call FROM main.events WHERE id IN selected UNION SELECT c.parent FROM main.call_payloads c JOIN included i ON c.id=i.id WHERE c.parent IS NOT NULL
            UNION SELECT c.run FROM main.call_payloads c JOIN included i ON c.id=i.id)
            INSERT INTO journal.call_payloads SELECT * FROM main.call_payloads WHERE id IN included`)
                  (each [name key] [["events" "id"] ["images" "event"] ["usage" "request"]]
                    (query s (string "INSERT INTO journal." name " SELECT * FROM main." name " WHERE " key " IN selected")))
                  (query s "DELETE FROM journal.sqlite_sequence WHERE name='events'; INSERT INTO journal.sqlite_sequence SELECT * FROM main.sqlite_sequence WHERE name='events'; DROP TABLE selected;")
                  (each name [:call_payloads :events :images :usage]
                    (def columns (map |($ :name) (query s (string "PRAGMA journal.table_info(" name ")"))))
                    (each row (get-in config [:snapshot name] [])
                      (query s (string "INSERT OR IGNORE INTO journal." name "(" (string/join columns ",") ") VALUES(" (string/join (map (fn [_] "?") columns) ",") ")")
                             (map |(if (and (= name :images) (= $ "bytes")) (buffer (base64/decode (row :bytes))) (get row (keyword $))) columns)))))
        (query s `INSERT INTO journal.lexemes(source,term) SELECT DISTINCT e.source,w.term FROM journal.event_words w JOIN journal.events e ON e.id=w.doc
          WHERE length(CAST(w.term AS BLOB))<=128 AND w.offset<2048 ON CONFLICT DO NOTHING;
          INSERT INTO journal.event_lexemes(event,lexeme) SELECT DISTINCT w.doc,l.id FROM journal.event_words w JOIN journal.events e ON e.id=w.doc
          JOIN journal.lexemes l ON l.source=e.source AND l.term=w.term WHERE w.offset<2048 ON CONFLICT DO NOTHING;
          PRAGMA foreign_keys=ON;`)
        (assert (<= (* (((query s "PRAGMA journal.page_count") 0) :page_count) (((query s "PRAGMA journal.page_size") 0) :page_size)) (config :journal-bytes)) "temporary history exceeds RAM journal budget")
        (each name [:call_payloads :events :images :usage :memory_records :conversation_records :unresolved_tools :invalid_summaries :lexemes :event_lexemes]
          (query s (string "CREATE TEMP VIEW " name " AS SELECT * FROM journal." name))))
      (query s (string `CREATE TEMP VIEW calls AS SELECT c.id,c.source,c.world,c.parent,c.root,c.kind,c.temporary,c.expires,c.cancelled,
        c.state,c.attempt,c.owner,c.lease_expires,c.retries,c.key,c.work_used,c.tool_used,c.request request_key,
        coalesce(p.run,c.id) run,g.request request,coalesce(p.config,r.config) config,p.entry,p.first,p.last,p.history_last,p.code,p.file,p.origin,p.agent,p.depth,p.visibility,p.checkpoint,
        a.id admission,json_extract(a.data,'$.input') input FROM main.call_controls c
        LEFT JOIN ` (s :journal) `.call_payloads p ON p.id=c.id LEFT JOIN ` (s :journal) `.call_payloads r ON r.id=p.run
        LEFT JOIN main.call_controls g ON g.id=coalesce(p.run,c.id)
        LEFT JOIN ` (s :journal) `.events a ON a.call=c.id AND a.kind IN ('user','summary-input');`))
      s)
    ([err] (sql/close (s :db)) (error err))))

(defn close [s]
  (when (s :temporary-call)
    (each row (query s "SELECT file FROM call_payloads WHERE run=? AND file IS NOT NULL" [(s :temporary-call)])
      (when (os/stat (row :file)) (os/rm (row :file)))))
  (sql/close (s :db)))

(defn charge [s work tokens]
  (assert (first (query s `UPDATE main.call_controls SET work_used=work_used+?,tool_used=tool_used+? WHERE id=? AND source=?
    AND (?=0 OR expires>? AND NOT cancelled) AND work_used+?<=? AND tool_used+?<=? RETURNING id`
                        [work tokens (s :budget-root) (s :source) work (os/clock) work ((s :config) :task-quota) tokens ((s :config) :tool-quota)])) "shared call budget exhausted"))

(defn call [s id]
  (def row (first (query s "SELECT * FROM calls WHERE id=? AND source=?" [id (s :source)])))
  (assert row "call unavailable") row)

(defn append [s scope kind text &opt data parent execution]
  (transact s
            (assert (and (string? text) (utf8/is-valid? text)) "invalid event text")
            (def context (when (scope :branch) (call s (scope :branch))))
            (def origin (when context (json/decode (context :origin) true true)))
            (def encoded (string (json/encode (merge (or data {}) {:world-source (when origin
                                                                                   {:root (origin :root) :path (origin :path) :ref (origin :ref) :base (origin :base)})}))))
            (assert (and (utf8/is-valid? encoded) (<= (+ (length text) (length encoded))
                                                      ((s :config) (if (index-of kind ["user" "summary-input" "call-admission" "code-admission" "model-admission"]) :request-bytes :response-bytes)))) "stored event must be bounded UTF-8 JSON")
            (when (= kind "operation-outcome") (charge s 0 (estimate (string text encoded))))
            (def row ((query s (string "INSERT INTO " (s :journal) ".events(source,call,parent,kind,text,data,estimate,author,at) VALUES(?,?,?,?,?,?,?,?,coalesce(?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))) RETURNING *")
                             [(s :source) (or execution (scope :branch)) parent kind text encoded (estimate (string text encoded))
                              (or (scope :author) (if context (string "self:" (context :request) "/" (context :id)) "system:zinc")) (scope :at)]) 0))
            (query s (string "INSERT INTO " (s :journal) ".lexemes(source,term) SELECT DISTINCT ?,term FROM (SELECT term FROM " (s :journal) ".event_words WHERE doc=? ORDER BY offset LIMIT 2048) WHERE length(CAST(term AS BLOB))<=128 ON CONFLICT DO NOTHING") [(s :source) (row :id)])
            (query s (string "INSERT INTO " (s :journal) ".event_lexemes(event,lexeme) SELECT DISTINCT ?,l.id FROM (SELECT term FROM " (s :journal) ".event_words WHERE doc=? ORDER BY offset LIMIT 2048) w JOIN " (s :journal) ".lexemes l ON l.term=w.term AND l.source=? ON CONFLICT DO NOTHING") [(row :id) (row :id) (s :source)])
            (when (s :temporary)
              (assert (<= (* (((query s "PRAGMA journal.page_count") 0) :page_count) (((query s "PRAGMA journal.page_size") 0) :page_size)) ((s :config) :journal-bytes)) "RAM journal byte ceiling"))
            row))

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
            (map (fn [record]
                   (assert (and (dictionary? record) (= (tuple/slice (sorted (keys record))) [:at :author :key :text])) "invalid context record")
                   (each key [:at :author :key :text] (assert (and (string? (record key)) (> (length (record key)) 0)) "invalid context field"))
                   (assert (<= (length (record :key)) 256) "context key byte ceiling")
                   (def data @{:key (record :key) :world ((s :config) :world)})
                   (def previous (first (query s "SELECT * FROM events WHERE source=? AND kind='context' AND json_extract(data,'$.key')=?" [(s :source) (record :key)])))
                   (if previous
                     (do (assert (and (= (previous :text) (record :text)) (= (previous :author) (record :author)) (= (previous :at) (record :at))
                                      (deep= (json/decode (previous :data) true true) data)) "context key reused with different data") (previous :id))
                     ((append s {:author (record :author) :at (record :at)} "context" (record :text) data) :id))) records)))

(defn visible [s view &opt order ceiling]
  (query s (string `WITH RECURSIVE ancestry(id,through) AS (
    SELECT ?,9007199254740991 UNION ALL SELECT c.parent,min(a.through,c.last) FROM call_payloads c JOIN ancestry a ON c.id=a.id WHERE c.parent IS NOT NULL
  ), members(id) AS (SELECT ? UNION SELECT c.value FROM members m JOIN events n ON n.id=m.id,json_each(n.data,'$.children') c WHERE n.kind='summary')
  SELECT ` (get view :columns "e.*") `,coalesce(b.world,json_extract(e.data,'$.world')) world FROM `
                   (cond (view :lexical) (string (s :journal) ".lexeme_grams JOIN lexemes l ON l.id=lexeme_grams.rowid JOIN event_lexemes w ON w.lexeme=l.id JOIN memory_records e ON e.id=w.event")
                     (view :match) (string (s :journal) ".event_fts JOIN memory_records e ON e.id=event_fts.rowid") "memory_records e")
                   ` LEFT JOIN call_payloads b ON b.id=e.branch WHERE `
                   (when (view :match) (if (view :lexical) "lexeme_grams MATCH ? AND " "event_fts MATCH ? AND "))
                   `e.source=? AND e.id BETWEEN ? AND ? AND (coalesce(b.world,json_extract(e.data,'$.world'))=? OR coalesce(b.world,json_extract(e.data,'$.world')) IN (SELECT value FROM json_each(?)))
    AND (e.id<=? OR (e.run=? AND EXISTS(SELECT 1 FROM ancestry a WHERE a.id=e.branch AND e.id<=a.through)))
    AND (e.kind='context' OR b.temporary=0 OR b.id IN (SELECT id FROM ancestry) OR (? AND e.id<=?))
    AND (? IS NULL OR e.kind IN (SELECT value FROM json_each(?))) AND e.id NOT IN (SELECT value FROM json_each(?))`
                   (when (view :memory) " AND e.memory") " ORDER BY "
                   (if (view :match) (if (view :lexical) "l.term,e.id" "bm25(event_fts),e.id") (string "e.id " (if (= order :recent) "DESC" "ASC"))) " LIMIT ?")
         (array/concat @[(view :branch) (view :root)] (if (view :match) [(view :match)] [])
                       [(s :source) (view :first) (view :last) (view :world) (string (json/encode (get view :visibility [])))
                        (get view :history-last (view :last)) (view :run) (if (s :temporary) 1 0) (get view :history-last (view :last))
                        (when (view :kinds) 1) (string (json/encode (view :kinds))) (string (json/encode (get view :exclude []))) (or ceiling 4096)])))

(defn event [s view id]
  (def row (first (visible s (merge view {:first id :last id}))))
  (assert (and (<= (view :first) id (view :last)) row) "event outside granted history") row)

(defn checkpoint [s &opt value]
  (def current (dyn :zinc/call))
  (assert current "checkpoint requires an executing call")
  (if value
    (let [encoded (string (json/encode value))]
      (assert (<= (length encoded) ((s :config) :request-bytes)) "stored checkpoint byte ceiling")
      (assert (first (query s (string "UPDATE " (s :journal) ".call_payloads SET checkpoint=? WHERE id IN (SELECT id FROM main.live_calls WHERE id=? AND source=? AND owner=?) RETURNING id")
                            [encoded (current :id) (s :source) (current :owner)])) "call lease lost")
      (put current :checkpoint value))
    (assert (first (query s "SELECT id FROM main.live_calls WHERE id=? AND source=? AND owner=?" [(current :id) (s :source) (current :owner)])) "call lease lost")))

(defn start [s input config &opt caller origin key]
  (def summary (has-key? input :children))
  (def admitted (tabseq [[k v] :in (pairs input) :unless (index-of k [:after :images])] k v))
  (default key (when caller (string (json/encode ["child" (caller :branch) (caller :event)]))))
  (transact s
            (when (dyn :zinc/call) (checkpoint s))
            (def previous (first (query s "SELECT * FROM calls WHERE source=? AND ((? IS NOT NULL AND request_key=?) OR (? IS NOT NULL AND key=?))"
                                        [(s :source) (input :request) (input :request) key key])))
            (if previous
              (do
                (assert (= 0 (previous :cancelled)) "call cancelled")
                (assert (deep= admitted (json/decode (previous :input) true true)) "request ID reused with different work")
                (assert (deep= (query s "SELECT mime AS type,bytes FROM images WHERE event=? ORDER BY position" [(previous :admission)]) (get input :images @[])) "request ID reused with different images")
                previous)
              (do
                (def world (config :world))
                (def latest (first (query s "SELECT e.id FROM memory_records e LEFT JOIN call_payloads c ON c.id=e.branch WHERE e.source=? AND coalesce(c.world,json_extract(e.data,'$.world'))=? AND (e.kind='context' OR c.temporary=0) ORDER BY e.id DESC LIMIT 1" [(s :source) world])))
                (def entry (unless summary (get input :parent (if caller (caller :last) (get latest :id 0)))))
                (def last (if summary (caller :last) (get-in input [:memory_range :end] entry)))
                (def earliest (first (query s "SELECT min(id) id FROM memory_records WHERE source=? AND id<=? AND (kind='context' AND json_extract(data,'$.world')=? OR branch IN (SELECT id FROM call_payloads WHERE world=? AND temporary=0) AND kind IN ('user','response','completed','tool-result'))" [(s :source) last world world])))
                (def first-id (if summary (caller :first) (get-in input [:memory_range :start] (if (= last 0) 0 (if caller (caller :first) (or (earliest :id) last))))))
                (def allowed (or caller {:world world :first 1 :last 9007199254740991 :visibility (config :visibility)}))
                (assert (and (<= 0 first-id last) (= (= first-id 0) (= last 0))) "invalid history range")
                (each id (if summary [] [entry first-id last]) (when (> id 0) (event s allowed id)))
                (when caller
                  (assert (= world (caller :world)) "child changes world")
                  (assert (or (= last 0) (<= (caller :first) first-id last (caller :last))) "child history exceeds caller view"))
                (def saved (unless caller (merge config)))
                (when saved
                  (when (saved :agent) (put saved :agent (merge (saved :agent))))
                  (each profile (filter identity [saved (saved :agent)])
                    (put profile :snapshot nil)
                    (put profile :capabilities (tabseq [[name capability] :in (pairs (profile :capabilities))] name {:module (capability :module)}))))
                (def temporary (if (s :temporary) 1 0))
                (when caller (assert (or (= temporary 1) (= 0 ((call s (caller :branch)) :temporary))) "temporary calls cannot create durable descendants"))
                (def depth (if summary (caller :depth) (if caller (+ 1 (caller :depth)) (get-in config [:snapshot :depth] 0))))
                (assert (<= depth (config :task-depth)) "agent recursion ceiling exhausted")
                (def id (((query s "INSERT INTO main.call_controls(source,world,request,parent,root,kind,temporary,expires,key) VALUES(?,?,?,?,?,?,?,?,?) RETURNING id"
                                 [(s :source) world (input :request) (or (get-in (dyn :zinc/call) [:id]) (when caller (caller :branch)) (get-in config [:snapshot :parent-call]))
                                  (or (s :budget-root) (get-in config [:snapshot :budget-root])) (cond summary "summarize" (input :code) "code" "text") temporary
                                  (if caller (caller :expires) (min (+ (os/clock) (config :run-seconds)) (get-in config [:snapshot :deadline] math/inf))) key]) 0) :id))
                (unless (s :budget-root) (put s :budget-root (get-in config [:snapshot :budget-root] id)))
                (def run (if caller (caller :run) id))
                (when (and (s :temporary) (not caller)) (put s :temporary-call id))
                (def code (get origin :code ""))
                (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
                (query s (string "INSERT INTO " (s :journal) ".call_payloads(id,parent,run,kind,config,entry,first,last,history_last,world,code,origin,temporary,agent,depth,visibility) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
                       [id (or (when caller (caller :branch)) (get-in config [:snapshot :parent-call])) run (cond summary "summarize" (input :code) "code" "text")
                        (when (and saved (not summary)) (string (json/encode saved))) entry first-id last (if caller (caller :history-last) last) world code
                        (string (json/encode (tabseq [[k v] :in (pairs (or origin {})) :unless (= k :code)] k v))) temporary (if (and caller (caller :agent)) 1 0) depth (string (json/encode (config :visibility)))])
                (when (and (not summary) (get-in config [:repl :enabled]))
                  (def directory (string (config :store) ".worlds"))
                  (os/mkdir directory) (os/chmod directory 8r700)
                  (def file (path/join directory (string (string/join (map |(string/format "%02x" $) (os/cryptorand 18))) ".janet")))
                  (with [out (file/open file :wbn)] (file/write out code)) (os/chmod file 8r600)
                  (query s (string "UPDATE " (s :journal) ".call_payloads SET file=? WHERE id=?") [file id]))
                (def input-event (append s {:branch id :author (input :author) :at (input :at)} (if summary "summary-input" "user") "" {:input admitted} (when (and entry (> entry 0)) entry) id))
                (var image-bytes 0)
                (eachp [position image] (get input :images [])
                  (def bytes (image :bytes)) (+= image-bytes (length bytes))
                  (assert (<= image-bytes (config :image-bytes)) "stored image byte ceiling")
                  (query s (string "INSERT INTO " (s :journal) ".images(event,position,mime,bytes) VALUES(?,?,?,?)") [(input-event :id) position (image :type) (buffer bytes)]))
                (charge s 1 (if (input :code) (estimate (input :code)) 0))
                (call s id)))))

(defn view [s id &opt active]
  (default active true)
  (def c (call s id))
  (def view {:run (c :run) :branch id :world (c :world) :first (c :first) :last (c :last) :expires (c :expires)
             :history-last (c :history_last) :visibility (json/decode (c :visibility)) :agent (= 1 (c :agent)) :depth (c :depth)})
  (if active (merge view {:first (if (= 0 (view :first)) (c :admission) (view :first))
                          :last (get (first (visible s (merge view {:last 9007199254740991 :columns "e.id"}) :recent 1)) :id (view :last))}) view))

(defn snapshot [s view]
  (def snapshot @{:depth (+ 1 (view :depth)) :budget-root (s :budget-root) :parent-call (view :branch) :deadline (view :expires)
                  :archive-last (or (s :archive-last) (((query s "SELECT coalesce(max(id),0) n FROM main.events") 0) :n))})
  (when (s :temporary)
    (each name [:call_payloads :events :images :usage]
      (put snapshot name (map |(if (= name :images) (merge $ {:bytes (base64/encode (string ($ :bytes)))}) $) (query s (string "SELECT * FROM journal." name))))))
  snapshot)

(defn tool-used [s run]
  (((query s "SELECT coalesce(sum(estimate),0) estimate FROM memory_records WHERE source=? AND run=? AND kind IN ('tool-result','code-admission')" [(s :source) run]) 0) :estimate))

(defn park [s waiting]
  (def current (dyn :zinc/call))
  (checkpoint s)
  (if waiting
    (first (query s "UPDATE main.call_controls SET state='waiting' WHERE id=? AND owner=? AND state='running' RETURNING id" [(current :id) (current :owner)]))
    (while true
      (checkpoint s)
      (when (first (query s "UPDATE main.call_controls SET state='running' WHERE id=? AND owner=? AND state='waiting' AND (SELECT count(*) FROM running WHERE source=?)<? RETURNING id"
                          [(current :id) (current :owner) (s :source) ((s :config) :parallel)])) (break))
      (ev/sleep 0.1))))

(defn claim [s id]
  (when (first (query s `UPDATE main.call_controls SET state='running',attempt=attempt+1,owner=?,lease_expires=?
    WHERE id=? AND source=? AND state='queued' AND expires>? AND NOT cancelled
    AND EXISTS(SELECT 1 FROM main.call_controls r WHERE r.id=coalesce(call_controls.root,call_controls.id) AND r.expires>? AND NOT r.cancelled)
    AND (SELECT count(*) FROM running WHERE source=?)<? RETURNING id`
                      [(base64/encode (string (os/cryptorand 24))) (+ (os/clock) ((s :config) :lease-seconds)) id (s :source) (os/clock) (os/clock) (s :source) ((s :config) :parallel)]))
    (call s id)))

(defn heartbeat [[file seconds id owner stop]]
  (def db (sql/open file))
  (defer (sql/close db)
    (sql/eval db "PRAGMA busy_timeout=5000;")
    (try (while true
           (assert (first (sql/eval db "UPDATE call_controls SET lease_expires=? WHERE id IN (SELECT id FROM live_calls WHERE id=? AND owner=?) RETURNING id"
                                    [(+ (os/clock) seconds) id owner])) "execution fenced")
           (def tick (ev/chan 1))
           (def timer (ev/go (fn [] (ev/sleep (/ seconds 3)) (ev/give tick true))))
           (when (= stop ((ev/select stop tick) 1)) (ev/cancel timer "finished") (break))) ([err] nil))))

(defn finish [s row value failure]
  (transact s
            (def owner (first (query s "SELECT state FROM main.call_controls WHERE id=? AND owner=? AND state IN ('running','waiting','uncertain','cancelled')" [(row :id) (row :owner)])))
            (assert owner "call completion fenced")
            (def state (if (= "cancelled" (owner :state)) "cancelled" (if failure "failed" "done")))
            (def outcome (merge {:ok (= state "done") :value value :state state :attempt (row :attempt)} (or failure {})))
            (append s (view s (if (= "summarize" (row :kind)) (row :parent) (row :id))) "call-result" "" outcome nil (row :id))
            (query s "UPDATE main.call_controls SET state=?,owner=NULL,lease_expires=NULL WHERE id=?" [state (row :id)])
            outcome))

(defn recover [s]
  (transact s
            (each row (query s `SELECT c.* FROM main.call_controls c JOIN main.call_controls r ON r.id=coalesce(c.root,c.id)
      WHERE c.source=? AND (?=0 OR c.temporary=1) AND
      (c.state IN ('queued','running','waiting') AND min(c.expires,r.expires)<=? OR c.state IN ('running','waiting') AND c.lease_expires<=?) ORDER BY c.id`
                             [(s :source) (if (s :temporary) 1 0) (os/clock) (os/clock)])
              (def expired (or (<= (row :expires) (os/clock))
                               (first (query s "SELECT id FROM main.call_controls WHERE id=? AND expires<=?" [(or (row :root) (row :id)) (os/clock)]))))
              (def unstarted (and expired (= 0 (row :attempt))))
              (def retry (and (= 0 (row :temporary)) (not expired) (not= "code" (row :kind)) (> (row :retries) 0)))
              (def state (cond unstarted "cancelled" retry "queued" "uncertain"))
              (when (= 0 (row :temporary))
                (append s (view s (if (= "summarize" (row :kind)) (row :parent) (row :id))) "interruption"
                        (if unstarted "Deadline expired before execution." "Interrupted execution; effects may have happened.")
                        {:state state :attempt (row :attempt)} nil (row :id)))
              (query s "UPDATE main.call_controls SET state=?,retries=retries-?,owner=CASE WHEN ? THEN NULL ELSE owner END,lease_expires=CASE WHEN ? THEN NULL ELSE lease_expires END WHERE id=?"
                     [state (if retry 1 0) (or retry unstarted) (or retry unstarted) (row :id)]))))

(defn abort [s value]
  (assert (and (not= (nil? (value :run)) (nil? (value :request))) (string? (value :reason)) (<= (length (value :reason)) 2048)) "abort requires run or request and reason")
  (transact s
            (when (value :request)
              (query s "INSERT INTO main.call_controls(source,world,request,kind,temporary,expires,state,cancelled) VALUES(?,?,?,'text',0,?,'cancelled',1) ON CONFLICT(source,request) DO NOTHING"
                     [(s :source) ((s :config) :world) (value :request) (os/clock)]))
            (def row (first (query s "SELECT * FROM calls WHERE source=? AND request_key IS NOT NULL AND (id=? OR request_key=?)" [(s :source) (value :run) (value :request)])))
            (assert (and row (= (row :world) ((s :config) :world))) "run unavailable")
            (def completed (or (= "done" (row :state)) (first (query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [(row :id)]))))
            (unless completed
              (query s "UPDATE main.call_controls SET cancelled=1 WHERE id=?" [(row :id)])
              (def affected (query s `UPDATE main.call_controls SET state='cancelled' WHERE source=? AND state IN ('queued','running','waiting','uncertain')
        AND (id=? OR root=? AND (?=0 OR temporary=1)) RETURNING id,kind,attempt`
                                   [(s :source) (row :id) (or (row :root) (row :id)) (row :temporary)]))
              (when (and (= 0 (row :temporary)) (row :admission)
                         (not (first (query s "SELECT id FROM events WHERE call=? AND kind='cancelled'" [(row :id)]))))
                (append s {:branch (row :id)} "cancelled" "Interrupted. Performed effects are not rolled back; running effects may still finish."
                        {:reason (value :reason) :tasks-at-request affected})))
            {:run (row :id) :state (if completed "completed" "cancelled")}))
