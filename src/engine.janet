(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./world)
(import ./io)

(def bindings
  {"self" {:arity [1 1] :doc "(self request) admits independent work and returns its handle. Supply :text or :code; :persist false creates a RAM session."}
   "task/status" {:arity [1 1] :doc "(task/status handle) reads an authorized task's outcome and uncertain operations."}
   "task/wait" {:arity [1 1] :doc "(task/wait handle) suspends until a child's committed outcome is available."}
   "task/cancel" {:arity [1 1] :doc "(task/cancel handle) cancels a child and its descendants without undoing effects."}
   "task/resolve" {:arity [2 2] :doc "(task/resolve operation outcome) records a verified :value or :error and :evidence for an uncertain operation in this inquiry."}
   "world/get" {:arity [1 1] :doc "(world/get key) reads a shared value."}
   "world/view" {:arity [0 1] :doc "(world/view &opt point) reports a committed world publication."}
   "world/commit" {:arity [1 2] :doc "(world/commit values &opt expected-revision) publishes shared values. Task execution is saved automatically."}
   "world/remove" {:arity [1 1] :doc "(world/remove key) removes a shared value."}
   "memory/expand" {:arity [1 2] :doc "(memory/expand id &opt byte-offset) reads a bounded original record within granted history."}
   "fs/list" {:arity [2 2] :resource :fs :permission :read :doc "(fs/list resource relative-path) lists a granted directory."}
   "fs/read" {:arity [2 2] :resource :fs :permission :read :doc "(fs/read resource relative-path) reads granted UTF-8 text."}
   "fs/write" {:arity [3 3] :resource :fs :permission :write :doc "(fs/write resource relative-path text) writes granted UTF-8 text."}
   "http/request" {:arity [4 4] :resource :http :doc "(http/request resource method segments body) requests a granted endpoint."}
   "process/run" {:arity [1 1] :resource :processes :doc "(process/run resource) executes granted argv/env."}})

(defn- ready? [s task sessions]
  (def state (store/progress s (task :id)))
  (defn satisfied [wait]
    (def target (if (get wait :session) (sessions (wait :session)) s))
    (cond
      (nil? wait) true
      (wait :any) (some satisfied (wait :any))
      (wait :until) (>= (os/clock) (wait :until))
      (wait :tasks) (or (nil? target) (every? (map |(store/result target $) (wait :tasks))))
      (wait :operations) (every? (map |(store/result s $) (wait :operations)))
      (wait :changes) (first (store/query s `WITH RECURSIVE members(id) AS (
        SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
      ) SELECT e.id FROM events e JOIN members m ON m.id=e.id WHERE e.id>?
        AND e.kind IN ('result','world','artifact','diagnostic') AND e.parent<>?
        AND NOT EXISTS(SELECT 1 FROM events p WHERE p.id=e.parent AND p.kind IN ('model','operation') AND p.parent=?) LIMIT 1`
        [(task :id) (get-in state [:data :after] 0) (task :id) (task :id)]))
      (error "unsupported stored wait condition")))
  (satisfied (get-in state [:data :wait])))

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
      (var admitted false) (var rejected nil)
      (each tool (get response :tools [])
        (def receipt (try
          (do
            (when (tool :error) (error (tool :error)))
            (def child (store/start s {:code (tool :code) :request (string "tool:" (pending :id) ":" (tool :id))} config (pending :id)))
            (set admitted true) {:task (child :id) :status "accepted"})
          ([err fiber] {:status "rejected" :error (schema/diagnostic "AdmissionRejected" err fiber)})))
        (when (receipt :error) (set rejected (or rejected (receipt :error))))
        (store/append s (pending :id) "receipt"
          {:tool (tool :id) :message {:role "tool" :tool_call_id (tool :id) :content (schema/encode receipt)}}
          (string "receipt:" (pending :id) ":" (tool :id))))
      (store/append s (pending :id) "turn" {} (string "turn:" (pending :id)))
      (if (index-of (response :status) ["complete" "refused" "blocked"])
        (store/finish s (task :id) "done" {:text (response :text) :status (response :status)})
        (if admitted
          (store/advance s {:wait {:changes true} :after (get-in (store/event s (pending :parent)) [:data :views :after] 0)})
          (store/finish s (task :id) "failed" nil rejected))))
    (label turn (do
      (when-let [unknown (first (store/query s `SELECT m.* FROM events m WHERE m.parent=? AND m.kind='model'
        AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=m.id AND r.kind='result') ORDER BY m.id LIMIT 1` [(task :id)]))]
        (def saved (store/restore s (unknown :image)))
        (return turn (model/call s (saved :input) (saved :key) (saved :selected))))
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
          (def images @[]) (each row rows (array/concat images (get-in row [:data :input :images] [])))
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
          (and (not own) (index-of (row :kind) ["result" "world" "artifact" "diagnostic"])
            (not= "summary" (get-in (store/task s (row :id)) [:data :type])))
          (array/push messages {:role "user" :content (string "Committed task progress:\n" (memory/render row)
            (when (= "world" (row :kind)) (schema/encode (store/view s (data :world) (row :id)))))})))
      (assert (< (+ (model/estimate messages (selected :reference)) (store/estimate (schema/encode tools))) capacity) "inquiry exchanges exhaust context")
      (model/call s {:turn true :messages messages :tools tools :views views} (string "turn:" rounds) selected)))))

