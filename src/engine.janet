(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)
(import portable-agents/src/pa)
(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./repl)

(defn make [spec]
  (def scope store/view)

  (defn spawn-job [s id]
    (def lease (store/claim s id))
    (when lease
      (try
        (if (or (s :temporary) (and (= "summarize" (lease :kind)) (not (dyn :zinc/background))))
          (ev/go (fn [] ((dyn :zinc/execute) s lease)))
          (pa/spawn (merge (dyn :pa/program) {"entry" "task"})
                    (string (json/encode {:task id :owner (lease :owner)}))
                    (string (json/encode (dyn :zinc/config))) {:limits (dyn :pa/limits) :emit pa/emit}))
        ([err] (store/transact s
                 (store/append s (scope s (lease :branch))
                               "launch-uncertain" "Task acceptance could not be confirmed." {} nil id)))))
    id)

  (defn wait [s id]
    (def current (dyn :zinc/task))
    (def parked (and current (not (current :waiting))))
    (when parked (store/park s true) (put current :waiting true))
    (defer (when parked
             (when (= "waiting" ((store/task s (current :id)) :state)) (store/park s false))
             (put current :waiting nil))
      (label done (while true
        (store/recover s)
        (when current
          (def owner (store/task s (current :id)))
          (assert (and (= (current :owner) (owner :owner)) (index-of (owner :state) ["running" "waiting"])) "waiting execution fenced"))
        (def row (store/task s id))
        (case (row :state)
          "done" (return done ((json/decode (row :result) true true) :value))
          "failed" (error ((json/decode (row :result) true true) :error))
          "uncertain" (error (string "Job #" id ": uncertain effects; inspect receipts, do not replay."))
          "cancelled" (error "job cancelled")
          "queued" (spawn-job s id))
        (ev/sleep 0.1)))))

  (defn start-child [s granted value]
    (def view (merge granted (scope s (granted :branch))))
    (def value (schema/request
      (postwalk |(if (dictionary? $) (tabseq [[key item] :in (pairs $)] (keyword key) item) $) value)
      [:text :code :parent :memory_range :persist :revision]))
    (assert (not= (nil? (value :text)) (nil? (value :code))) "self requires text or code")
    (def current (s :config))
    (def config (if (value :text) (or (current :agent) current) current))
    (assert (if (value :text) (config :inference) (config :repl)) "child execution is not permitted")
    (def child (merge s {:config config :bindings (if (= config current) (s :bindings) (repl/definitions config (spec :capabilities)))}))
    (def parent (store/branch s (view :branch)))
    (put value :author (string "self:" (parent :request) "/" (parent :id)))
    (put value :at (((store/query s "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now') at") 0) :at))
    (put value :persist (get value :persist (= 0 (parent :temporary))))
    (when (= 1 (parent :temporary)) (assert (not (value :persist)) "temporary calls cannot create durable descendants"))
    (def origin (repl/source config
      (when (s :runtime) (merge (json/decode (parent :origin) true true) {:file ((s :runtime) :file)})) (value :revision)))
    (def selected (merge origin {:ref (string "refs/heads/self/" (string/join (map |(string/format "%02x" $) (os/cryptorand 12))))}))
    (if (value :persist)
      (do
        (when (selected :base)
          (repl/git (selected :root) ["update-ref" "--stdin"] (string "create " (selected :ref) " " (selected :base) "\n")))
        (def branch (store/start child value config (merge view {:event (dyn :zinc/effect) :agent (or (view :agent) (not= config current))}) selected))
        {:job (store/driver child branch) :branch (branch :id)})
      (do
        (def visible (scope s (view :branch)))
        (each key [:parent] (when (> (get value key 0) 0) (store/event s visible (value key))))
        (when (value :memory_range)
          (each bound [:start :end]
            (when (> (get-in value [:memory_range bound] 0) 0) (store/event s visible (get-in value [:memory_range bound])))))
        (def request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))
        (def depth (+ 1 (get-in (dyn :zinc/task) [:scope :depth] 0)))
        (assert (<= depth (config :task-depth)) "agent recursion ceiling exhausted")
        (def snapshot (merge (store/snapshot s visible) {:origin selected}))
        (def handle (pa/spawn (merge (dyn :pa/program) {"entry" "self"})
          (string (json/encode (merge value {:request request :parent (get value :parent (visible :last))
            :memory_range (get value :memory_range {:start (visible :first) :end (visible :last)})})))
          (string (json/encode (merge config {:snapshot snapshot}))) {:limits (dyn :pa/limits) :emit pa/emit}))
        (put ((dyn :zinc/task) :children) request handle)
        {:temporary request})))

  (defn message [s event]
    (when (and (event :branch) (index-of (event :kind) ["user" "response" "completed" "task-admission" "tool-result" "tool-ambiguity" "interruption" "model-outcome" "saved" "error"]))
      (def data (json/decode (event :data) true true))
      (def origin (data :world-source))
      (def assistant (when (event :public_message) (json/decode (event :public_message) true true)))
      (def base {:run (event :run) :branch (event :branch) :execution (string (event :request) "/" (event :branch))
        :persist (= 0 (event :branch_temporary)) :event (if (= 0 (event :branch_temporary)) (event :id) :null)
        :sequence (event :id) :author (event :author) :at (event :at)
        :world {:file (event :branch_file) :path (origin :path) :ref (or (data :ref) (origin :ref))
          :base (origin :base) :revision (or (data :after) (origin :base))}})
      (case (get {"response" "turn" "completed" "turn"} (event :kind) (event :kind))
        "user" (merge base {:type "start" :root (and (nil? (event :branch_parent)) (not (get-in (s :config) [:snapshot :child])))})
        "turn" (merge base {:type "turn" :text (event :text) :message assistant
          :status (get data :status "complete") :usage (data :usage) :final (= "completed" (event :kind))})
        "task-admission" (when (= "code" (data :kind)) (merge base {:type "tool" :call (event :id) :code (event :text)}))
        "tool-result" (merge base {:type "tool_result" :call (or (get-in data [:original :event]) (event :task)) :ok (data :ok) :text (event :text)})
        "tool-ambiguity" (merge base {:type "ambiguity" :call (event :task) :text (event :text)})
        "interruption" (when (= "uncertain" (data :state)) (merge base {:type "ambiguity" :call (event :task) :text (event :text)}))
        "model-outcome" (when (data :visible)
          (merge base {:type "model" :role (data :role) :text (or (data :text) (string (json/encode (data :results))))
            :status (data :status) :message assistant :results (data :results) :usage (data :usage)}))
        "saved" (merge base {:type "saved" :text (event :text) :ref (data :ref) :before (data :before) :after (data :after) :pushed (data :pushed)})
        "error" (merge base {:type "error" :text (event :text)}) nil)))

  (defn result [s id]
    (def branch (store/branch s id))
    (def final (first (store/query s "SELECT * FROM memory_records WHERE branch=? AND kind='completed'" [id])))
    (assert final "branch has no completion")
    (merge (message s final)
      {:start (if (= 0 (branch :temporary))
        ((first (store/query s "SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [id])) :id) :null)
       :parent (or (branch :entry) 0) :memory_range {:start (branch :first) :end (branch :last)}
       :tool_usage (store/tool-used s (branch :run)) :context_unit "token-estimate"
       :usage (first (store/query s
         "SELECT coalesce(sum(u.total),0) reported_total,count(*) FILTER(WHERE u.total IS NULL) unreported FROM events e LEFT JOIN usage u ON u.request=e.id WHERE e.source=? AND e.run=? AND e.kind='model-admission'"
         [(s :source) (branch :run)]))}))

  (defn run-code [s view code]
    (def config (s :config))
    (assert (and (config :repl) (s :runtime)) "Janet execution is not permitted")
    (assert (<= (length code) (config :source-bytes)) "tool source byte ceiling")
    (store/checkpoint s ((dyn :zinc/task) :checkpoint))
    (repl/execute (s :runtime) code
      (fn [name args]
        (def current (dyn :zinc/task))
        (store/checkpoint s (current :checkpoint))
        (if (= name "await")
          (let [handle (first args)]
            (assert (dictionary? handle) "await requires a self handle")
            (if (handle :temporary)
              (let [child ((current :children) (handle :temporary))]
                (assert child "temporary self is not owned by this call")
                (store/park s true)
                (defer (store/park s false) (json/decode (pa/await child) true true)))
              (do
                (assert (and (int? (handle :job)) (not= (current :id) (handle :job))
                             (first (store/query s `WITH RECURSIVE parents(id) AS (
                               SELECT id FROM tasks WHERE id=? AND source=? UNION ALL
                               SELECT t.parent FROM tasks t JOIN parents p ON t.id=p.id WHERE t.parent IS NOT NULL)
                               SELECT id FROM parents WHERE id=?` [(handle :job) (s :source) (current :id)]))) "await requires descendant work")
                (def value (wait s (handle :job)))
                (if (and (dictionary? value) (value :completion)) (result s ((store/task s (handle :job)) :branch)) value))))
          (do
            (def admission (store/transact s
              (store/charge s 1 0)
              (store/append s view "call-admission" name {:arguments args} nil (current :id))))
            (store/checkpoint s {:phase "operation" :event (admission :id)})
            (def value
              (if (= name "self")
                (let [handle (with-dyns [:zinc/effect (admission :id)] (start-child s view (first args)))]
                  (when (handle :job) (spawn-job s (handle :job))) handle)
                (do
                  (def binding ((s :bindings) name))
                  (assert binding "function revoked")
                  (with-dyns [:zinc/context [s view] :capability/config (binding :config)]
                    (apply (binding :value) args)))))
            (store/transact s
              (store/checkpoint s {:phase "code"})
              (store/append s view "operation-outcome" name {:value value} (admission :id) (current :id)))
            value)))
      (min (config :seconds) (max 0.001 (- (((store/query s "SELECT expires FROM main.run_controls WHERE id=?" [(view :run)]) 0) :expires) (os/clock))))))

  (defn infer [s task input]
    (assert ((s :config) :inference) "inference is not permitted in this view")
    (def branch (input :branch))
    (def config (s :config))
    (def granted (scope s branch))
    (def inherited (store/view s branch false))
    (def selected (model/profile s (input :model) :chat))
    (def evaluate (and (config :repl) (selected :tools)))
    (def system (repl/instructions config (merge granted {:tools evaluate}) (spec :document) (s :bindings)))
    (def user (first (store/query s "SELECT * FROM memory_records WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [branch])))
    (def inquiry {:role "user" :content (model/images s (user :id) (memory/render user))})
    (def tool-size (if evaluate (store/estimate (json/encode [model/tool])) 0))
    (def capacity (min (config :context-quota) (- (selected :context) 256)))
    (def space (- capacity (model/estimate [{:role "system" :content system} inquiry]) tool-size 256))
    (assert (> space 256) "question and instructions exhaust context")
    (def pool (or (get-in (dyn :zinc/task) [:checkpoint :semantic])
      (let [boundary ((dyn :zinc/task) :checkpoint)]
        (store/checkpoint s {:phase "semantic" :request (when (= "semantic" (boundary :phase)) (boundary :request))})
        (def rows (memory/semantic-window s inherited (user :text) (get-in (dyn :zinc/task) [:checkpoint :request])))
        (store/checkpoint s {:phase "semantic" :semantic rows}) rows)))
    (var context (memory/context s inherited space pool))
    (while (not (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [branch])))
      (def responses (store/query s "SELECT e.id,e.data FROM memory_records e WHERE e.branch=? AND e.kind='response' ORDER BY e.id" [branch]))
      (each tool (store/query s "SELECT * FROM unresolved_tools WHERE branch=?" [branch])
        (store/append s (scope s branch) "tool-ambiguity" "Interrupted evaluation; effects may have happened. Inspect before repeating."
          {:tool-id (tool :tool_id) :response (tool :response) :ok false :uncertain true} (tool :response) (task :id)))
      (assert (< (length responses) (config :rounds)) "model round limit exhausted")
      (def view (scope s branch))
      (def final-round (= (+ 1 (length responses)) (config :rounds)))
      (def messages @[])
      (while true
        (array/clear messages) (array/push messages {:role "system" :content system})
        (each [title text] [["History" (string/join (map |($ :rendered) (context :nodes)))] ["Retrieved text" (string/join (context :evidence))]]
          (when (> (length text) 0) (array/push messages {:role "user" :content (string "## " title "\n\n" text)})))
        (array/push messages inquiry)
        (each record (store/query s "SELECT conversation_message FROM conversation_records WHERE branch=? AND id>? ORDER BY id" [branch (context :through)])
          (array/push messages (json/decode (record :conversation_message) true true)))
        (when final-round (array/push messages {:role "system" :content "Tool calls are unavailable in this inference round."}))
        (when (<= (+ (model/estimate messages) (if final-round 0 tool-size)) capacity) (break))
        (assert (< (context :through) (view :last)) "context metadata cannot fit")
        (set context (memory/context s (merge view {:exclude [(user :id)]}) space pool)))
      (def boundary ((dyn :zinc/task) :checkpoint))
      (store/checkpoint s {:phase "model" :round (length responses)})
      (def response (with-dyns [:zinc/round true]
        (model/call s {:model (input :model) :messages messages :tools (when (and evaluate (not final-round)) [model/tool])}
          (when (and (= "model" (boundary :phase)) (= (length responses) (boundary :round))) (boundary :request)) selected)))
      (def turn (store/transact s
        (store/checkpoint s {:phase "commit"})
        (def event (store/append s view (if (index-of (response :status) ["complete" "refused" "blocked"]) "completed" "response") "" {}
                                 (response :request) ((dyn :zinc/task) :id)))
        (when (> (length (response :tools)) 0)
          (store/checkpoint s {:phase "tools"}))
        event))
      (assert (not (index-of (response :status) ["invalid" "truncated"])) (string "Model response " (response :status) ": " (response :error)))
      (each tool (response :tools)
        (def admission (store/transact s
          (store/checkpoint s {:phase "code" :tool (tool :id)})
          (store/charge s 1 (store/estimate (tool :code)))
          (store/append s view "task-admission" (tool :code) {:kind "code" :tool-id (tool :id) :response (turn :id)} nil (task :id))))
        (def outcome (try {:ok true :text (run-code s view (tool :code))}
                         ([err] (when (or (= err "deadline expired") (string/has-prefix? "World evaluator stopped:" (string err))) (error err)) {:ok false :text (string err)})))
        (store/charge s 0 (store/estimate (json/encode outcome)))
        (store/transact s
          (store/checkpoint s {:phase "tools"})
          (store/append s view "tool-result" (outcome :text) {:ok (outcome :ok) :tool-id (tool :id) :response (turn :id) :original {:event (admission :id)}}
                        (admission :id) (task :id)))))
    (unless (s :temporary)
      (try (with-dyns [:zinc/background true] (memory/context s (scope s branch) space pool true))
        ([err] (store/append s (scope s branch) "launch-uncertain" "Background compaction preparation failed." {:error (string err)}))))
    {:completion ((first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [branch])) :id)})

  (defn execute-job [store row]
    (def s (merge store {:runtime nil}))
    (def id (row :id))
    (do
      (def view (scope s (row :branch)))
      (when (and (view :agent) ((s :config) :agent))
        (put s :config ((s :config) :agent)) (put s :bindings nil))
      (def config (s :config))
      (unless (s :budget-root) (put s :budget-root (row :run)))
      (def input (json/decode (row :input) true true))
      (store/transact s
        (assert (first (store/query s "SELECT id FROM main.live_tasks WHERE id=? AND owner=? AND state='running'" [id (row :owner)])) "task execution fenced")
        (store/append s view "task-attempt" "execution entered" {:attempt (row :attempt)} nil id))
      (def stop (ev/thread-chan 1))
      (def finished (ev/thread-chan 1))
      (ev/thread store/heartbeat [config id (row :owner) stop] :n finished)
      (defer (do (ev/give stop true) (ev/take finished))
        (with-dyns [:zinc/task @{:id id :owner (row :owner) :scope view
                    :children @{} :checkpoint (json/decode (row :checkpoint) true true)}
                    :zinc/effect (row :admission)]
          (var value nil)
          (var failure nil)
          (try
            (do
              (store/checkpoint s ((dyn :zinc/task) :checkpoint))
              (def available (or (s :bindings) (repl/definitions config (spec :capabilities))))
              (put s :bindings available)
              (when (and (config :repl) (index-of (row :kind) ["agent" "code"]))
                (def branch (store/branch s (view :branch)))
                (os/cd (path/dirname (config :file)))
                (assert (<= (os/stat (branch :file) :size) (config :source-bytes)) "world source byte ceiling")
                (put s :runtime (repl/open (branch :file) (string (slurp (branch :file)))
                  (get-in (json/decode ((first (store/query s "SELECT data FROM events WHERE branch=? AND kind='user'" [(view :branch)])) :data) true true) [:input])
                  (repl/instructions config view (spec :document) available)
                  (seq [[name binding] :in (sorted (pairs available))] {:name name :doc (binding :doc)})
                  (config :forbid) (config :response-bytes))))
              (set value (case (row :kind)
                           "agent" (infer s row input)
                           "summarize" (memory/summarize s row input)
                           "code" (run-code s view ((first (store/query s "SELECT text FROM events WHERE id=?" [(row :admission)])) :text))
                           (error "unknown task kind"))))
            ([err fiber]
              (def trace @"")
              (with-dyns [:err (fn [bytes]
                                 (buffer/push-string trace (string/slice bytes 0 (min (length bytes) (- (config :response-bytes) (length trace))))))]
                (debug/stacktrace fiber))
              (set value nil)
              (set failure (string err))
              (var detail (string trace))
              (each provider (values (config :providers))
                (when (provider :token)
                  (set failure (string/replace-all (provider :token) "[redacted]" failure))
                  (set detail (string/replace-all (provider :token) "[redacted]" detail))))
              (store/append s view "traceback" detail {} nil id)))
          (when (s :runtime) (repl/close (s :runtime)) (put s :runtime nil))
          (unless (index-of ((store/task s id) :state) ["done" "failed"])
            (store/finish s row value failure))
          (each pending (store/query s "SELECT id FROM tasks WHERE source=? AND run=? AND state='queued' AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?) ORDER BY id LIMIT ?" [(s :source) (row :run) (os/clock) (config :parallel)])
            (spawn-job s (pending :id)))))))

  (defn drain [s run after]
    (var sequence after)
    (while true
      (def records (memory/events s run sequence))
      (each event records
        (def frame (message s event))
        (when frame (pa/emit (string (json/encode frame))))
        (set sequence (event :id)))
      (when (< (length records) 256) (break)))
    sequence)

  (defn run [s value operation]
    (def config (s :config))
    (def resume (= operation "resume"))
    (def task (= operation "task"))
    (unless (or resume task)
      (assert (and (value :author) (value :at)) "self requires authenticated author and occurrence time")
      (assert (not= (nil? (value :text)) (nil? (value :code))) "self requires text or code")
      (assert (if (value :text) (config :inference) (config :repl)) "execution is not permitted in this view"))
    (unless (or task resume (value :request))
      (put value :request (string/join (map |(string/format "%02x" $) (os/cryptorand 24)))))
    (do
      (def existing (cond task (first (store/query s "SELECT r.* FROM runs r JOIN tasks t ON t.run=r.id WHERE t.id=? AND t.source=?" [(value :task) (s :source)]))
                      (value :run) (first (store/query s "SELECT * FROM runs WHERE id=? AND source=?" [(value :run) (s :source)]))
                      (value :request) (first (store/query s "SELECT * FROM runs WHERE request=? AND source=?" [(value :request) (s :source)]))))
      (when (or task resume) (assert existing "task/run unavailable"))
      (when existing
        (assert (= 0 (existing :temporary)) "temporary execution cannot be reattached"))
      (when existing
        (assert (= (existing :world) (config :world)) "saved world differs")
        (assert (= 0 (existing :cancelled)) "run cancelled")
        (put s :config (schema/authorize (spec :schema) config (json/decode (existing :config) true true)))
        (store/query s "UPDATE main.run_controls SET expires=min(expires,(SELECT min(created) FROM events WHERE run=run_controls.id AND kind='user')+?) WHERE id=?" [((s :config) :run-seconds) (existing :id)]))
      (unless task (put s :bindings (repl/definitions (s :config) (spec :capabilities))))
      (with-dyns [:zinc/wait wait :zinc/spawn spawn-job :zinc/execute execute-job :zinc/config (s :config)]
        (store/recover s)
        (if task
          (let [row (store/task s (value :task))]
            (assert (= (value :owner) (row :owner)) "task ownership changed")
            (execute-job s row) {:task (value :task)})
          (do
            (def branch (if resume (store/branch s ((first (store/query s "SELECT id FROM branches WHERE run=? AND parent IS NULL" [(existing :id)])) :id)) (store/start s value (s :config) nil
              (or (get-in config [:snapshot :origin]) (repl/source (s :config) nil (value :revision))))))
            (when resume (assert (= 0 (branch :temporary)) "temporary conversation cannot be resumed"))
            (def id (branch :id))
            (def view (scope s id))
            (var sequence (drain s (view :run) (get value :after 0)))
            (if (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [id]))
              (result s id)
              (do
                (def driver (store/driver s branch resume))
                (def emitter (ev/go (fn [] (try (while true (set sequence (drain s (view :run) sequence)) (ev/sleep 0.1)) ([err] nil)))))
                (defer (ev/cancel emitter "observer detached")
                  (while (= "queued" ((store/task s driver) :state))
                    (when-let [lease (store/claim s driver)] (execute-job s lease))
                    (when (= "queued" ((store/task s driver) :state)) (ev/sleep 0.1)))
                  (wait s driver)
                  (drain s (view :run) sequence)
                  (result s id)))))))))

  (defn describe [config]
    (def parameters @[])
    (each [target fields] [[:config (spec :schema)] [:input (spec :input)]]
      (each [key field] (sorted (pairs fields))
        (when (field :option)
          (def parameter (merge field {:name (field :option) :path (string target "." key) :type (string (field :type))}))
          (when (and (= target :config) (= :integer (field :type)) (> (config key) 0)) (put parameter :maximum (config key)))
          (put parameter :default (get config key (get field :default "automatic")))
          (each key [:optional :option] (put parameter key nil))
          (array/push parameters parameter))))
    {:input "json" :output "json" :durable true :record true :contract "inquiry-v2"
     :profile {:field "agent" :inference "inference"} :parameters parameters})

  (tabseq [[operation fields] :in [["self" (keys (spec :input))] ["task" [:task :owner]] ["resume" [:run :request :after]]
    ["describe" []] ["document" []] ["models" [:role]] ["events" [:run :after]] ["record" [:records]]
    ["pending" [:request]] ["abort" [:run :request :reason]] ["invalidate" [:event]]]]
    operation (fn [bytes opaque]
      (def config (schema/configuration (spec :schema) (json/decode opaque true true) (= operation "describe")))
      (assert (and (utf8/is-valid? bytes) (<= (length bytes) (config :request-bytes))) "request must be bounded UTF-8")
      (when (index-of operation ["describe" "document"]) (assert (= "" bytes) "operation takes empty input"))
      (def value (if (and (= "" bytes) (index-of operation ["describe" "document" "pending"])) {} (schema/request (json/decode bytes true true) fields)))
      (def s (unless (index-of operation ["describe" "document" "models"])
        (store/open config (and (= operation "self") (= false (get value :persist true))))))
      (defer (when s (store/close s))
        (with-dyns [:zinc/config config]
          (def output (case operation
            "describe" (describe config)
            "document" (let [available (repl/definitions config (spec :capabilities))]
              (repl/instructions config {} (spec :document) available))
            "models" (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get value :role "chat")))
            "record" {:events (store/record s (value :records))}
            "invalidate" {:event ((memory/invalidate s (value :event)) :id)}
            "events" (let [records (memory/events s (value :run) (get value :after 0))]
              {:events (filter identity (map |(message s $) records))
               :after (if (last records) ((last records) :id) (get value :after 0)) :more (= 256 (length records))})
            "pending" (do
              (store/recover s)
              (store/query s `SELECT r.id run,r.request,b.id branch,t.id job,t.state,t.kind,t.attempt,t.retry_policy,
                t.admission,t.outcome,r.expires run_expires,t.lease_expires,r.temporary FROM runs r JOIN tasks t ON t.run=r.id
                LEFT JOIN branches b ON b.id=t.branch WHERE t.parent IS NULL AND b.parent IS NULL AND r.source=? AND r.world=?
                AND (? IS NULL OR r.request=?) AND (? IS NOT NULL OR t.state IN ('queued','running','waiting','failed','uncertain','cancelled'))
                ORDER BY r.id,t.id` [(s :source) (config :world) (value :request) (value :request) (value :request)]))
            "abort" (store/transact s
              (assert (and (not= (nil? (value :run)) (nil? (value :request))) (string? (value :reason)) (<= (length (value :reason)) 2048)) "abort requires run or request and reason")
              (when (value :request)
                (store/query s "INSERT INTO main.run_controls(source,request,world,expires) VALUES(?,?,?,?) ON CONFLICT(source,request) DO NOTHING"
                  [(s :source) (value :request) (config :world) (os/clock)]))
              (def run (first (store/query s "SELECT * FROM runs WHERE source=? AND (id=? OR request=?)" [(s :source) (value :run) (value :request)])))
              (assert (and run (= (run :world) (config :world))) "run unavailable")
              (def completed (or (first (store/query s "SELECT e.id FROM events e JOIN branches b ON b.id=e.branch WHERE e.run=? AND e.kind='completed' AND b.parent IS NULL" [(run :id)]))
                (first (store/query s "SELECT id FROM tasks WHERE run=? AND parent IS NULL AND state='done' AND run IN (SELECT id FROM runs WHERE temporary=1)" [(run :id)]))))
              (unless completed
                (store/query s "UPDATE main.run_controls SET cancelled=1 WHERE id=?" [(run :id)])
                (def tasks (store/query s `UPDATE main.task_controls SET state='cancelled' WHERE source=? AND state IN ('queued','running','waiting','uncertain')
                  AND run IN (SELECT id FROM main.run_controls WHERE id=? OR temporary=1 AND coalesce(root,id)=?) RETURNING id,kind,attempt`
                  [(s :source) (run :id) (or (run :root) (run :id))]))
                (when (and (= 0 (run :temporary)) (run :input) (not (first (store/query s "SELECT id FROM events WHERE run=? AND kind='cancelled'" [(run :id)]))))
                  (store/append s {:run (run :id) :branch (get (first (store/query s "SELECT id FROM branches WHERE run=? AND parent IS NULL" [(run :id)])) :id)}
                    "cancelled" "Interrupted. Performed effects are not rolled back; running effects may still finish."
                    {:reason (when (= 0 (run :temporary)) (value :reason)) :tasks-at-request tasks})))
              {:run (run :id) :state (if completed "completed" "cancelled")})
            (run s value operation)))
          (if (= operation "document") output (string (json/encode output))))))))
