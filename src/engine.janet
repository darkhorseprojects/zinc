(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./world)
(import ./protocol)
(import ./io)

(def bindings
  {"self" {:doc "(self request {:operation key}) admits an independent child and returns its handle immediately. Supply :text or :code; :persist false creates a RAM session. Children inherit history bounds, deadline and grants. No implicit joining or state merging."}
   "task/checkpoint" {:doc "(task/checkpoint) reads this script's last committed checkpoint. Guard completed steps when entering or restarting a script."}
   "task/commit" {:doc "(task/commit {:checkpoint value :put values :remove keys :expect revision :text text}) atomically publishes this task's checkpoint and shared JSON state. Optional :expect rejects stale writes. Only explicit JSON data persists."}
   "task/status" {:doc "(task/status handle) reads a child's committed outcome, or reports pending. A recorded admission is not completion."}
   "task/wait" {:doc "(task/wait handle) waits explicitly for a child. If unfinished, commit a checkpoint first: this task releases capacity and re-enters from source when the condition becomes true."}
   "task/cancel" {:doc "(task/cancel handle) explicitly cancels that child and its descendants. Prior commits and external effects remain."}
   "world/get" {:doc "(world/get key) reads a shared committed JSON value. JSON null is :null; nil means absent."}
   "world/view" {:doc "(world/view &opt event) returns shared values and their revision at the selected committed point."}
   "world/commit" {:doc "(world/commit values &opt expected-revision) publishes shared JSON values with the existing task checkpoint. Use task/commit to advance both atomically."}
   "world/remove" {:doc "(world/remove key) deletes a shared JSON value while retaining the task checkpoint."}
   "world/fork" {:doc "(world/fork name) forks the committed shared values under a new name. self may select it with :world. There is no implicit merge."}
   "memory/expand" {:doc "(memory/expand id &opt byte-offset) reads a bounded original record within granted history, with :next and :total offsets."}
   "fs/list" {:resource :fs :permission :read :doc "(fs/list resource relative-path) lists names beneath a granted root. Use . for the root."}
   "fs/read" {:resource :fs :permission :read :doc "(fs/read resource relative-path) reads bounded UTF-8 text beneath a granted root."}
   "fs/write" {:resource :fs :permission :write :doc "(fs/write resource relative-path text {:operation key}) writes bounded UTF-8 text. Use a stable operation key."}
   "http/request" {:resource :http :doc "(http/request resource method segments body {:operation key}) requests a granted base without redirects. Use a stable operation key."}
   "process/run" {:resource :processes :doc "(process/run resource {:operation key}) executes fixed granted argv/env. Use a stable operation key."}})

(defn- ready? [s task sessions]
  (def checkpoint (store/checkpoint s (task :id)))
  (def wait (get-in checkpoint [:data :wait]))
  (def target (if (get wait :session) (sessions (wait :session)) s))
  (cond
    (nil? wait) true
    (wait :tasks) (or (nil? target) (every? (map |(store/result target $) (wait :tasks))))
    (wait :operations) (every? (map |(store/result s $) (wait :operations)))
    (wait :changes)
    (not (nil? (first (store/query s `WITH RECURSIVE members(id) AS (
      SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
    ) SELECT e.id FROM events e JOIN members m ON m.id=e.id WHERE e.id>?
      AND e.kind IN ('result','commit','artifact','diagnostic') AND e.parent<>?
      AND NOT EXISTS(SELECT 1 FROM events p WHERE p.id=e.parent AND p.kind IN ('model','operation') AND p.parent=?)
      AND (e.kind<>'commit' OR json_type(e.data,'$.wait') IS NULL) LIMIT 1`
      [(task :id) (get-in checkpoint [:data :after] 0) (task :id) (task :id)]))))
    (error "unsupported stored wait condition")))

