(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./runtime)
(import ./io)

(def bindings
  {"self" {:arity [1 1] :doc "(self request) starts independent :text, :code or :stages work and returns a handle. Descendants inherit persistence."}
   "task/status" {:arity [1 1] :doc "(task/status handle) reads an authorized task's outcome and uncertain operations."}
   "task/wait" {:arity [1 1] :doc "(task/wait handle) is a workflow call stage. It waits for a descendant or declared dependency and returns its outcome object; read :value for the result. Ordinary scripts cannot wait."}
   "task/cancel" {:arity [1 1] :doc "(task/cancel handle) cancels a descendant tree without undoing effects."}
   "task/resolve" {:arity [2 2] :doc "(task/resolve operation outcome) records an uncertain operation's verified :value or :error and :evidence."}
   "world/get" {:arity [1 1] :doc "(world/get key) reads a shared JSON value."}
   "world/view" {:arity [0 1] :doc "(world/view &opt point) reports a world publication."}
   "world/commit" {:arity [1 2] :doc "(world/commit values &opt expected-revision) publishes JSON values."}
   "world/remove" {:arity [1 1] :doc "(world/remove key) removes a shared value."}
   "memory/expand" {:arity [1 2] :doc "(memory/expand id &opt byte-offset) reads an original record within granted history."}
   "ev/sleep" {:arity [1 1] :doc "(ev/sleep seconds) suspends a workflow call stage until its recorded deadline."}
   "fs/list" {:arity [2 2] :resource :fs :permission :read :doc "(fs/list resource relative-path) lists a granted directory."}
   "fs/read" {:arity [2 2] :resource :fs :permission :read :doc "(fs/read resource relative-path) reads granted UTF-8 text."}
   "fs/write" {:arity [3 3] :resource :fs :permission :write :doc "(fs/write resource relative-path text) writes granted UTF-8 text."}
   "http/request" {:arity [4 4] :resource :http :doc "(http/request resource method segments body) requests a granted endpoint."}
   "process/run" {:arity [1 1] :resource :processes :doc "(process/run resource) executes granted argv/env."}})

(defn- ready? [s task]
  (def dependencies (get-in task [:data :input :dependencies] []))
  (def state (store/progress s (task :id)))
  (def wait (get-in state [:data :wait]))
  (and (every? (map |(store/result s $) dependencies))
    (cond
      (nil? wait) true
      (wait :until) (>= (os/clock) (wait :until))
      (wait :tasks) (every? (map |(store/result s $) (wait :tasks)))
      (wait :operations) (or (every? (map |(store/result s $) (wait :operations)))
        (and (wait :retry) (>= (os/clock) (wait :retry))))
      (wait :changes) (first (store/query s `WITH RECURSIVE members(id) AS (
        SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
      ) SELECT e.id FROM events e JOIN members m ON m.id=e.id WHERE e.id>?
        AND e.kind IN ('result','world','artifact','diagnostic') AND e.parent<>?
        AND NOT EXISTS(SELECT 1 FROM events p WHERE p.id=e.parent AND p.kind IN ('model','operation') AND p.parent=?) LIMIT 1`
        [(task :id) (get-in state [:data :after] 0) (task :id) (task :id)]))
      (error "unsupported stored wait condition"))))

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
            (def child (store/start s (merge (schema/project tool [:code :stages])
              {:request (string "tool:" (pending :id) ":" (tool :id))}) config (pending :id)))
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
      (def system {:role "system" :content (runtime/instructions config available)})
      (def budget @[(config :image-bytes)])
      (def inquiry {:role "user" :content (model/images (get-in task [:data :input])
        (string "Author: " (get-in task [:data :author]) " · Occurred: " (get-in task [:data :at]) "\n\n" (get-in task [:data :input :text])) budget)})
      (def state {:role "user" :content (string "## Shared state\n\n" (schema/encode ((store/view s (get-in task [:data :world])) :values)))})
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
        (def owner (store/task s (row :id)))
        (def own (= (task :id) (get owner :id)))
        (cond
          (and own (= "result" (row :kind)) (= "model" (data :type)) (data :turn)) (array/push messages (data :message))
          (and own (= "receipt" (row :kind))) (array/push messages (data :message))
          (and (not own) (index-of (row :kind) ["result" "world" "artifact" "diagnostic"])
            (not= "summary" (get-in owner [:data :type])))
          (array/push messages {:role "user" :content (string "Task progress:\n" (memory/render row)
            (when (= "world" (row :kind)) (schema/encode (store/view s (data :world) (row :id)))))})))
      (assert (< (+ (model/estimate messages (selected :reference)) (store/estimate (schema/encode tools))) capacity) "inquiry exchanges exhaust context")
      (model/call s {:turn true :messages messages :tools tools :views views} (string "turn:" rounds) selected)))))

