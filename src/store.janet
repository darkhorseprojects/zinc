(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)
(import ./schema)

(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn query [s statement &opt parameters control]
  (sql/eval (s (if control :control :db)) statement (or parameters [])))

(defmacro transact [s & body]
  (def db (gensym)) (def control (gensym))
  ~(let [,db (,s :db) ,control (,s :control)]
     (if (= ,db (dyn :zinc/transaction)) (do ,;body)
       (do
         (,sql/eval ,control "BEGIN IMMEDIATE")
         (try
           (do
             (when (not= ,db ,control) (,sql/eval ,db "BEGIN IMMEDIATE"))
             (def result (with-dyns [:zinc/transaction ,db] ,;body))
             (when (not= ,db ,control) (,sql/eval ,db "COMMIT"))
             (,sql/eval ,control "COMMIT") result)
           ([err]
             (when (not= ,db ,control) (try (,sql/eval ,db "ROLLBACK") ([ignored] nil)))
             (,sql/eval ,control "ROLLBACK") (error err)))))))

(defn- index [s id]
  (query s "INSERT INTO lexemes(source,term) SELECT DISTINCT ?,term FROM (SELECT term FROM event_words WHERE doc=? ORDER BY offset LIMIT 2048) WHERE length(CAST(term AS BLOB))<=128 ON CONFLICT DO NOTHING" [(s :source) id])
  (query s "INSERT INTO event_lexemes(event,lexeme) SELECT DISTINCT ?,l.id FROM (SELECT term FROM event_words WHERE doc=? ORDER BY offset LIMIT 2048) w JOIN lexemes l ON l.term=w.term AND l.source=? ON CONFLICT DO NOTHING" [id id (s :source)]))

(defn open [config &opt temporary]
  (def control (sql/open (config :store)))
  (var db control)
  (try
    (do
      (sql/eval db "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=5000; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL; PRAGMA temp_store=MEMORY;")
      (def s @{:db db :control control :source (config :source) :config config :temporary temporary :profiles @{}})
      (def version (((query s "PRAGMA user_version") 0) :user_version))
      (assert (index-of version [0 3]) "unsupported Zinc database; provision a fresh database")
      (when (= version 0)
        (transact s
          (when (= 0 (((query s "PRAGMA user_version") 0) :user_version)) (query s (schema/database)))))
      (when temporary
        (set db (sql/open ":memory:"))
        (put s :db db)
        (sql/eval db "PRAGMA temp_store=MEMORY; PRAGMA foreign_keys=OFF; PRAGMA trusted_schema=OFF;")
        (sql/eval db (string "PRAGMA max_page_count=" (math/floor (/ (config :journal-bytes) (((sql/eval db "PRAGMA page_size") 0) :page_size)))))
        (sql/eval db (schema/database true))
        (sql/eval db "ATTACH DATABASE ? AS archive" [(config :store)])
        (def cutoff (get-in config [:snapshot :archive-last] (((sql/eval control "SELECT coalesce(max(id),0) n FROM events") 0) :n)))
        (put s :archive-last cutoff)
        (sql/eval db `CREATE TEMP TABLE selected AS SELECT e.id FROM archive.events e
          LEFT JOIN archive.branches b ON b.id=e.branch WHERE e.source=? AND e.id<=?
          AND (coalesce(b.world,json_extract(e.data,'$.world'))=? OR coalesce(b.world,json_extract(e.data,'$.world')) IN (SELECT value FROM json_each(?)))`
          [(config :source) cutoff (config :world) (string (json/encode (config :visibility)))])
        (each [name key field] [["runs" "id" "run"] ["branches" "id" "branch"] ["tasks" "id" "task"] ["events" "id" "id"] ["images" "event" "id"] ["usage" "request" "id"]]
          (def columns (string/join (map |(string ($ :name)) (sql/eval db (string "PRAGMA table_info(" name ")"))) ","))
          (sql/eval db (string "INSERT INTO " name " SELECT " columns " FROM archive." name " WHERE " key " IN (SELECT " field " FROM archive.events WHERE id IN selected)")))
        (sql/eval db "DELETE FROM main.sqlite_sequence WHERE name IN ('branches','events'); INSERT INTO main.sqlite_sequence SELECT * FROM archive.sqlite_sequence WHERE name IN ('branches','events'); DETACH DATABASE archive;")
        (each name [:runs :branches :tasks :events]
          (def columns (map |($ :name) (sql/eval db (string "PRAGMA table_info(" name ")"))))
          (each row (get-in config [:snapshot name] [])
            (sql/eval db (string "INSERT OR IGNORE INTO " name "(" (string/join columns ",") ") VALUES(" (string/join (map (fn [_] "?") columns) ",") ")")
                      (map |(get row (keyword $)) columns))))
        (each row (query s "SELECT id FROM events WHERE source=?" [(s :source)]) (index s (row :id)))
        (sql/eval db "PRAGMA foreign_keys=ON;")
        (assert (<= (* (((query s "PRAGMA page_count") 0) :page_count) (((query s "PRAGMA page_size") 0) :page_size)) (config :journal-bytes)) "temporary history exceeds RAM journal budget"))
      s)
    ([err] (when (not= db control) (sql/close db)) (sql/close control) (error err))))

