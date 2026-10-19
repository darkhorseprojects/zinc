(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)
(import ./schema)

(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn query [s statement &opt parameters] (sql/eval (s :db) statement (or parameters [])))

(defmacro transact [s & body]
  (def db (gensym))
  ~(let [,db (,s :db)]
     (if (= ,db (dyn :zinc/transaction)) (do ,;body)
       (do
         (,sql/eval ,db "BEGIN IMMEDIATE")
         (try
           (let [result (with-dyns [:zinc/transaction ,db] ,;body)]
             (,sql/eval ,db "COMMIT") result)
           ([err] (,sql/eval ,db "ROLLBACK") (error err)))))))

(defn- index [s id]
  (query s (string "INSERT INTO " (s :journal) ".lexemes(source,term) SELECT DISTINCT ?,term FROM (SELECT term FROM " (s :journal) ".event_words WHERE doc=? ORDER BY offset LIMIT 2048) WHERE length(CAST(term AS BLOB))<=128 ON CONFLICT DO NOTHING") [(s :source) id])
  (query s (string "INSERT INTO " (s :journal) ".event_lexemes(event,lexeme) SELECT DISTINCT ?,l.id FROM (SELECT term FROM " (s :journal) ".event_words WHERE doc=? ORDER BY offset LIMIT 2048) w JOIN " (s :journal) ".lexemes l ON l.term=w.term AND l.source=? ON CONFLICT DO NOTHING") [id id (s :source)]))

(defn open [config &opt temporary]
  (def db (sql/open (config :store)))
  (def journal (if temporary "journal" "main"))
  (def s @{:db db :journal journal :source (config :source) :config config :temporary temporary :profiles @{}})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA temp_store=MEMORY;")
      (transact s
        (def version (((query s "PRAGMA user_version") 0) :user_version))
        (assert (index-of version [0 4]) "unsupported Zinc database; provision a fresh database")
        (when (= version 0) (query s (schema/database))))
      (when temporary
        (query s "ATTACH DATABASE ':memory:' AS journal; PRAGMA foreign_keys=OFF;")
        (query s (string "PRAGMA journal.max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA journal.page_size") 0) :page_size)))))
        (query s (schema/database true))
        (def cutoff (get-in config [:snapshot :archive-last] (((query s "SELECT coalesce(max(id),0) n FROM main.events") 0) :n)))
        (put s :archive-last cutoff)
        (query s "BEGIN")
        (do
          (query s `CREATE TEMP TABLE selected AS SELECT e.id FROM main.events e LEFT JOIN main.branches b ON b.id=e.branch
            WHERE e.source=? AND e.id<=? AND (coalesce(b.world,json_extract(e.data,'$.world'))=?
            OR coalesce(b.world,json_extract(e.data,'$.world')) IN (SELECT value FROM json_each(?)))`
            [(config :source) cutoff (config :world) (string (json/encode (config :visibility)))])
          (each [name key field] [["run_payloads" "id" "run"] ["branches" "id" "branch"] ["task_payloads" "id" "task"]
                                  ["events" "id" "id"] ["images" "event" "id"] ["usage" "request" "id"]]
            (query s (string "INSERT INTO journal." name " SELECT * FROM main." name " WHERE " key " IN (SELECT " field " FROM main.events WHERE id IN selected)")))
          (query s "DELETE FROM journal.sqlite_sequence WHERE name IN ('branches','events'); INSERT INTO journal.sqlite_sequence SELECT * FROM main.sqlite_sequence WHERE name IN ('branches','events'); DROP TABLE selected;")
          (each name [:run_payloads :branches :task_payloads :events :images :usage]
            (def columns (map |($ :name) (query s (string "PRAGMA journal.table_info(" name ")"))))
            (each row (get-in config [:snapshot name] [])
              (query s (string "INSERT OR IGNORE INTO journal." name "(" (string/join columns ",") ") VALUES(" (string/join (map (fn [_] "?") columns) ",") ")")
                (map |(if (and (= name :images) (= $ "bytes")) (buffer (base64/decode (row :bytes))) (get row (keyword $))) columns)))))
        (query s "UPDATE journal.task_payloads SET outcome=NULL WHERE outcome NOT IN (SELECT id FROM journal.events); COMMIT")
        (each row (query s "SELECT id FROM journal.events WHERE source=?" [(s :source)]) (index s (row :id)))
        (query s "PRAGMA foreign_keys=ON;")
        (assert (<= (* (((query s "PRAGMA journal.page_count") 0) :page_count) (((query s "PRAGMA journal.page_size") 0) :page_size)) (config :journal-bytes)) "temporary history exceeds RAM journal budget")
        (each name [:run_payloads :task_payloads :branches :events :images :usage :memory_records :conversation_records :unresolved_tools :invalid_summaries :lexemes :event_lexemes]
          (query s (string "CREATE TEMP VIEW " name " AS SELECT * FROM journal." name))))
      (query s (string "CREATE TEMP VIEW runs AS SELECT c.*,p.input,p.config FROM main.run_controls c LEFT JOIN " journal ".run_payloads p ON p.id=c.id;
        CREATE TEMP VIEW tasks AS SELECT c.*,p.branch,p.input,p.checkpoint,p.admission,p.outcome,e.data result FROM main.task_controls c
          LEFT JOIN " journal ".task_payloads p ON p.id=c.id LEFT JOIN " journal ".events e ON e.id=p.outcome;"))
      s)
    ([err] (sql/close db) (error err))))