(defn- invoke [s task available admission]
  (label handled
    (def name (get-in admission [:data :name]))
    (def args (get-in admission [:data :arguments]))
    (def binding (available name))
    (assert (and binding (not (binding :local))) "binding is not granted")
    (def local? (or (= name "self") (= name "ev/sleep")
      (string/has-prefix? "world/" name) (string/has-prefix? "task/" name) (= name "memory/expand")))
    (when-let [previous (store/result s (admission :id))]
      (when (get-in previous [:data :error]) (error (get-in previous [:data :error])))
      (return handled (get-in previous [:data :value])))
    (defn reconcile [failure]
      (def inspectable (and (= name "discord/create-message") (get-in (s :config) [:imports :connector/discord])))
      (def receipt (when inspectable
        (try (io/call (get-in (s :config) [:imports :connector/discord]) "receipt" []
          (string (s :identity) "/" (task :id) "/" (admission :id)) ((s :config) :response-bytes))
          ([err] (when (= "CapabilityOwnerLost" (get err :code)) (error err)) {:error err}))))
      (if (= "done" (get receipt :state))
        (do (store/settle s admission receipt) (receipt :value))
        (error (merge failure {:context (merge (get failure :context {})
          {:operation (admission :id) :outcome "unknown" :receipt-error (get receipt :error)
           :wait {:operations [(admission :id)] :retry (when inspectable (+ (os/clock) 1))}})}))))
    (when (and (not local?) (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(admission :id)])))
      (return handled (reconcile {:code "Blocked" :message "Reconcile the external operation before continuing."})))
    (defn execute []
      (store/check s (task :id))
      (when-let [[minimum maximum] (get binding :arity)]
        (assert (<= minimum (length args) maximum) (string name ": invalid argument count")))
      (def world-name (get-in task [:data :world]))
      (case name
        "world/view" (apply store/view s world-name args)
        "world/get" (get (store/world-values s world-name) (first args))
        "world/commit" (apply store/publish s args)
        "world/remove" (store/publish s {} nil args)
        "memory/expand" (apply memory/expand s task args)
        "ev/sleep" (do
          (assert (and (number? (first args)) (<= 0 (first args)) (< (first args) math/inf)) "sleep requires finite nonnegative seconds")
          (def until (+ (admission :created) (first args)))
          (unless (>= (os/clock) until)
            (error {:code "Yield" :message "Timer suspended." :context {:wait {:until until}}})))
        "task/resolve"
        (let [[id outcome] args target (store/event s id)]
          (assert (= ((store/root s id) :id) ((store/root s (task :id)) :id)) "operation is outside this inquiry")
          (store/resolve s target outcome) outcome)
        "self"
        (let [input (merge (schema/request (first args) [:text :code :stages :parent :memory_range :world]) {:request (admission :key)})
              config (if (input :text) (get (s :config) :agent (s :config)) (s :config))]
          (when-let [deadline (get-in (store/root s (task :id)) [:data :expires])] (put input :deadline deadline))
          (def child (store/start s input config (task :id)))
          {:task (child :id) :store (s :identity) :request (admission :key) :persist (not (s :temporary))})
        (if (index-of name ["task/status" "task/wait" "task/cancel"])
          (let [handle (first args) id (if (dictionary? handle) (handle :task) handle)]
            (when (= name "task/wait")
              (assert (= "stage" (get-in task [:data :type]))
                "task/wait requires a workflow call stage; ordinary scripts cannot resume after yielding"))
            (when (dictionary? handle) (assert (= (handle :store) (s :identity)) "task belongs to another store"))
            (assert (= "task" ((store/event s id) :kind)) "choose a task")
            (assert (= ((store/root s id) :id) ((store/root s (task :id)) :id)) "task is outside this inquiry")
            (when (not= name "task/status")
              (assert (some (fn [parent]
                (and (not= id (task :id)) (find |(= id ($ :id)) (store/tree s parent))))
                (array/concat @[(task :id)] (get-in task [:data :input :dependencies] [])))
                "choose a descendant of this task or a declared dependency"))
            (case name
              "task/cancel" (store/abort s (get-in (store/event s id) [:data :request]) "cancelled by caller")
              "task/status" (merge (get (store/result s id) :data {:state "pending"})
                {:task id :uncertain (map |(merge ($ :data) {:id ($ :id)}) (store/query s `WITH RECURSIVE members(id) AS (
                  SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
                ) SELECT o.id,o.data FROM events o JOIN members m ON m.id=o.id WHERE o.kind IN ('operation','model')
                  AND EXISTS(SELECT 1 FROM events d WHERE d.parent=o.id AND d.kind='dispatch')
                  AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=o.id AND r.kind='result')` [id]))})
              (or (get (store/result s id) :data)
                (error {:code "Yield" :message "Waiting for a descendant." :context {:wait {:tasks [id]}}}))))
          (with-dyns [:zinc/operation (string (s :identity) "/" (task :id) "/" (admission :id))]
            (when (function? (binding :value))
              (def signature (disasm (binding :value)))
              (assert (<= (signature :min-arity) (length args) (signature :max-arity)) "invalid argument count"))
            (store/append s (admission :id) "dispatch" {})
            (if (index-of name ["fs/list" "fs/read" "fs/write" "http/request" "process/run"])
              (io/invoke (s :config) name args) (apply (binding :value) args))))))
    (def outcome (try
      (if local? (store/transact s (store/settle s admission {:state "done" :value (execute)}))
        (store/settle s admission {:state "done" :value (execute)}))
      ([err fiber]
        (when (index-of (get err :code) ["Yield" "Blocked" "TaskClosed" "TaskReplaced" "CapabilityOwnerLost"]) (error err))
        (def failure (schema/diagnostic "OperationFailed" err fiber))
        (if (or local? (= "failed" (get-in failure [:context :outcome]))
          (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(admission :id)]))))
          (store/settle s admission {:state "failed" :error failure})
          (return handled (reconcile failure))))))
    (when (get-in outcome [:data :error]) (error (get-in outcome [:data :error])))
    (get-in outcome [:data :value])))

