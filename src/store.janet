(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)
(import ./schema)

(def interval 0.1)
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

(defn process [argv environment input limit seconds &opt diagnostics]
  (def child (os/spawn argv :pe (merge environment {:in :pipe :out :pipe :err (if diagnostics :pipe :out)})))
  (defer (do (when (nil? (get child :return-code)) (try (os/proc-kill child) ([err] nil))) (os/proc-close child))
    (def output @"") (var size 0)
    (def [_ _ _ status] (ev/with-deadline (if (= seconds 0) math/inf seconds)
      (ev/gather
        (defer (ev/close (child :in)) (when input (ev/write (child :in) input)))
        (do (var chunk nil)
          (while (set chunk (ev/read (child :out) 4096))
            (+= size (length chunk))
            (assert (<= size limit) "process output byte ceiling")
            (buffer/push-string output chunk)))
        (when diagnostics
          (var chunk nil)
          (while (set chunk (ev/read (child :err) 4096))
            (+= size (length chunk))
            (assert (<= size limit) "process output byte ceiling")
            (buffer/push-string diagnostics chunk)))
        (os/proc-wait child))))
    {:exit status :output (string output)}))

(defn git [directory args &opt input environment probe]
  (def config (dyn :zinc/config))
  (def result (process ["git" "-C" directory "--literal-pathspecs" ;args] (merge (os/environ) (or environment {})) input
                      (max (config :world-bytes) (config :response-bytes)) (/ (config :http-ms) 1000)))
  (assert (or probe (= 0 (result :exit))) (string "Git " (string/join args " ") ": " (result :output)))
  (when (= 0 (result :exit)) (result :output)))

(defn open [config &opt temporary]
  (each profile (filter identity [config (config :agent)])
    (put profile :world (os/realpath (profile :world))))
  (def s @{:db (sql/open (config :store)) :journal (if temporary "journal" "main")
           :config config :temporary temporary :profiles @{} :recovery @[0]})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA temp_store=MEMORY;")
      (unless (= 1 (((query s "PRAGMA user_version") 0) :user_version))
        (transact s
                  (def version (((query s "PRAGMA user_version") 0) :user_version))
                  (assert (index-of version [0 1]) "unsupported Zinc database; preserve it and provision a fresh database")
                  (when (= version 0) (query s (schema/database)))))
      (assert (first (query s "SELECT name FROM pragma_table_info('events') WHERE name='record_kind'")) "incompatible Zinc layout; preserve it and provision a fresh database")
      (query s "INSERT INTO main.world(id,file) VALUES(1,?) ON CONFLICT(id) DO NOTHING" [(config :world)])
      (assert (= (config :world) (((query s "SELECT file FROM main.world WHERE id=1") 0) :file)) "history database belongs to another world")
      (when temporary
        (query s "ATTACH DATABASE ':memory:' AS journal;")
        (query s (string "PRAGMA journal.max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA journal.page_size") 0) :page_size)))))
        (query s (schema/database true))
        (put s :archive-last (get-in config [:snapshot :archive-last] (((query s "SELECT coalesce(max(id),0) n FROM main.events") 0) :n)))
        (each [name key] [["call_payloads" nil] ["events" "id"] ["images" "event"] ["usage" "request"]]
          (query s (string "CREATE TEMP VIEW " name " AS SELECT * FROM main." name " WHERE "
                           (if key (string key "<=" (s :archive-last)) "id IN (SELECT id FROM main.call_controls WHERE temporary=0)")
                           " UNION ALL SELECT * FROM journal." name)))
        (query s (string `CREATE VIRTUAL TABLE temp.archive_words USING fts5vocab(main,event_fts,'instance');
          CREATE TEMP VIEW event_words AS SELECT term FROM archive_words WHERE doc<=` (s :archive-last) `
            UNION SELECT term FROM journal.event_words;
          CREATE TEMP TRIGGER journal_parent BEFORE INSERT ON journal.events
            WHEN new.parent IS NOT NULL AND NOT EXISTS(SELECT 1 FROM events WHERE id=new.parent)
            BEGIN SELECT raise(ABORT,'event parent unavailable'); END;`))
        (transact s
          (query s "INSERT INTO journal.sqlite_sequence(name,seq) SELECT 'events',coalesce(max(seq),0) FROM main.sqlite_sequence WHERE name='events';")
          (each name [:call_payloads :events :images :usage]
            (def columns (map |($ :name) (query s (string "PRAGMA journal.table_info(" name ")"))))
            (each row (get-in config [:snapshot name] [])
              (query s (string "INSERT INTO journal." name "(" (string/join columns ",") ") VALUES(" (string/join (map (fn [_] "?") columns) ",") ")")
                     (map |(if (and (= name :images) (= $ "bytes")) (buffer (base64/decode (row :bytes))) (get row (keyword $))) columns))))))
      (query s (string `CREATE TEMP VIEW calls AS SELECT c.id,c.parent,c.root,c.kind,c.temporary,c.expires,c.cancelled,
        c.state,c.attempt,c.owner,c.lease_expires,c.retries,c.key,c.work_used,c.tool_used,c.request request_key,
        coalesce(p.run,c.id) run,g.request request,coalesce(p.config,r.config) config,p.entry,p.first,p.last,p.history_last,p.origin,p.agent,p.depth,p.checkpoint,
        a.id admission,json_extract(a.data,'$.input') input FROM main.call_controls c
        LEFT JOIN call_payloads p ON p.id=c.id LEFT JOIN call_payloads r ON r.id=p.run
        LEFT JOIN main.call_controls g ON g.id=coalesce(p.run,c.id)
        LEFT JOIN events a ON a.call=c.id AND a.kind IN ('user','summary-input');`))
      (query s schema/projections)
      s)
    ([err] (sql/close (s :db)) (error err))))