(defn close [s]
  (when (s :temporary)
    (each row (query s "SELECT file FROM branches WHERE run=? AND temporary=1" [(s :temporary-run)])
      (when (and (row :file) (os/stat (row :file))) (os/rm (row :file)))))
  (sql/close (s :db)))

(defn charge [s work tokens]
  (assert (s :budget-root) "missing run budget")
  (assert (first (query s
    `UPDATE main.run_controls SET work_used=work_used+?,tool_used=tool_used+? WHERE id=? AND source=? AND (?=0 OR expires>? AND NOT cancelled)
     AND work_used+?<=? AND tool_used+?<=? RETURNING id`
    [work tokens (s :budget-root) (s :source) work (os/clock) work ((s :config) :task-quota) tokens ((s :config) :tool-quota)])) "shared run budget exhausted"))

(defn append [s scope kind text &opt data parent task]
  (transact s
    (assert (and (string? text) (utf8/is-valid? text)) "invalid event text")
    (def branch-row (when (scope :branch) (first (query s "SELECT b.origin,r.request FROM branches b JOIN runs r ON r.id=b.run WHERE b.id=? AND b.run=?" [(scope :branch) (scope :run)]))))
    (def origin (when branch-row (json/decode (branch-row :origin) true true)))
    (def data (string (json/encode (merge (or data {}) {:world-source (when origin {:root (origin :root) :path (origin :path) :ref (origin :ref) :base (origin :base)})}))))
    (assert (and (utf8/is-valid? data) (<= (+ (length text) (length data))
                ((s :config) (if (index-of kind ["user" "call-admission" "task-admission" "model-admission"]) :request-bytes :response-bytes)))) "stored event must be bounded UTF-8 JSON")
    (when (= kind "operation-outcome") (charge s 0 (estimate (string text data))))
    (def row ((query s (string "INSERT INTO " (s :journal) ".events(source,run,branch,parent,task,kind,text,data,estimate,author,at) VALUES(?,?,?,?,?,?,?,?,?,?,coalesce(?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))) RETURNING *")
      [(s :source) (scope :run) (scope :branch) parent task kind text data (estimate (string text data))
       (or (scope :author) (if branch-row (string "self:" (branch-row :request) "/" (scope :branch)) "system:zinc")) (scope :at)]) 0))
    (index s (row :id))
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
        (do (assert (and (= (previous :text) (record :text)) (= (previous :author) (record :author)) (= (previous :at) (record :at)) (deep= (json/decode (previous :data) true true) data)) "context key reused with different data") (previous :id))
        ((append s {:author (record :author) :at (record :at)} "context" (record :text) data) :id))) records)))