(defn- workflow [s task]
  (store/transact s
    (def children @{})
    (each stage (get-in task [:data :input :stages])
      (def child (store/start s {:stage (stage :id) :dependencies (map children (stage :after))
        :request (string "stage:" (task :id) ":" (stage :id))} (s :config) (task :id)))
      (put children (stage :id) (child :id)))
    (if (every? (map |(store/result s $) (values children)))
      (let [failed (find |(not= "done" (get-in (store/result s $) [:data :state])) (values children))]
        (if failed (store/finish s (task :id) "failed" nil
          {:code "StageFailed" :message "A workflow stage failed."
           :context {:task failed :cause (get-in (store/result s failed) [:data :error])}})
          (store/finish s (task :id) "done" (tabseq [[name id] :pairs children] name (get-in (store/result s id) [:data :value])))))
      (store/advance s {:wait {:tasks (values children)}}))))

(defn- stage [s task available]
  (def spec (find |(= ($ :id) (get-in task [:data :input :stage]))
    (get-in (store/event s (task :parent)) [:data :input :stages])))
  (def inputs (tabseq [id :in (get-in task [:data :input :dependencies])
    :let [result (store/result s id)]]
    (do (assert (= "done" (get-in result [:data :state])) "dependency did not succeed")
      (keyword (get-in (store/event s id) [:data :input :stage]))) (get-in result [:data :value])))
  (def value (if (spec :code) (runtime/run s task available nil (spec :code) inputs true)
    (let [key (string "stage-call:" (task :id))
          previous (first (store/query s "SELECT * FROM events WHERE key=?" [key]))
          admission (or previous
            (let [args (runtime/run s task available nil (spec :arguments) inputs true)]
              (assert (indexed? args)
                {:code "InvalidStageArguments"
                 :message (string "Stage " (spec :id) " arguments must return an array or tuple, got " (type args) ". Use [value] for one argument.")
                 :context {:stage (spec :id) :call (spec :call)}})
              (store/append s (task :id) "operation" {:name (spec :call) :arguments args} key)))]
      (invoke s task available admission))))
  (store/finish s (task :id) "done" value))