(defn close [s] (sql/close (s :db)))

(defn charge [s work tokens]
  (assert (first (query s `UPDATE main.call_controls SET work_used=work_used+?,tool_used=tool_used+? WHERE id=?
    AND (?=0 OR (expires IS NULL OR expires>?) AND NOT cancelled) AND work_used+?<=? AND tool_used+?<=? RETURNING id`
                        [work tokens (s :budget-root) work (os/clock) work ((s :config) :task-quota) tokens ((s :config) :tool-quota)])) "shared call budget exhausted"))

(defn call [s id]
  (def row (first (query s "SELECT * FROM calls WHERE id=?" [id])))
  (assert row "call unavailable") row)

(defn origin [s &opt id]
  (json/decode (if id ((call s id) :origin) (((query s "SELECT origin FROM main.world WHERE id=1") 0) :origin)) true true))

(defn image [s origin bytes]
  (assert (<= (length bytes) ((s :config) :world-bytes)) "world image byte ceiling")
  (def blob (string/trim (git (origin :root) ["hash-object" "-w" "--stdin"] bytes)))
  (unless (= blob (origin :blob))
    (git (origin :root) ["update-ref" (string "refs/zinc/world/" blob) blob]))
  (merge origin {:blob blob}))

(defn append [s scope kind text &opt data parent execution]
  (transact s
            (assert (and (string? text) (utf8/is-valid? text)) "invalid event text")
            (def context (when (scope :branch) (call s (scope :branch))))
            (def task (if (and execution (not= execution (scope :branch))) (call s execution) context))
            (def data (or data {}))
            (def record-kind (cond
              (and (= kind "model-outcome") (data :turn)) (if (index-of (data :status) ["complete" "refused" "blocked"]) "completed" "response")
              (and (= kind "call-result") (dictionary? (data :error))) "error"
              (and (= (get task :kind) "code") (or (= kind "call-attempt") (and (= kind "call-result") (= (data :state) "done"))))
              (if (= kind "call-attempt") "code-admission" "completed") kind))
            (def memory (case record-kind
              "error" (not= (get task :kind) "summarize") "interruption" (not= (get task :kind) "summarize")
              "artifact" (not (has-key? data :invalidates))
              (not (nil? (index-of record-kind ["user" "context" "response" "completed" "code-admission" "tool-result" "tool-ambiguity"
                                               "call-admission" "operation-outcome" "cancelled" "save-intent" "saved"])))))
            (def encoded (string (json/encode (merge data {:world (json/decode (if context (context :origin) (((query s "SELECT origin FROM main.world WHERE id=1") 0) :origin)) true true)}))))
            (assert (utf8/is-valid? encoded) "stored event must be UTF-8 JSON")
            (when (index-of kind ["call-admission" "operation-outcome"]) (charge s 0 (estimate (string text encoded))))
            (def row ((query s (string "INSERT INTO " (s :journal) ".events(call,parent,kind,record_kind,memory,text,data,estimate,author,at) VALUES(?,?,?,?,?,?,?,?,?,coalesce(?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))) RETURNING *")
                             [(or execution (scope :branch)) parent kind record-kind (if memory 1 0) text encoded (estimate (string text encoded))
                              (or (scope :author) (if context (string "self:" (context :request) "/" (context :id)) "system:zinc")) (scope :at)]) 0))
            row))

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
            (map (fn [record]
                   (assert (and (dictionary? record) (= (tuple/slice (sorted (keys record))) [:at :author :key :text])) "invalid context record")
                   (each key [:at :author :key :text] (assert (and (string? (record key)) (> (length (record key)) 0)) "invalid context field"))
                   (assert (<= (length (record :key)) 256) "context key byte ceiling")
                   (def data @{:key (record :key)})
                   (def previous (first (query s `SELECT *,json_remove(data,'$.world') payload FROM events WHERE kind='context' AND json_extract(data,'$.key')=?` [(record :key)])))
                   (if previous
                     (do (assert (and (= (previous :text) (record :text)) (= (previous :author) (record :author)) (= (previous :at) (record :at))
                                      (deep= (json/decode (previous :payload) true true) data)) "context key reused with different data") (previous :id))
                     ((append s {:author (record :author) :at (record :at)} "context" (record :text) data) :id))) records)))

