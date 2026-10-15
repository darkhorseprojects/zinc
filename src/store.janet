(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/utf8 :as utf8)
(import ./schema)

(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn query [s statement &opt parameters]
  (map (fn [row] (struct ;(catseq [[key value] :in (pairs row)] [(string key) value])))
       (sql/eval (s :db) statement (or parameters []))))

(defmacro transact [s & body]
  (def db (gensym))
  ~(let [,db (,s :db)]
     (if (= ,db (dyn :zinc/transaction)) (do ,;body)
       (do
         (,sql/eval ,db "BEGIN IMMEDIATE")
         (try (let [result (with-dyns [:zinc/transaction ,db] ,;body)] (,sql/eval ,db "COMMIT") result)
           ([err] (,sql/eval ,db "ROLLBACK") (error err)))))))

(defn open [config]
  (def db (sql/open (config :store)))
  (try
    (do
      (sql/eval db "PRAGMA foreign_keys=ON; PRAGMA trusted_schema=OFF; PRAGMA busy_timeout=200; PRAGMA synchronous=FULL; PRAGMA journal_mode=WAL;")
      (def s @{:db db :source (config :source) :config config})
      (transact s
        (def version (((query s "PRAGMA user_version") 0) "user_version"))
        (assert (index-of version [0 1]) "unsupported Zinc database; preserve it and select a fresh database")
        (when (= version 0) (query s schema/database))
        (assert (first (query s "SELECT name FROM pragma_table_info('branches') WHERE name='code'"))
                "stale Zinc database; preserve it and select a fresh database")
        (query s `CREATE TRIGGER IF NOT EXISTS event_kind BEFORE INSERT ON events
          WHEN new.kind NOT IN ('user','response','completed','tools','tool-result','tool-ambiguity',
            'task-admission','task-attempt','task-outcome','model-admission','model-outcome',
            'call-admission','launch-uncertain','traceback','summary','interruption','cancelled','artifact','context','error')
          BEGIN SELECT raise(ABORT,'unsupported event kind'); END;`))
      s)
    ([err] (sql/close db) (error err))))

(defn close [s] (sql/close (s :db)))
(defn append [s scope kind text &opt data parent task]
  (assert (and (string? text) (utf8/is-valid? text)) "invalid event text")
  (def data (string (json/encode (or data {}))))
  (assert (<= (+ (length text) (length data))
              ((s :config) (if (index-of kind ["user" "call-admission" "task-admission" "model-admission"]) :request-bytes :response-bytes)))
          "stored event byte ceiling")
  (def row ((query s "INSERT INTO events(source,run,branch,parent,task,kind,text,data,estimate) VALUES(?,?,?,?,?,?,?,?,?) RETURNING *"
                   [(s :source) (scope :run) (scope :branch) parent task kind text data (estimate (string text data))]) 0))
  (when (index-of kind ["user" "response" "tools" "completed" "tool-result" "artifact" "context"])
    (query s "INSERT INTO lexemes(source,term) SELECT DISTINCT ?,term FROM (SELECT term FROM event_words WHERE doc=? ORDER BY offset LIMIT 2048) WHERE length(CAST(term AS BLOB))<=128 ON CONFLICT DO NOTHING" [(s :source) (row "id")])
    (query s "INSERT INTO event_lexemes(event,lexeme) SELECT DISTINCT ?,l.id FROM (SELECT term FROM event_words WHERE doc=? ORDER BY offset LIMIT 2048) w JOIN lexemes l ON l.term=w.term AND l.source=? ON CONFLICT DO NOTHING" [(row "id") (row "id") (s :source)]))
  row)

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
    (map (fn [record]
           (assert (and (dictionary? record) (= (tuple/slice (sorted (keys record))) [:at :author :key :text])) "invalid context record")
           (each key [:at :author :key :text]
             (assert (and (string? (record key)) (> (length (record key)) 0)) "invalid context field"))
           (assert (<= (length (record :key)) 256) "context key byte ceiling")
           (def data @{:at (record :at) :author (record :author) :key (record :key) :world ((s :config) :world)})
           (def previous (first (query s "SELECT * FROM events WHERE source=? AND kind='context' AND json_extract(data,'$.key')=?" [(s :source) (record :key)])))
           (if previous
             (do (assert (and (= (previous "text") (record :text)) (deep= (json/decode (previous "data") true true) data)) "context key reused with different data")
               (previous "id"))
             ((append s {} "context" (record :text) data) "id"))) records)))