(defn- code [s task available sessions]
  (world/run s task available (fn [admission] (label handled
    (def name (get-in admission [:data :name]))
    (def args (store/restore s (admission :image)))
    (def binding (available name))
    (assert (or (= name "ev/sleep") (and binding (not (binding :local)))) "binding is not granted")
    (def local? (or (= name "self") (= name "ev/sleep")
      (string/has-prefix? "world/" name) (string/has-prefix? "task/" name) (= name "memory/expand")))
    (when-let [previous (store/result s (admission :id))]
      (def outcome (store/restore s (previous :image)))
      (when (outcome :error) (error (outcome :error))) (return handled (outcome :value)))
    (var created nil)
    (defer (when created (store/close created))
    (defn reconcile [failure]
      (def receipt (when (and (= name "discord/create-message") (get-in (s :config) [:imports :connector/discord]))
        (try (io/call (get-in (s :config) [:imports :connector/discord]) "receipt" []
          (string (s :identity) "/" (task :id) "/" (admission :id)) ((s :config) :response-bytes))
          ([err] (error {:code "Blocked" :message "Delivery receipt could not be checked." :context {:operation (admission :id) :cause err}})))))
      (if (= "done" (get receipt :state))
        (do (store/settle s admission receipt) (receipt :value))
        (error (merge failure {:context (merge (get failure :context {}) {:operation (admission :id) :outcome "unknown"})}))))
    (when (and (not local?) (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(admission :id)])))
      (return handled (reconcile {:code "Blocked" :message "Reconcile the external operation before continuing."})))
    (defn invoke []
      (store/check s (task :id))
      (when-let [[minimum maximum] (get binding :arity)]
        (assert (<= minimum (length args) maximum) (string name " expects " minimum (if (= minimum maximum) "" (string ".." maximum)) " arguments")))
      (def world-name (get-in task [:data :world]))
      (case name
        "world/view" (apply store/view s world-name args)
        "world/get" (get (store/world-values s world-name) (first args))
        "world/commit" (apply store/publish s args)
        "world/remove" (store/publish s {} nil args)
        "memory/expand" (apply memory/expand s task args)
        "ev/sleep" (if (>= (os/clock) (get-in admission [:data :until])) nil
          (error {:code "Yield" :message "Timer suspended." :context {:wait {:until (get-in admission [:data :until])}}}))
        "task/resolve"
        (let [[id outcome] args target (store/event s id)]
          (assert (= ((store/root s id) :id) ((store/root s (task :id)) :id)) "operation is outside this inquiry")
          (store/resolve s target outcome) (store/display outcome))
        "self"
        (let [input (merge (schema/request (first args) [:text :code :parent :memory_range :world :persist]) {:request (admission :key)})
              config (if (input :text) (get (s :config) :agent (s :config)) (s :config))
              persistent (get input :persist (not (s :temporary)))]
          (assert (or (not persistent) (not (s :temporary))) "temporary tasks cannot create durable descendants")
          (def target (or created s))
          (when-let [deadline (get-in (store/root s (task :id)) [:data :expires])] (put input :deadline deadline))
          (def child (with-dyns [:zinc/token (if (= target s) (dyn :zinc/token) false)]
            (store/start target input config (when (= target s) (task :id)))))
          (unless (target :root) (put target :root (child :id)))
          {:task (child :id) :store (target :identity) :request (admission :key) :persist (not (target :temporary))})
        (if (index-of name ["task/status" "task/wait" "task/cancel"])
          (let [handle (first args)
                local (if (and (dictionary? handle) (not= (handle :store) (s :identity)))
                  (or (sessions (handle :store)) (error {:code "TemporarySessionLost" :message "Temporary session was lost."})) s)
                id (if (dictionary? handle) (handle :task) handle)]
            (assert (if (= local s) (= ((store/root s id) :id) ((store/root s (task :id)) :id))
              (and (local :caller) (= ((local :caller) 0) (s :identity))
                (= ((store/root s ((local :caller) 1)) :id) ((store/root s (task :id)) :id)))) "task is outside this inquiry")
            (when (not= name "task/status")
              (assert (and (not= id (task :id)) (or (not= local s)
                (find |(= id ($ :id)) (store/tree s (task :id))))) "choose a descendant task"))
            (case name
              "task/cancel" (with-dyns [:zinc/token (if (= local s) (dyn :zinc/token) false)]
                (store/abort local (get-in (store/event local id) [:data :request]) "cancelled by caller"))
              "task/status" (merge (get (store/result local id) :data {:state "pending"})
                {:task id :uncertain (map |(merge ($ :data) {:id ($ :id)}) (store/query local `SELECT o.id,o.data FROM events o WHERE o.parent=? AND o.kind='operation'
                  AND EXISTS(SELECT 1 FROM events d WHERE d.parent=o.id AND d.kind='dispatch')
                  AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=o.id AND r.kind='result')` [id]))})
              (or (get (store/result local id) :data)
                (error {:code "Yield" :message "Waiting for a child." :context
                  {:wait (merge {:tasks [id]} (if (not= local s) {:session (local :identity)} {}))}}))))
          (with-dyns [:zinc/operation (string (s :identity) "/" (task :id) "/" (admission :id))]
            (when (function? (binding :value))
              (def signature (disasm (binding :value)))
              (assert (<= (signature :min-arity) (length args) (signature :max-arity)) (string name ": invalid argument count")))
            (store/append s (admission :id) "dispatch" {})
            (if (index-of name ["fs/list" "fs/read" "fs/write" "http/request" "process/run"])
              (io/invoke (s :config) name args) (apply (binding :value) args))))))
    (defn complete []
      (store/restore s ((store/settle s admission {:state "done" :value (invoke)}) :image)))
    (def outcome (try
      (do
        (when (and (= name "self") (= false (get (first args) :persist true)) (not (s :temporary)))
          (set created (store/temporary (if (get (first args) :text) (get (s :config) :agent (s :config)) (s :config))))
          (put created :caller [(s :identity) (task :id)]))
        (if local? (store/transact s (complete)) (complete)))
      ([err fiber]
        (when (index-of (get err :code) ["Yield" "Blocked" "TaskClosed" "TaskReplaced"]) (error err))
        (def failure (schema/diagnostic "OperationFailed" err fiber))
        (if (or local? (= "failed" (get-in failure [:context :outcome]))
          (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(admission :id)]))))
          (store/restore s ((store/settle s admission {:state "failed" :error failure}) :image))
          {:value (reconcile failure)}))))
    (when (outcome :error) (error (outcome :error)))
    (when created (put sessions (created :identity) created) (set created nil))
    (outcome :value))))))