(defn- infer [s task available]
  (def config (s :config))
  (def pending (first (store/query s `SELECT r.* FROM events m JOIN events r ON r.parent=m.id
    WHERE m.parent=? AND m.kind='model' AND r.kind='result' AND json_extract(m.data,'$.turn')=1
      AND NOT EXISTS(SELECT 1 FROM events a WHERE a.parent=r.id AND a.kind='turn') ORDER BY r.id LIMIT 1` [(task :id)])))
  (if pending
    (store/transact s
      (store/check s (task :id))
      (def response (pending :data))
      (when (response :error) (error (response :error)))
      (var admitted false)
      (each tool (get response :tools [])
        (def receipt (try
          (do
            (when (tool :error) (error (tool :error)))
            (def child (store/start s {:code (tool :code) :request (string "tool:" (pending :id) ":" (tool :id))}
              config (pending :id)))
            (set admitted true)
            {:task (child :id) :status "accepted"})
          ([err fiber] {:status "rejected" :error (protocol/diagnostic "AdmissionRejected" err fiber)})))
        (store/append s (pending :id) "receipt"
          {:tool (tool :id) :message {:role "tool" :tool_call_id (tool :id) :content (schema/encode receipt)}}
          (string "receipt:" (pending :id) ":" (tool :id))))
      (store/append s (pending :id) "turn" {} (string "turn:" (pending :id)))
      (if (index-of (response :status) ["complete" "refused" "blocked"])
        (store/finish s (task :id) "done" {:text (response :text) :status (response :status)})
        (when admitted
          (store/commit s {:wait {:changes true} :after (get-in (store/event s (pending :parent)) [:data :views :after] 0)}))))
    (do
      (when-let [unknown (first (store/query s `SELECT m.id FROM events m WHERE m.parent=? AND m.kind='model'
        AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=m.id AND r.kind='result') ORDER BY m.id LIMIT 1` [(task :id)]))]
        (error {:code "Blocked" :message "Inference outcome must be reconciled." :context {:operation (unknown :id)}}))
      (def rounds (((store/query s "SELECT count(*) n FROM events WHERE parent=? AND kind='model' AND json_extract(data,'$.turn')=1" [(task :id)]) 0) :n))
      (assert (< rounds (config :rounds)) "model round limit exhausted")
      (def selected (model/profile s (config :chat) :chat))
      (def tools (filter |(or (config :janet) (not= "function" ($ :type))) (selected :tools)))
      (def system {:role "system" :content (world/instructions config available)})
      (def budget @[(config :image-bytes)])
      (def inquiry {:role "user" :content (model/images (get-in task [:data :input])
        (string "Author: " (get-in task [:data :author]) " · Occurred: " (get-in task [:data :at]) "\n\n" (get-in task [:data :input :text])) budget)})
      (def state {:role "user" :content (string "## Committed shared state\n\n" (schema/encode ((store/view s (get-in task [:data :world])) :values)))})
      (def capacity (min (get config :context-quota math/inf) (selected :context)))
      (def room (- capacity (model/estimate [system inquiry state]) (store/estimate (schema/encode tools)) 512))
      (assert (> room 256) "instructions, inquiry and state exhaust context")
      (def context (memory/context s task room))
      (def messages @[system])
      (def views @{:through (context :through) :records (map |($ :id) (context :nodes))
        :retrieved (map |($ :id) (context :evidence)) :candidates (context :candidates) :cutoff (config :score)})
      (each [key title rows] [[:chronological "Chronological memory" (context :nodes)] [:semantic "Retrieved excerpts" (context :evidence)]]
        (when (> (length rows) 0)
          (put views key (length messages))
          (def images @[])
          (each row rows (array/concat images (get-in row [:data :input :images] [])))
          (array/push messages {:role "user" :content (model/images {:images images} (string "## " title "\n\n" (string/join (map memory/render rows))) budget)})))
      (put views :world (length messages)) (array/push messages state)
      (put views :inquiry (length messages)) (array/push messages inquiry)
      (def scope (store/tree s (task :id)))
      (put views :after (if (> (length scope) 0) ((last scope) :id) (task :id)))
      (each row scope
        (def data (row :data))
        (def own (= (task :id) (get (store/task s (row :id)) :id)))
        (cond
          (and own (= "result" (row :kind)) (= "model" (data :type)) (data :turn)) (array/push messages (data :message))
          (and own (= "receipt" (row :kind))) (array/push messages (data :message))
          (and (not own) (index-of (row :kind) ["result" "commit" "artifact" "diagnostic"])
            (not (data :wait)) (not= "summary" (get-in (store/task s (row :id)) [:data :type])))
          (array/push messages {:role "user" :content (string "Committed task progress:\n" (memory/render row)
            (when (= "commit" (row :kind)) (schema/encode (schema/project data [:put :remove]))))})))
      (assert (< (+ (model/estimate messages (selected :reference)) (store/estimate (schema/encode tools))) capacity) "inquiry exchanges exhaust context")
      (model/call s {:turn true :messages messages :tools tools :views views} (string "turn:" rounds) selected))))