(defn branch [s id]
  (def rows (query s "SELECT b.*,r.source,r.config FROM branches b JOIN runs r ON r.id=b.run WHERE b.id=? AND r.source=? AND b.retired=0" [id (s :source)]))
  (assert (> (length rows) 0) "branch unavailable") (rows 0))

(defn visible [s view &opt order ceiling]
  (query s (string `WITH RECURSIVE ancestry(id,through) AS (
    SELECT ?,9007199254740991 UNION ALL SELECT b.parent,min(a.through,b.last) FROM branches b JOIN ancestry a ON b.id=a.id WHERE b.parent IS NOT NULL
  ) SELECT ` (get view :columns "e.*") `,coalesce(b.world,json_extract(e.data,'$.world')) world FROM `
                   (cond (view :lexical) "lexeme_grams JOIN lexemes l ON l.id=lexeme_grams.rowid JOIN event_lexemes w ON w.lexeme=l.id JOIN events e ON e.id=w.event"
                     (view :match) "event_fts JOIN events e ON e.id=event_fts.rowid" "events e")
                   ` LEFT JOIN branches b ON b.id=e.branch LEFT JOIN runs r ON r.id=e.run
  WHERE ` (if (view :match) (if (view :lexical) "lexeme_grams MATCH ? AND " "event_fts MATCH ? AND ") "") `e.source=? AND e.id BETWEEN ? AND ? AND (coalesce(b.world,json_extract(e.data,'$.world'))=? OR coalesce(b.world,json_extract(e.data,'$.world')) IN (SELECT value FROM json_each(?)))
    AND (e.id<=? OR (e.run=? AND EXISTS(SELECT 1 FROM ancestry a WHERE a.id=e.branch AND e.id<=a.through)))
    AND ((e.kind='context' AND e.branch IS NULL AND e.run IS NULL) OR (b.retired=0 AND (b.temporary=0 OR b.id IN (SELECT id FROM ancestry))))
    AND (? IS NULL OR e.kind IN (SELECT value FROM json_each(?)))
    AND NOT EXISTS(SELECT 1 FROM json_each(?) c WHERE e.id BETWEEN json_extract(c.value,'$.first') AND json_extract(c.value,'$.last')) ORDER BY `
                   (if (view :match) (if (view :lexical) "l.term,e.id" "bm25(event_fts),e.id")
                     (string "e.id " (if (= order :recent) "DESC" "ASC")))
                   " LIMIT ?")
         (array/concat @[(view :branch)] (if (view :match) [(view :match)] [])
                       [(s :source) (view :first) (view :last) (view :world)
                        (string (json/encode (get view :visibility [])))
                        (get view :history-last (view :last)) (view :run)
                        (when (view :kinds) 1) (string (json/encode (view :kinds)))
                        (string (json/encode (get view :covered []))) (or ceiling 4096)])))

(defn event [s view id]
  (def rows (visible s (merge view {:first id :last id})))
  (assert (and (<= (view :first) id (view :last)) (> (length rows) 0)) "event outside granted history")
  (rows 0))