(defn close [s]
  (when (s :temporary)
    (each row (query s "SELECT file FROM branches WHERE run=? AND temporary=1" [(s :temporary-run)])
      (when (and (row :file) (os/stat (row :file))) (os/rm (row :file))))
    (sql/close (s :db)))
  (sql/close (s :control)))

(defn charge [s work tokens]
  (assert (s :budget-root) "missing run budget")
  (assert (first (query s
    `UPDATE runs SET work_used=work_used+?,tool_used=tool_used+? WHERE id=? AND source=? AND (?=0 OR expires>?)
     AND work_used+?<=? AND tool_used+?<=? RETURNING id`
    [work tokens (s :budget-root) (s :source) work (os/clock) work ((s :config) :task-quota) tokens ((s :config) :tool-quota)] true)) "shared run budget exhausted"))

(defn append [s scope kind text &opt data parent task]
  (transact s
    (assert (and (string? text) (utf8/is-valid? text)) "invalid event text")
    (def branch-row (when (scope :branch) (first (query s "SELECT b.origin,r.request FROM branches b JOIN runs r ON r.id=b.run WHERE b.id=? AND b.run=?" [(scope :branch) (scope :run)]))))
    (def origin (when branch-row (json/decode (branch-row :origin) true true)))
    (def data (string (json/encode (merge (or data {}) {:world-source (when origin {:root (origin :root) :path (origin :path) :ref (origin :ref) :base (origin :base)})}))))
    (assert (and (utf8/is-valid? data) (<= (+ (length text) (length data))
                ((s :config) (if (index-of kind ["user" "call-admission" "task-admission" "model-admission"]) :request-bytes :response-bytes)))) "stored event must be bounded UTF-8 JSON")
    (when (= kind "operation-outcome") (charge s 0 (estimate (string text data))))
    (def row ((query s "INSERT INTO events(source,run,branch,parent,task,kind,text,data,estimate,author,at) VALUES(?,?,?,?,?,?,?,?,?,?,coalesce(?,strftime('%Y-%m-%dT%H:%M:%fZ','now'))) RETURNING *"
      [(s :source) (scope :run) (scope :branch) parent task kind text data (estimate (string text data))
       (or (scope :author) (if branch-row (string "self:" (branch-row :request) "/" (scope :branch)) "system:zinc")) (scope :at)]) 0))
    (index s (row :id))
    (when (s :temporary)
      (assert (<= (* (((query s "PRAGMA page_count") 0) :page_count) (((query s "PRAGMA page_size") 0) :page_size)) ((s :config) :journal-bytes)) "RAM journal byte ceiling"))
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
    (cond (view :lexical) "lexeme_grams JOIN lexemes l ON l.id=lexeme_grams.rowid JOIN event_lexemes w ON w.lexeme=l.id JOIN memory_records e ON e.id=w.event"
      (view :match) "event_fts JOIN memory_records e ON e.id=event_fts.rowid" "memory_records e")
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
    (when (and (s :temporary) (not caller))
      (def run (((query s "INSERT INTO runs(source,request,input,world,config,expires,root,temporary) VALUES(?,?,'{}',?,'{}',?,?,1) RETURNING id"
        [(s :source) (input :request) (config :world) (min (+ (os/clock) (config :run-seconds)) (get-in config [:snapshot :deadline] math/inf)) (get-in config [:snapshot :budget-root])] true) 0) :id))
      (put s :temporary-run run) (put s :budget-root (get-in config [:snapshot :budget-root] run)))
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
        (def run (if caller (caller :run) (((query s "INSERT INTO runs(id,source,request,input,world,config,expires,temporary) VALUES(?,?,?,?,?,?,?,?) RETURNING id"
          [(s :temporary-run) (s :source) (input :request) encoded world (string (json/encode saved))
           (if (s :temporary) (((query s "SELECT expires FROM runs WHERE id=?" [(s :temporary-run)] true) 0) :expires)
             (get-in config [:snapshot :deadline] (+ (os/clock) (config :run-seconds)))) (if (s :temporary) 1 0)]) 0) :id)))
        (unless (s :budget-root) (put s :budget-root run))
        (def code (get origin :code ""))
        (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
        (def id (((query s "INSERT INTO branches(run,parent,caller,entry,first,last,history_last,world,code,origin,temporary) VALUES(?,?,?,?,?,?,?,?,?,?,?) RETURNING id"
          [run (when caller (caller :branch)) (when caller (caller :event)) (when (> entry 0) entry) first-id last
           (if caller (min last (caller :history-last)) last) world code
           (string (json/encode (tabseq [[key value] :in (pairs (or origin {})) :unless (= key :code)] key value))) (if (get input :persist true) 0 1)]) 0) :id))
        (when (config :repl)
          (def directory (string (config :store) ".worlds"))
          (os/mkdir directory) (os/chmod directory 8r700)
          (def file (string directory "/" (string/join (map |(string/format "%02x" $) (os/cryptorand 18))) ".janet"))
          (with [out (file/open file :wbn)] (file/write out code))
          (os/chmod file 8r600) (query s "UPDATE branches SET file=? WHERE id=?" [file id]))
        (def user (append s {:run run :branch id :world world :first first-id :last last :visibility (config :visibility) :author (input :author) :at (input :at)} "user" (get input :text "") {:input admitted} (when (> entry 0) entry)))
        (var image-bytes 0)
        (eachp [position image] (get input :images [])
          (def bytes (base64/decode (image :data)))
          (+= image-bytes (length bytes))
          (assert (<= image-bytes (config :image-bytes)) "stored image byte ceiling")
          (query s "INSERT INTO images(event,position,mime,bytes) VALUES(?,?,?,?)" [(user :id) position (image :type) (buffer bytes)]))
        (branch s id)))))