(defn- code [s task available sessions]
  (world/run s task available (fn [name args]
    (store/check s (task :id))
    (def binding (available name))
    (assert (and binding (not (binding :local))) "binding is not granted")
    (def state (store/checkpoint s (task :id)))
    (def world-name (get-in task [:data :world]))
    (cond
      (= name "task/checkpoint") (do (assert (= 0 (length args)) "checkpoint takes no arguments") (get-in state [:data :checkpoint] {}))
      (= name "task/commit") (do (assert (= 1 (length args)) "commit requires options") (store/commit s (first args)))
      (= name "world/view") (store/view s world-name (first args))
      (= name "world/get") (do (assert (and (= 1 (length args)) (string? (first args))) "world/get requires a key") (get ((store/view s world-name) :values) (first args)))
      (= name "world/commit") (let [[values expected] args] (store/commit s (merge {:put values} (when expected {:expect expected}))))
      (= name "world/remove") (do (assert (and (= 1 (length args)) (string? (first args))) "world/remove requires a key") (store/commit s {:remove args}))
      (= name "world/fork")
      (let [[target] args]
        (assert (and (= 1 (length args)) (string? target) (> (length target) 0) (not= target "main")) "invalid fork name")
        (store/append s (task :id) "fork" {:world target :source world-name :put ((store/view s world-name) :values)} (string "fork:" target))
        target)
      (= name "memory/expand") (apply memory/expand s task args)
      (index-of name ["task/status" "task/wait" "task/cancel"])
      (do
        (assert (= 1 (length args)) "task operation requires a handle")
        (def handle (first args))
        (def local (if (and (dictionary? handle) (not= (handle :store) (s :identity)))
          (let [target (or (sessions (handle :store)) (error {:code "TemporarySessionLost" :message "Temporary session is no longer available."}))
                caller (target :caller)]
            (assert (and (target :temporary) caller (= (caller 0) (s :identity))
              (find |(= ($ :id) (caller 1)) (store/tree s (task :id)))) "session is outside this task's descendants")
            target) s))
        (def id (if (dictionary? handle) (handle :task) handle))
        (assert (and (int? id) (or (not= local s) (not= id (task :id)))
          (if (= local s) (find |(and (= id ($ :id)) (= "task" ($ :kind))) (store/tree s (task :id)))
            (and (> id (local :floor)) (= "task" ((store/event local id) :kind))))) "choose a descendant task")
        (case name
          "task/cancel" (with-dyns [:zinc/token (when (= local s) (dyn :zinc/token))]
            (store/abort local (get-in (store/event local id) [:data :request]) "cancelled by caller"))
          "task/status" (get (store/result local id) :data {:state "pending"})
          (or (get (store/result local id) :data)
            (do
              (store/commit s {:wait (merge {:tasks [id]} (when (not= local s) {:session (local :identity)}))})
              (error {:code "Yield" :message "Waiting for a child."})))))
      (index-of name ["fs/list" "fs/read"]) (io/invoke (s :config) name args)
      (do
        (def options (last args))
        (assert (and (dictionary? options) (= 1 (length options)) (has-key? options :operation)
                     (string? (options :operation)) (> (length (options :operation)) 0))
                "host effects require final {:operation stable-key}")
        (def args (slice args 0 -1))
        (def key (string "operation:" (task :id) ":" (options :operation)))
        (def [admission fresh] (store/transact s
          (def prior (first (store/query s "SELECT id FROM events WHERE key=?" [key])))
          [(store/append s (task :id) "operation" {:name name :arguments args} key) (nil? prior)]))
        (def previous (store/result s (admission :id)))
        (if previous
          (do (when (get-in previous [:data :error]) (error (get-in previous [:data :error]))) (get-in previous [:data :value]))
          (do
            (unless (or fresh (and (= name "self") (or (s :temporary) (get (first args) :persist true))))
              (error {:code "Blocked" :message "Admitted operation must be reconciled before repeating." :context {:operation (admission :id)}}))
            (def value (try
              (with-dyns [:zinc/operation (string ((store/root s (task :id)) :id) "/" (task :id) "/" (admission :id))]
                (cond
                  (= name "self")
                  (do
                    (assert (= 1 (length args)) "self requires a request")
                    (def input (merge (schema/request (first args) [:text :code :parent :memory_range :world :persist]) {:request key}))
                    (def config (if (input :text) (get (s :config) :agent (s :config)) (s :config)))
                    (def persistent (get input :persist (not (s :temporary))))
                    (assert (or (not persistent) (not (s :temporary))) "temporary tasks cannot create durable descendants")
                    (def target (if (or persistent (s :temporary)) s
                      (let [local (store/temporary config)]
                        (put local :caller [(s :identity) (task :id)])
                        (put sessions (local :identity) local) local)))
                    (when-let [deadline (get-in (store/root s (task :id)) [:data :expires])] (put input :deadline deadline))
                    (def child (with-dyns [:zinc/token (when (= target s) (dyn :zinc/token))]
                      (store/start target input config (when (= target s) (task :id)))))
                    {:task (child :id) :store (target :identity) :request key :persist (not (target :temporary))})
                  (index-of name ["fs/write" "http/request" "process/run"]) (io/invoke (s :config) name args)
                  (apply (binding :value) args)))
              ([err fiber]
                (if (index-of (get err :code) ["Yield" "Blocked"]) (error err)
                  (error {:code "Blocked" :message "Operation was admitted; reconcile its outcome before repeating."
                    :context {:operation (admission :id) :cause (protocol/diagnostic "OperationFailed" err fiber)}})))))
            (store/append s (admission :id) "result" {:state "done" :value value :text (if (string? value) value "")} (string "result:" (admission :id)))
            value)))))))