(defn branch [s id]
  (def row (first (query s "SELECT b.*,r.source,r.config,r.request FROM branches b JOIN runs r ON r.id=b.run WHERE b.id=? AND r.source=?" [id (s :source)])))
  (assert row "branch unavailable") row)

(defn visible [s view &opt order ceiling]
  (query s (string `WITH RECURSIVE ancestry(id,through) AS (
    SELECT ?,9007199254740991 UNION ALL SELECT b.parent,min(a.through,b.last) FROM branches b JOIN ancestry a ON b.id=a.id WHERE b.parent IS NOT NULL
  ), members(id) AS (SELECT ? UNION SELECT c.value FROM members m JOIN events n ON n.id=m.id,json_each(n.data,'$.children') c WHERE n.kind='summary')
  SELECT ` (get view :columns "e.*") `,coalesce(b.world,json_extract(e.data,'$.world')) world FROM `
    (cond (view :lexical) (string (s :journal) ".lexeme_grams JOIN lexemes l ON l.id=lexeme_grams.rowid JOIN event_lexemes w ON w.lexeme=l.id JOIN memory_records e ON e.id=w.event")
      (view :match) (string (s :journal) ".event_fts JOIN memory_records e ON e.id=event_fts.rowid") "memory_records e")
    ` LEFT JOIN branches b ON b.id=e.branch LEFT JOIN runs r ON r.id=e.run
  WHERE ` (if (view :match) (if (view :lexical) "lexeme_grams MATCH ? AND " "event_fts MATCH ? AND ") "") `e.source=? AND e.id BETWEEN ? AND ? AND (coalesce(b.world,json_extract(e.data,'$.world'))=? OR coalesce(b.world,json_extract(e.data,'$.world')) IN (SELECT value FROM json_each(?)))
    AND (e.id<=? OR (e.run=? AND EXISTS(SELECT 1 FROM ancestry a WHERE a.id=e.branch AND e.id<=a.through)))
    AND ((e.kind='context' AND e.branch IS NULL AND e.run IS NULL) OR (b.temporary=0 OR b.id IN (SELECT id FROM ancestry) OR (? AND e.id<=?)))
    AND (? IS NULL OR e.kind IN (SELECT value FROM json_each(?)))
    AND e.id NOT IN (SELECT value FROM json_each(?)) ` (when (view :memory) " AND e.memory ") ` ORDER BY `
    (if (view :match) (if (view :lexical) "l.term,e.id" "bm25(event_fts),e.id") (string "e.id " (if (= order :recent) "DESC" "ASC"))) " LIMIT ?")
    (array/concat @[(view :branch) (view :root)] (if (view :match) [(view :match)] [])
      [(s :source) (view :first) (view :last) (view :world) (string (json/encode (get view :visibility [])))
       (get view :history-last (view :last)) (view :run) (if (s :temporary) 1 0) (get view :history-last (view :last))
       (when (view :kinds) 1) (string (json/encode (view :kinds))) (string (json/encode (get view :exclude []))) (or ceiling 4096)])))

(defn event [s view id]
  (def row (first (visible s (merge view {:first id :last id}))))
  (assert (and (<= (view :first) id (view :last)) row) "event outside granted history") row)