(defn start [s input config &opt caller]
  (when (input :code)
    (assert (<= (length (input :code)) (config :source-bytes)) "stored Janet source byte ceiling"))
  (def input (json/decode (json/encode input) true true))
  (transact s
    (def admitted (table ;(kvs input)))
    (each key [:after :images] (put admitted key nil))

    (def previous (if caller
                    (first (query s "SELECT b.id,json_extract(e.data,'$.input') input FROM branches b JOIN events e ON e.branch=b.id AND e.kind='user' WHERE b.caller=? AND e.source=?"
                                  [(caller :event) (s :source)]))
                    (when (input :request)
                      (first (query s "SELECT b.id,r.input FROM runs r JOIN branches b ON b.run=r.id WHERE r.source=? AND r.request=? AND b.parent IS NULL"
                                    [(s :source) (input :request)])))))

    (if previous
      (do
        (assert (deep= admitted (json/decode (previous "input") true true))
                "request ID reused with different work")

        (def saved-images
          (map (fn [row] (table :type (row "mime") :data (base64/encode (string (row "bytes")))))
               (query s "SELECT mime,bytes FROM images WHERE event=(SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1) ORDER BY position"
                      [(previous "id")])))

        (assert (deep= saved-images (get input :images @[]))
                "request ID reused with different images")

        (branch s (previous "id")))
      (do
        (when caller
          (def parent-branch (branch s (caller :branch)))
          (when (= 1 (parent-branch "temporary"))
            (assert (not (get input :persist false)) "temporary calls cannot create durable descendants"))
          (def attachment (first (query s "SELECT branch FROM events WHERE id=? AND source=?" [(caller :event) (s :source)])))
          (assert (= (caller :branch) (attachment "branch")) "caller admission is outside its branch"))
        (def world (config :world))
        (when caller (assert (= world (caller :world)) "child changes world"))
        # An interrupted turn is history too; freeze the latest committed boundary.
        (def automatic (first (query s
                                     `SELECT e.id FROM events e LEFT JOIN branches b ON b.id=e.branch
                   WHERE e.source=? AND coalesce(b.world,json_extract(e.data,'$.world'))=?
                     AND ((e.kind='context' AND e.branch IS NULL AND e.run IS NULL) OR (b.temporary=0 AND b.retired=0))
                   ORDER BY e.id DESC LIMIT 1` [(s :source) world])))
        (def entry (get input :parent (if caller (caller :last) (if automatic (automatic "id") 0))))
        (def range (get input :memory_range {}))
        (def last (get range :end entry))
        (def earliest (when (> last 0)
                        (first (query s "SELECT min(e.id) id FROM events e LEFT JOIN branches b ON b.id=e.branch WHERE e.source=? AND coalesce(b.world,json_extract(e.data,'$.world'))=? AND e.id<=? AND ((e.kind='context' AND e.branch IS NULL AND e.run IS NULL) OR (b.temporary=0 AND b.retired=0 AND e.kind IN ('user','response','completed','tool-result')))"
                                      [(s :source) world last]))))
        (def first-id (get range :start (if (= last 0) 0 (if caller (caller :first) (or (earliest "id") last)))))
        (def allowed (if caller caller {:branch nil :world world :first 1 :last 9007199254740991 :visibility (config :visibility)}))
        (assert (and (int? entry) (int? last) (int? first-id) (>= entry 0) (<= 0 first-id last) (= (= first-id 0) (= last 0))) "invalid history range")
        (when (> entry 0) (event s allowed entry))
        (when (> last 0) (event s allowed last) (event s allowed first-id))
        (when caller (assert (or (= last 0) (and (<= (caller :first) first-id) (<= last (caller :last)))) "child history exceeds caller view"))
        (def encoded (string (json/encode admitted)))
        (assert (<= (length encoded) (config :request-bytes)) "stored request byte ceiling")
        (def run (if caller (caller :run)
                   (((query s "INSERT INTO runs(source,request,input,world,config,expires) VALUES(?,?,?,?,?,?) RETURNING id"
                            [(s :source) (input :request) encoded world
                             (string (json/encode (merge config {:providers (tabseq [[name provider] :in (pairs (config :providers))]
                                                                              name {:url (provider :url) :identity (provider :identity)})})))
                             (+ (os/clock) (config :run-seconds))]) 0) "id")))
        (def code (if caller ((branch s (caller :branch)) "code")
                    (if (config :repl) (string (slurp (config :file))) "")))
        (assert (<= (length code) (config :source-bytes)) "world source byte ceiling")
        (def id (((query s "INSERT INTO branches(run,parent,caller,entry,first,last,history_last,world,code,temporary) VALUES(?,?,?,?,?,?,?,?,?,?) RETURNING id"
                         [run (when caller (caller :branch)) (when caller (caller :event)) (when (> entry 0) entry)
                          first-id last (if caller (min last (caller :history-last)) last) world code
                          (if (get input :persist true) 0 1)]) 0) "id"))
        (def scope {:run run :branch id :world world :first first-id :last last :visibility (config :visibility)})
        (def user (append s scope "user" (get input :text "") {:input admitted} (when (> entry 0) entry)))

        (var image-bytes 0)
        (eachp [position image] (get input :images [])
          (def bytes (base64/decode (image :data)))
          (+= image-bytes (length bytes))
          (assert (<= image-bytes (config :image-bytes)) "stored image byte ceiling")
          (query s "INSERT INTO images(event,position,mime,bytes) VALUES(?,?,?,?)" [(user "id") position (image :type) (buffer bytes)]))
        (branch s id)))))