(defn run [config root-id &opt file floor]
  (def s (store/open config nil file))
  (put s :floor (or floor 0))
  (def sessions @{(s :identity) s})
  (def active @{})
  (def finished (ev/chan 1))
  (defer (do
    (each [_ local] (pairs sessions) (store/close local))
    (ev/chan-close finished))
    (while true
      (def now (os/clock))
      (each [[identity id] running] (pairs active)
        (def local (sessions identity))
        (unless (first (store/query local "UPDATE claims SET expires=? WHERE task=? AND token=? AND expires>? RETURNING task"
          [(+ now (config :lease-seconds)) id (running :token) now]))
          (when (fiber/can-resume? (running :fiber)) (ev/cancel (running :fiber) :ownership-lost))))
      (var pending 0)
      (each [identity local] (pairs (merge sessions))
        (def tasks (store/query local (if (= identity (s :identity))
          `WITH RECURSIVE members(id) AS (SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id)
            SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.kind='task' AND e.id>?
            AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') ORDER BY e.id`
          `SELECT e.* FROM events e WHERE e.kind='task' AND e.id>?
            AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') ORDER BY e.id`)
          (if (= identity (s :identity)) [root-id (local :floor)] [(local :floor)])))
        (when-let [[source parent] (local :caller)]
          (when (= "cancelled" (get-in (store/result (sessions source) parent) [:data :state]))
            (each task tasks (store/abort local (get-in task [:data :request]) "caller cancelled"))))
        (+= pending (length tasks))
        (each task tasks
          (def coordinate [identity (task :id)])
          (when-let [deadline (get-in task [:data :expires])]
            (when (<= deadline now)
              (store/transact local
                (unless (store/result local (task :id))
                  (store/query local "DELETE FROM claims WHERE task=?" [(task :id)])
                  (store/finish local (task :id) "failed" nil {:code "DeadlineExceeded" :message "Task deadline expired."})))))
          (when (and (< (length active) (config :parallel)) (not (active coordinate)) (not (store/result local (task :id))) (ready? local task sessions))
            (when-let [claim (store/claim local (task :id))]
              (def worker (ev/go (fn [[coordinate task claim file]]
                (def saved (get-in task [:data :config]))
                (def current (if (and (saved :inference) (not (config :inference)) (config :agent)) (config :agent) config))
                (def own (store/open current nil file))
                (defer (store/close own)
                  (with-dyns [:zinc/task task :zinc/token (claim :token)
                              :zinc/call {:database file :id (task :id) :owner (claim :token) :scope {:expires (get-in task [:data :expires])}}]
                    (try
                      (do
                        (store/check own (task :id))
                        (put own :config (schema/authorize current saved))
                        (def available (world/definitions (own :config) bindings))
                        (case (get-in task [:data :type])
                          "inquiry" (infer own task available)
                          "summary" (store/finish own (task :id) "done" (memory/summarize own task))
                          "script" (store/finish own (task :id) "done" (code own task available sessions))))
                      ([err fiber]
                        (unless (or (store/result own (task :id)) (not (first (store/query own "SELECT task FROM claims WHERE task=? AND token=? AND expires>?" [(task :id) (claim :token) (os/clock)]))))
                          (case (get err :code)
                            "Yield" nil
                            "TaskClosed" nil
                            "TaskReplaced" nil
                            "DeadlineExceeded" nil
                            "Blocked" (store/transact own
                              (when-let [operation (get-in err [:context :operation])]
                                (store/commit own {:wait {:operations [operation]}}))
                              (unless (first (store/query own "SELECT id FROM events WHERE key=?" [(string "blocked:" (task :id) ":" (get-in err [:context :operation] 0))]))
                                (store/append own (task :id) "diagnostic" {:error (protocol/diagnostic "Blocked" err fiber) :text (err :message)}
                                  (string "blocked:" (task :id) ":" (get-in err [:context :operation] 0)))))
                            (store/finish own (task :id) "failed" nil (protocol/diagnostic "ExecutionFailed" err fiber))))))))
                coordinate) [coordinate task claim (local :file)] finished))
              (put active coordinate {:token (claim :token) :fiber worker})))))
      (when (and (= 0 pending) (= 0 (length active))) (break))
      (if (> (ev/count finished) 0)
        (let [[status fiber] (ev/take finished) coordinate (fiber/last-value fiber)]
          (assert (= :ok status) (protocol/diagnostic "ExecutorFailed" coordinate fiber))
          (store/query (sessions (coordinate 0)) "DELETE FROM claims WHERE task=? AND token=?" [(coordinate 1) ((active coordinate) :token)])
          (put active coordinate nil))
        (ev/sleep store/interval)))))