(defn start [s input config &opt caller origin]
  (when (input :code) (assert (<= (length (input :code)) (config :source-bytes)) "stored Janet source byte ceiling"))
  (transact s
    (def admitted (table ;(kvs input)))
    (each key [:after :images] (put admitted key nil))
    (def previous (if caller
      (first (query s "SELECT b.id,json_extract(e.data,'$.input') input FROM branches b JOIN events e ON e.branch=b.id AND e.kind='user' WHERE b.caller=? AND e.source=?" [(caller :event) (s :source)]))
      (when (input :request) (first (query s "SELECT b.id,r.input FROM runs r JOIN branches b ON b.run=r.id WHERE r.source=? AND r.request=? AND b.parent IS NULL" [(s :source) (input :request)])))))
    (if previous
      (do
        (assert (deep= admitted (json/decode (previous :input) true true)) "request ID reused with different work")
        (assert (deep= (map |(table :type ($ :mime) :data (base64/encode (string ($ :bytes))))
          (query s "SELECT mime,bytes FROM images WHERE event=(SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1) ORDER BY position" [(previous :id)])) (get input :images @[])) "request ID reused with different images")
        (branch s (previous :id)))
      (do
        (when caller
          (assert (and (= (config :world) (caller :world)) (= (caller :branch) ((first (query s "SELECT branch FROM events WHERE id=? AND source=?" [(caller :event) (s :source)])) :branch))) "caller admission is outside its world/branch")
          (when (= 1 ((branch s (caller :branch)) :temporary)) (assert (not (get input :persist false)) "temporary calls cannot create durable descendants")))
        (def world (config :world))
        (def automatic (first (query s `SELECT e.id FROM events e LEFT JOIN branches b ON b.id=e.branch WHERE e.source=? AND coalesce(b.world,json_extract(e.data,'$.world'))=?
          AND ((e.kind='context' AND e.branch IS NULL AND e.run IS NULL) OR b.temporary=0) ORDER BY e.id DESC LIMIT 1` [(s :source) world])))
        (def entry (get input :parent (if caller (caller :last) (get automatic :id 0))))
        (def range (get input :memory_range {}))
        (def last (get range :end entry))
        (def earliest (when (> last 0) (first (query s "SELECT min(e.id) id FROM events e LEFT JOIN branches b ON b.id=e.branch WHERE e.source=? AND coalesce(b.world,json_extract(e.data,'$.world'))=? AND e.id<=? AND ((e.kind='context' AND e.branch IS NULL AND e.run IS NULL) OR (b.temporary=0 AND e.kind IN ('user','response','completed','tool-result')))" [(s :source) world last]))))
        (def first-id (get range :start (if (= last 0) 0 (if caller (caller :first) (or (earliest :id) last)))))
        (def allowed (or caller {:branch nil :world world :first 1 :last 9007199254740991 :visibility (config :visibility)}))
        (assert (and (int? entry) (int? last) (int? first-id) (>= entry 0) (<= 0 first-id last) (= (= first-id 0) (= last 0))) "invalid history range")
        (when (> entry 0) (event s allowed entry))
        (when (> last 0) (event s allowed last) (event s allowed first-id))
        (when caller (assert (or (= last 0) (<= (caller :first) first-id last (caller :last))) "child history exceeds caller view"))
        (def encoded (string (json/encode admitted)))
        (assert (<= (length encoded) (config :request-bytes)) "stored request byte ceiling")
        (def saved (merge config))
        (when (config :agent) (put saved :agent (merge (config :agent))))
        (each profile (filter identity [saved (saved :agent)])
          (put profile :snapshot nil)
          (put profile :capabilities (tabseq [[name capability] :in (pairs (profile :capabilities))] name {:module (capability :module)}))
          (put profile :providers (tabseq [[name provider] :in (pairs (profile :providers))] name {:url (provider :url) :identity (provider :identity)})))
        (def run (if caller (caller :run) (((query s `INSERT INTO main.run_controls(source,request,world,expires,root,temporary) VALUES(?,?,?,?,?,?) RETURNING id`
          [(s :source) (input :request) world (min (+ (os/clock) (config :run-seconds)) (get-in config [:snapshot :deadline] math/inf))
           (get-in config [:snapshot :budget-root]) (if (s :temporary) 1 0)]) 0) :id)))
        (unless caller
          (query s (string "INSERT INTO " (s :journal) ".run_payloads(id,input,config) VALUES(?,?,?)") [run encoded (string (json/encode saved))])
          (when (s :temporary) (put s :temporary-run run)))
        (unless (s :budget-root) (put s :budget-root (get-in config [:snapshot :budget-root] run)))
        (def depth (if caller (+ 1 (caller :depth)) (get-in config [:snapshot :depth] 0)))
        (assert (<= depth (config :task-depth)) "agent recursion ceiling exhausted")
        (def code (get origin :code ""))
        (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
        (def id (((query s (string "INSERT INTO " (s :journal) ".branches(run,parent,caller,entry,first,last,history_last,world,code,origin,temporary,agent,depth,visibility) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) RETURNING id")
          [run (when caller (caller :branch)) (when caller (caller :event)) (when (> entry 0) entry) first-id last
           (if caller (min last (caller :history-last)) last) world code
           (string (json/encode (tabseq [[key value] :in (pairs (or origin {})) :unless (= key :code)] key value)))
           (if (get input :persist true) 0 1) (if (and caller (caller :agent)) 1 0) depth (string (json/encode (config :visibility)))]) 0) :id))
        (when (config :repl)
          (def directory (string (config :store) ".worlds"))
          (os/mkdir directory) (os/chmod directory 8r700)
          (def file (string directory "/" (string/join (map |(string/format "%02x" $) (os/cryptorand 18))) ".janet"))
          (with [out (file/open file :wbn)] (file/write out code))
          (os/chmod file 8r600) (query s (string "UPDATE " (s :journal) ".branches SET file=? WHERE id=?") [file id]))
        (def user (append s {:run run :branch id :author (input :author) :at (input :at)} "user" (get input :text "") {:input admitted} (when (> entry 0) entry)))
        (var image-bytes 0)
        (eachp [position image] (get input :images [])
          (def bytes (base64/decode (image :data)))
          (+= image-bytes (length bytes))
          (assert (<= image-bytes (config :image-bytes)) "stored image byte ceiling")
          (query s (string "INSERT INTO " (s :journal) ".images(event,position,mime,bytes) VALUES(?,?,?,?)") [(user :id) position (image :type) (buffer bytes)]))
        (branch s id)))))

(defn view [s id &opt active]
  (default active true)
  (def b (branch s id))
  (def view {:run (b :run) :branch id :world (b :world) :first (b :first) :last (b :last)
             :history-last (b :history_last) :visibility (json/decode (b :visibility)) :agent (= 1 (b :agent)) :depth (b :depth)})
  (if active
    (merge view {:first (if (= 0 (view :first)) ((first (query s "SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [id])) :id) (view :first))
                 :last (get (first (visible s (merge view {:last 9007199254740991 :columns "e.id"}) :recent 1)) :id (view :last))})
    view))

(defn snapshot [s view]
  (def snapshot @{:depth (+ 1 (view :depth)) :budget-root (s :budget-root) :child true
    :deadline (((query s "SELECT expires FROM main.run_controls WHERE id=?" [(view :run)]) 0) :expires)
    :archive-last (or (s :archive-last) (((query s "SELECT coalesce(max(id),0) n FROM main.events") 0) :n))})
  (when (s :temporary)
    (each name [:run_payloads :branches :task_payloads :events :images :usage]
      (put snapshot name (map (fn [row]
        (if (= name :images) (merge row {:bytes (base64/encode (string (row :bytes)))}) row))
        (query s (string "SELECT * FROM journal." name))))))
  snapshot)

(defn tool-used [s run]
  (((query s "SELECT coalesce(sum(estimate),0) estimate FROM events WHERE source=? AND run=? AND (kind='tool-result' OR kind='task-admission' AND json_extract(data,'$.kind')='code')" [(s :source) run]) 0) :estimate))

(defn checkpoint [s value]
  (def current (dyn :zinc/task))
  (assert current "checkpoint requires an executing job")
  (def value (merge {:semantic (get-in current [:checkpoint :semantic])} value))
  (def encoded (string (json/encode value)))
  (assert (<= (length encoded) ((s :config) :request-bytes)) "stored checkpoint byte ceiling")
  (assert (first (query s (string "UPDATE " (s :journal) `.task_payloads SET checkpoint=? WHERE id IN (
    SELECT t.id FROM main.task_controls t JOIN main.run_controls r ON r.id=t.run WHERE t.id=? AND t.source=? AND t.owner=?
      AND t.state IN ('running','waiting') AND t.lease_expires>? AND r.expires>? AND NOT r.cancelled) RETURNING id`)
    [encoded (current :id) (s :source) (current :owner) (os/clock) (os/clock)])) "job lease lost")
  (put current :checkpoint value) value)

(defn task [s id]
  (def row (first (query s "SELECT * FROM tasks WHERE id=? AND source=?" [id (s :source)])))
  (assert row "job unavailable") row)

(defn submit [s view kind input &opt options]
  (default options {})
  (when (= kind "code") (assert (and (string? (input :code)) (<= 1 (length (input :code)) ((s :config) :source-bytes))) "invalid tool source"))
  (def saved (tabseq [[key value] :in (pairs input) :unless (and (= kind "code") (= key :code))] key value))
  (def encoded (string (json/encode saved)))
  (def saved-checkpoint (string (json/encode (get options :checkpoint {}))))
  (assert (<= (max (length encoded) (length saved-checkpoint)) ((s :config) :request-bytes)) "stored task input/checkpoint byte ceiling")
  (def current (dyn :zinc/task))
  (def retry-policy (if (s :temporary) "manual" (get options :retry-policy "manual")))
  (def key (when (options :key) (string (when (s :temporary) (string "temporary:" (view :run) ":")) (options :key))))
  (transact s
    (when current (checkpoint s (current :checkpoint)))
    (def existing (when key (first (query s "SELECT * FROM tasks WHERE source=? AND key=?" [(s :source) key]))))
    (if existing
      (do
        (assert (and (= kind (existing :kind)) (= retry-policy (existing :retry_policy)) (deep= saved (json/decode (existing :input) true true))
          (or (not= kind "code") (= (input :code) ((first (query s "SELECT text FROM events WHERE id=?" [(existing :admission)])) :text)))) "job key reused with different work")
        (existing :id))
      (do
        (charge s 1 (if (= kind "code") (estimate (input :code)) 0))
        (def id (((query s "INSERT INTO main.task_controls(source,run,parent,world,kind,retry_policy,key) VALUES(?,?,?,?,?,?,?) RETURNING id"
          [(s :source) (view :run) (when current (current :id)) (view :world) kind retry-policy key]) 0) :id))
        (query s (string "INSERT INTO " (s :journal) ".task_payloads(id,branch,input,checkpoint) VALUES(?,?,?,?)") [id (view :branch) encoded saved-checkpoint])
        (def event (append s view "task-admission" (if (= kind "code") (input :code) kind) {:kind kind :retry-policy retry-policy :parent (when current (current :id))} nil id))
        (query s (string "UPDATE " (s :journal) ".task_payloads SET admission=? WHERE id=?") [(event :id) id]) id))))

(defn park [s waiting]
  (def current (dyn :zinc/task))
  (checkpoint s (current :checkpoint))
  (if waiting
    (query s "UPDATE main.task_controls SET state='waiting' WHERE id=? AND source=? AND owner=? AND state='running'" [(current :id) (s :source) (current :owner)])
    (while true
      (checkpoint s (current :checkpoint))
      (when (first (query s "UPDATE main.task_controls SET state='running' WHERE id=? AND source=? AND owner=? AND state='waiting' AND (SELECT count(*) FROM running WHERE source=?)<? RETURNING id"
        [(current :id) (s :source) (current :owner) (s :source) ((s :config) :parallel)])) (break))
      (ev/sleep 0.1))))

(defn claim [s id]
  (transact s
    (when (first (query s `UPDATE main.task_controls SET state='running',attempt=attempt+1,owner=?,lease_expires=? WHERE id=? AND source=? AND state='queued'
      AND EXISTS(SELECT 1 FROM main.run_controls WHERE id=task_controls.run AND expires>? AND NOT cancelled) AND (SELECT count(*) FROM running WHERE source=?)<? RETURNING id`
      [(base64/encode (string (os/cryptorand 24))) (+ (os/clock) ((s :config) :lease-seconds)) id (s :source) (os/clock) (s :source) ((s :config) :parallel)]))
      (task s id))))

(defn heartbeat [[config id owner stop]]
  (def db (sql/open (config :store)))
  (defer (sql/close db)
    (sql/eval db "PRAGMA busy_timeout=5000;")
    (try
      (while true
        (assert (first (sql/eval db `UPDATE task_controls SET lease_expires=? WHERE id=? AND owner=? AND state IN ('running','waiting')
          AND EXISTS(SELECT 1 FROM run_controls WHERE id=task_controls.run AND expires>? AND NOT cancelled) RETURNING id`
          [(+ (os/clock) (config :lease-seconds)) id owner (os/clock)])) "execution fenced")
        (def tick (ev/chan 1))
        (def timer (ev/go (fn [] (ev/sleep (/ (config :lease-seconds) 3)) (ev/give tick true))))
        (when (= stop ((ev/select stop tick) 1)) (ev/cancel timer "finished") (break)))
      ([err] nil))))

(defn finish [s row value failure]
  (transact s
    (assert (first (query s "SELECT id FROM main.task_controls WHERE id=? AND owner=? AND state IN ('running','waiting','uncertain','cancelled')" [(row :id) (row :owner)])) "job completion fenced")
    (def state (if (= "cancelled" ((task s (row :id)) :state)) "cancelled" (if failure "failed" "done")))
    (def outcome {:ok (= state "done") :value value :error failure :state state :attempt (row :attempt)})
    (def encoded (string (json/encode outcome)))
    (assert (<= (length encoded) ((s :config) :response-bytes)) "stored task outcome byte ceiling")
    (when (= "code" (row :kind)) (charge s 0 (estimate encoded)))
    (def view (view s (row :branch)))
    (def event (append s view "task-outcome" "" outcome nil (row :id)))
    (query s (string "UPDATE " (s :journal) ".task_payloads SET outcome=? WHERE id=?") [(event :id) (row :id)])
    (query s "UPDATE main.task_controls SET state=?,owner=NULL,lease_expires=NULL WHERE id=?" [state (row :id)])
    (when (or failure (= "code" (row :kind)))
      (append s view (if (= state "done") "completed" "error") (if failure failure (if (string? value) value (string (json/encode value)))) {:original {:event (event :id)} :state state} nil (row :id)))
    outcome))

(defn recover [s]
  (transact s
    (each row (query s `SELECT t.*,r.expires run_expires,r.temporary FROM tasks t JOIN main.run_controls r ON r.id=t.run WHERE t.source=? AND (?=0 OR r.temporary=1)
      AND ((t.state IN ('queued','running','waiting') AND r.expires<=?) OR (t.state IN ('running','waiting') AND (t.lease_expires IS NULL OR t.lease_expires<=?))) ORDER BY t.id`
      [(s :source) (if (s :temporary) 1 0) (os/clock) (os/clock)])
      (def expired (<= (row :run_expires) (os/clock)))
      (def unstarted (and expired (= "queued" (row :state)) (= 0 (row :attempt))))
      (def retry (and (= 0 (row :temporary)) (not expired) (= (row :retry_policy) "retry") (<= (row :attempt) (row :retries))))
      (def state (cond unstarted "cancelled" retry "queued" "uncertain"))
      (def outcome {:ok false :state state :attempt (row :attempt) :error (cond unstarted "Run deadline expired before execution." expired "Run deadline expired; effects may have happened." "Interrupted execution; effects may have happened.")})
      (when (= 0 (row :temporary))
        (def event (append s (view s (row :branch)) "interruption" (outcome :error) outcome nil (row :id)))
        (unless retry (query s "UPDATE main.task_payloads SET outcome=? WHERE id=?" [(event :id) (row :id)])))
      (query s "UPDATE main.task_controls SET state=?,owner=CASE WHEN ? THEN NULL ELSE owner END,lease_expires=CASE WHEN ? THEN NULL ELSE lease_expires END WHERE id=?"
        [state (or retry unstarted) (or retry unstarted) (row :id)]))))