(defn visible [s view &opt order ceiling]
  (if (and (s :temporary) (view :match) (not (view :index)))
    (take (or ceiling 4096)
      (sorted (array/concat @[]
        (visible s (merge view {:index "main" :last (min (view :last) (s :archive-last))}) order ceiling)
        (visible s (merge view {:index "journal" :first (max (view :first) (+ 1 (s :archive-last)))}) order ceiling))
        |(if (= order :recent) (> ($0 :id) ($1 :id)) (< ($0 :id) ($1 :id)))))
    (query s (string `WITH RECURSIVE ancestry(id,through) AS (
    SELECT ?,9007199254740991 UNION ALL SELECT c.parent,min(a.through,c.last) FROM calls c JOIN ancestry a ON c.id=a.id WHERE c.parent IS NOT NULL
  ), members(id) AS (SELECT ? UNION SELECT c.value FROM members m JOIN events n ON n.id=m.id,json_each(n.data,'$.children') c WHERE n.kind='summary')
  SELECT ` (get view :columns "e.*") ` FROM `
                   (if (view :match) (string (get view :index (s :journal)) ".event_fts JOIN memory_records e ON e.id=event_fts.rowid") "memory_records e")
                   ` LEFT JOIN main.call_controls b ON b.id=e.branch WHERE `
                   (when (view :match) "event_fts MATCH ? AND ")
                   `e.id BETWEEN ? AND ? AND (e.id<=? OR (e.run=? AND EXISTS(SELECT 1 FROM ancestry a WHERE a.id=e.branch AND e.id<=a.through)))
    AND (e.kind='context' OR b.temporary=0 OR b.id IN (SELECT id FROM ancestry) OR (? AND e.id<=?))
    AND (? IS NULL OR e.kind IN (SELECT value FROM json_each(?))) AND e.id NOT IN (SELECT value FROM json_each(?))`
                   (when (view :memory) " AND e.memory") " ORDER BY "
                   "e.id " (if (= order :recent) "DESC" "ASC") " LIMIT ?")
         (array/concat @[(view :branch) (view :root)] (if (view :match) [(view :match)] [])
                       [(view :first) (view :last)
                        (get view :history-last (view :last)) (view :run) (if (s :temporary) 1 0) (get view :history-last (view :last))
                        (when (view :kinds) 1) (string (json/encode (view :kinds))) (string (json/encode (get view :exclude []))) (or ceiling 4096)]))))

(defn event [s view id]
  (def row (first (visible s (merge view {:first id :last id}))))
  (assert (and (<= (view :first) id (view :last)) row) "event outside granted history") row)