(defn run [config root-id &opt file]
  (def s (store/open config nil file))
  (def active @{}) (def finished (ev/chan 1))
  (defer (do
    (each [id running] (pairs active)
      (store/query s "UPDATE claims SET token=NULL,expires=0 WHERE task=? AND token=?" [id (running :token)])
      (when (fiber/can-resume? (running :fiber)) (ev/cancel (running :fiber) :ownership-lost)))
    (repeat (length active) (ev/take finished))
    (store/close s) (ev/chan-close finished))
    (while true
      (def now (os/clock))
      (each [id running] (pairs active)
        (if (store/result s id)
          (when (fiber/can-resume? (running :fiber)) (ev/cancel (running :fiber) :task-ended))
          (when (>= now (running :renew))
            (if (first (store/query s "UPDATE claims SET expires=? WHERE task=? AND token=? AND expires>? RETURNING task"
              [(+ now (config :lease-seconds)) id (running :token) now]))
              (put running :renew (+ now (/ (config :lease-seconds) 3)))
              (when (fiber/can-resume? (running :fiber)) (ev/cancel (running :fiber) :ownership-lost))))))
      (def tasks (store/query s `WITH RECURSIVE members(id) AS (
        SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
      ) SELECT e.* FROM events e JOIN members m ON m.id=e.id WHERE e.kind='task'
        AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') ORDER BY e.id` [root-id]))
      (each task tasks
        (def id (task :id))
        (when-let [deadline (get-in task [:data :expires])]
          (when (<= deadline now) (store/finish s id "failed" nil {:code "DeadlineExceeded" :message "Task deadline expired."})))
        (when (and (< (length active) (config :parallel)) (not (active id)) (not (store/result s id)) (ready? s task))
          (when-let [claim (store/claim s id)]
            (def worker (ev/go (fn [[task claim]]
              (def saved (store/restore s (task :image)))
              (def current (if (and (saved :inference) (not (config :inference)) (config :agent)) (config :agent) config))
              (def own (store/open current nil (s :file)))
              (put own :profiles (s :profiles))
              (defer (store/close own)
                (with-dyns [:zinc/task task :zinc/token (claim :token) :zinc/call own]
                  (try
                    (do
                      (store/check own (task :id))
                      (put own :config (schema/authorize current saved))
                      (def available (runtime/definitions (own :config) bindings))
                      (case (get-in task [:data :type])
                        "inquiry" (infer own task available)
                        "summary" (store/finish own (task :id) "done" (memory/summarize own task))
                        "workflow" (workflow own task)
                        "stage" (stage own task available)
                        "script" (do
                          (assert (not (get-in (store/progress own (task :id)) [:data :started]))
                            {:code "ScriptInterrupted" :message "Script execution was interrupted; use stages for restartable work."})
                          (store/advance own {:started true})
                          (store/finish own (task :id) "done" (runtime/run own task available (partial invoke own task available)
                            (get-in task [:data :input :code]) (get-in task [:data :input]) false)))))
                    ([err fiber]
                      (when (= "CapabilityOwnerLost" (get err :code)) (error err))
                      (when (and (not (store/result own (task :id)))
                        (first (store/query own "SELECT task FROM claims WHERE task=? AND token=? AND expires>?" [(task :id) (claim :token) (os/clock)])))
                        (if (and (not= "script" (get-in task [:data :type]))
                          (or (index-of (get err :code) ["Yield" "Blocked"]) (= "unknown" (get-in err [:context :outcome]))))
                          (do (store/advance own {:wait (get-in err [:context :wait] {:operations [(get-in err [:context :operation])]})})
                            (unless (= "Yield" (get err :code))
                              (def key (string "blocked:" (task :id) ":" (get-in err [:context :operation])))
                              (unless (first (store/query own "SELECT id FROM events WHERE key=?" [key]))
                                (store/append own (task :id) "diagnostic" {:error err :text (err :message)} key))))
                          (unless (index-of (get err :code) ["TaskClosed" "TaskReplaced" "DeadlineExceeded"])
                            (store/finish own (task :id) "failed" nil (schema/diagnostic "ExecutionFailed" err fiber)))))))))
              (task :id)) [task claim] finished))
            (put active id {:token (claim :token) :fiber worker :renew (+ now (/ (config :lease-seconds) 3))}))))
      (when (and (= 0 (length tasks)) (= 0 (length active))) (break))
      (if (> (ev/count finished) 0)
        (let [[status fiber] (ev/take finished)
              id (first (find |(= fiber (($ 1) :fiber)) (pairs active)))]
          (store/query s "UPDATE claims SET token=NULL,expires=0 WHERE task=? AND token=?" [id ((active id) :token)])
          (put active id nil)
          (assert (= :ok status) (schema/diagnostic "ExecutorFailed" (fiber/last-value fiber) fiber)))
        (ev/sleep store/interval)))))