(defn presentation [s row]
  (def task (store/task s (row :id)))
  (when task
    (def root (store/root s (task :id)))
    (def data (row :data))
    (def body (cond
      (and (= "result" (row :kind)) (= "model" (data :type)) (or (data :turn) (not= "summary" (get-in task [:data :type])))) (model/render data)
      (and (= "task" (row :kind)) (= "script" (data :type))) (data :text)
      (and (= "result" (row :kind)) (not= "model" (data :type))) (data :text)
      (index-of (row :kind) ["commit" "artifact" "summary" "diagnostic"]) (data :text)))
    (when (and body (not= "summary" (get-in task [:data :type])))
      {:kind (if (= "model" (data :type)) "model" (row :kind)) :task (task :id) :root (root :id) :store (s :identity)
       :agent (get-in root [:data :config :identity]) :request (get-in root [:data :request])
       :parent (row :parent) :status (get data :status (get data :state "complete")) :world (get-in task [:data :world])
       :persist (not (s :temporary)) :sequence (row :id) :body body :diagnostic (data :error)})))

(defn observe [s task after emit &opt until-done]
  (var cursor after)
  (while true
    (def rows (store/query s `WITH RECURSIVE members(id) AS (
      SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
    ) SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.id>? ORDER BY e.id LIMIT 256` [(task :id) cursor]))
    (each row rows
      (when-let [frame (presentation s row)] (emit frame))
      (set cursor (row :id)))
    (def pending (first (store/query s `WITH RECURSIVE members(id) AS (
      SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
    ) SELECT e.id FROM events e JOIN members m ON m.id=e.id WHERE e.kind='task'
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') LIMIT 1` [(task :id)])))
    (when (and until-done (not pending) (< (length rows) 256)) (break))
    (unless (= 256 (length rows)) (ev/sleep store/interval)))
  (merge {:task (task :id) :store (s :identity)} ((store/result s (task :id)) :data)))

(defn describe [config]
  {:contract "inquiry-v1" :initialize "init" :profile {:field "agent" :inference "inference"}
   :parameters (catseq [[target declarations] :in [[:config schema/fields] [:input schema/inputs]]]
     (seq [[key field] :in (sorted (pairs declarations)) :when (field :option)]
       (merge (schema/project field [:description :minimum :choices :autocomplete])
         {:name (field :option) :path (string target "." key) :type (string (field :type))
          :default (get config key (get field :default "automatic"))}
         (if (and (= target :config) (= :integer (field :type)) (> (get config key 0) 0)) {:maximum (config key)} {}))))})
