(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/path :as path)
(import jsec/crypto :as crypto)
(import ./schema)

(def interval 0.1)
(def- directory (path/dirname (dyn :source)))
(def- layout (string (slurp (path/join directory "store.sql"))))
(defn digest [bytes] (string/join (map |(string/format "%02x" $) (string/bytes (crypto/digest :sha256 bytes)))))
(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn uuid [] (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))

(defn uri [file]
  (def file (if (index-of (os/which) [:windows :mingw]) (string/replace-all "\\" "/" file) file))
  (string "file:" (string/replace-all "?" "%3F" (string/replace-all "#" "%23" (string/replace-all "%" "%25" file)))))

(defn query [s statement &opt parameters]
  (map (fn [row] (if (string? (row :data)) (merge row {:data (json/decode (row :data) true)}) row))
       (sql/eval (s :db) statement (or parameters []))))

(defmacro transact [s & body]
  ~(if (= (,s :db) (dyn :zinc/transaction)) (do ,;body)
     (do
       (,sql/eval (,s :db) "BEGIN IMMEDIATE")
       (try
         (let [result (with-dyns [:zinc/transaction (,s :db)] ,;body)]
           (,sql/eval (,s :db) "COMMIT") result)
         ([err] (,sql/eval (,s :db) "ROLLBACK") (error err))))))

(defn open [config &opt readonly file]
  (def file (or file (uri (config :store))))
  (def temporary (not (nil? (string/find "vfs=memdb" file))))
  (def s @{:db (sql/open (string file (when readonly (string (if (string/find "?" file) "&" "?") "mode=ro"))))
           :file file :temporary temporary :config config :profiles @{}})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY;")
      (if readonly (query s "PRAGMA query_only=ON")
        (do
          (unless temporary (query s "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
          (transact s
            (if (first (query s "SELECT name FROM sqlite_schema WHERE name='events'"))
              (assert (and (first (query s "SELECT name FROM pragma_table_info('events') WHERE name='image'"))
                           (first (query s "SELECT name FROM pragma_table_xinfo('events') WHERE name='text'"))
                           (not (first (query s "SELECT name FROM pragma_table_info('claims') WHERE name='image'")))
                           (not (first (query s "SELECT name FROM pragma_table_info('images') WHERE name='runtime'"))))
                      "incompatible Zinc store; initialize a fresh database")
              (do (query s layout) (query s "INSERT INTO events(key,kind,data) VALUES('store','store',?)" [(schema/encode {:id (uuid)})]))))))
      (put s :identity (get-in (first (query s "SELECT data FROM events WHERE key='store'")) [:data :id])) s)
    ([err] (sql/close (s :db)) (error err))))

(defn close [s] (sql/close (s :db)))

(defn temporary [config]
  (def s (open config nil (string "file:/zinc-" (uuid) "?vfs=memdb")))
  (try
    (do
      (query s (string "PRAGMA max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA page_size") 0) :page_size)))))
      (query s "ATTACH DATABASE ? AS archive" [(string (uri (config :store)) "?mode=ro")])
      (transact s
        (query s "INSERT INTO images SELECT * FROM archive.images WHERE hash IN (SELECT image FROM archive.events)")
        (query s "INSERT INTO events(id,parent,key,kind,data,image,created) SELECT id,parent,key,kind,data,image,created FROM archive.events WHERE key IS NOT 'store' ORDER BY id")
        (query s "INSERT INTO worlds SELECT * FROM archive.worlds"))
      (query s "DETACH DATABASE archive") s)
    ([err] (close s) (error err))))

(defn image [s value &opt encoded]
  (def bytes (if encoded value (schema/encode value)))
  (assert (<= (length bytes) ((s :config) :journal-bytes)) "stored value byte ceiling")
  (def hash (digest bytes))
  (query s "INSERT OR IGNORE INTO images(hash,bytes) VALUES(?,?)" [hash (buffer bytes)]) hash)

(defn restore [s hash]
  (def row (first (query s "SELECT * FROM images WHERE hash=?" [hash])))
  (assert row "stored value is unavailable")
  (json/decode (row :bytes) true))

(defn event [s id]
  (def row (first (query s "SELECT * FROM events WHERE id=?" [id])))
  (assert row "event unavailable") row)

(defn tree [s id &opt after]
  (query s `WITH RECURSIVE members(id) AS (
    SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
  ) SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.id>? ORDER BY e.id` [id (or after 0)]))