(defn presentation [s row]
  (def task (store/task s (row :id)))
  (when task
    (def root (store/root s (task :id))) (def data (row :data))
    (def source (when (= "task" (row :kind))
      (case (data :type)
        "script" (get-in data [:input :code])
        "stage" (let [spec (find |(= ($ :id) (get-in data [:input :stage]))
          (get-in (store/event s (task :parent)) [:data :input :stages]))]
          (or (spec :code) (string "(apply " (spec :call) " (do\n" (spec :arguments) "\n))")))
        nil)))
    (def terminal (and (= "result" (row :kind)) (= (task :id) (row :parent))))
    (def body (cond
      (and (= "result" (row :kind)) (= "model" (data :type)) (not (data :error)) (or (data :turn) (not= "summary" (get-in task [:data :type])))) (model/render data)
      source source
      (and terminal (or (data :error) (not= "inquiry" (get-in task [:data :type])))) (data :text)
      (index-of (row :kind) ["world" "artifact" "summary" "diagnostic"]) (data :text)))
    (when (and body (not= "summary" (get-in task [:data :type])))
      {:kind (if (= "model" (data :type)) "model" (row :kind)) :task (task :id) :root (root :id) :store (s :identity)
       :agent (get-in s [:config :identity]) :request (get-in root [:data :request])
       :parent (or (row :parent) :null) :status (if source "accepted" (get data :status (get data :state "complete"))) :world (get-in task [:data :world])
       :language (cond source "clojure"
         (and terminal (not (data :error)) (not (string? (data :value)))) "json" :null)
       :persist (not (s :temporary)) :sequence (row :id) :body body :diagnostic (data :error)})))

(defn observe [s task after emit &opt until-done]
  (var cursor after)
  (while true
    (def pending (and until-done (first (store/query s `WITH RECURSIVE members(id) AS (
      SELECT ? UNION ALL SELECT e.id FROM events e JOIN members m ON e.parent=m.id
    ) SELECT e.id FROM events e JOIN members m ON m.id=e.id WHERE e.kind='task'
      AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=e.id AND r.kind='result') LIMIT 1` [(task :id)]))))
    (each row (store/tree s (task :id) cursor)
      (when-let [frame (presentation s row)] (emit frame))
      (set cursor (row :id)))
    (when (and until-done (not pending)) (break))
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
