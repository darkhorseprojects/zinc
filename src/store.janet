(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/base64 :as base64)
(import spork/path :as path)
(import ./schema)

(def interval 0.1)
(def- layout (slurp (path/join (path/dirname (dyn :source)) "store.sql")))
(defn estimate [bytes] (math/ceil (/ (length bytes) 4)))
(defn uuid [] (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))

(defn uri [file]
  (def file (if (index-of (os/which) [:windows :mingw]) (string/replace-all "\\" "/" file) file))
  (string "file:" (string/replace-all "?" "%3F" (string/replace-all "#" "%23" (string/replace-all "%" "%25" file)))))

(defn query [s statement &opt parameters]
  (map (fn [row] (if (string? (row :data)) (merge row {:data (json/decode (row :data) true true)}) row))
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
           :file file :temporary temporary :config config :profiles @{} :floor 0})
  (try
    (do
      (query s "PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000; PRAGMA trusted_schema=OFF;")
      (if readonly (query s "PRAGMA query_only=ON")
        (do
          (unless temporary (query s "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;"))
          (transact s
            (if (first (query s "SELECT name FROM sqlite_schema WHERE name='events'"))
              (assert (and (first (query s "SELECT name FROM pragma_table_info('events') WHERE name='key'"))
                           (first (query s "SELECT name FROM sqlite_schema WHERE name='claims'")))
                      "incompatible Zinc store; initialize a fresh database")
              (do
                (query s layout)
                (query s "INSERT INTO events(key,kind,data) VALUES('store','store',?)" [(schema/encode {:id (uuid)})]))))))
      (put s :identity (get-in (first (query s "SELECT data FROM events WHERE key='store'")) [:data :id]))
      s)
    ([err] (sql/close (s :db)) (error err))))

(defn close [s] (sql/close (s :db)))

(defn temporary [config]
  (def s (open config nil (string "file:/zinc-" (uuid) "?vfs=memdb")))
  (try
    (do
      (query s (string "PRAGMA max_page_count=" (math/floor (/ (config :journal-bytes) (((query s "PRAGMA page_size") 0) :page_size)))))
      (query s "ATTACH DATABASE ? AS archive" [(string (uri (config :store)) "?mode=ro")])
      (transact s
        (query s "INSERT INTO events(id,parent,key,kind,data,created) SELECT id,parent,key,kind,data,created FROM archive.events WHERE key IS NOT 'store' ORDER BY id")
        (put s :floor (((query s "SELECT coalesce(max(id),0) id FROM events") 0) :id)))
      (query s "DETACH DATABASE archive")
      s)
    ([err] (close s) (error err))))

(defn event [s id]
  (def row (first (query s "SELECT * FROM events WHERE id=?" [id])))
  (assert row "event unavailable") row)

(defn tree [s id &opt after]
  (query s `WITH RECURSIVE members(id) AS (
    SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
  ) SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.id>? ORDER BY e.id`
    [id (or after 0)]))