(defn view [s id]
  (def b (branch s id))
  {:run (b :run) :branch id :world (b :world) :first (b :first) :last (b :last)
   :history-last (b :history_last) :visibility ((s :config) :visibility)})

(defn tool-used [s run]
  (((query s "SELECT coalesce(sum(estimate),0) estimate FROM events WHERE source=? AND run=? AND (kind='tool-result' OR kind='task-admission' AND json_extract(data,'$.kind')='code')" [(s :source) run]) 0) :estimate))

(defn checkpoint [s value]
  (def current (dyn :zinc/task))
  (assert current "checkpoint requires an executing job")
  (def value (merge {:semantic (get-in current [:checkpoint :semantic])} value))
  (def encoded (string (json/encode value)))
  (assert (<= (length encoded) ((s :config) :request-bytes)) "stored checkpoint byte ceiling")
  (assert (first (query s `UPDATE tasks SET checkpoint=? WHERE id=? AND source=? AND state IN ('running','waiting') AND owner=? AND attempt=? AND lease_expires>?
    AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?) RETURNING id`
    [(if (s :temporary) "{}" encoded) (current :id) (s :source) (current :owner) (current :generation) (os/clock) (os/clock)] true)) "job lease lost")
  (when (s :temporary) (query s "UPDATE tasks SET checkpoint=? WHERE id=?" [encoded (current :id)]))
  (put current :checkpoint value) value)

(defn task [s id]
  (def row (first (query s "SELECT * FROM tasks WHERE id=? AND source=?" [id (s :source)] true)))
  (assert row "job unavailable")
  (def payload (if (s :temporary) (first (query s "SELECT * FROM tasks WHERE id=?" [id])) row))
  (merge row payload (struct :state (row :state) :result (when (payload :outcome) ((first (query s "SELECT data FROM events WHERE id=?" [(payload :outcome)])) :data)))))