(defn view [s id]
  (def b (branch s id))
  {:run (b "run") :branch id :world (b "world")
   :first (b "first") :last (b "last")
   :history-last (b "history_last") :visibility ((s :config) :visibility)})

(defn tool-used [s run]
  (((query s `SELECT coalesce(sum((length(CAST(e.text AS BLOB))+3)/4 + (coalesce(length(CAST(t.result AS BLOB)),0)+3)/4),0) estimate
    FROM tasks t JOIN events e ON e.id=t.admission WHERE t.source=? AND t.run=? AND t.kind='code'` [(s :source) run]) 0) "estimate"))

(defn checkpoint [s value]
  (def encoded (string (json/encode value)))
  (assert (<= (length encoded) ((s :config) :request-bytes)) "stored checkpoint byte ceiling")
  (def current (dyn :zinc/task))
  (assert current "checkpoint requires an executing job")
  (assert (first (query s
                        `UPDATE tasks SET checkpoint=?
     WHERE id=? AND source=? AND state IN ('running','waiting') AND EXISTS(
       SELECT 1 FROM leases WHERE task=? AND owner=? AND generation=? AND expires>?)
       AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?)
     RETURNING id`
                        [encoded (current :id) (s :source)
                         (current :id) (current :owner) (current :generation) (os/clock) (os/clock)])) "job lease lost")
  (put current :checkpoint value)
  value)

(defn task [s id]
  (def row (first (query s "SELECT * FROM tasks WHERE id=? AND source=?" [id (s :source)])))
  (assert row "job unavailable")
  row)

