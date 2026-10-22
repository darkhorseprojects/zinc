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
  (defn message [event]
    (when (event :branch)
      (def data (json/decode (event :data) true true))
      (def origin (data :world-source))
      (def body (case (event :kind)
                  "user" ""
                  "response" (model/render event data)
                  "completed" (if (event :public_message) (model/render event data) (event :text))
                  "model-outcome" (when (data :visible) (model/render event data))
                  "interruption" (when (= "uncertain" (data :state)) (event :text))
                  "saved" (string "Saved " (data :ref) " @ " (string/slice (data :after) 0 7) (when (data :pushed) " · pushed") "\n" (event :text))
                  (when (index-of (event :kind) ["code-admission" "tool-result" "tool-ambiguity" "error"]) (event :text))))
      (when body
        {:type (if (= "user" (event :kind)) "start" "display") :body body :root (nil? (event :branch_parent))
         :language (case (event :kind) "code-admission" "janet" "tool-result" "text" nil)
         :run (event :run) :branch (event :branch) :execution (string (event :request) "/" (event :branch))
         :persist (= 0 (event :branch_temporary)) :event (if (= 0 (event :branch_temporary)) (event :id) :null)
         :sequence (event :id) :author (event :author) :at (event :at)
         :world {:file (event :branch_file) :path (origin :path) :ref (or (data :ref) (origin :ref))
                 :base (origin :base) :revision (or (data :after) (origin :base))}})))

  (defn result [s id]
    (def call (store/call s id))
    (def final (first (store/query s "SELECT * FROM memory_records WHERE branch=? AND kind='completed'" [id])))
    (assert final "call has no completion")
    (def data (json/decode (final :data) true true))
    (merge (tabseq [[key value] :in (pairs (message final)) :unless (index-of key [:body :language])] key value) {:type "result" :final true :text (final :text) :status (get data :status "complete")
                                                                                                                  :message (when (final :public_message) (json/decode (final :public_message) true true))
                                                                                                                  :start (if (= 0 (call :temporary)) (call :admission) :null)
                                                                                                                  :parent (or (call :entry) 0) :memory_range {:start (call :first) :end (call :last)}
                                                                                                                  :tool_usage (store/tool-used s (call :run)) :context_unit "token-estimate"
                                                                                                                  :usage (first (store/query s `SELECT coalesce(sum(u.total),0) reported_total,count(*) FILTER(WHERE u.total IS NULL) unreported
        FROM memory_records e LEFT JOIN usage u ON u.request=e.id WHERE e.source=? AND e.run=? AND e.kind='model-admission'`
                                                                                                                                             [(s :source) (call :run)]))}))

  (defn launch [s id &opt here]
    (when-let [row (store/claim s id)]
      (try
        (cond here ((dyn :zinc/execute) s row)
          (or (s :temporary) (and (= "summarize" (row :kind)) (not (dyn :zinc/background))))
          (ev/go (fn [] ((dyn :zinc/execute) s row)))
          (pa/spawn (merge (dyn :pa/program) {"entry" "task"})
                    (string (json/encode {:task id :owner (row :owner)}))
                    (string (json/encode (dyn :zinc/config))) {:limits (dyn :pa/limits) :emit pa/emit}))
        ([err] (store/append s (store/view s (if (= "summarize" (row :kind)) (row :parent) id))
                             "launch-uncertain" "Call acceptance could not be confirmed." {} nil id))))
    id)

  (defn wait [s id &opt here]
    (def current (dyn :zinc/call))
    (def parked (when current (store/park s true)))
    (defer (when (and parked (= "waiting" (get (first (store/query s "SELECT state FROM main.call_controls WHERE id=?" [(current :id)])) :state))) (store/park s false))
      (label done (while true
                    (store/recover s)
                    (when current (store/checkpoint s))
                    (def row (first (store/query s "SELECT state,kind FROM main.call_controls WHERE id=? AND source=?" [id (s :source)])))
                    (assert row "call unavailable")
                    (case (row :state)
                      "done" (return done (if (= "text" (row :kind)) (result s id)
                                            ((json/decode ((first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])) :data) true true) :value)))
                      "failed" (error ((json/decode ((first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])) :data) true true) :error))
                      "uncertain" (error (string "Call #" id ": uncertain effects; inspect receipts, do not replay."))
                      "cancelled" (error "call cancelled")
                      "queued" (launch s id here))
                    (ev/sleep 0.1)))))

  (defn start-child [s granted value]
    (def view (merge granted (store/view s (granted :branch))))
    (def value (schema/request (postwalk |(if (dictionary? $) (tabseq [[k v] :in (pairs $)] (keyword k) v) $) value)
                               [:text :code :parent :memory_range :persist :revision]))
    (assert (not= (nil? (value :text)) (nil? (value :code))) "self requires text or code")
    (def config (if (value :text) (or ((s :config) :agent) (s :config)) (s :config)))
    (assert (if (value :text) (config :inference) (config :repl)) "child execution is not permitted")
    (def parent (store/call s (view :branch)))
    (put value :author (string "self:" (parent :request) "/" (parent :id)))
    (put value :at (((store/query s "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now') at") 0) :at))
    (put value :persist (get value :persist (= 0 (parent :temporary))))
    (when (= 1 (parent :temporary)) (assert (not (value :persist)) "temporary calls cannot create durable descendants"))
    (def origin (merge (repl/source config (when (parent :file) (merge (json/decode (parent :origin) true true) {:file (parent :file)})) (value :revision))
                       {:ref (string "refs/heads/self/" (string/join (map |(string/format "%02x" $) (os/cryptorand 12))))}))
    (if (value :persist)
      (do
        (when (origin :base) (repl/git (origin :root) ["update-ref" "--stdin"] (string "create " (origin :ref) " " (origin :base) "\n")))
        (def call (store/start s value config (merge view {:event (dyn :zinc/effect) :agent (or (view :agent) (not= config (s :config)))}) origin))
        {:job (call :id) :branch (call :id)})
      (do
        (each id [(get value :parent 0) (get-in value [:memory_range :start] 0) (get-in value [:memory_range :end] 0)]
          (when (> id 0) (store/event s view id)))
        (assert (< (view :depth) (config :task-depth)) "agent recursion ceiling exhausted")
        (def request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))
        (def handle (pa/spawn (merge (dyn :pa/program) {"entry" "self"})
                              (string (json/encode (merge value {:request request :parent (get value :parent (view :last))
                                                                 :memory_range (get value :memory_range {:start (view :first) :end (view :last)})})))
                              (string (json/encode (merge config {:snapshot (merge (store/snapshot s view) {:origin origin})})))
                              {:limits (dyn :pa/limits) :emit pa/emit}))
        (put ((dyn :zinc/call) :children) request handle)
        {:temporary request})))

  (defn run-code [s view bindings code]
    (def config (s :config))
    (assert (config :repl) "Janet execution is not permitted")
    (assert (<= (length code) (config :source-bytes)) "tool source byte ceiling")
    (store/checkpoint s)
    (def current (dyn :zinc/call))
    (unless (current :runtime)
      (os/cd (path/dirname (config :file)))
      (assert (<= (os/stat (current :file) :size) (config :source-bytes)) "world source byte ceiling")
      (put current :runtime (repl/open (current :file) (string (slurp (current :file))) (current :input)
                                       (repl/instructions config view (spec :document) bindings)
                                       (seq [[name binding] :in (sorted (pairs bindings))] {:name name :doc (binding :doc)}) (config :forbid) (config :response-bytes))))
    (repl/execute (current :runtime) code (fn [name args]
                                            (store/checkpoint s)
                                            (if (= name "await")
                                              (let [handle (first args) current (dyn :zinc/call)]
                                                (assert (dictionary? handle) "await requires a self handle")
                                                (if (handle :temporary)
                                                  (let [child ((current :children) (handle :temporary))]
                                                    (assert child "temporary self is not owned by this call")
                                                    (def parked (store/park s true))
                                                    (defer (when parked (store/park s false)) (json/decode (pa/await child) true true)))
                                                  (do
                                                    (assert (and (int? (handle :job)) (not= (current :id) (handle :job))
                                                                 (first (store/query s `WITH RECURSIVE parents(id) AS (SELECT parent FROM main.call_controls WHERE id=? AND source=?
                  UNION SELECT c.parent FROM main.call_controls c JOIN parents p ON c.id=p.id WHERE c.parent IS NOT NULL)
                  SELECT id FROM parents WHERE id=?` [(handle :job) (s :source) (current :id)]))) "await requires descendant work")
                                                    (wait s (handle :job)))))
                                              (let [admission (store/transact s (store/charge s 1 0)
                                                                              (store/append s view "call-admission" name {:arguments args} nil ((dyn :zinc/call) :id)))]
                                                (def value (if (= name "self")
                                                             (let [handle (with-dyns [:zinc/effect (admission :id)] (start-child s view (first args)))]
                                                               (when (handle :job) (launch s (handle :job))) handle)
                                                             (let [binding (bindings name)]
                                                               (assert binding "function revoked")
                                                               (with-dyns [:zinc/context [s view] :capability/config (binding :config)] (apply (binding :value) args)))))
                                                (store/transact s (store/checkpoint s)
                                                                (store/append s view "operation-outcome" name {:value value} (admission :id) ((dyn :zinc/call) :id)))
                                                value)))
                  (min (config :seconds) (max 0.001 (- (view :expires) (os/clock))))))

  (defn infer [s call bindings]
    (def id (call :id))
    (def config (s :config))
    (def inherited (store/view s id false))
    (def selected (model/profile s (config :chat) :chat))
    (def evaluate (and (config :repl) (selected :tools)))
    (def system (repl/instructions config (merge inherited {:tools evaluate}) (spec :document) bindings))
    (def user (first (store/query s "SELECT * FROM memory_records WHERE task=? AND kind='user'" [id])))
    (def inquiry {:role "user" :content (model/images s (user :id) (memory/render user))})
    (def tool-size (if evaluate (store/estimate (json/encode [model/tool])) 0))
    (def capacity (min (get config :context-quota math/inf) (- (selected :context) 256)))
    (def space (- capacity (model/estimate [{:role "system" :content system} inquiry]) tool-size 256))
    (assert (> space 256) "question and instructions exhaust context")
    (def progress ((dyn :zinc/call) :checkpoint))
    (def pool (or (progress :semantic)
                  (let [pending (when (progress :request) (first (store/query s "SELECT id FROM events WHERE id=? AND json_extract(data,'$.input.role')='rerank'" [(progress :request)])))
                        rows (memory/semantic-window s inherited (user :text) (when pending (pending :id)))]
                    (store/checkpoint s {:semantic rows}) rows)))
    (var context (memory/context s inherited space pool))
    (while (not (first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])))
      (def responses (store/query s "SELECT id FROM memory_records WHERE task=? AND kind='response' ORDER BY id" [id]))
      (each tool (store/query s "SELECT * FROM unresolved_tools WHERE branch=?" [id])
        (store/append s (store/view s id) "tool-ambiguity" "Interrupted evaluation; effects may have happened. Inspect before repeating."
                      {:tool-id (tool :tool_id) :response (tool :response) :ok false :uncertain true} (tool :response) id))
      (assert (< (length responses) (config :rounds)) "model round limit exhausted")
      (def view (store/view s id))
      (def final-round (= (+ 1 (length responses)) (config :rounds)))
      (def messages @[])
      (while true
        (array/clear messages) (array/push messages {:role "system" :content system})
        (each [title text] [["History" (string/join (map |($ :rendered) (context :nodes)))] ["Retrieved text" (string/join (context :evidence))]]
          (when (> (length text) 0) (array/push messages {:role "user" :content (string "## " title "\n\n" text)})))
        (array/push messages inquiry)
        (each record (store/query s "SELECT conversation_message FROM conversation_records WHERE branch=? AND id>? ORDER BY id" [id (context :through)])
          (array/push messages (json/decode (record :conversation_message) true true)))
        (when final-round (array/push messages {:role "system" :content "Tool calls are unavailable in this inference round."}))
        (when (<= (+ (model/estimate messages) (if final-round 0 tool-size)) capacity) (break))
        (assert (< (context :through) (view :last)) "context metadata cannot fit")
        (set context (memory/context s (merge view {:exclude [(user :id)]}) space pool)))
      (def pending (get-in (dyn :zinc/call) [:checkpoint :request]))
      (def response (model/call s {:turn true :model (config :chat) :messages messages :tools (when (and evaluate (not final-round)) [model/tool])}
                                (when (and pending (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='model-outcome'" [pending])))) pending) selected))
      (assert (not (index-of (response :status) ["invalid" "truncated"])) (string "Model response " (response :status) ": " (response :error)))
      (each tool (response :tools)
        (def admission (store/transact s (store/checkpoint s) (store/charge s 1 (store/estimate (tool :code)))
                                       (store/append s view "code-admission" (tool :code) {:tool-id (tool :id) :response (response :event)} nil id)))
        (def outcome (try {:ok true :text (run-code s view bindings (tool :code))}
                       ([err] (when (or (= err "deadline expired") (string/has-prefix? "World evaluator stopped:" (string err))) (error err)) {:ok false :text (string err)})))
        (store/charge s 0 (store/estimate (json/encode outcome)))
        (store/transact s (store/checkpoint s)
                        (store/append s view "tool-result" (outcome :text) {:ok (outcome :ok) :tool-id (tool :id) :response (response :event)} (admission :id) id))))
    (unless (s :temporary)
      (try (with-dyns [:zinc/background true] (memory/context s (store/view s id) space pool true))
        ([err] (store/append s (store/view s id) "launch-uncertain" "Background compaction preparation failed." {:error (string err)}))))
    {:completion ((first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])) :id)})

  (defn execute [store row]
    (def config (if (and (= 1 (row :agent)) ((store :config) :agent)) ((store :config) :agent) (store :config)))
    (def s (merge store {:config config :budget-root (or (row :root) (row :id))}))
    (def id (row :id))
    (def view (store/view s (if (= "summarize" (row :kind)) (row :parent) id)))
    (def stop (ev/thread-chan 1))
    (def finished (ev/thread-chan 1))
    (ev/thread store/heartbeat [(config :store) (config :lease-seconds) id (row :owner) stop] :n finished)
    (defer (do (ev/give stop true) (ev/take finished))
      (with-dyns [:zinc/call (merge row {:scope view :children @{} :input (json/decode (row :input) true true)
                                         :checkpoint (json/decode (row :checkpoint) true true)}) :zinc/effect (row :admission)]
        (store/transact s
                        (store/checkpoint s)
                        (store/append s view "call-attempt" "execution entered" {:attempt (row :attempt)} nil id))
        (var value nil) (var failure nil)
        (try
          (do
            (def input ((dyn :zinc/call) :input))
            (def bindings (if (and (not= "summarize" (row :kind)) (config :repl)) (repl/definitions config (spec :capabilities)) {}))
            (set value (case (row :kind) "text" (infer s row bindings)
                         "code" (run-code s view bindings (input :code)) "summarize" (memory/summarize s row input)))
            (when (= "code" (row :kind)) (store/charge s 0 (store/estimate (json/encode value)))))
          ([err fiber]
            (set value nil)
            (def trace @"")
            (with-dyns [:err (fn [bytes] (buffer/push-string trace (string/slice bytes 0 (min (length bytes) (- (config :response-bytes) (length trace))))))]
              (debug/stacktrace fiber))
            (set failure @{:error (string err) :trace (string trace)})
            (each provider (values (config :providers))
              (when (provider :token) (each key [:error :trace] (put failure key (string/replace-all (provider :token) "[redacted]" (failure key))))))))
        (when-let [runtime ((dyn :zinc/call) :runtime)] (repl/close runtime))
        (store/finish s row value failure)
        (each pending (store/query s "SELECT c.id FROM main.call_controls c JOIN call_payloads p ON p.id=c.id WHERE c.source=? AND p.run=? AND c.state='queued' AND c.expires>? ORDER BY c.id LIMIT ?"
                                   [(s :source) (row :run) (os/clock) (config :parallel)]) (launch s (pending :id))))))

  (defn drain [s run after]
    (var sequence after)
    (while true
      (def records (memory/events s run sequence))
      (each event records
        (when-let [frame (message event)] (pa/emit (string (json/encode frame))))
        (set sequence (event :id)))
      (when (< (length records) 256) (break)))
    sequence)

  (defn run [s value operation]
    (def existing (first (store/query s "SELECT * FROM calls WHERE source=? AND (id=? OR request_key=?)" [(s :source) (or (value :task) (value :run)) (value :request)])))
    (when (index-of operation ["task" "resume"]) (assert existing "call unavailable"))
    (when existing
      (assert (= 0 (existing :temporary)) "temporary execution cannot be reattached")
      (assert (and (= (existing :world) ((s :config) :world)) (= 0 (existing :cancelled))) "saved call unavailable")
      (put s :config (schema/authorize (spec :schema) (s :config) (json/decode (existing :config) true true)))
      (put s :budget-root (or (existing :root) (existing :id)))
      (store/query s "UPDATE main.call_controls SET expires=min(expires,(SELECT created FROM events WHERE call=call_controls.id AND kind='user')+?) WHERE id=?"
                   [((s :config) :run-seconds) (existing :run)]))
    (with-dyns [:zinc/wait wait :zinc/spawn launch :zinc/execute execute :zinc/config (s :config)]
      (store/recover s)
      (if (= operation "task")
        (do (assert (= (value :owner) (existing :owner)) "call ownership changed") (execute s existing) {:task (value :task)})
        (do
          (unless (= operation "resume")
            (assert (and (value :author) (value :at) (not= (nil? (value :text)) (nil? (value :code)))) "self requires text or code, authenticated author and occurrence time")
            (assert (if (value :text) ((s :config) :inference) ((s :config) :repl)) "execution is not permitted in this view")
            (unless (value :request) (put value :request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))))
          (def call (if (= operation "resume") existing (store/start s value (s :config) nil
                                                                     (unless existing (or (get-in (s :config) [:snapshot :origin]) (repl/source (s :config) nil (value :revision)))))))
          (def id (call :id))
          (var sequence (drain s (call :run) (get value :after 0)))
          (if (first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])) (result s id)
            (do
              (when (= operation "resume")
                (assert (and (= "text" (call :kind)) (> (call :expires) (os/clock))) "call requires reconciliation or its deadline expired")
                (store/query s "UPDATE main.call_controls SET state='queued',retries=1,owner=NULL,lease_expires=NULL WHERE id=? AND state IN ('failed','uncertain')" [id]))
              (def emitter (ev/go (fn [] (try (while true (set sequence (drain s (call :run) sequence)) (ev/sleep 0.1)) ([err] nil)))))
              (defer (ev/cancel emitter "observer detached")
                (wait s id true)
                (drain s (call :run) sequence)
                (result s id))))))))

  (defn describe [config]
    {:contract "inquiry-v3" :profile {:field "agent" :inference "inference"}
     :parameters (catseq [[target fields] :in [[:config (spec :schema)] [:input (spec :input)]]]
                   (seq [[key field] :in (sorted (pairs fields)) :when (field :option)]
                     (def parameter (merge (tabseq [[k v] :in (pairs field) :unless (index-of k [:optional :option])] k v)
                                           {:name (field :option) :path (string target "." key) :type (string (field :type)) :default (get config key (get field :default "automatic"))}))
                     (when (and (= target :config) (= :integer (field :type)) (> (config key) 0)) (put parameter :maximum (config key))) parameter))})

  (tabseq [[operation fields] :in [["self" (keys (spec :input))] ["task" [:task :owner]] ["resume" [:run :request :after]]
                                   ["describe" []] ["document" []] ["models" [:role]] ["events" [:run :after]] ["record" [:records]] ["pending" [:request]] ["abort" [:run :request :reason]] ["invalidate" [:event]]]]
    operation (fn [bytes opaque]
                (def config (schema/configuration (spec :schema) (json/decode opaque true true) (= operation "describe")))
                (assert (and (utf8/is-valid? bytes) (<= (length bytes) (config :request-bytes))) "request must be bounded UTF-8")
                (when (index-of operation ["describe" "document"]) (assert (= "" bytes) "operation takes empty input"))
                (def value (if (and (= "" bytes) (index-of operation ["describe" "document" "pending"])) {} (schema/request (json/decode bytes true true) fields)))
                (def s (unless (index-of operation ["describe" "document" "models"]) (store/open config (and (= operation "self") (= false (get value :persist true))))))
                (defer (when s (store/close s))
                  (with-dyns [:zinc/config config]
                    (def output (case operation
                                  "describe" (describe config)
                                  "document" (repl/instructions config {} (spec :document) (repl/definitions config (spec :capabilities)))
                                  "models" (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get value :role "chat")))
                                  "record" {:events (store/record s (value :records))}
                                  "invalidate" {:event ((memory/invalidate s (value :event)) :id)}
                                  "abort" (store/abort s value)
                                  "events" (let [records (memory/events s (value :run) (get value :after 0))]
                                             {:events (filter identity (map message records)) :after (get (last records) :id (get value :after 0)) :more (= 256 (length records))})
                                  "pending" (do (store/recover s)
                                              (store/query s `SELECT c.id run,c.request,c.id branch,c.id job,c.state,CASE WHEN c.kind='text' THEN 'agent' ELSE c.kind END kind,c.attempt,
                (SELECT id FROM events WHERE call=c.id AND kind IN ('user','summary-input')) admission,
                (SELECT id FROM events WHERE call=c.id AND kind='call-result' ORDER BY id DESC LIMIT 1) outcome,
                CASE WHEN c.temporary OR c.kind='code' THEN 'manual' ELSE 'retry' END retry_policy,c.expires run_expires,c.lease_expires,c.temporary
                FROM main.call_controls c WHERE c.request IS NOT NULL AND c.source=? AND c.world=? AND (? IS NULL OR c.request=?)
                AND (? IS NOT NULL OR c.state IN ('queued','running','waiting','failed','uncertain','cancelled')) ORDER BY c.id`
                                                           [(s :source) (config :world) (value :request) (value :request) (value :request)]))
                                  (run s value operation)))
                    (if (= operation "document") output (string (json/encode output))))))))