(defn submit [s view kind input &opt options]
  (default options {})
  (def saved (tabseq [[key value] :in (pairs input) :unless (and (= kind "code") (= key :code))] key value))
  (when (= kind "code") (assert (and (string? (input :code)) (<= 1 (length (input :code)) ((s :config) :source-bytes))) "invalid tool source"))
  (def encoded (string (json/encode saved)))
  (def saved-checkpoint (string (json/encode (get options :checkpoint {}))))
  (assert (<= (max (length encoded) (length saved-checkpoint)) ((s :config) :request-bytes)) "stored task input/checkpoint byte ceiling")
  (def current (dyn :zinc/task))
  (def parent (when current (current :id)))
  (def granted (when current (current :scope)))
  (def depth (if parent (+ (get granted :depth 0) (if (index-of kind ["agent" "code"]) 1 0)) (get-in (s :config) [:snapshot :depth] 0)))
  (def view (merge (or granted {}) view {:depth depth}))
  (assert (<= depth ((s :config) :task-depth)) "agent recursion ceiling exhausted")
  (when parent
    (assert (and (= (view :run) (granted :run)) (= (view :world) (granted :world)) (>= (view :first) (granted :first)) (<= (view :history-last) (granted :history-last))) "child broadens execution scope")
    (each name (view :visibility) (assert (index-of name (granted :visibility)) "child broadens grants")))
  (def retry-policy (if (s :temporary) "manual" (get options :retry-policy "manual")))
  (def key (when (options :key) (string (when (s :temporary) (string "temporary:" (view :run) ":")) (options :key))))
  (transact s
    (when current (checkpoint s (current :checkpoint)))
    (def existing (when key (first (query s "SELECT id FROM tasks WHERE source=? AND key=?" [(s :source) key] true))))
    (if existing
      (let [row (task s (existing :id))]
        (assert (and (= kind (row :kind)) (= retry-policy (row :retry_policy)) (deep= saved (json/decode (row :input) true true))
          (or (not= kind "code") (= (input :code) ((first (query s "SELECT text FROM events WHERE id=?" [(row :admission)])) :text)))) "job key reused with different work")
        (row :id))
      (do
        (charge s 1 (if (= kind "code") (estimate (input :code)) 0))
        (def id (((query s `INSERT INTO tasks(source,run,branch,parent,world,kind,input,scope,retry_policy,retries,key,checkpoint)
          VALUES(?,?,?,?,?,?,?,?,?,1,?,?) RETURNING id`
          [(s :source) (view :run) (unless (s :temporary) (view :branch)) parent (view :world) kind
           (if (s :temporary) "{}" encoded) (string (json/encode view)) retry-policy key (if (s :temporary) "{}" saved-checkpoint)] true) 0) :id))
        (when (s :temporary)
          (query s "INSERT INTO tasks(id,branch,parent,kind,input,scope,checkpoint) VALUES(?,?,?,?,?,?,?)" [id (view :branch) parent kind encoded (string (json/encode view)) saved-checkpoint]))
        (def event (append s view "task-admission" (if (= kind "code") (input :code) kind) {:kind kind :retry-policy retry-policy :parent parent} nil id))
        (query s "UPDATE tasks SET admission=? WHERE id=?" [(event :id) id]) id))))

(defn park [s waiting]
  (def current (dyn :zinc/task))
  (checkpoint s (current :checkpoint))
  (if waiting
    (query s "UPDATE tasks SET state='waiting' WHERE id=? AND source=? AND state='running'" [(current :id) (s :source)] true)
    (while true
      (checkpoint s (current :checkpoint))
      (when (first (query s "UPDATE tasks SET state='running' WHERE id=? AND source=? AND state='waiting' AND (SELECT count(*) FROM running WHERE source=?)<? RETURNING id"
        [(current :id) (s :source) (s :source) ((s :config) :parallel)] true)) (break))
      (ev/sleep 0.1))))

