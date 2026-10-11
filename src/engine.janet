(import spork/json :as json)
(import spork/base64 :as base64)

(import ./store)
(import ./model)
(import ./memory)
(import ./schema)

(defn- document [node]
  (cond
    (string? node) node
    (dictionary? node) (cond
                         (node :text) (node :text)
                         (has-key? node :content)
                         (string (when (node :name) (string (node :name) "\n"))
                                 (string/join (map document (node :content)) "\n\n"))
                         (string (json/encode node)))
    (indexed? node) (string/join (map document node) "\n")
    ""))

(defn make [spec]
  (var operations nil)

  (defn scope [s branch]
    (def view (store/view s branch))
    (def user (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [branch])))
    (merge view {:first (if (= 0 (view :first)) (user "id") (view :first))
                 :last (max (view :last) (((store/query s "SELECT coalesce(max(id),0) id FROM events WHERE run=?" [(view :run)]) 0) "id"))
                 :capabilities ((s :config) :capabilities)
                 :imports (filter |(and (not (index-of $ ["repl" "ledger"]))
                                        (get-in (s :config) [:imports (keyword $)])) (pa/imports))}))

  (defn spawn-job [s id]
    (def lease (store/transact s
                               (first (store/query s
                                                   `INSERT INTO leases(task,owner,generation,expires)
       SELECT id,'launch',-1,? FROM tasks WHERE id=? AND actor=? AND state='queued'
         AND (SELECT count(*) FROM tasks WHERE actor=? AND state='running')<?
       ON CONFLICT(task) DO UPDATE SET expires=excluded.expires
       WHERE leases.owner='launch' AND leases.expires<=? RETURNING task`
                                                   [(+ (os/clock) ((s :config) :lease-seconds)) id (s :actor)
                                                    (s :actor) ((s :config) :parallel) (os/clock)]))))
    (when lease
      (try
        (pa/spawn "self" (string (json/encode {:task id})) (string (json/encode (s :config)))
                  :member "run-task" :imports (pa/imports) :spawn true)
        ([err]
          (store/transact s
                          (store/append s (json/decode ((store/task s id) "scope") true true)
                                        "launch-uncertain" "Task admission acknowledgment was lost." {} nil id)))))
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
          (assert (and (= (current :generation) (owner "attempt"))
                       (index-of (owner "state") ["running" "waiting"])) "waiting execution fenced"))
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

  (defn parallel [s ids &opt outcomes]
    (def results @[])
    (each id (take ((s :config) :parallel) ids) (spawn-job s id))
    (eachp [position id] ids
      (def outcome (with-dyns [:zinc/dependencies ids]
                     (try {:ok true :value (wait s id)} ([err] {:ok false :error (string err)}))))
      (if outcomes (array/push results outcome)
        (do (assert (outcome :ok) (outcome :error)) (array/push results (outcome :value))))
      (when (< (+ position ((s :config) :parallel)) (length ids))
        (spawn-job s (ids (+ position ((s :config) :parallel))))))
    results)

  (defn inspect-job [s view id]
    (def row (store/task s id))
    (def owned (or (= id ((dyn :zinc/task) :id))
                   (first (store/query s
                                       `WITH RECURSIVE parents(id) AS (SELECT ? UNION ALL SELECT t.parent FROM tasks t JOIN parents p ON t.id=p.id WHERE t.parent IS NOT NULL)
                    SELECT id FROM parents WHERE id=?`
                                       [id ((dyn :zinc/task) :id)]))))
    (unless owned (store/event s view (row "admission")))
    {:owned (not (nil? owned)) :job id :state (row "state") :kind (row "kind") :admission (row "admission") :outcome (row "outcome")
     :children (store/query s "SELECT id,kind,policy,admission,outcome,state FROM tasks WHERE parent=? AND actor=? ORDER BY id LIMIT 256" [id (s :actor)])})

  (defn start-child [s view value]
    (def value (schema/request (json/encode value) [:text :parent :memory_range :persist]))
    (assert (value :text) "nested question required")
    (def parent (store/branch s (view :branch)))
    (def branch (store/start s (merge value {:operation "call" :persist (get value :persist (= 0 (parent "temporary")))})
                             (s :config) (merge view {:event (dyn :zinc/effect)})))
    (def id (store/submit s (merge (scope s (branch "id")) {:imports (view :imports) :capabilities (view :capabilities)})
                          "agent" {:branch (branch "id") :model ((s :config) :chat)}
                          {:policy "safe" :key (string "child:" (branch "id"))}))
    {:job id :branch (branch "id")})

  (defn instructions [config view]
    (def evaluate (and (config :repl) (get view :tools true)))
    (def resident (when (config :repl) (json/decode ((pa/import "repl") "" :member "document") true true)))
    (def imports (tabseq [name :in (view :imports)] name (get-in config [:imports (keyword name)])))
    (string (document (spec :document)) "\n\nWorld: " (json/encode (config :world))
            (when resident
              (string "\nEntry: " (resident :file)
                      "\nNative restrictions: " (json/encode (resident :forbid)) ". OS access is invoker-scoped."
                      (when (> (length (resident :instructions)) 0)
                        (string "\n\nWorld instructions:\n" (resident :instructions)))))
            (when evaluate
              (string "\n\nworld is the live environment; (dyn :current-file) names its source. REPL-only changes are ephemeral."
                      (unless (any? (map |(index-of $ (resident :forbid)) ["all" "fs" "fs-write"]))
                        " Edit source/data files for durability.")
                      (unless (any? (map |(index-of $ (resident :forbid)) ["all" "fs" "fs-read"]))
                        " Reload explicitly: (eval-string (slurp (dyn :current-file)) world).")
                      "\n(input) -> current request; (self/document) -> instructions."
                      "\n(await (self {:text \"Investigate this subproblem\" :persist false})) -> nested result."
                      (when (> (length (view :capabilities)) 0)
                        (string "\n(self/member name & arguments) -> handle; (await handle) -> result.\n"
                                (string/join (map |((operations $) :description) (sorted (view :capabilities))) "\n")))
                      (when (index-of "memory/document" (view :capabilities))
                        "\n(await (self/member \"memory/document\" \"An observation\")) -> document handle.")
                      (when (> (length imports) 0) (string "\nImports: " (json/encode imports)))
                      (string/join
                        (map (fn [[name members]]
                               (case name
                                 "git" (string
                                         (when (index-of "status" members)
                                           "\n((pa/import \"git\") `{\"paths\":[\"path/to/file\"]}` :member \"status\")")
                                         (when (index-of "diff" members)
                                           "\n((pa/import \"git\") `{\"paths\":[\"path/to/file\"]}` :member \"diff\")")
                                         (when (index-of "add" members)
                                           "\nStage only intended paths with the granted add member.")
                                         (when (index-of "commit" members)
                                           "\nReview the diff before commit; select explicit paths and describe their changes in message."))
                                 (when (index-of "document" members)
                                   (string "\n((pa/import " (json/encode name) ") \"\" :member \"document\") -> granted service documentation."))))
                             (sorted (pairs imports))) "")
                      "\nInspect uncertain effects before repeating them."))))

  (defn model-request [s view value]
    (def value (schema/request (json/encode value) [:role :model :messages :tools :output :query :documents]))
    (model/call s value (get-in (dyn :zinc/task) [:checkpoint :request])))

  (defn result [s id]
    (def branch (store/branch s id))
    (def saved (first (store/query s "SELECT result FROM tasks WHERE branch=? AND parent IS NULL AND kind='agent' AND state='done' ORDER BY id DESC LIMIT 1" [id])))
    (if saved ((json/decode (saved "result") true true) :value) (do
                                                                  (def final (first (store/query s "SELECT *,strftime('%Y-%m-%dT%H:%M:%fZ',created,'unixepoch') created_at FROM events WHERE branch=? AND kind='completed'" [id])))
                                                                  (assert final "branch has no completion")
                                                                  (def user (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [id])))
                                                                  {:text (final "text") :run (branch "run") :branch id :start (user "id") :event (final "id")
                                                                   :parent (or (branch "entry") 0) :memory_range {:start (branch "first") :end (branch "last")}
                                                                   :created_at (final "created_at") :tool_usage (store/tool-used s (branch "run"))
                                                                   :usage {:reported_total (model/used s (branch "run"))
                                                                           :unreported (((store/query s "SELECT count(*) n FROM events e LEFT JOIN usage u ON u.request=e.id WHERE e.actor=? AND e.run=? AND e.kind='model-admission' AND u.total IS NULL" [(s :actor) (branch "run")]) 0) "n")}
                                                                   :context_unit "utf8-quarter-byte"})))

  (defn infer [s task input]
    (def branch (input :branch))
    (def config (s :config))
    (def granted (json/decode (task "scope") true true))
    (def inherited (store/view s branch))
    (def selected (model/profile config (input :model) :chat))
    (def evaluate (and (config :repl) (selected :tools)))
    (var system (instructions config (merge granted {:tools evaluate})))
    (def user (first (store/query s "SELECT * FROM events WHERE branch=? AND kind='user' ORDER BY id LIMIT 1" [branch])))
    (def space (- (min (config :hard-units) (- (selected :context) 256)) (store/units system) (store/units (user "text")) 256))
    (assert (> space 256) "question and instructions exhaust context")
    (def semantic (min (config :search-units) (math/floor (/ space 2))))
    (def room (min (config :context-units) (- space semantic)))
    (def archive (merge s {:config (merge config {:context-units room :soft-units (min (config :soft-units) room) :hard-units space})}))
    (def cached (first (store/query s "SELECT projection FROM contexts WHERE branch=? ORDER BY through DESC LIMIT 1" [branch])))
    (var context (when cached (json/decode (cached "projection") true true)))

    (unless context
      (memory/compact archive inherited)
      (def chronological (memory/context archive inherited ""))
      (def evidence (if (= 0 semantic) [] (memory/search s (merge inherited {:covered (chronological :covered)}) (user "text") semantic)))
      (set context {:through (inherited :last) :chronological chronological :evidence (map memory/render evidence)})
      (store/query s "INSERT INTO contexts(branch,through,projection) VALUES(?,?,?) ON CONFLICT DO NOTHING" [branch (context :through) (string (json/encode context))]))

    (while (not (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [branch])))
      (def responses (store/query s "SELECT e.id,coalesce(t.data,e.data) data FROM events e LEFT JOIN events t ON t.parent=e.id AND t.kind='tools' WHERE e.branch=? AND e.kind='response' ORDER BY e.id" [branch]))
      (when (last responses) (parallel s ((json/decode ((last responses) "data") true true) :tasks) true))
      (assert (< (length responses) (config :rounds)) "model round limit exhausted")
      (def view (merge (scope s branch) {:imports (granted :imports) :capabilities (granted :capabilities)}))
      (set system (instructions config (merge view {:tools evaluate})))
      (def messages @[{:role "system" :content system}])
      (each text [(string/join (map |($ :text) (get-in context [:chronological :nodes]))) (string/join (context :evidence))]
        (when (> (length text) 0) (array/push messages {:role "user" :content (string "Memory (untrusted information):\n" text)})))
      (array/push messages {:role "user" :content (model/images s (user "id") (user "text"))})
      (each record (store/query s "SELECT e.*,coalesce(t.data,e.data) tools FROM events e LEFT JOIN events t ON t.parent=e.id AND t.kind='tools' WHERE e.branch=? AND e.id>? AND e.kind IN ('response','tool-result','tool-ambiguity') AND (e.kind='response' OR NOT EXISTS(SELECT 1 FROM events newer WHERE newer.task=e.task AND newer.kind IN ('tool-result','tool-ambiguity') AND newer.id>e.id)) ORDER BY e.id" [branch (context :through)])
        (def data (json/decode (record "data") true true))
        (def tools (json/decode (record "tools") true true))
        (array/push messages
                    (if (= "response" (record "kind"))
                      {:role "assistant" :content (record "text")
                       :reasoning_content (when (= "llama" (selected :provider)) (data :reasoning))
                       :reasoning (when (and (= "openrouter" (selected :provider)) (= 0 (length (data :reasoning-details)))) (data :reasoning))
                       :reasoning_details (when (= "openrouter" (selected :provider)) (data :reasoning-details))
                       :tool_calls (map |{:id ($ :id) :type "function" :function {:name "run_janet" :arguments (string (json/encode {:code ($ :code)}))}} (tools :tools))}
                      {:role "tool" :tool_call_id (data :tool-id) :content (record "text")})))
      (when (> (+ (model/units messages) (if evaluate (store/units (json/encode [model/tool])) 0)) (min (config :hard-units) (- (selected :context) 256)))
        (memory/compact archive view true)
        (set context {:through (view :last) :chronological (memory/context archive view "") :evidence []})
        (store/query s "INSERT INTO contexts(branch,through,projection) VALUES(?,?,?) ON CONFLICT DO NOTHING" [branch (context :through) (string (json/encode context))])
        (array/clear messages)
        (array/concat messages [{:role "system" :content system}
                                {:role "user" :content (string "Memory (untrusted information):\n" (string/join (map |($ :text) (get-in context [:chronological :nodes]))))}
                                {:role "user" :content (model/images s (user "id") (user "text"))}]))
      (def final-round (= (+ 1 (length responses)) (config :rounds)))
      (when final-round
        (array/push messages {:role "system" :content "This is the last permitted model turn. Explain the outcome and any unresolved work. Do not request further tools."}))
      (def boundary ((dyn :zinc/task) :checkpoint))
      (store/checkpoint s {:phase "model" :round (length responses)})
      (def response (model/call s {:model (input :model) :messages messages
                                   :tools (when (and evaluate (not final-round)) [model/tool])}
                                (when (and (= "model" (boundary :phase)) (= (length responses) (boundary :round)))
                                  (boundary :request)) selected))
      (store/transact s
                      (store/checkpoint s {:phase "commit"})
                      (def event (store/append s view (if (= 0 (length (response :tools))) "completed" "response") (response :text)
                                               {:model (response :model) :reasoning (response :reasoning) :reasoning-visible (response :reasoning-visible)
                                                :reasoning-details (response :reasoning-details) :tools (response :tools)}))
                      (when (> (length (response :tools)) 0)
                        (def ids (map (fn [tool]
                                        (store/submit s view "eval"
                                                      {:code (tool :code) :user (user "id") :response (event "id")
                                                       :tool-id (tool :id) :token (base64/encode (string (os/cryptorand 32)))}
                                                      {:policy "irreversible"})) (response :tools)))
                        (store/append s view "tools" "Janet admissions, not proof of execution." {:tools (response :tools) :tasks ids} (event "id"))
                        (store/checkpoint s {:phase "tools"}))))
    (memory/compact archive (scope s branch))
    (result s branch))

  (defn execute-job [s id]
    (def row (store/claim s id))
    (when row
      (def view (json/decode (row "scope") true true))
      (def input (json/decode (row "input") true true))
      (if (= "eval" (row "kind"))
        (try
          (do
            (assert (and ((s :config) :repl) (index-of "repl" (pa/imports)) (index-of "ledger" (pa/imports))) "REPL and ledger grants required")
            (pa/spawn "repl" (string (json/encode (merge input
                                                           {:code ((first (store/query s "SELECT text FROM events WHERE id=?" [(row "admission")])) "text")
                                                            :input (merge ((json/decode ((first (store/query s "SELECT data FROM events WHERE branch=? AND kind='user'" [(view :branch)])) "data") true true) :input)
                                                                          {:parent (or (input :response) (view :last))
                                                                           :memory_range {:start (view :first) :end (view :last)}})
                                                            :document (instructions (s :config) view)
                                                            :task id :owner (row "owner") :generation (row "attempt")
                                                            :imports (view :imports)
                                                            :lease-seconds ((s :config) :lease-seconds)}))) ""
                      :member "eval" :imports ["ledger"] :spawn true))
          ([err] (store/transact s
                                 (store/append s view "launch-uncertain" "REPL relay admission could not be confirmed." {} nil id))))
        (let [stop (ev/thread-chan 1) finished (ev/thread-chan 1)]
          (ev/thread store/heartbeat [(s :config) id (row "owner") (row "attempt") stop finished] :n)
          (defer (do (ev/give stop true) (ev/take finished))
            (with-dyns [:zinc/task @{:id id :owner (row "owner") :generation (row "attempt")
                                     :scope view :checkpoint (json/decode (row "checkpoint") true true)}
                        :zinc/effect (row "admission")]
              (var value nil)
              (var failure nil)
              (try
                (do
                  (each name (view :imports) (assert (index-of name (pa/imports)) "saved Import revoked"))
                  (def member (when (= "operation" (row "kind")) (operations (input :capability))))
                  (when (= "operation" (row "kind"))
                    (assert (and member (index-of (input :capability) (view :capabilities))) "member revoked"))
                  (if (and member (member :transactional))
                    (store/transact s
                                    (set value (apply (member :function) s view (input :arguments)))
                                    (store/finish s row value nil))
                    (set value (case (row "kind")
                                 "agent" (infer s row input)
                                 "summarize" (memory/summarize s row input)
                                 "operation" (apply (member :function) s view (input :arguments))
                                 "import" {:data (base64/encode (string ((pa/import (input :name)) (base64/decode (input :data)) :member (input :member))))}
                                 (error "unknown job kind"))))
                  (unless (index-of ((store/task s id) "state") ["done" "failed"])
                    (store/finish s row value nil)))
                ([err]
                  (set value nil)
                  (set failure (string err))
                  (each provider (values ((s :config) :providers))
                    (when (provider :token) (set failure (string/replace-all (provider :token) "[redacted]" failure))))))
              (unless (index-of ((store/task s id) "state") ["done" "failed"])
                (store/finish s row value failure))
              (each pending (store/query s "SELECT id FROM tasks WHERE actor=? AND run=? AND state='queued' ORDER BY id LIMIT ?" [(s :actor) (row "run") ((s :config) :parallel)])
                (spawn-job s (pending "id")))))))))

  (defn receipt [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def value (schema/request bytes [:task :token :owner :generation :position :operation :arguments :value :error]))
    (def s (store/open config))
    (defer (store/close s)
      (def row (store/task s (value :task)))
      (def input (json/decode (row "input") true true))
      (def saved ((first (store/query s "SELECT config FROM runs WHERE id=? AND actor=?" [(row "run") (s :actor)])) "config"))
      (put s :config (schema/authorize (spec :schema) config (json/decode saved true true)))
      (assert (and (= "eval" (row "kind")) (= (input :token) (value :token))
                   (= (row "attempt") (value :generation))) "invalid evaluation receipt")
      (if (and (= "complete" (value :operation)) (row "result") (index-of (row "state") ["done" "failed" "cancelled"]))
        (do
          (def previous (json/decode (row "result") true true))
          (assert (and (deep= (previous :value) (value :value)) (= (previous :error) (value :error))) "conflicting completion")
          (string (json/encode {:ok true})))
        (do
          (def lease (first (store/query s "SELECT * FROM leases WHERE task=?" [(row "id")])))
          (assert (and lease (= (lease "owner") (value :owner)) (= (lease "generation") (value :generation))) "evaluation receipt fenced")
          (def granted (json/decode (row "scope") true true))
          (def view (merge granted {:last ((scope s (row "branch")) :last)}))
          (with-dyns [:zinc/task @{:id (row "id") :owner (lease "owner") :generation (lease "generation")
                                   :scope view :checkpoint (json/decode (row "checkpoint") true true)}
                      :zinc/wait wait :zinc/spawn spawn-job]
            (def result (case (value :operation)
                          "complete" (do
                                       (store/finish s (merge row {"owner" (lease "owner")}) (value :value) (value :error))
                                       (each pending (store/query s "SELECT id FROM tasks WHERE actor=? AND run=? AND state='queued' ORDER BY id LIMIT ?" [(s :actor) (row "run") ((s :config) :parallel)])
                                         (spawn-job s (pending "id")))
                                       nil)
                          "renew" (store/transact s
                                                  (assert (index-of (row "state") ["running" "waiting" "uncertain"]) "job cancelled")
                                                  (store/query s "UPDATE leases SET expires=? WHERE task=? AND owner=?"
                                                               [(+ (os/clock) (config :lease-seconds)) (row "id") (lease "owner")])
                                                  (when (= "uncertain" (row "state"))
                                                    (store/query s "UPDATE tasks SET state='waiting',result=NULL,outcome=NULL WHERE id=?" [(row "id")]))
                                                  nil)
                          "await" (do
                                    (def handle (first (value :arguments)))
                                    (assert (and (dictionary? handle) (int? (handle :job)) (not= (handle :job) (row "id"))
                                                 ((inspect-job s view (handle :job)) :owned)) "await requires descendant work")
                                    (wait s (handle :job)))
                          (do
                            (store/checkpoint s ((dyn :zinc/task) :checkpoint))
                            (assert (and (int? (value :position)) (<= 1 (value :position) (config :task-quota))) "invalid call position")
                            (def name (value :operation))
                            (def arguments (value :arguments))
                            (assert (indexed? arguments) "call arguments must be an array")
                            (def handle (if (= name "spawn")
                                          (store/transact s
                                                          (def prior (first (store/query s "SELECT * FROM events WHERE task=? AND kind='call-admission' AND json_extract(data,'$.position')=?"
                                                                                         [(row "id") (value :position)])))
                                                          (when prior (assert (deep= arguments ((json/decode (prior "data") true true) :arguments)) "call position reused"))
                                                          (def event (or prior (store/append s view "call-admission" "self" {:position (value :position) :arguments arguments} nil (row "id"))))
                                                          (with-dyns [:zinc/effect (event "id")] (start-child s view (first arguments))))
                                          (let [member (operations name)
                                                imported (= name "import") target (first arguments)]
                                            (if imported
                                              (assert (and (index-of (target :name) (view :imports))
                                                           (index-of (target :member) (get-in (s :config) [:imports (keyword (target :name))]))) "Import member not granted")
                                              (assert (and member (index-of name (view :capabilities))) "member not granted"))
                                            {:job (store/submit s view (if imported "import" "operation")
                                                                (if imported target {:capability name :arguments arguments})
                                                                {:policy (if imported "irreversible" (member :policy))
                                                                 :key (string "call:" (row "id") ":" (value :position))})
                                             :bytes imported})))
                            (spawn-job s (handle :job))
                            handle)))
            (string (json/encode {:ok true :value result})))))))

  (defn message [s event]
    (def data (json/decode (event "data") true true))
    (def kind (event "kind"))
    (def branch (when (event "branch") (store/branch s (event "branch"))))
    (def base {:sequence (event "id") :event (event "id") :run (event "run") :branch (event "branch")
               :created_at (event "created_at")})
    (case kind
      "user" (merge base {:type "start" :root (nil? (branch "parent")) :persist (= 0 (branch "temporary"))})
      "response" (merge base {:type "turn" :text (event "text") :reasoning (when (data :reasoning-visible) (data :reasoning)) :final false})
      "completed" (merge base {:type "turn" :text (event "text") :reasoning (when (data :reasoning-visible) (data :reasoning)) :final true})
      "task-admission" (when (= "eval" (data :kind)) (merge base {:type "tool" :call (event "task") :code (event "text")}))
      "tool-result" (merge base {:type "tool_result" :call (event "task") :ok (data :ok) :text (event "text")})
      "interruption" (when (= "uncertain" (data :state)) (merge base {:type "ambiguity" :call (event "task") :text (event "text")}))
      "delta" (when (data :visible) (merge base {:type "delta" :channel (data :channel) :text (event "text")}))
      "error" (merge base {:type "error" :text (event "text")})
      nil))

  (defn drain [s run after]
    (var sequence after)
    (each event (memory/events s run after)
      (def frame (message s event))
      (when frame (pa/emit (string (json/encode frame))))
      (set sequence (event "id")))
    sequence)

  (defn dispatch [member bytes opaque]
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def value (schema/request bytes (case member
                                       "call" (keys (spec :input))
                                       "invoke" [:code :capability :arguments :request :parent :memory_range :persist :after]
                                       "run-task" [:task]
                                       "resume" [:run :request :after])))
    (when (= member "invoke")
      (assert (not= (nil? (value :code)) (nil? (value :capability))) "invoke requires code or capability")
      (when (value :code) (assert (config :repl) "resident evaluator not enabled")))
    (def s (store/open config))
    (defer (store/close s)
      (def existing (cond
                      (= member "run-task") (first (store/query s "SELECT r.* FROM runs r JOIN tasks t ON t.run=r.id WHERE t.id=? AND t.actor=?" [(value :task) (s :actor)]))
                      (value :run) (first (store/query s "SELECT * FROM runs WHERE id=? AND actor=?" [(value :run) (s :actor)]))
                      (value :request) (first (store/query s "SELECT * FROM runs WHERE request=? AND actor=?" [(value :request) (s :actor)]))))
      (when (index-of member ["run-task" "resume"]) (assert existing "job/run unavailable"))
      (when existing
        (assert (= (existing "world") (config :world)) "saved world differs")
        (assert (not (first (store/query s "SELECT id FROM events WHERE run=? AND kind='cancelled'" [(existing "id")]))) "run cancelled")
        (put s :config (schema/authorize (spec :schema) config (json/decode (existing "config") true true))))
      (with-dyns [:zinc/wait wait :zinc/spawn spawn-job]
        (store/recover s)
        (if (= member "run-task")
          (do (execute-job s (value :task)) (string (json/encode {:task (value :task)})))
          (do
            (when (= member "call") (assert (value :text) "question required"))
            (def branch (if (= member "resume")
                          (store/branch s ((first (store/query s "SELECT id FROM branches WHERE run=? AND parent IS NULL" [(existing "id")])) "id"))
                          (store/start s (merge value {:operation member}) (s :config))))
            (when (= member "resume") (assert (= 0 (branch "temporary")) "temporary conversation cannot be resumed"))
            (def id (branch "id"))
            (def view (scope s id))
            (if (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [id]))
              (string (json/encode (result s id)))
              (do
                (def driver (store/transact s
                              (def prior (first (store/query s "SELECT * FROM tasks WHERE branch=? AND parent IS NULL ORDER BY id DESC LIMIT 1" [id])))
                              (if (and prior (or (index-of (prior "state") ["queued" "running" "waiting" "done"]) (not= member "resume")))
                                (prior "id")
                                (do
                                  (when prior (assert (= "safe" (prior "policy")) "effectful root requires reconciliation, not replay"))
                                  (def input ((json/decode ((first (store/query s "SELECT data FROM events WHERE branch=? AND kind='user'" [id])) "data") true true) :input))
                                  (def kind (if (= "call" (input :operation)) "agent" (if (input :code) "eval" "operation")))
                                  (def entry (when (= kind "operation") (operations (input :capability))))
                                  (when (= kind "operation")
                                    (assert (and entry (index-of (input :capability) ((s :config) :capabilities))) "member not granted"))
                                  (store/submit s view kind
                                                (if prior (json/decode (prior "input") true true)
                                                  (case kind
                                                    "agent" {:branch id :model ((s :config) :chat)}
                                                    "eval" {:code (input :code) :token (base64/encode (string (os/cryptorand 32)))}
                                                    "operation" {:capability (input :capability) :arguments (get input :arguments [])}))
                                                {:policy (if (= kind "eval") "irreversible" (if entry (entry :policy) "safe"))
                                                 :key (string "root:" id ":" (if prior (prior "id") 0))
                                                 :checkpoint (if prior (json/decode (prior "checkpoint") true true) {})})))))
                (var sequence (get value :after 0))
                (def emitter (ev/go (fn []
                                      (try (while true
                                             (set sequence (drain s (view :run) sequence))
                                             (ev/sleep 0.1))
                                        ([err] nil)))))
                (defer (do (ev/cancel emitter "observer detached")
                         (while true
                           (def next (drain s (view :run) sequence))
                           (when (= next sequence) (break))
                           (set sequence next)))
                  (wait s driver)
                  (string (json/encode (result s id)))))))))))

  (defn call [bytes opaque] (dispatch "call" bytes opaque))

  (defn resume [bytes opaque] (dispatch "resume" bytes opaque))

  (defn invoke [bytes opaque] (dispatch "invoke" bytes opaque))

  (defn run-task [bytes opaque] (dispatch "run-task" bytes opaque))

  (defn describe [bytes opaque]
    (assert (= "" bytes) "describe takes empty input")
    (def config (schema/configuration (spec :schema) opaque [] true))
    (def parameters @[])
    (each [target fields] [[:config (spec :schema)] [:input (spec :input)]]
      (each [key field] (sorted (pairs fields))
        (when (field :option)
          (def parameter (merge field {:name (field :option) :path (string target "." key) :type (string (field :type))}))
          (when (and (= target :config) (= :integer (field :type)) (> (config key) 0))
            (put parameter :maximum (config key)))
          (each key [:default :optional :option] (put parameter key nil))
          (array/push parameters parameter))))
    (string (json/encode {:input "json" :output "json" :durable true
                          :schema {:config (spec :schema) :input (spec :input)} :parameters parameters})))

  (defn document-entry [bytes opaque]
    (assert (= "" bytes) "document takes empty input")
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (instructions config {:capabilities (config :capabilities)
                          :imports (filter |(and (not (index-of $ ["repl" "ledger"]))
                                                 (get-in config [:imports (keyword $)])) (pa/imports))}))

  (defn models [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def value (schema/request bytes [:role]))
    (string (json/encode (model/catalogue config (get value :role "chat")))))

  (defn events [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def value (schema/request bytes [:run :after]))
    (def s (store/open config))
    (defer (store/close s)
      (def records (memory/events s (value :run) (get value :after 0)))
      (string (json/encode {:events (filter identity (map |(message s $) records))
                            :after (if (last records) ((last records) "id") (get value :after 0))
                            :more (= 256 (length records))}))))

  (defn pending [bytes opaque]
    (assert (= "" bytes) "pending takes empty input")
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def s (store/open config))
    (defer (store/close s)
      (string (json/encode (store/query s
                                        `SELECT r.id run,b.id branch,t.id job,t.state,t.kind,t.admission,t.outcome
       FROM runs r JOIN branches b ON b.run=r.id AND b.parent IS NULL
       JOIN tasks t ON t.branch=b.id AND t.parent IS NULL
       WHERE r.actor=? AND r.world=?
         AND t.state IN ('queued','running','waiting','failed','uncertain')
         AND NOT EXISTS(SELECT 1 FROM events e WHERE e.branch=b.id AND e.kind='completed')
       ORDER BY r.id,t.id`
                                        [(s :actor) (config :world)])))))

  (defn abort [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def value (schema/request bytes [:run :request :reason]))
    (assert (and (not= (nil? (value :run)) (nil? (value :request)))
                 (string? (value :reason)) (<= (length (value :reason)) 2048)) "abort requires run or request and reason")
    (def s (store/open config))
    (defer (store/close s)
      (string (json/encode (store/transact s
                                           (when (value :request)
                                             (store/query s `INSERT INTO runs(actor,request,input,world,config)
            VALUES(?,?,'{}',?,?) ON CONFLICT(actor,request) DO NOTHING`
                                                          [(s :actor) (value :request) (config :world)
                                                           (string (json/encode (merge config {:providers {}})))]))
                                           (def run (first (store/query s "SELECT id,world FROM runs WHERE actor=? AND (id=? OR request=?)"
                                                                        [(s :actor) (value :run) (value :request)])))
                                           (assert (and run (= (run "world") (config :world))) "run unavailable")
                                           (def root (first (store/query s "SELECT id FROM branches WHERE run=? AND parent IS NULL" [(run "id")])))
                                           (def complete (when root (first (store/query s "SELECT id FROM events WHERE branch=? AND kind='completed'" [(root "id")]))))
                                           (unless complete
                                             (store/query s "UPDATE tasks SET state='cancelled' WHERE actor=? AND run=? AND state IN ('queued','running','waiting','uncertain')" [(s :actor) (run "id")])
                                             (unless (first (store/query s "SELECT id FROM events WHERE run=? AND kind='cancelled'" [(run "id")]))
                                               (store/append s {:run (run "id") :branch (when root (root "id"))} "cancelled"
                                                             "Cancellation requested; effects are not rolled back." {:reason (value :reason)})))
                                           {:run (run "id") :state (if complete "completed" "cancelled")})))))

  (defn supervise [bytes opaque]
    (def config (schema/configuration (spec :schema) opaque (pa/imports)))
    (def value (schema/request bytes [:once]))
    (def s (store/open config))
    (defer (store/close s)
      (while true
        (store/recover s)
        (each job (store/query s "SELECT id FROM tasks WHERE actor=? AND state='queued' AND world=? ORDER BY id LIMIT ?"
                               [(s :actor) (config :world) (config :parallel)])
          (spawn-job s (job "id")))
        (when (value :once) (break))
        (ev/sleep 1))
      (string (json/encode {:state "supervised"}))))

  (set operations
       (merge memory/operations
              {"work/inspect"
               {:policy "safe"
                :description "work/inspect job -> owned work and effect receipts."
                :function inspect-job}

               "model/request"
               {:policy "safe"
                :description "model/request request -> granted, accounted model response."
                :function model-request}}))

  {"call" call
   "run-task" run-task
   "receipt" receipt
   "supervise" supervise
   "resume" resume
   "describe" describe
   "document" document-entry
   "events" events
   "invoke" invoke
   "abort" abort
   "pending" pending
   "models" models})