(defn submit [s view kind input &opt options]
  (def input (json/decode (json/encode input) true true))
  (def saved (table ;(kvs input)))
  (when (= kind "code")
    (assert (and (string? (input :code)) (<= 1 (length (input :code)) ((s :config) :source-bytes))) "invalid tool source")
    (put saved :code nil))
  (def encoded (string (json/encode saved)))
  (assert (<= (length encoded) ((s :config) :request-bytes)) "stored task input byte ceiling")
  (default options {})
  (def current (dyn :zinc/task))
  (def parent (when current (current :id)))
  (def granted (when parent (json/decode ((task s parent) "scope") true true)))
  (def depth (+ (get granted :depth 0) (if (and parent (= kind "agent")) 1 0)))
  (def view (merge (or granted {}) view {:depth depth}))

  (assert (<= depth ((s :config) :task-depth)) "agent recursion ceiling exhausted")

  (when parent
    (assert (and (= (view :run) (granted :run))
                 (= (view :world) (granted :world))
                 (>= (view :first) (granted :first))
                 (<= (view :history-last) (granted :history-last)))
            "child broadens execution scope")

    (each key [:visibility]
      (each name (get view key [])
        (assert (index-of name (get granted key [])) "child broadens grants"))))

  (def retry-policy (get options :retry-policy "manual"))

  (transact s
    (when current (checkpoint s (current :checkpoint)))
    (def existing (when (options :key)
                    (first (query s "SELECT * FROM tasks WHERE source=? AND key=?"
                                  [(s :source) (options :key)]))))

    (if existing
      (do
        (assert (and (= kind (existing "kind"))
                     (= retry-policy (existing "retry_policy"))
                     (deep= saved (json/decode (existing "input") true true))
                     (or (not= kind "code") (= (input :code) ((first (query s "SELECT text FROM events WHERE id=?" [(existing "admission")])) "text"))))
                "job key reused with different work")
        (existing "id"))
      (do
        (assert (first (query s "SELECT id FROM runs WHERE id=? AND source=? AND expires>?"
                              [(view :run) (s :source) (os/clock)])) "run deadline expired")
        (assert (< (((query s "SELECT count(*) n FROM tasks WHERE source=? AND run=?"
                            [(s :source) (view :run)]) 0) "n")
                   ((s :config) :task-quota))
                "shared job quota exhausted")

        (when (= kind "code")
          (assert (<= (+ (tool-used s (view :run)) (estimate (input :code)))
                      ((s :config) :tool-quota))
                  "shared tool quota exhausted"))

        (def id (((query s
                         `INSERT INTO tasks(source,run,branch,parent,world,kind,input,scope,
                             retry_policy,retries,key,checkpoint)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?) RETURNING id`
                         [(s :source) (view :run) (view :branch) parent (view :world)
                          kind encoded (string (json/encode view)) retry-policy
                          (get options :retries 1) (options :key)
                          (string (json/encode (get options :checkpoint {})))]) 0) "id"))

        (def event (append s view "task-admission"
                           (if (= kind "code") (input :code) kind)
                           {:kind kind :retry-policy retry-policy :parent parent} nil id))

        (query s "UPDATE tasks SET admission=? WHERE id=?" [(event "id") id])
        id))))

(defn park [s waiting]
  (def current (dyn :zinc/task))
  (checkpoint s (current :checkpoint))
  (if waiting
    (query s "UPDATE tasks SET state='waiting' WHERE id=? AND source=? AND state='running'" [(current :id) (s :source)])
    (while true
      (checkpoint s (current :checkpoint))
      (when (first (query s
                          `UPDATE tasks SET state='running' WHERE id=? AND source=? AND state='waiting'
         AND (SELECT count(*) FROM tasks WHERE source=? AND state='running')<? RETURNING id`
                          [(current :id) (s :source) (s :source) ((s :config) :parallel)])) (break))
      (ev/sleep 0.1))))

(defn claim [s id]
  (def owner (base64/encode (string (os/cryptorand 24))))

  (transact s
    (def row (first (query s
                           `UPDATE tasks SET state='running',attempt=attempt+1
       WHERE id=? AND source=? AND state='queued'
         AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?)
         AND (SELECT count(*) FROM tasks WHERE source=? AND state='running')<? RETURNING *`
                           [id (s :source) (os/clock) (s :source) ((s :config) :parallel)])))

    (when row
      (query s
             `INSERT INTO leases(task,owner,generation,expires) VALUES(?,?,?,?)
         ON CONFLICT(task) DO UPDATE SET owner=excluded.owner,
           generation=excluded.generation,expires=excluded.expires`
             [id owner (row "attempt") (+ (os/clock) ((s :config) :lease-seconds))])

      (append s (json/decode (row "scope") true true) "task-attempt"
              "execution claimed" {:attempt (row "attempt")} nil id)

      (merge row {"owner" owner}))))

(defn heartbeat [[config id owner generation stop finished]]
  (try
    (let [s (open config)]
      (defer (close s)
        (while true
          (unless (first (query s
                                `UPDATE leases SET expires=? WHERE task=? AND owner=? AND generation=?
             AND EXISTS(SELECT 1 FROM tasks t JOIN runs r ON r.id=t.run
               WHERE t.id=? AND t.state IN ('running','waiting') AND r.expires>?) RETURNING task`
                                [(+ (os/clock) (config :lease-seconds)) id owner generation id (os/clock)]))
            (break))

          (def tick (ev/chan 1))
          (def timer (ev/go (fn []
                              (try (do (ev/sleep (/ (config :lease-seconds) 3)) (ev/give tick true)) ([err] nil)))))

          (when (= stop ((ev/select stop tick) 1))
            (unless (= :dead (fiber/status timer)) (ev/cancel timer "finished"))
            (break)))))
    ([err] nil))

  (ev/give finished true))