(defn run [config root-id &opt file]
  (def s (store/open config nil file))
  (put s :root root-id)
  (def sessions @{(s :identity) s}) (def active @{}) (def visited @{}) (def finished (ev/chan 1))
  (defer (do (each [_ local] (pairs sessions) (store/close local)) (ev/chan-close finished))
    (while true
      (def now (os/clock))
      (each [[identity id] running] (pairs active)
        (unless (first (store/query (sessions identity) "UPDATE claims SET expires=? WHERE task=? AND token=? AND expires>? RETURNING task"
          [(+ now (config :lease-seconds)) id (running :token) now]))
          (when (fiber/can-resume? (running :fiber)) (ev/cancel (running :fiber) :ownership-lost))))
      (var pending 0)
      (each [identity local] (pairs (merge sessions))
        (def tasks (store/query local `WITH RECURSIVE members(id) AS (
          SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
        ) SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.kind='task'
          AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') ORDER BY e.id` [(local :root)]))
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
                  (store/query local "UPDATE claims SET token=NULL,expires=0 WHERE task=?" [(task :id)])
                  (store/finish local (task :id) "failed" nil {:code "DeadlineExceeded" :message "Task deadline expired."})))))
          (when (and (< (length active) (config :parallel)) (not (active coordinate)) (not (store/result local (task :id)))
            (or (and (not (visited coordinate)) (= "script" (get-in task [:data :type]))) (ready? local task sessions)))
            (when-let [claim (store/claim local (task :id))]
              (put visited coordinate true)
              (def worker (ev/go (fn [[coordinate task claim file]]
                (def saved (get-in task [:data :config]))
                (def current (if (and (saved :inference) (not (config :inference)) (config :agent)) (config :agent) config))
                (def own (store/open current nil file))
                (defer (store/close own)
                  (with-dyns [:zinc/task task :zinc/token (claim :token) :zinc/call own]
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
                          (case (if (= "unknown" (get-in err [:context :outcome])) "Blocked" (get err :code))
                            "Yield" nil "TaskClosed" nil "TaskReplaced" nil "DeadlineExceeded" nil
                            "Blocked" (do
                              (store/advance own {:wait {:operations [(get-in err [:context :operation])]}})
                              (store/append own (task :id) "diagnostic" {:error err :text (err :message)}))
                            (store/finish own (task :id) "failed" nil (schema/diagnostic "ExecutionFailed" err fiber))))))))
                coordinate) [coordinate task claim (local :file)] finished))
              (put active coordinate {:token (claim :token) :fiber worker})))))
      (when (and (= 0 pending) (= 0 (length active))) (break))
      (if (> (ev/count finished) 0)
        (let [[status fiber] (ev/take finished) coordinate (fiber/last-value fiber)]
          (assert (= :ok status) (schema/diagnostic "ExecutorFailed" coordinate fiber))
          (store/query (sessions (coordinate 0)) "UPDATE claims SET token=NULL,expires=0 WHERE task=? AND token=?" [(coordinate 1) ((active coordinate) :token)])
          (put active coordinate nil))
        (ev/sleep store/interval)))))

