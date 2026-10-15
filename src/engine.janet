(import spork/json :as json)
(import spork/path :as path)
(import portable-agents/src/pa)
(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./repl)

(defn make [spec]
  (defn scope [s branch]
    (def view (store/view s branch))
    (def user (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [branch])))
    (merge view {:first (if (= 0 (view :first)) (user "id") (view :first))
                 :last (max (view :last) (((store/query s "SELECT coalesce(max(id),0) id FROM events WHERE run=?" [(view :run)]) 0) "id"))
                 :permissions (sorted (keys (repl/definitions (s :config)))) :agent ((s :config) :inference)}))

  (defn spawn-job [s id]
    (def lease (store/transact s (first (store/query s
                                                     `INSERT INTO leases(task,owner,generation,expires)
       SELECT id,'launch',-1,? FROM tasks WHERE id=? AND source=? AND state='queued'
         AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?)
         AND (SELECT count(*) FROM tasks WHERE source=? AND state='running')<?
       ON CONFLICT(task) DO UPDATE SET expires=excluded.expires
       WHERE leases.owner='launch' AND leases.expires<=? RETURNING task`
                                                     [(+ (os/clock) ((s :config) :lease-seconds)) id (s :source) (os/clock) (s :source) ((s :config) :parallel) (os/clock)]))))
    (when lease
      (try
        (pa/spawn (merge (dyn :pa/program) {"entry" "task"}) (string (json/encode {:task id}))
                  (string (json/encode (dyn :zinc/config))) {:limits (dyn :pa/limits)})
        ([err] (store/transact s
                 (store/append s (json/decode ((store/task s id) "scope") true true)
                               "launch-uncertain" "Task acceptance could not be confirmed." {} nil id)))))
    id)

  (defn wait [s id]
    (def current (dyn :zinc/task))
    (def parked (and current (not (current :waiting))))
    (var result nil)
    (when parked (store/park s true) (put current :waiting true))
    (defer (when parked
             (when (= "waiting" ((store/task s (current :id)) "state")) (store/park s false))
             (put current :waiting nil))
      (while true
        (store/recover s)
        (when current
          (def owner (store/task s (current :id)))
          (assert (and (= (current :generation) (owner "attempt")) (index-of (owner "state") ["running" "waiting"])) "waiting execution fenced"))
        (each job (dyn :zinc/dependencies []) (spawn-job s job))
        (def row (store/task s id))
        (case (row "state")
          "done" (do (set result ((json/decode (row "result") true true) :value)) (break))
          "failed" (error ((json/decode (row "result") true true) :error))
          "uncertain" (error (string "Job #" id ": uncertain effects; inspect receipts, do not replay."))
          "cancelled" (error "job cancelled")
          "queued" (spawn-job s id))
        (ev/sleep 0.1))
      result))

  (defn start-child [s view value]
    (def config (or ((s :config) :agent) (s :config)))
    (assert (config :inference) "agent inference is not permitted")
    (def child (merge s {:config config}))
    (def value (schema/request (json/encode value) [:text :code :parent :memory_range :persist]))
    (assert (not= (nil? (value :text)) (nil? (value :code))) "self requires text or code")
    (def parent (store/branch s (view :branch)))
    (def branch (store/start child (merge value {:persist (get value :persist (= 0 (parent "temporary")))})
                             config (merge view {:event (dyn :zinc/effect)})))
    (def id (store/submit child (scope child (branch "id")) (if (value :text) "agent" "code")
                          (if (value :text) {:branch (branch "id") :model (config :chat)} {:code (value :code)})
                          {:retry-policy (if (value :text) "retry" "manual") :key (string "child:" (branch "id"))}))
    {:job id :branch (branch "id")})

  (defn result [s id]
    (def branch (store/branch s id))
    (def saved (first (store/query s "SELECT result FROM tasks WHERE branch=? AND parent IS NULL AND kind='agent' AND state='done' ORDER BY id DESC LIMIT 1" [id])))
    (if saved ((json/decode (saved "result") true true) :value)
      (do
        (def final (first (store/query s "SELECT *,strftime('%Y-%m-%dT%H:%M:%fZ',created,'unixepoch') created_at FROM events WHERE branch=? AND kind='completed'" [id])))
        (assert final "branch has no completion")
        (def user (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [id])))
        (def usage (first (store/query s
                                       "SELECT coalesce(sum(u.total),0) reported_total,count(*) FILTER(WHERE u.total IS NULL) unreported FROM events e LEFT JOIN usage u ON u.request=e.id WHERE e.source=? AND e.run=? AND e.kind='model-admission'"
                                       [(s :source) (branch "run")])))
        {:text (final "text") :run (branch "run") :branch id :start (user "id") :event (final "id")
         :parent (or (branch "entry") 0) :memory_range {:start (branch "first") :end (branch "last")}
         :created_at (final "created_at") :tool_usage (store/tool-used s (branch "run"))
         :usage usage
         :context_unit "token-estimate"})))

  (defn infer [s task input]
    (assert ((s :config) :inference) "inference is not permitted in this view")
    (def branch (input :branch))
    (def config (s :config))
    (def granted (json/decode (task "scope") true true))
    (def inherited (store/view s branch))
    (def selected (model/profile config (input :model) :chat))
    (def evaluate (and (config :repl) (selected :tools)))
    (var system (repl/instructions config (merge granted {:tools evaluate}) (spec :document)))
    (def user (first (store/query s "SELECT * FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [branch])))
    (def space (- (min (config :context-quota) (- (selected :context) 256)) (store/estimate system) (store/estimate (user "text")) 256))
    (assert (> space 256) "question and instructions exhaust context")
    (def semantic (if (config :search) (math/floor (/ space 2)) 0))
    (def archive (merge s {:config (merge config {:context-quota (- space semantic)})}))
    (memory/compact archive inherited)
    (def chronological (memory/context archive inherited))
    (def evidence (if (= 0 semantic) [] (memory/semantic-window s (merge inherited {:covered (chronological :covered)}) (user "text") semantic)))
    (var context {:through (inherited :last) :chronological chronological :evidence (map memory/render evidence)})
    (while (not (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [branch])))
      (def responses (store/query s "SELECT e.id,coalesce(t.data,e.data) data FROM events e LEFT JOIN events t ON t.parent=e.id AND t.kind='tools' WHERE e.branch=? AND e.kind='response' ORDER BY e.id" [branch]))
      (when (last responses)
        (def ids ((json/decode ((last responses) "data") true true) :tasks))
        (with-dyns [:zinc/dependencies ids]
          (each id ids (try (wait s id) ([err] nil)))))
      (assert (< (length responses) (config :rounds)) "model round limit exhausted")
      (def view (merge (scope s branch) {:permissions (granted :permissions)}))
      (set system (repl/instructions config (merge view {:tools evaluate}) (spec :document)))
      (def messages @[{:role "system" :content system}])
      (each [title text] [["History" (string/join (map |($ :text) (get-in context [:chronological :nodes])))] ["Retrieved text" (string/join (context :evidence))]]
        (when (> (length text) 0) (array/push messages {:role "user" :content (string "## " title "\n\n" text)})))
      (array/push messages {:role "user" :content (model/images s (user "id") (user "text"))})
      (each record (store/query s "SELECT e.*,coalesce(t.data,e.data) tools FROM events e LEFT JOIN events t ON t.parent=e.id AND t.kind='tools' WHERE e.branch=? AND e.id>? AND e.kind IN ('response','tool-result','tool-ambiguity') AND (e.kind='response' OR NOT EXISTS(SELECT 1 FROM events newer WHERE newer.task=e.task AND newer.kind IN ('tool-result','tool-ambiguity') AND newer.id>e.id)) ORDER BY e.id" [branch (context :through)])
        (def data (json/decode (record "data") true true))
        (def tools (json/decode (record "tools") true true))
        (array/push messages (if (= "response" (record "kind"))
                               {:role "assistant" :content (record "text")
                                :reasoning_content (when (= "llama" (selected :provider)) (data :reasoning))
                                :reasoning (when (and (= "openrouter" (selected :provider)) (= 0 (length (data :reasoning-details)))) (data :reasoning))
                                :reasoning_details (when (= "openrouter" (selected :provider)) (data :reasoning-details))
                                :tool_calls (map |{:id ($ :id) :type "function" :function {:name "run_janet" :arguments (string (json/encode {:code ($ :code)}))}} (tools :tools))}
                               {:role "tool" :tool_call_id (data :tool-id) :content (record "text")})))
      (when (> (+ (model/estimate messages) (if evaluate (store/estimate (json/encode [model/tool])) 0)) (min (config :context-quota) (- (selected :context) 256)))
        (memory/compact archive view true)
        (set context {:through (view :last) :chronological (memory/context archive view) :evidence []})
        (array/clear messages)
        (array/concat messages [{:role "system" :content system}
                                {:role "user" :content (string "## History\n\n" (string/join (map |($ :text) (get-in context [:chronological :nodes]))))}
                                {:role "user" :content (model/images s (user "id") (user "text"))}]))
      (def final-round (= (+ 1 (length responses)) (config :rounds)))
      (when final-round (array/push messages {:role "system" :content "Tool calls are unavailable in this inference round."}))
      (def boundary ((dyn :zinc/task) :checkpoint))
      (store/checkpoint s {:phase "model" :round (length responses)})
      (def response (model/call s {:model (input :model) :messages messages :tools (when (and evaluate (not final-round)) [model/tool])}
                                (when (and (= "model" (boundary :phase)) (= (length responses) (boundary :round))) (boundary :request)) selected))
      (store/transact s
        (store/checkpoint s {:phase "commit"})
        (def event (store/append s view (if (= 0 (length (response :tools))) "completed" "response") (response :text)
                                 {:model (response :model) :reasoning (response :reasoning) :reasoning-visible (response :reasoning-visible)
                                  :reasoning-details (response :reasoning-details) :tools (response :tools)}
                                 (response :request) ((dyn :zinc/task) :id)))
        (when (> (length (response :tools)) 0)
          (def ids (map (fn [tool] (store/submit s view "code" {:code (tool :code) :user (user "id") :response (event "id") :tool-id (tool :id)} {:retry-policy "manual"})) (response :tools)))
          (store/append s view "tools" "Janet admissions, not proof of execution." {:tools (response :tools) :tasks ids} (event "id"))
          (store/checkpoint s {:phase "tools"}))))
    (memory/compact archive (scope s branch))
    (result s branch))

  (defn execute-job [s id]
    (def row (store/claim s id))
    (when row
      (def view (json/decode (row "scope") true true))
      (when (and (view :agent) ((s :config) :agent)) (put s :config ((s :config) :agent)))
      (def config (s :config))
      (def input (json/decode (row "input") true true))
      (def stop (ev/thread-chan 1))
      (def finished (ev/thread-chan 1))
      (ev/thread store/heartbeat [config id (row "owner") (row "attempt") stop finished] :n)
      (defer (do (ev/give stop true) (ev/take finished))
        (with-dyns [:zinc/task @{:id id :owner (row "owner") :generation (row "attempt") :scope view :checkpoint (json/decode (row "checkpoint") true true)}
                    :zinc/effect (row "admission")]
          (var value nil)
          (var failure nil)
          (try
            (do
              (def available (repl/definitions config))
              (each name (view :permissions) (assert (available name) "saved function revoked"))
              (set value (case (row "kind")
                           "agent" (infer s row input)
                           "summarize" (memory/summarize s row input)
                           "operation" (do
                                         (assert (index-of (input :function) (view :permissions)) "function is not permitted")
                                         (def entry (available (input :function)))
                                         (apply (entry :function) s view (input :arguments)))
                           "code" (do
                                    (assert (config :repl) "Janet execution is not permitted")
                                    (def branch (store/branch s (view :branch)))
                                    (os/cd (path/dirname (config :file)))
                                    (var position 0)
                                    (repl/execute (config :file) (branch "code")
                                                  ((first (store/query s "SELECT text FROM events WHERE id=?" [(row "admission")])) "text")
                                                  (get-in (json/decode ((first (store/query s "SELECT data FROM events WHERE branch=? AND kind='user'" [(view :branch)])) "data") true true) [:input])
                                                  (repl/instructions config view (spec :document))
                                                  (seq [name :in (view :permissions)] {:name name :doc ((available name) :description) :module ((available name) :module)})
                                                  (fn [name args]
                                                    (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                                                    (if (= name "await")
                                                      (do
                                                        (def handle (first args))
                                                        (assert (and (dictionary? handle) (int? (handle :job)) (not= id (handle :job))
                                                                     ((repl/inspect-job s view (handle :job)) :owned)) "await requires descendant work")
                                                        (wait s (handle :job)))
                                                      (do
                                                        (def key (string "call:" id ":" (++ position)))
                                                        (if (= name "self")
                                                          (store/transact s
                                                            (def event (store/append s view "call-admission" "self" {:position position :arguments args} nil id))
                                                            (def handle (with-dyns [:zinc/effect (event "id")] (start-child s view (first args))))
                                                            (spawn-job s (handle :job)) handle)
                                                          (do
                                                            (assert (index-of name (view :permissions)) "function is not permitted")
                                                            (def job (store/submit s view "operation" {:function name :arguments args}
                                                                                   {:retry-policy ((available name) :retry-policy) :key key}))
                                                            (spawn-job s job)
                                                            (wait s job))))))
                                                  (min (config :seconds) (max 0.001 (- (((store/query s "SELECT expires FROM runs WHERE id=?" [(view :run)]) 0) "expires") (os/clock))))
                                                  (config :forbid) (config :response-bytes)))
                           (error "unknown task kind"))))
            ([err fiber]
              (def trace @"")
              (with-dyns [:err (fn [bytes]
                                 (buffer/push-string trace (string/slice bytes 0 (min (length bytes) (- (config :response-bytes) (length trace))))))]
                (debug/stacktrace fiber))
              (store/append s view "traceback" (string trace) {} nil id)
              (set value nil)
              (set failure (string err))
              (each provider (values (config :providers))
                (when (provider :token) (set failure (string/replace-all (provider :token) "[redacted]" failure))))))
          (unless (index-of ((store/task s id) "state") ["done" "failed"])
            (store/finish s row value failure))
          (each pending (store/query s "SELECT id FROM tasks WHERE source=? AND run=? AND state='queued' AND EXISTS(SELECT 1 FROM runs WHERE id=tasks.run AND expires>?) ORDER BY id LIMIT ?" [(s :source) (row "run") (os/clock) (config :parallel)])
            (spawn-job s (pending "id")))))))

  (defn message [s event]
    (def data (json/decode (event "data") true true))
    (def branch (when (event "branch") (store/branch s (event "branch"))))
    (def base {:sequence (event "id") :event (event "id") :run (event "run") :branch (event "branch") :created_at (event "created_at")})
    (case (event "kind")
      "user" (merge base {:type "start" :root (nil? (branch "parent")) :persist (= 0 (branch "temporary"))})
      "response" (merge base {:type "turn" :text (event "text") :reasoning (when (data :reasoning-visible) (data :reasoning)) :final false})
      "completed" (merge base {:type "turn" :text (event "text") :reasoning (when (data :reasoning-visible) (data :reasoning)) :final true})
      "task-admission" (when (= "code" (data :kind)) (merge base {:type "tool" :call (event "task") :code (event "text")}))
      "tool-result" (merge base {:type "tool_result" :call (event "task") :ok (data :ok) :text (event "text")})
      "interruption" (when (= "uncertain" (data :state)) (merge base {:type "ambiguity" :call (event "task") :text (event "text")}))
      "error" (merge base {:type "error" :text (event "text")}) nil))

  (defn drain [s run after]
    (var sequence after)
    (while true
      (def records (memory/events s run sequence))
      (each event records
        (def frame (message s event))
        (when frame (pa/emit (string (json/encode frame))))
        (set sequence (event "id")))
      (when (< (length records) 256) (break)))
    sequence)

  (defn dispatch [bytes opaque &opt resume task]
    (def config (schema/configuration (spec :schema) opaque))
    (def value (schema/request bytes (if task [:task] (if resume [:run :request :after] (keys (spec :input))))))
    (unless (or resume task)
      (assert (not= (nil? (value :text)) (nil? (value :code))) "self requires text or code")
      (assert (if (value :text) (config :inference) (config :repl)) "execution is not permitted in this view"))
    (def s (store/open config))
    (defer (store/close s)
      (def existing (cond task (first (store/query s "SELECT r.* FROM runs r JOIN tasks t ON t.run=r.id WHERE t.id=? AND t.source=?" [(value :task) (s :source)]))
                      (value :run) (first (store/query s "SELECT * FROM runs WHERE id=? AND source=?" [(value :run) (s :source)]))
                      (value :request) (first (store/query s "SELECT * FROM runs WHERE request=? AND source=?" [(value :request) (s :source)]))))
      (when (or task resume) (assert existing "task/run unavailable"))
      (when existing
        (assert (= (existing "world") (config :world)) "saved world differs")
        (assert (not (first (store/query s "SELECT id FROM events WHERE run=? AND kind='cancelled'" [(existing "id")]))) "run cancelled")
        (put s :config (schema/authorize (spec :schema) config (json/decode (existing "config") true true)))
        (store/query s "UPDATE runs SET expires=min(expires,(SELECT min(created) FROM events WHERE run=runs.id AND kind='user')+?) WHERE id=?" [((s :config) :run-seconds) (existing "id")]))
      (with-dyns [:zinc/wait wait :zinc/spawn spawn-job :zinc/config (s :config)]
        (store/recover s)
        (if task (do (execute-job s (value :task)) (string (json/encode {:task (value :task)})))
          (do
            (def branch (if resume (store/branch s ((first (store/query s "SELECT id FROM branches WHERE run=? AND parent IS NULL" [(existing "id")])) "id")) (store/start s value (s :config))))
            (when resume (assert (= 0 (branch "temporary")) "temporary conversation cannot be resumed"))
            (def id (branch "id"))
            (def view (scope s id))
            (var sequence (drain s (view :run) (get value :after 0)))
            (if (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [id]))
              (string (json/encode (result s id)))
              (do
                (def driver (store/transact s
                              (def prior (first (store/query s "SELECT * FROM tasks WHERE branch=? AND parent IS NULL ORDER BY id DESC LIMIT 1" [id])))
                              (if (and prior (or (index-of (prior "state") ["queued" "running" "waiting" "done"]) (not resume))) (prior "id")
                                (do
                                  (when prior (assert (= "retry" (prior "retry_policy")) "effectful root requires reconciliation, not replay"))
                                  (def input (get-in (json/decode ((first (store/query s "SELECT data FROM events WHERE branch=? AND kind='user'" [id])) "data") true true) [:input]))
                                  (store/submit s view (if (input :text) "agent" "code")
                                                (if prior (json/decode (prior "input") true true)
                                                  (if (input :text) {:branch id :model ((s :config) :chat)} {:code (input :code)}))
                                                {:retry-policy (if (input :text) "retry" "manual") :key (string "root:" id ":" (if prior (prior "id") 0))
                                                 :checkpoint (if prior (json/decode (prior "checkpoint") true true) {})})))))
                (def emitter (ev/go (fn [] (try (while true (set sequence (drain s (view :run) sequence)) (ev/sleep 0.1)) ([err] nil)))))
                (defer (ev/cancel emitter "observer detached")
                  (wait s driver)
                  (drain s (view :run) sequence)
                  (string (json/encode (result s id)))))))))))

  (defn describe [bytes opaque]
    (assert (= "" bytes) "describe takes empty input")
    (def config (schema/configuration (spec :schema) opaque true))
    (def parameters @[])
    (each [target fields] [[:config (spec :schema)] [:input (spec :input)]]
      (each [key field] (sorted (pairs fields))
        (when (field :option)
          (def parameter (merge field {:name (field :option) :path (string target "." key) :type (string (field :type))}))
          (when (and (= target :config) (= :integer (field :type)) (> (config key) 0)) (put parameter :maximum (config key)))
          (each key [:default :optional :option] (put parameter key nil))
          (array/push parameters parameter))))
    (string (json/encode {:input "json" :output "json" :durable true :record true :schema {:config (spec :schema) :input (spec :input)} :parameters parameters})))

  (defn events [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque))
    (def value (schema/request bytes [:run :after]))
    (def s (store/open config))
    (defer (store/close s)
      (def records (memory/events s (value :run) (get value :after 0)))
      (string (json/encode {:events (filter identity (map |(message s $) records))
                            :after (if (last records) ((last records) "id") (get value :after 0)) :more (= 256 (length records))}))))

  (defn record [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque))
    (assert (<= (length bytes) (config :request-bytes)) "context batch byte ceiling")
    (def s (store/open config))
    (defer (store/close s)
      (string (json/encode {:events (store/record s ((schema/request bytes [:records]) :records))}))))

  (defn pending [bytes opaque]
    (assert (= "" bytes) "pending takes empty input")
    (def config (schema/configuration (spec :schema) opaque))
    (def s (store/open config))
    (defer (store/close s)
      (store/recover s)
      (string (json/encode (store/query s `SELECT r.id run,r.request,b.id branch,t.id job,t.state,t.kind,t.attempt,t.retry_policy,
        t.admission,t.outcome,r.expires run_expires,l.expires lease_expires FROM runs r JOIN branches b ON b.run=r.id AND b.parent IS NULL
        JOIN tasks t ON t.branch=b.id AND t.parent IS NULL LEFT JOIN leases l ON l.task=t.id WHERE r.source=? AND r.world=?
        AND t.state IN ('queued','running','waiting','failed','uncertain','cancelled')
        AND NOT EXISTS(SELECT 1 FROM events e WHERE e.branch=b.id AND e.kind='completed') ORDER BY r.id,t.id` [(s :source) (config :world)])))))

  (defn abort [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque))
    (def value (schema/request bytes [:run :request :reason]))
    (assert (and (not= (nil? (value :run)) (nil? (value :request))) (string? (value :reason)) (<= (length (value :reason)) 2048)) "abort requires run or request and reason")
    (def s (store/open config))
    (defer (store/close s)
      (string (json/encode (store/transact s
                             (when (value :request) (store/query s "INSERT INTO runs(source,request,input,world,config,expires) VALUES(?,?,'{}',?,?,?) ON CONFLICT(source,request) DO NOTHING"
                                                                 [(s :source) (value :request) (config :world) (string (json/encode (merge config {:providers {}}))) (os/clock)]))
                             (def run (first (store/query s "SELECT id,world FROM runs WHERE source=? AND (id=? OR request=?)" [(s :source) (value :run) (value :request)])))
                             (assert (and run (= (run "world") (config :world))) "run unavailable")
                             (def completed (first (store/query s "SELECT e.id FROM events e JOIN branches b ON b.id=e.branch WHERE e.run=? AND e.kind='completed' AND b.parent IS NULL" [(run "id")])))
                             (unless completed
                               (def root (first (store/query s "SELECT id FROM branches WHERE run=? AND parent IS NULL" [(run "id")])))
                               (def tasks (store/query s
                                                       "SELECT id,kind,state,attempt,admission,outcome FROM tasks WHERE source=? AND run=? AND state IN ('queued','running','waiting','uncertain') ORDER BY id"
                                                       [(s :source) (run "id")]))
                               # Fence scheduling; an external effect already in flight may still finish.
                               (store/query s "UPDATE tasks SET state='cancelled' WHERE source=? AND run=? AND state IN ('queued','running','waiting','uncertain')" [(s :source) (run "id")])
                               (unless (first (store/query s "SELECT id FROM events WHERE run=? AND kind='cancelled'" [(run "id")]))
                                 (store/append s {:run (run "id") :branch (when root (root "id"))}
                                               "cancelled" "Interrupted. Performed effects are not rolled back; running effects may still finish."
                                               {:reason (value :reason) :tasks-at-request tasks})))
                             {:run (run "id") :state (if completed "completed" "cancelled")})))))

  {"self" (fn [bytes opaque] (dispatch bytes opaque))
   "task" (fn [bytes opaque] (dispatch bytes opaque false true))
   "resume" (fn [bytes opaque] (dispatch bytes opaque true))
   "describe" describe "events" events "record" record "pending" pending "abort" abort
   "models" (fn [bytes opaque]
              (def config (schema/configuration (spec :schema) opaque))
              (def value (schema/request bytes [:role]))
              (string (json/encode (model/catalogue config (get value :role "chat")))))
   "document" (fn [bytes opaque]
                (assert (= "" bytes) "document takes empty input")
                (def config (schema/configuration (spec :schema) opaque))
                (repl/instructions config {:permissions (sorted (keys (repl/definitions config)))} (spec :document)))})