(defn finish [s row value failure]
  (def view (json/decode (row "scope") true true))
  (def text (if failure failure
              (if (string? value) value (string (json/encode value)))))

  (transact s
    (assert (first (query s
                          `SELECT l.task FROM leases l JOIN tasks t ON t.id=l.task
       WHERE l.task=? AND l.owner=? AND l.generation=? AND t.attempt=l.generation
         AND t.state IN ('running','waiting','uncertain','cancelled')`
                          [(row "id") (row "owner") (row "attempt")]))
            "job completion fenced")

    (def state (if (= "cancelled" ((task s (row "id")) "state")) "cancelled"
                 (if failure "failed" "done")))
    (def outcome {:ok (= state "done") :value value :error failure
                  :state state :attempt (row "attempt")})
    (def encoded (string (json/encode outcome)))
    (assert (<= (length encoded) ((s :config) :response-bytes)) "stored task outcome byte ceiling")
    (def event (append s view "task-outcome" text
                       outcome nil (row "id")))

    (query s "UPDATE tasks SET state=?,result=?,outcome=? WHERE id=?"
           [state encoded (event "id") (row "id")])
    (query s "DELETE FROM leases WHERE task=?" [(row "id")])

    (when (and (nil? (row "parent")) (not= "agent" (row "kind")))
      (append s view (if (= state "done") "completed" "error") text
              {:original {:event (event "id")} :state state} nil (row "id")))

    (def input (json/decode (row "input") true true))
    (when (and (= "code" (row "kind")) (input :tool-id))
      (append s view "tool-result" text
              {:ok (outcome :ok)
               :tool-id (input :tool-id)
               :original {:event (event "id")}
               :bytes (length encoded)}
              (input :response) (row "id")))

    outcome))

(defn recover [s]
  (transact s
    (each row (query s
                     `SELECT t.*,r.expires run_expires FROM tasks t JOIN runs r ON r.id=t.run LEFT JOIN leases l ON l.task=t.id
       WHERE t.source=? AND ((t.state IN ('queued','running','waiting') AND r.expires<=?)
         OR (t.state IN ('running','waiting') AND (l.task IS NULL OR l.expires<=?)))
       ORDER BY t.id`
                     [(s :source) (os/clock) (os/clock)])

      (def expired (<= (row "run_expires") (os/clock)))
      (def unstarted (and expired (= "queued" (row "state")) (= 0 (row "attempt"))))
      (def retry (and (not expired) (= (row "retry_policy") "retry")
                      (<= (row "attempt") (row "retries"))))
      (def state (cond unstarted "cancelled" retry "queued" "uncertain"))
      (def outcome {:ok false :state state :attempt (row "attempt")
                    :error (cond unstarted "Run deadline expired before execution."
                             expired "Run deadline expired; effects may have happened."
                             "Interrupted execution; effects may have happened.")})
      (def event (append s (json/decode (row "scope") true true) "interruption"
                         (outcome :error) outcome nil (row "id")))

      (query s "UPDATE tasks SET state=?,result=?,outcome=? WHERE id=?"
             [state (unless retry (string (json/encode outcome)))
              (unless retry (event "id")) (row "id")])
      (when (or retry unstarted) (query s "DELETE FROM leases WHERE task=?" [(row "id")]))

      (def input (json/decode (row "input") true true))
      (when (and (= "code" (row "kind")) (input :tool-id) (not retry))
        (append s (json/decode (row "scope") true true) "tool-ambiguity"
                (outcome :error)
                {:ok false :uncertain true :tool-id (input :tool-id)
                 :original {:event (event "id")}}
                (input :response) (row "id"))))))