(defn claim [s id]
  (transact s
    (def row (first (query s `UPDATE tasks SET state='running',attempt=attempt+1,owner=?,lease_expires=? WHERE id=? AND source=? AND state='queued'
      AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?) AND (SELECT count(*) FROM running WHERE source=?)<? RETURNING id`
      [(base64/encode (string (os/cryptorand 24))) (+ (os/clock) ((s :config) :lease-seconds)) id (s :source) (os/clock) (s :source) ((s :config) :parallel)] true)))
    (when row (task s id))))

(defn heartbeat [[config id owner generation stop]]
  (def db (sql/open (config :store)))
  (defer (sql/close db)
    (sql/eval db "PRAGMA busy_timeout=5000;")
    (try
      (while true
        (assert (first (sql/eval db `UPDATE tasks SET lease_expires=? WHERE id=? AND owner=? AND attempt=? AND state IN ('running','waiting')
          AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?) RETURNING id`
          [(+ (os/clock) (config :lease-seconds)) id owner generation (os/clock)])) "execution fenced")
        (def tick (ev/chan 1))
        (def timer (ev/go (fn [] (ev/sleep (/ (config :lease-seconds) 3)) (ev/give tick true))))
        (when (= stop ((ev/select stop tick) 1)) (ev/cancel timer "finished") (break)))
      ([err] nil))))

(defn finish [s row value failure]
  (transact s
    (assert (first (query s "SELECT id FROM tasks WHERE id=? AND owner=? AND attempt=? AND state IN ('running','waiting','uncertain','cancelled')" [(row :id) (row :owner) (row :attempt)] true)) "job completion fenced")
    (def state (if (= "cancelled" ((task s (row :id)) :state)) "cancelled" (if failure "failed" "done")))
    (def outcome {:ok (= state "done") :value value :error failure :state state :attempt (row :attempt)})
    (def encoded (string (json/encode outcome)))
    (assert (<= (length encoded) ((s :config) :response-bytes)) "stored task outcome byte ceiling")
    (when (= "code" (row :kind)) (charge s 0 (estimate encoded)))
    (def view (json/decode (row :scope) true true))
    (def event (append s view "task-outcome" "" outcome nil (row :id)))
    (query s "UPDATE tasks SET state=?,outcome=?,owner=NULL,lease_expires=NULL WHERE id=?" [state (unless (s :temporary) (event :id)) (row :id)] true)
    (when (s :temporary) (query s "UPDATE tasks SET outcome=? WHERE id=?" [(event :id) (row :id)]))
    (when (or failure (= "code" (row :kind)))
      (append s view (if (= state "done") "completed" "error") (if failure failure (if (string? value) value (string (json/encode value)))) {:original {:event (event :id)} :state state} nil (row :id)))
    outcome))

(defn recover [s]
  (transact s
    (each row (query s `SELECT t.*,r.expires run_expires,r.temporary FROM tasks t JOIN runs r ON r.id=t.run WHERE t.source=? AND (?=0 OR r.temporary=1)
      AND ((t.state IN ('queued','running','waiting') AND r.expires<=?) OR (t.state IN ('running','waiting') AND (t.lease_expires IS NULL OR t.lease_expires<=?))) ORDER BY t.id`
      [(s :source) (if (s :temporary) 1 0) (os/clock) (os/clock)] true)
      (def expired (<= (row :run_expires) (os/clock)))
      (def unstarted (and expired (= "queued" (row :state)) (= 0 (row :attempt))))
      (def retry (and (= 0 (row :temporary)) (not expired) (= (row :retry_policy) "retry") (<= (row :attempt) (row :retries))))
      (def state (cond unstarted "cancelled" retry "queued" "uncertain"))
      (def outcome {:ok false :state state :attempt (row :attempt) :error (cond unstarted "Run deadline expired before execution." expired "Run deadline expired; effects may have happened." "Interrupted execution; effects may have happened.")})
      (def event (when (= 0 (row :temporary)) (append s (json/decode (row :scope) true true) "interruption" (outcome :error) outcome nil (row :id))))
      (query s "UPDATE tasks SET state=?,outcome=?,owner=CASE WHEN ? THEN NULL ELSE owner END,lease_expires=CASE WHEN ? THEN NULL ELSE lease_expires END WHERE id=?"
        [state (unless retry (get event :id)) (or retry unstarted) (or retry unstarted) (row :id)] true))))
