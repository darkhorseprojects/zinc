(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)
(import spork/base64 :as base64)
(import portable-agents/protocol :as wire)
(import portable-agents/markdown :as markdown)
(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./world)
(import ./io)

(defn- recover [s &opt force]
  (when (or force (>= (os/clock) ((s :recovery) 0)))
    (put (s :recovery) 0 (+ (os/clock) store/interval))
    (unless (s :temporary) (world/reconcile s))
    (store/recover s)
    (unless (s :temporary) (world/materialize s))))

(defn- events [s run after &opt through]
  (store/query s `SELECT id,parent,run,branch,branch_temporary,branch_parent,request,kind,text,public_message,
    json_remove(data,'$.message','$.input','$.request','$.views','$.text') data FROM memory_records
    WHERE run=? AND id>? AND (? IS NULL OR id<=?)
      AND kind IN ('response','completed','model-outcome','interruption','artifact','saved','summary',
                   'code-admission','tool-result','tool-ambiguity','error','launch-uncertain') ORDER BY id LIMIT ?`
               [run (if (s :temporary) (max after (s :archive-last)) after) through through (if through -1 256)]))

(defn- message [event config]
  (when (event :branch)
    (def data (json/decode (event :data) true true))
    (def origin (data :world))
    (def durable (= 0 (event :branch_temporary)))
    (def body (case (event :kind)
      "response" (model/render event)
      "completed" (if (event :public_message) (model/render event) (event :text))
      "model-outcome" (when (and (= "chat" (data :role)) (data :visible)) (model/render event))
      "interruption" (when (= "uncertain" (data :state)) (event :text))
      "artifact" (when (data :display) (event :text))
      "saved" (string "Saved " (data :ref) " @ " (string/slice (data :base) 0 7) "\n" (event :text))
      "summary" (string "summary " (if durable "#" "local ") (event :id) " · " (data :count)
                        " records · source range " (data :first) "–" (data :last))
      (when (and (not= false (data :display)) (index-of (event :kind) ["code-admission" "tool-result" "tool-ambiguity" "error" "launch-uncertain"]))
        (if-let [failure (data :error)]
          (string/trim (string (get-in failure [:context :output] "") "\n" (failure :code) ": " (failure :message))) (event :text)))))
    (when body
      (merge {:body (if (and (event :public_message) (data :status) (not (index-of (data :status) ["complete" "tools"])))
               (string body "\n\n[" (data :status) "]") body)
       :kind (event :kind) :agent (config :identity)
       :caller (if-let [parent (event :branch_parent)]
                 {:agent (config :identity) :request (event :request) :branch parent} (or (config :caller) :null))
       :prompt (if (or (data :turn) (= "model-outcome" (event :kind))) (event :parent) :null)
       :related (if (and (not (data :turn)) (index-of (event :kind) ["tool-result" "tool-ambiguity" "completed"])) (or (event :parent) :null) :null)
       :status (or (data :status) (case (event :kind) "code-admission" "admitted" "error" "failed" "tool-ambiguity" "uncertain" "launch-uncertain" "uncertain" "interruption" "uncertain"
                                  (if (or (data :error) (= false (data :ok))) "failed" "complete")))
       :run (event :run) :branch (event :branch) :request (event :request)
       :persist durable :sequence (event :id)
       :world {:path (origin :path) :blob (or (data :blob) (origin :blob)) :ref (or (data :ref) (origin :ref))}}
             (when (data :error) {:diagnostic (data :error)})))))

(defn- receipt [call]
  {:type "admission" :run (call :run) :branch (call :id) :request (call :request)
   :persist (= 0 (call :temporary))})

(defn- observe [s call progress]
  (print (json/encode (receipt call)))
  (put progress 1 true)
  (while true
    (def pending (store/query s `SELECT c.state,c.lease_expires,
      min(coalesce(c.expires,1e999),coalesce(r.expires,1e999)) expires FROM main.call_controls c
      JOIN main.call_controls r ON r.id=coalesce(c.root,c.id) JOIN call_payloads p ON p.id=c.id
      WHERE p.run=? AND c.kind<>'summarize' AND c.state IN ('queued','running','waiting')` [(call :run)]))
    (while true
      (def records (events s (call :run) (progress 0)))
      (each event records
        (when-let [frame (message event (s :config))] (print (json/encode frame)))
        (put progress 0 (event :id)))
      (when (< (length records) 256) (break)))
    (when (= 0 (length pending)) (break))
    (each row pending
      (assert (and (> (row :expires) (os/clock))
                   (or (= "queued" (row :state)) (> (row :lease_expires) (os/clock))))
              "executor lease or deadline expired; inspect before resuming"))
    (ev/sleep store/interval))
  (store/result s (call :id)))