(defn task [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' ORDER BY id DESC LIMIT 1` [id])))

(defn root [s id]
  (first (query s `WITH RECURSIVE ancestors AS (
    SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
  ) SELECT * FROM ancestors WHERE kind='task' ORDER BY id LIMIT 1` [id])))

(defn result [s id] (first (query s "SELECT * FROM events WHERE parent=? AND kind='result'" [id])))
(defn checkpoint [s id] (first (query s "SELECT * FROM events WHERE parent=? AND kind='commit' ORDER BY id DESC LIMIT 1" [id])))

(defn check [s id &opt token]
  (default token (dyn :zinc/token))
  (assert (not (result s id)) {:code "TaskClosed" :message "Task ended."})
  (assert (first (query s "SELECT task FROM claims WHERE task=? AND token=? AND expires>?" [id token (os/clock)]))
          {:code "TaskReplaced" :message "Execution ownership expired or changed."})
  (def expires (get-in (event s id) [:data :expires]))
  (assert (or (nil? expires) (> expires (os/clock))) {:code "DeadlineExceeded" :message "Task deadline expired."}))

(defn append [s parent kind data &opt key]
  (transact s
    (when (dyn :zinc/token) (check s ((dyn :zinc/task) :id)))
    (def previous (when key (first (query s "SELECT * FROM events WHERE key=?" [key]))))
    (if previous
      (do (assert (and (= parent (previous :parent)) (= kind (previous :kind))
                       (= (schema/encode data) (schema/encode (previous :data)))) "event key reused with different work") previous)
      (do
        (when (dyn :zinc/token)
          (def rows (tree s ((root s ((dyn :zinc/task) :id)) :id)))
          (when (index-of kind ["task" "model" "operation"])
            (assert (< (length (filter |(index-of ($ :kind) ["task" "model" "operation"]) rows)) ((s :config) :task-quota)) "work quota exhausted"))
          (when (and (not (data :error)) (or (and (= kind "task") (= (data :type) "script"))
            (= kind "operation") (and (= kind "result") (not= (data :type) "model")) (= kind "commit")))
            (def used (sum (seq [row :in rows :unless (= "model" (get-in row [:data :type]))]
              (cond
                (index-of (row :kind) ["operation" "result"]) (estimate (schema/encode (row :data)))
                (or (= "commit" (row :kind)) (and (= "task" (row :kind)) (= "script" (get-in row [:data :type]))))
                (estimate (get-in row [:data :text] ""))
                0))))
            (def cost (estimate (if (index-of kind ["operation" "result"]) (schema/encode data) (get data :text ""))))
            (assert (<= (+ used cost) ((s :config) :tool-quota)) "tool output quota exhausted")))
        (def bytes (schema/encode data))
        (assert (<= (length bytes) (+ ((s :config) :request-bytes) ((s :config) :response-bytes))) "event byte ceiling")
        (first (query s "INSERT INTO events(parent,key,kind,data) VALUES(?,?,?,?) RETURNING *" [parent key kind bytes]))))))

(defn finish [s id state value &opt failure]
  (transact s
    (or (result s id)
        (append s id "result" (merge {:state state :value value :text (cond failure (string (failure :code) ": " (failure :message)) (string? value) value "")}
                                     (when failure {:error failure})) (string "result:" id)))))

(defn start [s input config &opt parent]
  (assert (not= (nil? (input :text)) (nil? (input :code))) "supply exactly one of text or code")
  (assert (if (input :text) (config :inference) (config :janet)) "execution is not granted")
  (when (input :code) (assert (<= (length (input :code)) (config :source-bytes)) "source byte ceiling"))
  (assert (<= (sum (map |(length (base64/decode ($ :data))) (get input :images []))) (config :image-bytes)) "input image byte ceiling")
  (def key (get input :request (uuid)))
  (transact s
    (if-let [previous (first (query s "SELECT * FROM events WHERE key=?" [(string "task:" key)]))]
      (do (assert (and (= (schema/encode input) (schema/encode (get-in previous [:data :input]))) (= parent (previous :parent))) "request key reused with different work") previous)
      (do
        (def caller (when parent (task s parent)))
        (def root (when caller (root s (caller :id))))
        (when caller
          (assert (not= "cancelled" (get-in (result s (root :id)) [:data :state])) "inquiry cancelled")
          (assert (< (length (filter |(= "task" ($ :kind)) (tree s (root :id)))) (config :task-quota)) "task quota exhausted")
          (assert (< (((query s `WITH RECURSIVE ancestors AS (
            SELECT * FROM events WHERE id=? UNION ALL SELECT e.* FROM events e JOIN ancestors a ON e.id=a.parent
          ) SELECT count(*) n FROM ancestors WHERE kind='task'` [parent]) 0) :n) (config :task-depth)) "task depth exhausted"))
        (def last (get input :parent (or parent (((query s "SELECT coalesce(max(id),0) id FROM events") 0) :id))))
        (def bounds (get input :memory_range {:start (if (= last 0) 0 (if caller (max 1 (get-in caller [:data :memory_range :start])) 1)) :end last}))
        (assert (and (int? (bounds :start)) (int? (bounds :end)) (<= 0 (bounds :start) (bounds :end))
                     (= (= 0 (bounds :start)) (= 0 (bounds :end)))) "invalid memory range")
        (when (> (bounds :end) 0) (event s (bounds :end)))
        (when caller
          (assert (and (<= (bounds :end) parent)
                       (or (= 0 (bounds :end)) (>= (bounds :start) (get-in caller [:data :memory_range :start])))) "child history exceeds caller view"))
        (def world (get input :world (if caller (get-in caller [:data :world]) (config :world))))
        (assert (or (= world "main") (first (query s "SELECT id FROM events WHERE kind='fork' AND json_extract(data,'$.world')=?" [world]))) "fork the world before selecting it")
        (def own-deadline (when (> (config :run-seconds) 0) (+ (os/clock) (config :run-seconds))))
        (def deadline (min (or own-deadline math/inf) (or (get-in root [:data :expires]) math/inf) (or (input :deadline) math/inf)))
        (def admitted (append s parent "task" {:type (cond (input :summary) "summary" (input :text) "inquiry" "script") :request key :input input :config config
          :world world :memory_range bounds :author (get input :author "self") :at (get input :at (os/strftime "%Y-%m-%dT%H:%M:%SZ"))
          :text (get input :text (input :code)) :expires (unless (= deadline math/inf) deadline)} (string "task:" key)))
        (when (first (query s "SELECT id FROM events WHERE key=?" [(string "cancel:" key)])) (finish s (admitted :id) "cancelled" nil))
        admitted))))

(defn claim [s id]
  (transact s
    (first (query s `INSERT INTO claims(task,token,expires)
      SELECT e.id,?,? FROM events e WHERE e.id=? AND e.kind='task'
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result')
      AND NOT EXISTS(SELECT 1 FROM claims c WHERE c.task=e.id AND c.expires>?)
      AND (SELECT count(*) FROM claims WHERE expires>?)<?
      ON CONFLICT(task) DO UPDATE SET token=excluded.token,expires=excluded.expires WHERE claims.expires<=?
      RETURNING *`
      [(uuid) (+ (os/clock) ((s :config) :lease-seconds)) id (os/clock) (os/clock) ((s :config) :parallel) (os/clock)]))))

(defn view [s world &opt through]
  (def values @{}) (var revision 0)
  (each row (query s `SELECT id,kind,data serialized FROM events
    WHERE kind IN ('commit','fork') AND json_extract(data,'$.world')=? AND id<=? ORDER BY id`
    [world (or through 9007199254740991)])
    (def data (json/decode (row :serialized)))
    (when (= "fork" (row :kind)) (table/clear values))
    (merge-into values (get data "put" {}))
    (each key (get data "remove" []) (put values key nil))
    (when (or (= "fork" (row :kind)) (> (length (get data "put" {})) 0) (> (length (get data "remove" [])) 0)) (set revision (row :id))))
  {:world world :revision revision :values values :summary (string "World " world " · #" revision) :text (schema/encode values)})

(defn commit [s options]
  (def current (dyn :zinc/task))
  (schema/request options [:checkpoint :put :remove :expect :text :wait :after])
  (def world (get-in current [:data :world]))
  (transact s
    (check s (current :id))
    (def previous (checkpoint s (current :id)))
    (def changes (get options :put {}))
    (def remove (get options :remove []))
    (assert (and (dictionary? changes) (indexed? remove) (every? (map string? remove))) "invalid state changes")
    (def snapshot (view s world))
    (when (has-key? options :expect) (assert (= (options :expect) (snapshot :revision)) "world revision changed"))
    (def values (merge (snapshot :values)))
    (each [key value] (pairs changes) (assert (or (string? key) (keyword? key)) "world keys must be text") (put values (string key) (if (nil? value) :null value)))
    (each key remove (put values key nil))
    (assert (<= (length (schema/encode values)) ((s :config) :world-bytes)) "world byte ceiling")
    (append s (current :id) "commit" (merge {:world world :checkpoint (get options :checkpoint (get-in previous [:data :checkpoint] {}))
                                             :put changes :remove remove :text (get options :text "")}
                                            (schema/project options [:wait :after])))))

(defn record [s records]
  (assert (and (indexed? records) (<= (length records) ((s :config) :history-records))) "invalid context batch")
  (transact s
    (map (fn [record]
      (assert (= (tuple/slice (sorted (keys record))) [:at :author :key :text]) "invalid context fields")
      (each value (values record) (assert (and (string? value) (> (length value) 0)) "invalid context value"))
      ((append s nil "context" record (string "context:" (record :key))) :id)) records)))

(defn abort [s request reason]
  (transact s
    (def previous (first (query s "SELECT id FROM events WHERE key=?" [(string "cancel:" request)])))
    (unless previous (append s nil "cancel" {:request request :reason reason} (string "cancel:" request)))
    (def task (first (query s "SELECT id FROM events WHERE key=?" [(string "task:" request)])))
    (when task
      (each child (filter |(= "task" ($ :kind)) (tree s (task :id)))
        (unless (result s (child :id))
          (query s "DELETE FROM claims WHERE task=?" [(child :id)])
          (finish s (child :id) "cancelled" nil))))
    {:task (get task :id) :state (if (= "done" (get-in (when task (result s (task :id))) [:data :state])) "completed" "cancelled")}))