(defn checkpoint [s &opt value]
  (def current (dyn :zinc/call))
  (assert current "checkpoint requires an executing call")
  (if value
    (let [encoded (string (json/encode value))]
      (assert (<= (length encoded) (+ ((s :config) :request-bytes) ((s :config) :response-bytes))) "stored checkpoint byte ceiling")
      (assert (first (query s (string "UPDATE " (s :journal) ".call_payloads SET checkpoint=? WHERE id IN (SELECT id FROM main.live_calls WHERE id=? AND owner=?) RETURNING id")
                            [encoded (current :id) (current :owner)])) "call lease lost")
      (put current :checkpoint value))
    (assert (first (query s "SELECT id FROM main.live_calls WHERE id=? AND owner=?" [(current :id) (current :owner)])) "call lease lost")))

(defn publish [s candidate]
  (checkpoint s)
  (def row (call s ((dyn :zinc/call) :id)))
  (assert (= 0 (row :cancelled)) "call cancelled")
  (def updated (string (json/encode candidate)))
  (when (and (nil? (row :parent)) (= 0 (row :temporary)) (nil? ((json/decode (row :input) true true) :revision)))
    (assert (first (query s "UPDATE main.world SET origin=? WHERE id=1 AND origin=? RETURNING id"
                          [updated (row :origin)])) "world changed; retry against the current world"))
  (query s (string "UPDATE " (s :journal) ".call_payloads SET origin=? WHERE id=?") [updated (row :id)])
  (put (dyn :zinc/call) :candidate nil))

(defn view [s id &opt active]
  (default active true)
  (def c (call s id))
  (def view {:run (c :run) :branch id :first (c :first) :last (c :last) :expires (c :expires)
             :history-last (c :history_last) :agent (= 1 (c :agent)) :depth (c :depth)})
  (if active (merge view {:first (if (= 0 (view :first)) (c :admission) (view :first))
                          :last (get (first (visible s (merge view {:last 9007199254740991 :columns "e.id"}) :recent 1)) :id (view :last))}) view))

(defn snapshot [s view]
  (def snapshot @{:depth (+ 1 (view :depth)) :budget-root (s :budget-root) :parent-call (view :branch) :deadline (view :expires)
                  :archive-last (or (s :archive-last) (((query s "SELECT coalesce(max(id),0) n FROM main.events") 0) :n))})
  (when (s :temporary)
    (each name [:call_payloads :events :images :usage]
      (put snapshot name (map |(if (= name :images) (merge $ {:bytes (base64/encode (string ($ :bytes)))}) $) (query s (string "SELECT * FROM journal." name (when (= name :events) " ORDER BY id")))))))
  snapshot)

(defn park [s waiting]
  (def current (dyn :zinc/call))
  (checkpoint s)
  (if waiting
    (first (query s "UPDATE main.call_controls SET state='waiting' WHERE id=? AND owner=? AND state='running' RETURNING id" [(current :id) (current :owner)]))
    (while (and (= 0 (get current :waiters 0))
                (= "waiting" (get (first (query s "SELECT state FROM main.call_controls WHERE id=?" [(current :id)])) :state)))
      (checkpoint s)
      (when (first (query s "UPDATE main.call_controls SET state='running' WHERE id=? AND owner=? AND state='waiting' AND (SELECT count(*) FROM running)<? RETURNING id"
                          [(current :id) (current :owner) ((s :config) :parallel)])) (break))
      (ev/sleep interval))))