(defn make [spec]
  (defn worker [entry input config]
    (def limits (dyn :pa/limits))
    (def process (os/spawn [(dyn :pa/executable) "run" (string (limits "frameBytes")) (string (limits "admissionSeconds"))]
                           :d {:in :pipe :out :pipe :err stderr}))
    (def exited (ev/chan 1))
    (ev/go (fn [] (os/proc-wait process)) nil exited)
    (try
      (do
        (defer (ev/close (process :in))
          (wire/send (process :in) (wire/request {"version" wire/version "program" (merge (dyn :pa/program) {"entry" entry})
                                                  "input" (wire/base64 (string (json/encode input)))
                                                  "config" (wire/base64 (string (json/encode config)))})))
        (def reader (wire/reader (process :out) true))
        (ev/with-deadline (limits "admissionSeconds") (wire/output reader true))
        [process reader exited])
      ([err] (ev/close (process :out)) (error err))))

  (defn launch [s id &opt here]
    (when-let [row (store/claim s id)]
      (try
        (cond here ((dyn :zinc/execute) s row)
          (or (s :temporary) (= "summarize" (row :kind)))
          (ev/go (fn [] ((dyn :zinc/execute) s row)))
          (let [[process] (worker "task" {:task id :owner (row :owner)} (dyn :zinc/config))]
            (ev/close (process :out))))
        ([err] (store/append s (store/view s (if (= "summarize" (row :kind)) (row :parent) id))
                             "launch-uncertain" "Call acceptance could not be confirmed." {:error err} nil id))))
    id)

  (defn wait [s id &opt mode]
    (def current (dyn :zinc/call))
    (when current
      (when (= 0 (get current :waiters 0)) (store/park s true))
      (put current :waiters (+ 1 (get current :waiters 0))))
    (defer (when current
             (put current :waiters (- (current :waiters) 1))
             (when (and (= 0 (current :waiters)) (= "waiting" (get (first (store/query s "SELECT state FROM main.call_controls WHERE id=?" [(current :id)])) :state)))
               (store/park s false)))
      (if (string? id)
        (let [child ((current :children) id)]
          (assert child "temporary self is not owned by this call")
          (def [worker done] child)
          (unless (index-of (fiber/status worker) [:dead :error]) (ev/take done))
          (put (current :children) id nil)
          (unless (= :dead (fiber/status worker)) (propagate (fiber/last-value worker) worker))
          (fiber/last-value worker))
        (label done (while true
                      (recover s (dictionary? id))
                      (when current (store/checkpoint s))
                      (if (dictionary? id)
                        (let [root (id :root)
                              pending (store/query s `SELECT c.id,c.state,c.owner,c.lease_expires,p.run,
                                min(coalesce(c.expires,1e999),coalesce(r.expires,1e999)) expires FROM main.call_controls c
                                JOIN main.call_controls r ON r.id=coalesce(c.root,c.id) LEFT JOIN call_payloads p ON p.id=c.id
                                WHERE (? IS NULL OR c.root=?)
                                AND (c.state IN ('queued','running','waiting') OR (? IS NULL AND (c.state='uncertain' OR c.owner IS NOT NULL))) ORDER BY c.id` [root root root])]
                          (unless root
                            (each row pending (assert (and (not= "uncertain" (row :state))
                              (or (nil? (row :owner)) (> (row :lease_expires) (os/clock)))) "instance has unsettled effects; preserve it for inspection")))
                          (when (= 0 (length pending)) (return done {:settled true}))
                          (each row pending
                            (when (and (= "queued" (row :state)) (or (nil? (id :run)) (= (id :run) (row :run)))) (launch s (row :id)))))
                        (let [row (first (store/query s `SELECT c.state,c.kind,c.lease_expires,
                                min(coalesce(c.expires,1e999),coalesce(r.expires,1e999)) expires FROM main.call_controls c
                                JOIN main.call_controls r ON r.id=coalesce(c.root,c.id) WHERE c.id=?` [id]))]
                          (assert row "call unavailable")
                          (case (row :state)
                            "done" (return done ((store/result s id) :value))
                            "failed" (error ((store/result s id) :error))
                            "uncertain" (error (string "Call #" id ": uncertain effects; inspect receipts, do not replay."))
                            "cancelled" (error "call cancelled")
                            "queued" (launch s id (= mode :inline)))))
                      (ev/sleep store/interval))))))

  (defn start-child [s view value &opt snapshot]
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
    (def origin (cond (value :revision) (world/resolve config nil (value :revision))
                      snapshot (world/image s (store/origin s (parent :id)) (snapshot :image) (not (value :persist)))
                      (world/resolve config (or ((dyn :zinc/call) :candidate) (store/origin s (parent :id))))))
    (if (or (value :persist) (s :temporary))
      (do
        (unless (s :temporary) (world/git (origin :root) ["update-ref" (string "refs/zinc/world/" (origin :blob)) (origin :blob)]))
        (def call (store/start s value config (merge view {:event (dyn :zinc/effect) :agent (or (view :agent) (not= config (s :config)))}) origin))
        {:job (call :id) :branch (call :id)})
      (do
        (each id [(get value :parent 0) (get-in value [:memory_range :start] 0) (get-in value [:memory_range :end] 0)]
          (when (> id 0) (store/event s view id)))
        (assert (< (view :depth) (config :task-depth)) "agent recursion ceiling exhausted")
        (def request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))
        (def entry (get value :parent (view :last)))
        (def slots (s :temporary-slots))
        (ev/give slots true)
        (def [process reader exited]
          (try (worker "self" (merge value {:request request :parent entry
                                       :memory_range (get value :memory_range {:start (if (= 0 entry) 0 (view :first)) :end entry})})
                  (merge config {:snapshot {:origin origin :image (base64/encode (world/bytes s origin))
                                            :depth (+ 1 (view :depth)) :deadline (view :expires)
                                            :budget-root (s :budget-root) :silent true}}))
            ([err] (ev/take slots) (error err))))
        (def done (ev/chan 1))
        (def collector (ev/go (fn []
          (defer (do (ev/close (process :out)) (ev/take slots))
            (def output (json/decode (wire/output reader) true true))
            (ev/take exited)
            (assert (= 0 (process :return-code)) "ProcessFailure")
            (when (output :error) (error (output :error)))
            (assert (= "done" (output :state)) (string "Temporary call ended " (output :state)))
            (output :value))) nil done))
        (put ((dyn :zinc/call) :children) request [collector done])
        {:temporary request})))

  (defn run-code [s view bindings scripts]
    (def config (s :config))
    (assert (config :repl) "Janet execution is not permitted")
    (each script scripts (assert (<= (length (script :code)) (config :source-bytes)) "tool source byte ceiling"))
    (store/checkpoint s)
    (def current (dyn :zinc/call))
    (os/cd (path/dirname (config :world)))
    (def origin (world/resolve config (store/origin s (current :id))))
    (put current :candidate nil)
    (def public (world/public config (spec :schema) bindings))
    (store/checkpoint s (merge (current :checkpoint) {:runtime true}))
    (def outcome (world/run (world/bytes s origin) (current :input) (world/instructions config (spec :document) bindings public) public
                  (tabseq [[name binding] :in (pairs bindings)] name (if (binding :local) binding {:doc (binding :doc)}))
                  {:world (config :world-bytes) :output (config :response-bytes)} (config :repl) scripts
                  (let [run (if (view :expires) (max 0.001 (- (view :expires) (os/clock))) math/inf)
                        seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds)) run)]
                    (if (= seconds math/inf) 0 seconds))
                  (fn [name args snapshot]
                    (store/checkpoint s)
                    (def view (store/view s (current :id)))
                    (def binding (bindings name))
                    (assert (and binding (not (binding :local))) "function revoked")
                    (def origin (when (and snapshot (not= name "self"))
                                  (world/image s (store/origin s (current :id)) (snapshot :image) (= name "world/view"))))
                    (when (get binding :intrinsic) (assert (= 1 (length args)) "invalid intrinsic arity"))
                    (let [admission (store/transact s (store/charge s 1 0)
                                                      (store/append s view "call-admission" name {:arguments args} (dyn :zinc/effect) ((dyn :zinc/call) :id)))]
                        (def args (schema/data args))
                        (def value
                          (cond
                            (or (= name "save") (string/has-prefix? "world/" name))
                            (do
                              (assert (<= (length args) 1) "invalid world operation arity")
                              (with-dyns [:zinc/call (merge current {:candidate origin})]
                                (world/operate s {:action (if (= name "save") "save" (string/slice name 6))
                                               :message (when (index-of name ["save" "world/save"]) (first args))
                                               :point (when (= name "world/view") (first args))
                                               :commit (when (= name "world/switch") (first args))})))
                            (= name "self")
                            (let [handle (with-dyns [:zinc/effect (admission :id)] (start-child s view (first args) snapshot))]
                              (when (handle :job) (launch s (handle :job)))
                              (wait s (or (handle :temporary) (handle :job))))
                            (index-of name ["fs/list" "fs/read" "fs/write" "http/request" "process/run"])
                            (io/invoke config name args)
                            (with-dyns [:zinc/context [s view]
                                        :pa/operation (string (view :run) "/" (view :branch) "/" (admission :id))]
                              (apply (binding :value) args))))
                        (store/transact s (store/checkpoint s)
                                        (store/append s view "operation-outcome" name {:value value} (admission :id) ((dyn :zinc/call) :id)))
                        (schema/data value)))))
    (put current :candidate (or (outcome :replacement)
                               (world/image s (store/origin s (current :id)) (outcome :image))))
    (outcome :values))

  (defn infer [s call bindings]
    (def id (call :id))
    (def config (s :config))
    (def inherited (store/view s id false))
    (def selected (model/profile s (config :chat) :chat))
    (def tools (filter |(or (config :repl) (not= "function" ($ :type))) (selected :tools)))
    (def system (world/instructions config (spec :document) (when (find |(= "function" ($ :type)) tools) bindings) (world/public config (spec :schema) bindings)))
    (def user (first (store/query s "SELECT * FROM memory_records WHERE task=? AND kind='user'" [id])))
    (def image-budget @[(config :image-bytes)])
    (def inquiry {:role "user" :content (model/images s [(user :id)] (memory/render user) image-budget)})
    (def image-room (image-budget 0))
    (def tool-size (if (> (length tools) 0) (store/estimate (json/encode tools)) 0))
    (def capacity (min (get config :context-quota math/inf) (- (selected :context) 256)))
    (var space 0) (var context nil)
    (def progress ((dyn :zinc/call) :checkpoint))
    (def pool (or (progress :semantic)
                  (let [pending (when (progress :request) (first (store/query s "SELECT id FROM events WHERE id=? AND json_extract(data,'$.input.role')='rerank'" [(progress :request)])))
                        rows (memory/semantic-window s inherited (user :text) (when pending (pending :id)))]
                    (store/checkpoint s {:semantic rows}) rows)))
    (while (not (first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])))
      (store/checkpoint s)
      (def responses (store/query s "SELECT id FROM memory_records WHERE task=? AND kind='response' ORDER BY id" [id]))
      (each tool (store/query s "SELECT * FROM unresolved_tools WHERE branch=?" [id])
        (store/append s (store/view s id) "tool-ambiguity" "Interrupted evaluation; effects may have happened. Inspect before repeating."
                      {:tool-id (tool :tool_id) :response (tool :response) :ok false :uncertain true} (tool :response) id))
      (assert (< (length responses) (config :rounds)) "model round limit exhausted")
      (def view (store/view s id))
      (def world (when (config :repl) {:role "user" :content (markdown/render {:name "World source" :level 2 :content [{:language "janet" :text ((world/operate s {:action "view"}) :text)}]})}))
      (set space (- capacity (model/estimate (filter identity [{:role "system" :content system} world inquiry])) tool-size 256))
      (assert (> space 256) "question, world bindings and instructions exhaust context")
      (unless context (set context (memory/context s inherited space pool)))
      (def messages @[]) (def views @{})
      (while true
        (put image-budget 0 image-room)
        (array/clear messages) (array/push messages {:role "system" :content system})
        (table/clear views) (put views :through (context :through))
        (each [key title rows] [[:chronological "Chronological memory" (context :nodes)] [:semantic "Retrieved excerpts" (context :evidence)]]
          (def text (string/join (map |($ :rendered) rows)))
          (put views key @{:message (when (> (length text) 0) (length messages))
                           :records (seq [row :in rows] (schema/project row [:id :label :first :last :children :offset :next :total :score]))})
          (when (> (length text) 0)
            (array/push messages {:role "user" :content (model/images s (map |($ :id) rows) (string "## " title "\n\n" text) image-budget)})))
        (put (views :semantic) :cutoff (config :score))
        (put (views :semantic) :candidates (seq [row :in pool] {:id (row :id) :score (row :score) :rerank (row :rerank)}))
        (when world (array/push messages world))
        (array/push messages inquiry)
        (each record (store/query s "SELECT conversation_message,json_extract(data,'$.status') status FROM conversation_records WHERE branch=? AND id>? ORDER BY id" [id (context :through)])
          (array/push messages (json/decode (record :conversation_message) true true))
          (when (= "continue" (record :status))
            (array/push messages {:role "system" :content "Continue the inquiry."})))
        (when (<= (+ (model/estimate messages (selected :reference)) tool-size) capacity) (break))
        (assert (< (context :through) (view :last)) "context metadata cannot fit")
        (set context (memory/context s (merge view {:exclude [(user :id)]}) space pool)))
      (def pending (get-in (dyn :zinc/call) [:checkpoint :request]))
      (def response (model/call s {:turn true :model (config :chat) :messages messages :views views :tools (when (> (length tools) 0) tools)}
                                (when (and pending (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='model-outcome'" [pending])))) pending) selected))
      (def work (store/transact s
                  (store/checkpoint s)
                  (seq [tool :in (response :tools)]
                    (store/charge s 1 (if (tool :error) 0 (store/estimate (tool :code))))
                    [tool (store/append s view (if (tool :error) "call-admission" "code-admission")
                                        (if (tool :error) "run_janet" (tool :code))
                                        {:tool-id (tool :id) :response (response :event)} nil id)])))
      (def scripts (seq [[tool admission] :in work :unless (tool :error)] {:code (tool :code) :event (admission :id)}))
      (def batch (try {:values (if (= 0 (length scripts)) [] (run-code s view bindings scripts))}
                     ([err fiber]
                       (put (dyn :zinc/call) :candidate nil)
                       {:error (wire/diagnostic "ToolBatchFailed" err fiber)})))
      (var index 0)
      (def outcomes (seq [[tool admission] :in work]
                      (def failure (or (tool :error) (batch :error)))
                      (def outcome (if failure
                                     {:ok false :text (string (failure :code) ": " (failure :message)) :error failure}
                                     {:ok true :text ((batch :values) index)}))
                      (unless (tool :error) (++ index))
                      [tool admission outcome]))
      (store/transact s
        (store/checkpoint s)
        (when (and (> (length scripts) 0) (not (batch :error))) (store/publish s ((dyn :zinc/call) :candidate)))
        (each [tool admission outcome] outcomes
          (store/charge s 0 (store/estimate (outcome :text)))
          (store/append s view "tool-result" (outcome :text)
                        (merge outcome {:text nil :tool-id (tool :id) :response (response :event) :display true}) (admission :id) id))))
    {:completion ((first (store/query s "SELECT id FROM memory_records WHERE branch=? AND kind='completed'" [id])) :id)})

  (defn execute [store row]
    (def config (if (and (= 1 (row :agent)) ((store :config) :agent)) ((store :config) :agent) (store :config)))
    (def s (merge store {:config config :budget-root (or (row :root) (row :id)) :temporary-slots (ev/chan (config :parallel))}))
    (def id (row :id))
    (def view (store/view s (if (= "summarize" (row :kind)) (row :parent) id)))
    (def stop (ev/thread-chan 1))
    (def finished (ev/thread-chan 1))
    (ev/thread store/heartbeat [(store :file) (config :lease-seconds) id (row :owner) stop] :n finished)
    (defer (do (ev/give stop true) (ev/take finished))
      (with-dyns [:zinc/call (merge row {:database (s :file) :scope view :children @{} :input (json/decode (row :input) true true)
                                         :checkpoint (json/decode (row :checkpoint) true true)}) :zinc/effect (row :admission)]
        (def [value failure]
          (try
            (do
              (store/transact s
                (store/checkpoint s)
                (store/append s view "call-attempt" (if (= "code" (row :kind)) (get-in (dyn :zinc/call) [:input :code]) "execution entered") {:attempt (row :attempt)} nil id))
            (let [input ((dyn :zinc/call) :input)
                  bindings (if (not= "summarize" (row :kind)) (world/definitions config (spec :bindings)) {})
                  owner (fiber/root)
                  stopped (ev/chan 1)
                  watcher (ev/go (fn [] (try (while true (store/checkpoint s) (ev/sleep store/interval))
                                            ([err] (unless (= err :finished) (ev/cancel owner err))))) nil stopped)]
              (defer (do (ev/cancel watcher :finished) (ev/take stopped))
                (def value (case (row :kind) "text" (infer s row bindings)
                            "code" (first (run-code s view bindings [{:code (input :code) :event (row :admission)}]))
                            "summarize" (memory/summarize s row input)))
                (each child (store/query s "SELECT id FROM main.call_controls WHERE parent=? AND kind<>'summarize' AND state IN ('queued','running','waiting','uncertain') ORDER BY id" [id])
                  (wait s (child :id)))
                (when (= "code" (row :kind)) (store/charge s 0 (store/estimate (json/encode value))))
                [value nil])))
            ([err fiber]
              (def tokens (keep |(when ($ :token-env) (os/getenv ($ :token-env))) (values (config :providers))))
              [nil {:error (postwalk (fn [value]
                                       (if (string? value) (reduce (fn [text token] (string/replace-all token "[redacted]" text)) value tokens) value))
                                     (wire/diagnostic "ExecutionFailed" err fiber))}])))
        (when (first (store/query s "SELECT id FROM main.live_calls WHERE id=? AND owner=?" [id (row :owner)]))
          (each request (keys ((dyn :zinc/call) :children))
            (try (wait s request) ([err fiber] (store/append s view "artifact" "Temporary child failed."
                                      {:display true :error (wire/diagnostic "ChildFailed" err fiber)} nil id)))))
        (try
          (store/transact s
                          (unless failure
                            (store/checkpoint s (schema/project ((dyn :zinc/call) :checkpoint) [:runtime] true)))
                          (when (and (nil? failure) (= "code" (row :kind))) (store/publish s ((dyn :zinc/call) :candidate)))
                          (store/finish s row value failure))
          ([err fiber]
            (store/finish s row nil {:error (wire/diagnostic "CommitFailed" err fiber)})))
        (each pending (store/query s "SELECT c.id FROM main.call_controls c JOIN call_payloads p ON p.id=c.id WHERE p.run=? AND c.state='queued' AND (c.expires IS NULL OR c.expires>?) ORDER BY c.id LIMIT ?"
                                   [(row :run) (os/clock) (config :parallel)]) (launch s (pending :id))))))

  (defn temporary [[config call program executable limits]]
    (with-dyns [:zinc/config config :zinc/execute execute :zinc/wait wait
                :pa/program program :pa/executable executable :pa/limits limits]
      (def s (store/open config :worker))
      (def supervised (ev/chan 1))
      (defer (store/close s)
        (ev/go (fn []
          (when-let [image (get-in config [:snapshot :image])]
            (put (s :worlds) (get-in config [:snapshot :origin :blob]) (base64/decode image)))
          (when (index-of (call :state) ["queued" "running" "waiting"])
            (if-let [row (or (when (call :owner) call) (store/claim s (call :id)))]
              (execute s row)
              (store/finish s call nil {:error {:code "DeadlineExceeded" :message "Temporary execution expired before starting."}})))
          (wait s {:root (call :id) :run (call :run)})) nil supervised)
        (var failure nil)
        (while (or (> (length (ev/all-tasks)) 1) (> (ev/count supervised) 0))
          (def [status task] (ev/take supervised))
          (when (and (= status :error) (nil? failure))
            (set failure (wire/diagnostic "ExecutionFailed" (fiber/last-value task) task))))
        (when failure (error failure)))))

  (defn run [s value operation]
    (def config (s :config))
    (def existing (first (store/query s "SELECT * FROM calls WHERE id=? OR request_key=?" [(or (value :task) (value :run)) (value :request)])))
    (when (index-of operation ["task" "resume"]) (assert existing "call unavailable"))
    (when existing
      (assert (= 0 (existing :cancelled)) "saved call unavailable")
      (put s :config (schema/authorize (spec :schema) config (json/decode (existing :config) true true)))
      (put s :budget-root (or (existing :root) (existing :id)))
      (when (> ((s :config) :run-seconds) 0)
        (store/query s "UPDATE main.call_controls SET expires=min(coalesce(expires,1e999),(SELECT created FROM events WHERE call=call_controls.id AND kind='user')+?) WHERE id=?"
                     [((s :config) :run-seconds) (existing :run)])))
    (with-dyns [:zinc/wait wait :zinc/execute execute :zinc/config (s :config)]
      (unless (s :temporary) (recover s))
      (if (= operation "task")
        (do
          (if (value :owner)
            (do (assert (= (value :owner) (existing :owner)) "call ownership changed") (execute s existing))
            (wait s (existing :id) :inline))
          {:task (value :task)})
        (do
          (unless (= operation "resume")
            (assert (and (value :author) (value :at) (not= (nil? (value :text)) (nil? (value :code)))) "self requires text or code, authenticated author and occurrence time")
            (assert (if (value :text) (config :inference) (config :repl)) "execution is not permitted in this view")
            (unless (value :request) (put value :request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))))
          (def call (if (= operation "resume") existing
                      (store/start s value config nil
                        (unless existing (or (get-in config [:snapshot :origin]) (world/resolve config (store/origin s) (value :revision)))))))
          (def id (call :id))
          (when (= operation "resume")
            (assert (and (= "text" (call :kind)) (or (nil? (call :expires)) (> (call :expires) (os/clock)))) "call requires reconciliation or its deadline expired")
            (def queued (not= false ((json/decode (call :input) true true) :queue)))
            (store/transact s
              (when (first (store/query s "UPDATE main.call_controls SET state='queued',retries=?,owner=NULL,lease_expires=NULL WHERE id=? AND state IN ('failed','uncertain') RETURNING id" [(if queued 1 0) id]))
                (unless queued (assert (store/claim s id) {:code "AgentBusy" :message "Target cannot resume immediately."})))))
          (if (s :temporary)
            (let [finished (ev/thread-chan 1)
                  progress @[(get value :after 0) false]
                  reader (store/open config :observe)]
              (def done (ev/chan 1))
              (var observing nil)
              (defer (do (when observing (ev/cancel observing :finished)) (store/close reader) (ev/chan-close finished))
                (store/close s)
                (ev/thread temporary [config call (dyn :pa/program) (dyn :pa/executable) (dyn :pa/limits)] :n finished)
                (unless (get-in config [:snapshot :silent])
                  (set observing (ev/go (fn [] (observe reader call progress)) nil done)))
                (def [status failure] (ev/take finished))
                (when observing
                  (ev/cancel observing :finished)
                  (unless (index-of (fiber/status observing) [:dead :error]) (ev/take done)))
                (assert (= status :ok) failure)
                (def result (store/result reader (call :id)))
                (def remaining (unless (get-in config [:snapshot :silent])
                                 (events reader (call :run) (progress 0) 9007199254740991)))
                (store/close reader)
                (unless (get-in config [:snapshot :silent])
                  (unless (progress 1) (print (json/encode (receipt call))))
                  (each event remaining (when-let [frame (message event config)] (print (json/encode frame)))))
                result))
            (do
              (def active (store/call s id))
              (when (or (= "queued" (active :state)) (and (active :owner) (not= (active :owner) (get existing :owner))))
                (def [process] (worker "task" (merge {:task id} (when (active :owner) {:owner (active :owner)})) (s :config)))
                (ev/close (process :out)))
              (store/close s)
              (def reader (store/open config :observe))
              (defer (store/close reader) (observe reader call @[(get value :after 0) false]))))))))

  (defn describe [config]
    {:contract "inquiry-v1" :initialize "init" :profile {:field "agent" :inference "inference"}
     :parameters (catseq [[target fields] :in [[:config (spec :schema)] [:input (spec :input)]]]
                   (seq [[key field] :in (sorted (pairs fields)) :when (field :option)]
                     (def parameter (merge (schema/project field [:optional :option :visible :public :unlimited] true)
                                           {:name (field :option) :path (string target "." key) :type (string (field :type)) :default (get config key (get field :default "automatic"))}))
                     (when (and (= target :config) (= :integer (field :type)) (> (config key) 0)) (put parameter :maximum (config key))) parameter))})

  (tabseq [[operation fields] :in [["self" (keys (spec :input))] ["task" [:task :owner]] ["resume" [:run :request :after]] ["observe" [:run :request :after]] ["diagnostics" [:request]]
                                   ["describe" []] ["init" []] ["join" []] ["instructions" []] ["models" [:role]] ["world" [:action :point :message :commit :name]] ["views" [:event :mode]] ["render" [:event]] ["record" [:records]] ["abort" [:run :request :reason]] ["invalidate" [:event]]]]
    operation (fn [bytes opaque]
                (def config (schema/configuration (spec :schema) (json/decode opaque true true) (= operation "describe")))
                (when (index-of operation ["self" "task" "resume"])
                  (each profile (filter identity [config (config :agent)]) (world/definitions profile (spec :bindings))))
                (assert (and (utf8/is-valid? bytes) (<= (length bytes) (config :request-bytes))) "request must be bounded UTF-8")
                (when (index-of operation ["describe" "instructions"]) (assert (= "" bytes) "operation takes empty input"))
                (def value (if (index-of operation ["describe" "instructions"]) {} (schema/request (json/decode bytes true true) fields)))
                (when (= operation "init")
                  (assert (= (config :identity) (os/realpath (config :identity))) "canonical instance directory required")
                  (each key [:store :world]
                    (def relative (path/relpath (config :identity) (config key)))
                    (assert (and (path/abspath? (config key)) (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "state must belong to the new instance directory")
                    (var directory (config :identity))
                    (each part (filter next (path/parts (path/dirname relative)))
                      (unless (= part ".")
                        (set directory (path/join directory part))
                        (os/mkdir directory)
                        (assert (= directory (os/realpath directory)) "state directories cannot contain links")))
                    (assert (not (os/lstat (config key))) "init requires a fresh instance"))
                  (with-dyns [:zinc/config config]
                    (def root (path/dirname (config :world)))
                    (world/git root ["init" "--quiet"])
                    (def initial (world/run nil {} "" {:settings {} :resources {}} {} {:world (config :world-bytes) :output (config :response-bytes)} {} [{:code ""}] (config :seconds)
                                          (fn [&] (error "initialization cannot invoke host functions"))))
                    (spit (config :world) (initial :image) :wb)
                    (world/git root ["add" "--" (path/basename (config :world))])
                    (world/git root ["commit" "--quiet" "-m" "Initialize world image"])))
                (when (and (= operation "self") (config :ephemeral))
                  (assert (= false (get value :persist true)) "ephemeral profiles require persist:false"))
                (def temporary (and (= operation "self") (= false (get value :persist true))))
                (when temporary
                  (put value :persist false)
                  (put config :snapshot (merge (config :snapshot)
                    {:database (string "file:/zinc-" (string/join (map |(string/format "%02x" $) (os/cryptorand 24))) "?vfs=memdb")})))
                (def s (unless (index-of operation ["describe" "instructions" "models"])
                         (store/open config (cond temporary :temporary (= operation "task") :worker
                           (or (index-of operation ["observe" "diagnostics" "views" "render"])
                               (and (= operation "world") (= "view" (value :action)))) :observe))))
                (defer (when s (store/close s))
                  (with-dyns [:zinc/config config]
                    (when (and s (or (index-of operation ["self" "task" "resume" "init"])
                                     (and (= operation "world") (not= "view" (value :action))))
                               (= "{}" (((store/query s "SELECT origin FROM main.world WHERE id=1") 0) :origin)))
                      (def origin (world/resolve config))
                      (store/query s "UPDATE main.world SET origin=? WHERE id=1 AND origin='{}'" [(string (json/encode origin))]))
                    (def output (cond
                                  (= operation "describe") (describe config)
                                  (= operation "init") {:world (world/operate s {:action "view"})}
                                  (= operation "join")
                                  (with-dyns [:zinc/execute execute] (wait s {}))
                                  (= operation "instructions")
                                  (let [bindings (world/definitions config (spec :bindings))]
                                    (world/instructions config (spec :document) bindings (world/public config (spec :schema) bindings)))
                                  (= operation "models") (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get value :role "chat")))
                                  (= operation "record") {:events (store/record s (value :records))}
                                  (= operation "observe")
                                  (let [call (first (store/query s "SELECT * FROM calls WHERE id=? OR request_key=?" [(value :run) (value :request)]))]
                                    (assert call "call unavailable")
                                    (assert (= (call :id) (call :run)) "observe requires a run root")
                                    (assert (= 0 (call :temporary)) "temporary execution cannot be reattached")
                                    (observe s call @[(get value :after 0) false]))
                                  (= operation "diagnostics")
                                  (map (fn [row] (merge row {:data (json/decode (row :data) true true)}))
                                    (store/query s `SELECT 'zinc' source,e.id,e.record_kind kind,e.at created_at,json_extract(e.data,'$.error') data
                                      FROM events e JOIN call_payloads p ON p.id=e.call
                                      WHERE p.run=(SELECT id FROM main.call_controls WHERE request=?)
                                        AND json_type(e.data,'$.error')='object' ORDER BY e.id` [(value :request)]))
                                  (= operation "world")
                                  (if (= "view" (value :action)) (world/operate s value)
                                    (do
                                      (assert (index-of (value :action) ["save" "discard" "switch" "remove"]) "unknown world action")
                                      (put config :agent nil)
                                      (def name (string "world/" (value :action)))
                                      (assert ((world/definitions config (spec :bindings)) name)
                                              {:code "WorldBindingNotGranted" :message (string name " is not granted; add it to the executing profile's repl.bindings.")})
                                      (def receipt (run s @{:code (string "(world/" (value :action)
                                                            (case (value :action)
                                                              "save" (string " " (string/format "%q" (value :message)))
                                                              "switch" (string " " (string/format "%q" (value :commit)))
                                                              "remove" (do (assert (string? (value :name)) "binding name required") (string " (symbol " (string/format "%q" (value :name)) ")")) "") ")")
                                              :author (string "system:" (config :identity))
                                              :at (((store/query s "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now') at") 0) :at)} "self"))
                                      (when (receipt :error) (error (receipt :error)))
                                      (def reader (store/open config :observe))
                                      (defer (store/close reader) (world/operate reader {:action "view"} true))))
                                  (index-of operation ["views" "render"])
                                  (do
                                    (assert (and (int? (value :event)) (> (value :event) 0)) "choose a model-admission event")
                                    (def row (store/event s {:first 1 :last 9007199254740991} (value :event)))
                                    (assert (= "model-admission" (row :kind)) "point must identify a model-admission event")
                                    (memory/report s row (if (= operation "render") "render" (get value :mode "memory"))))
                                  (= operation "invalidate") {:event ((memory/invalidate s (value :event)) :id)}
                                  (= operation "abort") (store/abort s value)
                                  (run s value operation)))
                    (if (= operation "instructions") output (string (json/encode output))))))))