(defn presentation [s row]
  (def task (store/task s (row :id)))
  (when task
    (def root (store/root s (task :id))) (def data (row :data))
    (def body (cond
      (and (= "result" (row :kind)) (= "model" (data :type)) (not (data :error)) (or (data :turn) (not= "summary" (get-in task [:data :type])))) (model/render data)
      (and (= "task" (row :kind)) (= "script" (data :type))) (data :text)
      (and (= "result" (row :kind)) (not= "model" (data :type))) (data :text)
      (index-of (row :kind) ["world" "artifact" "summary" "diagnostic"]) (data :text)))
    (when (and body (not= "summary" (get-in task [:data :type])))
      {:kind (if (= "model" (data :type)) "model" (row :kind)) :task (task :id) :root (root :id) :store (s :identity)
       :agent (get-in root [:data :config :identity]) :request (get-in root [:data :request])
       :parent (row :parent) :status (get data :status (get data :state "complete")) :world (get-in task [:data :world])
       :persist (not (s :temporary)) :sequence (row :id) :body body :diagnostic (data :error)})))

(defn observe [s task after emit &opt until-done]
  (var cursor after)
  (while true
    (def scope (store/tree s (task :id) cursor))
    (each row scope
      (when-let [frame (presentation s row)] (emit frame))
      (set cursor (row :id)))
    (when (and until-done (not (first (store/query s `WITH RECURSIVE members(id) AS (
      SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
    ) SELECT e.id FROM events e JOIN members m ON m.id=e.id WHERE e.kind='task'
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') LIMIT 1` [(task :id)])))) (break))
    (ev/sleep store/interval))
  (merge {:task (task :id) :store (s :identity)} ((store/result s (task :id)) :data)))

(defn describe [config]
  {:contract "inquiry-v1" :initialize "init" :profile {:field "agent" :inference "inference"}
   :parameters (catseq [[target declarations] :in [[:config schema/fields] [:input schema/inputs]]]
     (seq [[key field] :in (sorted (pairs declarations)) :when (field :option)]
       (merge (schema/project field [:description :minimum :choices :autocomplete])
         {:name (field :option) :path (string target "." key) :type (string (field :type))
          :default (get config key (get field :default "automatic"))}
         (if (and (= target :config) (= :integer (field :type)) (> (get config key 0) 0)) {:maximum (config key)} {}))))})