(defn task [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' ORDER BY id DESC LIMIT 1` [id])))

(defn root [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' ORDER BY id LIMIT 1` [id])))

(defn result [s id] (first (query s "SELECT * FROM events WHERE parent=? AND kind='result'" [id])))
(defn progress [s id] (first (query s "SELECT data FROM claims WHERE task=?" [id])))

(defn check [s id &opt token]
  (default token (dyn :zinc/token))
  (assert (not (result s id)) {:code "TaskClosed" :message "Task ended."})
  (assert (first (query s "SELECT task FROM claims WHERE task=? AND token=? AND expires>?" [id token (os/clock)]))
          {:code "TaskReplaced" :message "Execution ownership expired or changed."})
  (def current (event s id))
  (assert (= (get-in current [:data :epoch]) (get (first (query s "SELECT epoch FROM worlds WHERE name=?" [(get-in current [:data :world])])) :epoch))
          {:code "TaskReplaced" :message "World was rewound."})
  (def expires (get-in current [:data :expires]))
  (assert (or (nil? expires) (> expires (os/clock))) {:code "DeadlineExceeded" :message "Task deadline expired."}))

(defn append [s parent kind data &opt key image]
  (transact s
    (when (dyn :zinc/token) (check s ((dyn :zinc/task) :id)))
    (def previous (when key (first (query s "SELECT * FROM events WHERE key=?" [key]))))
    (if previous
      (do (assert (and (= parent (previous :parent)) (= kind (previous :kind)) (= image (previous :image))
                       (= (schema/encode data) (schema/encode (previous :data)))) "event key reused with different work") previous)
      (do
        (when (and (dyn :zinc/token) (index-of kind ["task" "model" "operation" "result"]))
          (def usage (first (query s `WITH RECURSIVE members(id) AS (
            SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
          ) SELECT count(CASE WHEN e.kind IN ('task','model','operation') THEN 1 END) work,
            coalesce(sum(CASE WHEN e.kind IN ('operation','result') AND json_extract(e.data,'$.type') IS NOT 'model'
              THEN (length(CAST(e.data AS BLOB))+3)/4 ELSE 0 END),0) tools
            FROM events e JOIN members m ON m.id=e.id` [((root s ((dyn :zinc/task) :id)) :id)])))
          (when (index-of kind ["task" "model" "operation"])
            (assert (< (usage :work) ((s :config) :task-quota)) "work quota exhausted"))
          (when (and (not (data :error)) (index-of kind ["operation" "result"]) (not= "model" (data :type)))
            (assert (<= (+ (estimate (schema/encode data)) (usage :tools)) ((s :config) :tool-quota)) "tool output quota exhausted")))
        (def bytes (schema/encode data))
        (assert (<= (length bytes) (+ ((s :config) :request-bytes) ((s :config) :response-bytes))) "event byte ceiling")
        (first (query s "INSERT INTO events(parent,key,kind,data,image) VALUES(?,?,?,?,?) RETURNING *" [parent key kind bytes image]))))))

(defn advance [s data]
  (transact s
    (def id ((dyn :zinc/task) :id))
    (check s id)
    (query s "UPDATE claims SET data=? WHERE task=?" [(schema/encode data) id])))

(defn finish [s id state value &opt failure]
  (transact s
    (def outcome (or (result s id) (append s id "result"
      (merge {:state state :value (if (nil? value) :null value) :text (cond failure (string (failure :code) ": " (failure :message)) (string? value) value (schema/encode value))}
        (if failure {:error failure} {})) (string "result:" id))))
    (query s "DELETE FROM claims WHERE task=?" [id]) outcome))

(defn settle [s admission outcome]
  (transact s
    (with-dyns [:zinc/token false]
      (or (result s (admission :id))
        (append s (admission :id) "result" (merge outcome (if (outcome :error) {} {:value (if (nil? (outcome :value)) :null (outcome :value))})) (string "result:" (admission :id)))))))

(defn resolve [s admission outcome]
  (assert (and (index-of (admission :kind) ["operation" "model"]) (not (result s (admission :id)))
    (first (query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(admission :id)]))) "choose a dispatched unresolved operation")
  (def evidence (get outcome :evidence))
  (assert (and (dictionary? outcome)
    (or (and (string? evidence) (> (length (string/trim evidence)) 0))
      (and (dictionary? evidence) (> (length evidence) 0)))) "outcome requires verification evidence")
  (when-let [failure (outcome :error)]
    (assert (and (dictionary? failure) (string? (failure :code)) (string? (failure :message))) "invalid outcome diagnostic"))
  (unless (outcome :error)
    (assert (if (= "operation" (admission :kind)) (has-key? outcome :value)
      (and (index-of (outcome :status) ["complete" "refused" "blocked" "tools"])
        (if (= "rerank" (get-in admission [:data :role])) (indexed? (outcome :results))
          (and (= "assistant" (get-in outcome [:message :role]))
            (or (not= "tools" (outcome :status)) (indexed? (outcome :tools))))))) "invalid normalized outcome"))
  (def data (merge outcome {:state (if (outcome :error) "failed" "done")}))
  (if (= "operation" (admission :kind)) (settle s admission data)
    (append s (admission :id) "result" (merge data {:type "model" :role (get-in admission [:data :role])
      :turn (get-in admission [:data :turn])}) (string "result:" (admission :id)))))

(defn point [s value &opt world]
  (def row (first (query s "SELECT * FROM events WHERE kind IN ('world','rewind') AND (CAST(id AS TEXT)=? OR image=?) AND (? IS NULL OR json_extract(data,'$.world')=?) ORDER BY id DESC LIMIT 1" [(string value) (string value) world world])))
  (assert row "choose a committed world publication ID or image hash") row)

(defn configure [s]
  (transact s
    (each profile (filter identity [(s :config) (get-in s [:config :agent])])
    (each [name spec] (pairs (profile :worlds))
      (unless (first (query s "SELECT name FROM worlds WHERE name=?" [(string name)]))
        (def source (when (spec :from) (point s (spec :from))))
        (def row (append s nil "world" {:world (string name) :from (get source :id)} nil
          (if source (source :image) (image s {}))))
        (query s "INSERT INTO worlds(name,head) VALUES(?,?)" [(string name) (row :id)]))))))

(defn world-values [s world &opt through]
  (def row (if through (point s through world)
    (event s ((first (query s "SELECT head FROM worlds WHERE name=?" [world])) :head))))
  (assert (= world (get-in row [:data :world])) "publication belongs to another world")
  (tabseq [[key value] :pairs (restore s (row :image))] (string key) value))

(defn view [s world &opt through]
  (def row (if through (point s through world) (event s ((first (query s "SELECT head FROM worlds WHERE name=?" [world])) :head))))
  (def state (world-values s world (row :id)))
  (def projected state)
  {:world world :revision (row :id) :hash (row :image) :values projected
   :summary (string "World " world " · #" (row :id) " · " (row :image)) :text (schema/encode projected)})

(defn publish [s changes &opt expected remove]
  (transact s
    (def current (dyn :zinc/task))
    (def world (get-in current [:data :world]))
    (def head ((first (query s "SELECT head FROM worlds WHERE name=?" [world])) :head))
    (when expected (assert (= expected head) "world revision changed"))
    (assert (dictionary? changes) "world publication requires values")
    (def state (merge (world-values s world)))
    (each [key value] (pairs changes) (assert (or (string? key) (keyword? key)) "world keys must be text") (put state (string key) value))
    (each key (or remove []) (assert (string? key) "world keys must be text") (put state key nil))
    (def bytes (schema/encode state))
    (assert (<= (length bytes) ((s :config) :world-bytes)) "world byte ceiling")
    (def row (append s (current :id) "world" {:world world :text ""} nil (image s bytes true)))
    (query s "UPDATE worlds SET head=? WHERE name=?" [(row :id) world])
    {:world world :revision (row :id) :hash (row :image)}))

(defn start [s input config &opt parent]
  (assert (or (not (config :ephemeral)) (s :temporary)) "ephemeral profiles require a RAM store")
  (assert (= 1 (length (filter |(not (nil? (input $))) [:text :code :stages :stage]))) "supply exactly one of text, code or stages")
  (assert (if (input :text) (config :inference) (config :janet)) "execution is not granted")
  (def input (if (input :stages)
    (do (assert (<= (length (input :stages)) (config :task-quota)) "stage quota exhausted")
      (merge input {:stages (schema/stages (input :stages))})) input))
  (assert (<= (if (input :stages)
    (sum (map |(+ (length (get $ :code "")) (length (get $ :arguments ""))) (input :stages)))
    (length (get input :code ""))) (config :source-bytes)) "source byte ceiling")
  (assert (<= (sum (map |(length (base64/decode ($ :data))) (get input :images []))) (config :image-bytes)) "input image byte ceiling")
  (def key (get input :request (uuid)))
  (transact s
    (if-let [previous (first (query s "SELECT * FROM events WHERE key=?" [(string "task:" key)]))]
      (do (assert (and (= (schema/encode input) (schema/encode (get-in previous [:data :input]))) (= parent (previous :parent))) "request key reused with different work") previous)
      (do
        (def caller (when parent (task s parent)))
        (def root (when caller (root s (caller :id))))
        (when caller
          (assert (< (((query s `WITH RECURSIVE ancestors AS (
            SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
          ) SELECT count(*) n FROM ancestors WHERE kind='task'` [parent]) 0) :n) (config :task-depth)) "task depth exhausted"))
        (def last (get input :parent (or parent (((query s "SELECT coalesce(max(id),0) id FROM events") 0) :id))))
        (def bounds (get input :memory_range {:start (if (= last 0) 0 (if caller (max 1 (get-in caller [:data :memory_range :start])) 1)) :end last}))
        (assert (and (int? (bounds :start)) (int? (bounds :end)) (<= 0 (bounds :start) (bounds :end))
          (= (= 0 (bounds :start)) (= 0 (bounds :end)))) "invalid memory range")
        (when (> (bounds :end) 0) (event s (bounds :end)))
        (when caller (assert (and (<= (bounds :end) parent)
          (or (= 0 (bounds :end)) (>= (bounds :start) (get-in caller [:data :memory_range :start])))) "child history exceeds caller view"))
        (def world (get input :world (if caller (get-in caller [:data :world]) (config :world))))
        (assert (has-key? (config :worlds) (keyword world)) "world is not granted")
        (def epoch ((first (query s "SELECT epoch FROM worlds WHERE name=?" [world])) :epoch))
        (assert epoch "configured world is unavailable")
        (def deadline (min (if (> (config :run-seconds) 0) (+ (os/clock) (config :run-seconds)) math/inf)
          (or (get-in root [:data :expires]) math/inf) (or (input :deadline) math/inf)))
        (def admitted (append s parent "task" {:type (cond (input :summary) "summary" (input :text) "inquiry" (input :stages) "workflow" (input :stage) "stage" "script") :request key :input input
          :world world :epoch epoch :memory_range bounds :author (get input :author "self") :at (get input :at (os/strftime "%Y-%m-%dT%H:%M:%SZ"))
          :expires (unless (= deadline math/inf) deadline)} (string "task:" key) (image s config)))
        (when (first (query s "SELECT id FROM events WHERE key=?" [(string "cancel:" key)])) (finish s (admitted :id) "cancelled" nil)) admitted))))

(defn claim [s id]
  (transact s
    (first (query s `INSERT INTO claims(task,token,expires)
      SELECT e.id,?,? FROM events e WHERE e.id=? AND e.kind='task'
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result')
      AND NOT EXISTS(SELECT 1 FROM claims c WHERE c.task=e.id AND c.expires>?)
      AND (SELECT count(*) FROM claims WHERE expires>?)<?
      ON CONFLICT(task) DO UPDATE SET token=excluded.token,expires=excluded.expires WHERE claims.expires<=? RETURNING *`
      [(uuid) (+ (os/clock) ((s :config) :lease-seconds)) id (os/clock) (os/clock) ((s :config) :parallel) (os/clock)]))))

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
    (map (fn [record]
      (assert (= (tuple/slice (sorted (keys record))) [:at :author :key :text]) "invalid context fields")
      (each value (values record) (assert (and (string? value) (> (length value) 0)) "invalid context value"))
      ((append s nil "context" record (string "context:" (record :key))) :id)) records)))

(defn abort [s request reason]
  (transact s
    (unless (first (query s "SELECT id FROM events WHERE key=?" [(string "cancel:" request)]))
      (append s nil "cancel" {:request request :reason reason} (string "cancel:" request)))
    (def task (first (query s "SELECT id FROM events WHERE key=?" [(string "task:" request)])))
    (when task
      (each child (filter |(= "task" ($ :kind)) (tree s (task :id)))
        (unless (result s (child :id))
          (finish s (child :id) "cancelled" nil))))
    {:task (get task :id) :state (if (= "done" (get-in (when task (result s (task :id))) [:data :state])) "completed" "cancelled")}))

(defn rewind [s world target]
  (transact s
    (def selected (point s target world))
    (assert (= world (get-in selected [:data :world])) "publication belongs to another world")
    (restore s (selected :image))
    (def previous (first (query s "SELECT * FROM worlds WHERE name=?" [world])))
    (each task (query s `SELECT e.* FROM events e WHERE kind='task' AND json_extract(data,'$.world')=?
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result')` [world])
      (finish s (task :id) "cancelled" nil {:code "WorldRewound" :message "World was rewound."}))
    (def row (append s nil "rewind" {:world world :previous (previous :head) :point (selected :id) :epoch (+ 1 (previous :epoch))} nil (selected :image)))
    (query s "UPDATE worlds SET head=?,epoch=epoch+1 WHERE name=?" [(row :id) world]) (view s world)))