(defn claim [s id]
  (transact s
    (when (first (query s `UPDATE main.call_controls SET state='running',attempt=attempt+1,owner=?,lease_expires=?
      WHERE id=? AND state='queued' AND (expires IS NULL OR expires>?) AND NOT cancelled
      AND EXISTS(SELECT 1 FROM main.call_controls r WHERE r.id=coalesce(call_controls.root,call_controls.id) AND (r.expires IS NULL OR r.expires>?) AND NOT r.cancelled)
      AND (parent IS NOT NULL OR temporary=1 OR NOT EXISTS(SELECT 1 FROM main.call_controls c
        WHERE c.id<>call_controls.id AND c.parent IS NULL AND c.temporary=0 AND NOT c.cancelled AND c.state IN ('running','waiting','uncertain')))
      AND (SELECT count(*) FROM running)<? RETURNING id`
                        [(base64/encode (string (os/cryptorand 24))) (+ (os/clock) ((s :config) :lease-seconds)) id (os/clock) (os/clock) ((s :config) :parallel)]))
      (def row (call s id))
      (when (and (nil? (row :parent)) (= 0 (row :temporary)) (= 1 (row :attempt))
                 (nil? ((json/decode (row :input) true true) :revision)))
        (query s "UPDATE main.call_payloads SET origin=(SELECT origin FROM main.world WHERE id=1) WHERE id=?" [id]))
      (call s id))))

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
            (def owner (first (query s `UPDATE main.call_controls SET state=CASE WHEN state='cancelled' THEN state WHEN ? THEN 'failed' ELSE 'done' END,
              owner=NULL,lease_expires=NULL WHERE id=? AND owner IS ?
              AND (state IN ('running','waiting','uncertain','cancelled') OR (? AND state='queued' AND attempt=0)) RETURNING state`
                                     [(not (nil? failure)) (row :id) (row :owner) (not (nil? failure))])))
            (assert owner "call completion fenced")
            (def state (owner :state))
            (def outcome (merge {:ok (= state "done") :value value :state state :attempt (row :attempt)} (or failure {})))
            (append s (view s (if (= "summarize" (row :kind)) (row :parent) (row :id))) "call-result"
                    (if failure (get-in failure [:error :message]) (if (string? value) value "")) outcome nil (row :id))
            outcome))

(defn start [s input config &opt caller origin key]
  (def summary (has-key? input :children))
  (def admitted (schema/project input [:after :images] true))
  (default key (when caller (string (json/encode ["child" (caller :branch) (caller :event)]))))
  (transact s
    (when (dyn :zinc/call) (checkpoint s))
    (def previous (first (query s "SELECT * FROM calls WHERE (? IS NOT NULL AND request_key=?) OR (? IS NOT NULL AND key=?)"
                               [(input :request) (input :request) key key])))
    (if previous
      (do
        (assert (= 0 (previous :cancelled)) "call cancelled")
        (assert (deep= admitted (json/decode (previous :input) true true)) "request ID reused with different work")
        (assert (deep= (query s "SELECT mime AS type,bytes FROM images WHERE event=? ORDER BY position" [(previous :admission)]) (get input :images @[])) "request ID reused with different images")
        (merge previous {:owner nil}))
      (do
        (def latest (first (query s "SELECT e.id FROM memory_records e LEFT JOIN main.call_controls c ON c.id=e.branch WHERE e.kind='context' OR c.temporary=0 ORDER BY e.id DESC LIMIT 1")))
        (def entry (unless summary (get input :parent (if caller (caller :last) (get latest :id 0)))))
        (def last (if summary (caller :last) (get-in input [:memory_range :end] entry)))
        (def earliest (first (query s "SELECT min(id) id FROM memory_records WHERE id<=? AND (kind='context' OR branch IN (SELECT id FROM main.call_controls WHERE temporary=0) AND kind IN ('user','response','completed','tool-result'))" [last])))
        (def first-id (if summary (caller :first) (get-in input [:memory_range :start] (if (= last 0) 0 (if caller (caller :first) (or (earliest :id) last))))))
        (def allowed (or caller {:first 1 :last 9007199254740991}))
        (assert (and (<= 0 first-id last) (= (= first-id 0) (= last 0))) "invalid history range")
        (each id (if summary [] [entry first-id last]) (when (> id 0) (event s allowed id)))
        (when caller (assert (or (= last 0) (<= (caller :first) first-id last (caller :last))) "child history exceeds caller view"))
        (def saved (unless caller (merge config)))
        (when saved
          (when (saved :agent) (put saved :agent (merge (saved :agent))))
          (each profile (filter identity [saved (saved :agent)])
            (put profile :snapshot nil)))
        (def temporary (if (s :temporary) 1 0))
        (when caller (assert (or (= temporary 1) (= 0 ((call s (caller :branch)) :temporary))) "temporary calls cannot create durable descendants"))
        (def depth (if summary (caller :depth) (if caller (+ 1 (caller :depth)) (get-in config [:snapshot :depth] 0))))
        (assert (<= depth (config :task-depth)) "agent recursion ceiling exhausted")
        (def id (((query s "INSERT INTO main.call_controls(request,parent,root,kind,temporary,expires,key,retries) VALUES(?,?,?,?,?,?,?,?) RETURNING id"
                         [(input :request) (or (get-in (dyn :zinc/call) [:id]) (when caller (caller :branch)) (get-in config [:snapshot :parent-call]))
                          (or (s :budget-root) (get-in config [:snapshot :budget-root])) (cond summary "summarize" (input :code) "code" "text") temporary
                          (if caller (caller :expires)
                            (let [deadline (min (if (= 0 (config :run-seconds)) math/inf (+ (os/clock) (config :run-seconds))) (or (get-in config [:snapshot :deadline]) math/inf))]
                              (unless (= deadline math/inf) deadline))) key (if (= false (input :queue)) 0 1)]) 0) :id))
        (unless (s :budget-root) (put s :budget-root (get-in config [:snapshot :budget-root] id)))
        (def run (if caller (caller :run) id))
        (query s (string "INSERT INTO " (s :journal) ".call_payloads(id,run,config,entry,first,last,history_last,origin,agent,depth) VALUES(?,?,?,?,?,?,?,?,?,?)")
               [id run (when (and saved (not summary)) (string (json/encode saved))) entry first-id last (if caller (caller :history-last) last)
                (string (json/encode (or origin {}))) (if (and caller (caller :agent)) 1 0) depth])
        (def input-event (append s {:branch id :author (input :author) :at (input :at)} (if summary "summary-input" "user") (get input :text (get input :code "")) {:input admitted} (when (and entry (> entry 0)) entry) id))
        (var image-bytes 0)
        (eachp [position image] (get input :images [])
          (def bytes (image :bytes)) (+= image-bytes (length bytes))
          (assert (<= image-bytes (config :image-bytes)) "stored image byte ceiling")
          (query s (string "INSERT INTO " (s :journal) ".images(event,position,mime,bytes) VALUES(?,?,?,?)") [(input-event :id) position (image :type) (buffer bytes)]))
        (charge s 1 (if (input :code) (estimate (input :code)) 0))
        (if (= false (input :queue))
          (or (claim s id)
              (do (finish s (call s id) nil {:error {:code "AgentBusy" :message "Target cannot start immediately."}}) (call s id)))
          (call s id))))))

(defn recover [s &opt force]
  (when (and (not force) (< (os/clock) ((s :recovery) 0))) (break))
  (put (s :recovery) 0 (+ (os/clock) interval))
  (def orphaned-previews (string (s :journal) ".previews WHERE request NOT IN
    (SELECT json_extract(p.checkpoint,'$.request') FROM main.live_calls c JOIN call_payloads p ON p.id=c.id
      WHERE json_type(p.checkpoint,'$.request')='integer')"))
  (when (first (query s (string "SELECT 1 FROM " orphaned-previews " LIMIT 1")))
    (query s (string "DELETE FROM " orphaned-previews)))
  (each intent (if (s :temporary) [] (query s `SELECT e.* FROM events e WHERE e.kind='save-intent'
    AND NOT EXISTS(SELECT 1 FROM events n WHERE n.parent=e.id AND n.kind IN ('saved','artifact'))
    AND NOT EXISTS(SELECT 1 FROM main.live_calls c WHERE c.id=json_extract(e.data,'$.call'))`))
    (def data (json/decode (intent :data) true true))
    (def origin (json/decode (data :origin) true true))
    (def ref (git (origin :root) ["rev-parse" "--verify" (data :ref)] nil nil true))
    (def actual (when ref (string/trim ref)))
    (assert (or (= actual (data :before)) (= actual (data :after))) "unfinished save conflicts with Git; reconcile explicitly")
    (transact s
      (unless (first (query s "SELECT id FROM events WHERE parent=? AND kind IN ('saved','artifact')" [(intent :id)]))
        (if (= actual (data :after))
          (do
            (assert (first (query s "UPDATE main.world SET origin=? WHERE id=1 AND origin=? RETURNING id"
                                [(string (json/encode (data :next))) (data :origin)])) "unfinished save conflicts with instance head")
            (query s "UPDATE main.call_payloads SET origin=? WHERE id=? AND origin=?" [(string (json/encode (data :next))) (data :call) (data :origin)])
            (append s {:branch (data :call)} "saved" (intent :text) (data :next) (intent :id)))
          (append s {:branch (data :call)} "artifact" "Save did not advance Git." {:save (intent :id)} (intent :id))))))
  (def now (os/clock))
  (def recovery-query `SELECT c.*,min(coalesce(c.expires,1e999),coalesce(r.expires,1e999))<=? expired,
    EXISTS(SELECT 1 FROM events a WHERE a.id=json_extract(p.checkpoint,'$.request') AND a.kind='model-admission'
      AND NOT EXISTS(SELECT 1 FROM events o WHERE o.parent=a.id AND o.kind='model-outcome')) pending_model,
    json_extract(p.checkpoint,'$.runtime') native_runtime
    FROM main.call_controls c JOIN main.call_controls r ON r.id=coalesce(c.root,c.id)
    LEFT JOIN call_payloads p ON p.id=c.id
    WHERE (?=0 OR c.temporary=1) AND
    (c.state IN ('queued','running','waiting') AND min(coalesce(c.expires,1e999),coalesce(r.expires,1e999))<=? OR c.state IN ('running','waiting') AND c.lease_expires<=?) ORDER BY c.id`)
  (def recovery-parameters [now (if (s :temporary) 1 0) now now])
  (when (first (query s (string recovery-query " LIMIT 1") recovery-parameters))
    (transact s
      (each row (query s recovery-query recovery-parameters)
        (def expired (= 1 (row :expired)))
        (def unstarted (and expired (= 0 (row :attempt))))
        (def retry (and (= 0 (row :temporary)) (not expired) (not= "code" (row :kind)) (> (row :retries) 0) (= 0 (row :pending_model)) (not= 1 (row :native_runtime))))
        (def state (cond unstarted "cancelled" retry "queued" "uncertain"))
        (when (= 0 (row :temporary))
          (append s (view s (if (= "summarize" (row :kind)) (row :parent) (row :id))) "interruption"
                  (if unstarted "Deadline expired before execution." "Interrupted execution; effects may have happened.")
                  {:state state :attempt (row :attempt)} nil (row :id)))
        (query s "UPDATE main.call_controls SET state=?,retries=retries-?,owner=CASE WHEN ? THEN NULL ELSE owner END,lease_expires=CASE WHEN ? THEN NULL ELSE lease_expires END WHERE id=?"
               [state (if retry 1 0) (or retry unstarted) (or retry unstarted) (row :id)]))))
  (unless (s :temporary)
    (def origin (origin s))
    (unless (= (origin :base) (s :checkpoint-base))
      (def bytes (git (origin :root) ["show" (string (origin :base) ":" (origin :path))]))
      (unless (= bytes (string (slurp ((s :config) :world)))) (spit ((s :config) :world) bytes :wb))
      (put s :checkpoint-base (origin :base)))))

(defn abort [s value]
  (assert (and (not= (nil? (value :run)) (nil? (value :request))) (string? (value :reason)) (<= (length (value :reason)) 2048)) "abort requires run or request and reason")
  (transact s
            (when (value :request)
              (query s "INSERT INTO main.call_controls(request,kind,temporary,expires,state,cancelled) VALUES(?,'text',0,?,'cancelled',1) ON CONFLICT(request) DO NOTHING"
                     [(value :request) (os/clock)]))
            (def row (first (query s "SELECT * FROM calls WHERE request_key IS NOT NULL AND (id=? OR request_key=?)" [(value :run) (value :request)])))
            (assert row "run unavailable")
            (def completed (= "done" (row :state)))
            (unless completed
              (query s "UPDATE main.call_controls SET cancelled=1 WHERE id=?" [(row :id)])
              (def affected (query s `UPDATE main.call_controls SET state='cancelled' WHERE state IN ('queued','running','waiting','uncertain')
        AND (id=? OR root=? AND (?=0 OR temporary=1)) RETURNING id,kind,attempt`
                                   [(row :id) (or (row :root) (row :id)) (row :temporary)]))
              (when (and (= 0 (row :temporary)) (row :admission)
                         (not (first (query s "SELECT id FROM events WHERE call=? AND kind='cancelled'" [(row :id)]))))
                (append s {:branch (row :id)} "cancelled" "Interrupted. Performed effects are not rolled back; running effects may still finish."
                        {:reason (value :reason) :tasks-at-request affected})))
            {:run (row :id) :state (if completed "completed" "cancelled")}))
