(import spork/json :as json)
(import spork/path :as path)
(import spork/utf8 :as utf8)
(import portable-agents/protocol :as wire)
(import portable-agents/markdown :as markdown)
(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./repl)
(import ./http)

(defn make [spec]
  (defn message [event]
    (when (event :branch)
      (def data (json/decode (event :data) true true))
      (def origin (data :world))
      (def durable (and (= 0 (event :branch_temporary)) (not ((dyn :zinc/config) :ephemeral))))
      (def coordinate (if durable "#" "local "))
      (def body (case (event :kind)
                  "user" ""
                  "response" (model/render event)
                  "model-admission" (when (event :public_message) (model/render event))
                  "completed" (if (event :public_message) (model/render event) (event :text))
                  "model-outcome" (when (and (= "chat" (data :role)) (data :visible)) (model/render event))
                  "interruption" (when (= "uncertain" (data :state)) (event :text))
                  "saved" (string "Saved " (data :ref) " @ " (string/slice (data :base) 0 7) (when (data :pushed) " · pushed") "\n" (event :text))
                  "summary" (string "summary " coordinate (event :id) " · " (data :count)
                                    " records · source range " coordinate (data :first) "–" (data :last))
                  (when (and (not= false (data :display)) (index-of (event :kind) ["code-admission" "tool-result" "tool-ambiguity" "error"]))
                    (if-let [failure (data :error)]
                      (string/trim (string (get-in failure [:context :output] "") "\n" (failure :code) ": " (failure :message))) (event :text)))))
      (when body
        {:body (if (and (event :public_message) (data :status) (not (index-of (data :status) ["complete" "tools"]))) (string body "\n\n[" (data :status) "]") body)
         :kind (event :kind)
         :agent ((dyn :zinc/config) :identity)
         :caller (if-let [parent (event :branch_parent)] {:agent ((dyn :zinc/config) :identity) :request (event :request) :branch parent} (or ((dyn :zinc/config) :caller) :null)) :prompt (cond (= "model-admission" (event :kind)) (event :id) (or (data :turn) (= "model-outcome" (event :kind))) (event :parent) :null)
         :related (if (and (not (data :turn)) (index-of (event :kind) ["tool-result" "tool-ambiguity" "completed"])) (or (event :parent) :null) :null)
         :status (or (data :status) (case (event :kind) "model-admission" "streaming" "code-admission" "admitted" "error" "failed" "tool-ambiguity" "uncertain" (if (= false (data :ok)) "failed" "complete")))
         :run (event :run) :branch (event :branch) :request (event :request)
         :persist durable :sequence (event :id)
         :world {:path (origin :path) :blob (or (data :blob) (origin :blob)) :ref (or (data :ref) (origin :ref))}})))

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
          (or (s :temporary) (and (= "summarize" (row :kind)) (not (dyn :zinc/background))))
          (ev/go (fn [] ((dyn :zinc/execute) s row)))
          (let [[process] (worker "task" {:task id :owner (row :owner)} (dyn :zinc/config))]
            (ev/close (process :out))))
        ([err] (store/append s (store/view s (if (= "summarize" (row :kind)) (row :parent) id))
                             "launch-uncertain" "Call acceptance could not be confirmed." {:error err} nil id))))
    id)

  (defn wait [s id &opt here]
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
                      (store/recover s (and (dictionary? id) (not (id :root))))
                      (when current (store/checkpoint s))
                      (if (dictionary? id)
                        (let [root (id :root)
                              pending (store/query s `SELECT c.id,c.state,c.owner,c.lease_expires,p.run FROM main.call_controls c
                                LEFT JOIN call_payloads p ON p.id=c.id
                                WHERE (? IS NULL OR c.root=? AND c.kind<>'summarize')
                                AND (c.state IN ('queued','running','waiting') OR (? IS NULL AND (c.state='uncertain' OR c.owner IS NOT NULL))) ORDER BY c.id` [root root root])]
                          (unless root
                            (each row pending (assert (and (not= "uncertain" (row :state))
                              (or (nil? (row :owner)) (> (row :lease_expires) (os/clock)))) "instance has unsettled effects; preserve it for inspection")))
                          (when (= 0 (length pending)) (return done {:settled true}))
                          (each row pending (when (and (= "queued" (row :state)) (or (nil? (id :run)) (= (id :run) (row :run)))) (launch s (row :id)))))
                        (let [row (first (store/query s "SELECT state,kind FROM main.call_controls WHERE id=?" [id]))]
                          (assert row "call unavailable")
                          (case (row :state)
                            "done" (return done (if (= "text" (row :kind))
                              {:text (((store/query s "SELECT text FROM memory_records WHERE branch=? AND kind='completed'" [id]) 0) :text)}
                              ((json/decode ((first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])) :data) true true) :value)))
                            "failed" (error ((json/decode ((first (store/query s "SELECT data FROM events WHERE call=? AND kind='call-result' ORDER BY id DESC LIMIT 1" [id])) :data) true true) :error))
                            "uncertain" (error (string "Call #" id ": uncertain effects; inspect receipts, do not replay."))
                            "cancelled" (error "call cancelled")
                            "queued" (launch s id here))))
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
    (def origin (or snapshot (repl/image config (or ((dyn :zinc/call) :candidate) (store/origin s (parent :id))) (value :revision))))
    (if (value :persist)
      (do
        (store/git (origin :root) ["update-ref" (string "refs/zinc/world/" (origin :blob)) (origin :blob)])
        (def call (store/start s value config (merge view {:event (dyn :zinc/effect) :agent (or (view :agent) (not= config (s :config)))}) origin))
        {:job (call :id) :branch (call :id)})
      (do
        (each id [(get value :parent 0) (get-in value [:memory_range :start] 0) (get-in value [:memory_range :end] 0)]
          (when (> id 0) (store/event s view id)))
        (assert (< (view :depth) (config :task-depth)) "agent recursion ceiling exhausted")
        (def request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))
        (def entry (get value :parent (view :last)))
        (def [process reader exited]
          (worker "self" (merge value {:request request :parent entry
                                       :memory_range (get value :memory_range {:start (if (= 0 entry) 0 (view :first)) :end entry})})
                  (merge config {:snapshot (merge (store/snapshot s view) {:origin origin})})))
        (def done (ev/chan 1))
        (def collector (ev/go (fn []
          (defer (ev/close (process :out))
            (def output (json/decode (wire/output reader) true true))
            (ev/take exited)
            (assert (= 0 (process :return-code)) "ProcessFailure")
            output)) nil done))
        (put ((dyn :zinc/call) :children) request [collector done])
        {:temporary request})))

  (defn run-code [s view bindings code]
    (def config (s :config))
    (assert (config :repl) "Janet execution is not permitted")
    (assert (<= (length code) (config :source-bytes)) "tool source byte ceiling")
    (store/checkpoint s)
    (def current (dyn :zinc/call))
    (os/cd (path/dirname (config :world)))
    (def origin (repl/image config (store/origin s (current :id))))
    (put current :candidate nil)
    (def public (repl/public config (spec :schema) bindings))
    (def outcome (repl/execute (store/git (origin :root) ["cat-file" "blob" (origin :blob)]) (current :input) (repl/instructions config (spec :document) bindings public) public
                  (tabseq [[name binding] :in (pairs bindings)] name (if (binding :local) binding {:doc (binding :doc)}))
                  code {:world (config :world-bytes) :output (config :response-bytes)} (config :repl)
                  (fn [name args snapshot]
                    (store/checkpoint s)
                    (def binding (bindings name))
                    (assert (and binding (not (binding :local))) "function revoked")
                    (when snapshot
                      (put current :candidate (store/image s (store/origin s (current :id)) (snapshot :image))))
                    (when (get binding :intrinsic) (assert (= 1 (length args)) "invalid intrinsic arity"))
                    (let [admission (store/transact s (store/charge s 1 0)
                                                      (store/append s view "call-admission" name {:arguments args} nil ((dyn :zinc/call) :id)))]
                        (def args (schema/data args))
                        (def value
                          (cond
                            (or (= name "save") (string/has-prefix? "world/" name))
                            (do
                              (assert (<= (length args) 1) "invalid world operation arity")
                              (repl/world s {:action (if (= name "save") "save" (string/slice name 6))
                                             :message (when (index-of name ["save" "world/save"]) (first args))
                                             :point (when (= name "world/view") (first args))
                                             :commit (when (= name "world/switch") (first args))}))
                            (= name "self")
                            (let [handle (with-dyns [:zinc/effect (admission :id)] (start-child s (merge view (store/view s (view :branch))) (first args)))]
                              (when (handle :job) (launch s (handle :job)))
                              (wait s (or (handle :temporary) (handle :job))))
                            (index-of name ["fs/list" "fs/read" "fs/write"])
                            (do
                              (assert (= (length args) (if (= name "fs/write") 3 2)) "invalid filesystem arity")
                              (def [root relative text] args)
                              (def grant (get-in config [:fs (keyword root)]))
                              (assert (and grant (grant (if (= name "fs/write") :write :read))) "filesystem operation is not granted")
                              (assert (and (string? relative) (> (length relative) 0) (not (string/find "\0" relative))
                                           (not (string/find "\\" relative)) (not (string/find ":" relative)) (not (path/abspath? relative))) "invalid relative path")
                              (var target (os/realpath (grant :root)))
                              (each part (array/concat @[""] (if (= relative ".") [] (string/split "/" relative)))
                                (unless (= part "")
                                  (assert (not (index-of part ["." ".."])) "invalid path component")
                                  (when (index-of (os/which) [:windows :mingw])
                                    (assert (and (not (index-of (last part) [32 46]))
                                                 (not (peg/match ~(* (choice "CON" "PRN" "AUX" "NUL" (* (choice "COM" "LPT") (range "19"))) -1)
                                                                 (string/ascii-upper (first (string/split "." part)))))) "invalid Windows path component"))
                                  (set target (path/join target part)))
                                (assert (if (index-of (os/which) [:windows :mingw])
                                          (let [attributes (ffi/call (ffi/lookup (ffi/native "kernel32.dll") "GetFileAttributesA") (ffi/signature :default :uint32 :string) target)]
                                            (or (= attributes 0xffffffff) (= 0 (band attributes 0x400))))
                                          (not= :link (os/lstat target :mode))) "filesystem links are not permitted"))
                              (case name
                                "fs/list" (do (assert (= :directory (os/stat target :mode)) "directory required")
                                            (def names (os/dir target))
                                            (assert (<= (sum (map length names)) (config :response-bytes)) "directory result exceeds limit")
                                            (sorted names))
                                "fs/read" (do (assert (= :file (os/stat target :mode)) "regular file required")
                                            (with [file (file/open target :rbn)]
                                              (def bytes (or (file/read file (+ 1 (config :response-bytes))) ""))
                                              (assert (and (<= (length bytes) (config :response-bytes)) (utf8/is-valid? bytes)) "file exceeds limit or is not UTF-8")
                                              (string bytes)))
                                (do (assert (and (string? text) (utf8/is-valid? text) (<= (length text) (config :response-bytes))) "invalid file contents")
                                  (assert (or (nil? (os/stat target)) (= :file (os/stat target :mode))) "regular file required")
                                  (spit target text :wb) nil)))
                            (= name "http/request")
                            (do
                              (assert (= 4 (length args)) "invalid HTTP arity")
                              (def [root method segments body] args)
                              (def grant (get-in config [:http (keyword root)]))
                              (assert (and grant (index-of method (grant :methods))) "HTTP operation is not granted")
                              (assert (and (indexed? segments) (every? (map |(and (string? $) (not (index-of $ ["." ".."]))
                                                                                  (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~.")) -1) $)) segments))) "invalid HTTP path")
                              (assert (or (nil? body) (string? body)) "HTTP body must be text or nil")
                              (http/request config grant method (string/join segments "/") body))
                            (= name "process/run")
                            (do
                              (assert (= 1 (length args)) "invalid process arity")
                              (def command (get-in config [:processes (keyword (first args))]))
                              (assert command "process is not granted")
                              (def result (store/process (command :argv) (tabseq [[k v] :pairs (command :env)] (string k) v) nil (config :response-bytes) 0))
                              (assert (utf8/is-valid? (result :output)) "process output is not UTF-8")
                              result)
                            (with-dyns [:zinc/context [s view]
                                        :pa/operation (string (view :run) "/" (view :branch) "/" (admission :id))]
                              (apply (binding :value) args))))
                        (store/transact s (store/checkpoint s)
                                        (store/append s view "operation-outcome" name {:value value} (admission :id) ((dyn :zinc/call) :id)))
                        (schema/data value)))
                  (let [run (if (view :expires) (max 0.001 (- (view :expires) (os/clock))) math/inf)
                        seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds)) run)]
                    (if (= seconds math/inf) 0 seconds))))
    (put current :candidate (or (outcome :replacement)
                               (store/image s (store/origin s (current :id)) (outcome :image))))
    (outcome :value))

  (defn infer [s call bindings]
    (def id (call :id))
    (def config (s :config))
    (def inherited (store/view s id false))
    (def selected (model/profile s (config :chat) :chat))
    (def tools (filter |(or (config :repl) (not= "function" ($ :type))) (selected :tools)))
    (def system (repl/instructions config (spec :document) (when (find |(= "function" ($ :type)) tools) bindings) (repl/public config (spec :schema) bindings)))
    (def user (first (store/query s "SELECT * FROM memory_records WHERE task=? AND kind='user'" [id])))
    (def inquiry {:role "user" :content (model/images s (user :id) (memory/render user))})
    (def tool-size (if (> (length tools) 0) (store/estimate (json/encode tools)) 0))
    (def capacity (min (get config :context-quota math/inf) (- (selected :context) 256)))
    (var space 0)
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
      (def world (when (config :repl) {:role "user" :content (markdown/render {:name "World source" :level 2 :content [{:language "janet" :text ((repl/world s {:action "view"}) :text)}]})}))
      (set space (- capacity (model/estimate (filter identity [{:role "system" :content system} world inquiry])) tool-size 256))
      (assert (> space 256) "question, world bindings and instructions exhaust context")
      (var context (memory/context s inherited space pool))
      (def messages @[]) (def views @{})
      (while true
        (array/clear messages) (array/push messages {:role "system" :content system})
        (when world (array/push messages world))
        (table/clear views) (put views :through (context :through))
        (each [key title rows] [[:chronological "Chronological memory" (context :nodes)] [:semantic "Retrieved excerpts" (context :evidence)]]
          (def text (string/join (map |($ :rendered) rows)))
          (put views key @{:message (when (> (length text) 0) (length messages))
                           :records (seq [row :in rows] (schema/project row [:id :label :first :last :children :offset :next :total :score]))})
          (when (> (length text) 0) (array/push messages {:role "user" :content (string "## " title "\n\n" text)})))
        (put (views :semantic) :cutoff (config :score))
        (put (views :semantic) :candidates (seq [row :in pool] {:id (row :id) :score (row :score) :rerank (row :rerank)}))
        (array/push messages inquiry)
        (each record (store/query s "SELECT conversation_message,json_extract(data,'$.status') status FROM conversation_records WHERE branch=? AND id>? ORDER BY id" [id (context :through)])
          (array/push messages (json/decode (record :conversation_message) true true))
          (when (= "continue" (record :status))
            (array/push messages {:role "system" :content "Continue the inquiry."})))
        (when (<= (+ (model/estimate messages) tool-size) capacity) (break))
        (assert (< (context :through) (view :last)) "context metadata cannot fit")
        (set context (memory/context s (merge view {:exclude [(user :id)]}) space pool)))
      (def pending (get-in (dyn :zinc/call) [:checkpoint :request]))
      (def response (model/call s {:turn true :model (config :chat) :messages messages :views views :tools (when (> (length tools) 0) tools)}
                                (when (and pending (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='model-outcome'" [pending])))) pending) selected))
      (def parallel (> (length (response :tools)) 1))
      (def fork (store/view s id))
      (def origin (when parallel (repl/image config (store/origin s id))))
      (def work (seq [tool :in (response :tools)]
                  (def admission (store/transact s (store/checkpoint s) (store/charge s 1 (if (or parallel (tool :error)) 0 (store/estimate (tool :code))))
                                                 (store/append s view (if (or parallel (tool :error)) "call-admission" "code-admission") (cond (tool :error) "run_janet" parallel "self" (tool :code))
                                                               {:tool-id (tool :id) :response (response :event)} nil id)))
                  [tool admission (if (tool :error) tool (when parallel (try (with-dyns [:zinc/effect (admission :id)] (start-child s fork {:code (tool :code)} origin)) ([err fiber] {:error (wire/diagnostic "ToolFailed" err fiber)}))))]))
      (each [_ _ handle] work (when-let [job (get handle :job)] (launch s job)))
      (each [tool admission handle] work
        (def outcome (try
                       {:ok true :text (if (get handle :error) (error (get handle :error)) (if parallel
                                                                                             (wait s (or (handle :temporary) (handle :job)))
                                                                                             (run-code s view bindings (tool :code))))}
                       ([err fiber]
                         (put (dyn :zinc/call) :candidate nil)
                         (def failure (wire/diagnostic "ToolFailed" err fiber))
                         {:ok false :text (string (failure :code) ": " (failure :message)) :error failure})))
        (store/transact s (store/checkpoint s)
                        (store/charge s 0 (store/estimate (outcome :text)))
                        (when (and (not parallel) (outcome :ok)) (store/publish s ((dyn :zinc/call) :candidate)))
                        (store/append s view "tool-result" (outcome :text)
                                      (merge outcome {:text nil :tool-id (tool :id) :response (response :event) :child (get handle :branch) :display (or (not parallel) (has-key? handle :error))}) (admission :id) id))
        (unless (outcome :ok)
          (eprint (json/encode (merge (outcome :error) {:context (merge (or (get-in outcome [:error :context]) {}) {:tool-call {:branch id :tool (tool :id) :event (admission :id)}})}))))))
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
                        (store/append s view "call-attempt" (if (= "code" (row :kind)) (get-in (dyn :zinc/call) [:input :code]) "execution entered") {:attempt (row :attempt)} nil id))
        (def [value failure]
          (try
            (let [input ((dyn :zinc/call) :input)
                  bindings (if (not= "summarize" (row :kind)) (repl/definitions config (spec :bindings)) {})
                  owner (fiber/root)
                  watcher (ev/go (fn [] (try (while true (store/checkpoint s) (ev/sleep store/interval))
                                            ([err] (unless (= err :finished) (ev/cancel owner err))))))]
              (defer (ev/cancel watcher :finished)
                (def value (case (row :kind) "text" (infer s row bindings)
                            "code" (run-code s view bindings (input :code)) "summarize" (memory/summarize s row input)))
                (when (= "code" (row :kind)) (store/charge s 0 (store/estimate (json/encode value))))
                [value nil]))
            ([err fiber]
              (def tokens (keep |(when ($ :token-env) (os/getenv ($ :token-env))) (values (config :providers))))
              [nil {:error (postwalk (fn [value]
                                       (if (string? value) (reduce (fn [text token] (string/replace-all token "[redacted]" text)) value tokens) value))
                                     (wire/diagnostic "ExecutionFailed" err fiber))}])))
        (when (first (store/query s "SELECT id FROM main.live_calls WHERE id=? AND owner=?" [id (row :owner)]))
          (each request (keys ((dyn :zinc/call) :children))
            (try (wait s request) ([err] (eprint (json/encode (if (dictionary? err) err {:code "ChildFailed" :message (string err)})))))))
        (try
          (store/transact s
                          (unless failure (store/checkpoint s))
                          (when (and (nil? failure) (= "code" (row :kind))) (store/publish s ((dyn :zinc/call) :candidate)))
                          (store/finish s row value failure))
          ([err fiber]
            (store/finish s row nil {:error (wire/diagnostic "CommitFailed" err fiber)})))
        (each pending (store/query s "SELECT c.id FROM main.call_controls c JOIN call_payloads p ON p.id=c.id WHERE p.run=? AND c.state='queued' AND (c.expires IS NULL OR c.expires>?) ORDER BY c.id LIMIT ?"
                                   [(row :run) (os/clock) (config :parallel)]) (launch s (pending :id))))))

  (defn drain [s run after previews]
    (var sequence after)
    (while true
      (def records (memory/events s run sequence))
      (each event records
        (when-let [frame (message event)] (print (json/encode frame)))
        (set sequence (event :id)))
      (when (< (length records) 256) (break)))
    (def active @{})
    (each event (store/query s `SELECT e.* FROM main.live_calls c JOIN call_payloads p ON p.id=c.id
      JOIN memory_records e ON e.id=json_extract(p.checkpoint,'$.request') AND e.task=p.id
      WHERE p.run=? AND c.kind<>'summarize' AND e.kind='model-admission'` [run])
      (put active (event :id) true)
      (def progress (get previews (event :id) @{:after 0 :message @{}}))
      (put previews (event :id) progress)
      (def updates (store/query s (string "SELECT id,delta FROM " (s :journal) ".previews WHERE request=? AND id>? ORDER BY id") [(event :id) (progress :after)]))
      (each update updates
        (model/delta (progress :message) (json/decode (update :delta) true true))
        (put progress :after (update :id)))
      (when (> (length updates) 0)
        (when-let [frame (message (merge event {:public_message (string (json/encode (progress :message))) :text ""}))] (print (json/encode frame)))))
    (each id (keys previews) (unless (active id) (put previews id nil)))
    sequence)

  (defn run [s value operation]
    (def existing (first (store/query s "SELECT * FROM calls WHERE id=? OR request_key=?" [(or (value :task) (value :run)) (value :request)])))
    (when (index-of operation ["task" "resume" "observe"]) (assert existing "call unavailable"))
    (when existing
      (assert (= 0 (existing :temporary)) "temporary execution cannot be reattached")
      (assert (= 0 (existing :cancelled)) "saved call unavailable")
      (put s :config (schema/authorize (spec :schema) (s :config) (json/decode (existing :config) true true)))
      (put s :budget-root (or (existing :root) (existing :id)))
      (when (> ((s :config) :run-seconds) 0)
        (store/query s "UPDATE main.call_controls SET expires=min(coalesce(expires,1e999),(SELECT created FROM events WHERE call=call_controls.id AND kind='user')+?) WHERE id=?"
                     [((s :config) :run-seconds) (existing :run)])))
    (with-dyns [:zinc/wait wait :zinc/spawn launch :zinc/execute execute :zinc/config (s :config)]
      (store/recover s)
      (if (= operation "task")
        (do (assert (= (value :owner) (existing :owner)) "call ownership changed") (execute s existing) {:task (value :task)})
        (do
          (unless (index-of operation ["resume" "observe"])
            (assert (and (value :author) (value :at) (not= (nil? (value :text)) (nil? (value :code)))) "self requires text or code, authenticated author and occurrence time")
            (assert (if (value :text) ((s :config) :inference) ((s :config) :repl)) "execution is not permitted in this view")
            (unless (value :request) (put value :request (string/join (map |(string/format "%02x" $) (os/cryptorand 24))))))
          (def call (if (index-of operation ["resume" "observe"]) existing
                      (store/start s value (s :config) nil
                        (unless existing (or (get-in (s :config) [:snapshot :origin])
                                             (repl/image (s :config) (store/origin s) (value :revision)))))))
          (var claimed (when (and (= operation "self") (call :owner)) call))
          (def id (call :id))
          (when (= operation "resume")
            (assert (and (= "text" (call :kind)) (or (nil? (call :expires)) (> (call :expires) (os/clock)))) "call requires reconciliation or its deadline expired")
            (def queued (not= false ((json/decode (call :input) true true) :queue)))
            (store/transact s
              (when (first (store/query s "UPDATE main.call_controls SET state='queued',retries=?,owner=NULL,lease_expires=NULL WHERE id=? AND state IN ('failed','uncertain') RETURNING id" [(if queued 1 0) id]))
                (unless queued
                  (set claimed (store/claim s id))
                  (unless claimed (error {:code "AgentBusy" :message "Target cannot resume immediately."}))))))
          (var sequence (get value :after 0))
          (def previews @{})
          (def emitter (ev/go (fn [] (try (while true (set sequence (drain s (call :run) sequence previews)) (ev/sleep store/interval))
                                       ([err] (eprint (json/encode {:code "ObservationFailed" :message (string err)})))))))
          (defer (do (ev/cancel emitter "observer detached") (drain s (call :run) sequence previews))
            (var failure nil)
            (def output (try (do (when claimed (execute s claimed)) (wait s id true)) ([err] (set failure err))))
            (wait s {:root (or (call :root) id) :run (call :run)})
            (if failure (error failure) output))))))

  (defn describe [config]
    {:contract "inquiry-v1" :initialize "init" :settle "join" :profile {:field "agent" :inference "inference"}
     :parameters (catseq [[target fields] :in [[:config (spec :schema)] [:input (spec :input)]]]
                   (seq [[key field] :in (sorted (pairs fields)) :when (field :option)]
                     (def parameter (merge (schema/project field [:optional :option :visible :public :unlimited] true)
                                           {:name (field :option) :path (string target "." key) :type (string (field :type)) :default (get config key (get field :default "automatic"))}))
                     (when (and (= target :config) (= :integer (field :type)) (> (config key) 0)) (put parameter :maximum (config key))) parameter))})

  (tabseq [[operation fields] :in [["self" (keys (spec :input))] ["task" [:task :owner]] ["resume" [:run :request :after]] ["observe" [:run :request :after]]
                                   ["describe" []] ["init" []] ["join" []] ["instructions" []] ["models" [:role]] ["world" [:action :point :message :commit :name]] ["views" [:event]] ["render" [:event]] ["record" [:records]] ["abort" [:run :request :reason]] ["invalidate" [:event]]]]
    operation (fn [bytes opaque]
                (def config (schema/configuration (spec :schema) (json/decode opaque true true) (= operation "describe")))
                (when (index-of operation ["self" "task" "resume" "observe"])
                  (each profile (filter identity [config (config :agent)]) (repl/definitions profile (spec :bindings))))
                (assert (and (utf8/is-valid? bytes) (<= (length bytes) (config :request-bytes))) "request must be bounded UTF-8")
                (when (index-of operation ["describe" "instructions"]) (assert (= "" bytes) "operation takes empty input"))
                (def value (if (index-of operation ["describe" "instructions"]) {} (schema/request (json/decode bytes true true) fields)))
                (when (= operation "init")
                  (assert (= (config :identity) (os/realpath (config :identity))) "canonical instance directory required")
                  (each key [:store :world]
                    (def relative (path/relpath (config :identity) (config key)))
                    (assert (and (path/abspath? (config key)) (not (path/abspath? relative)) (not= ".." (first (path/parts relative)))) "state must belong to the new instance directory")
                    (var directory (config :identity))
                    (each part (path/parts (path/dirname relative))
                      (unless (= part ".")
                        (set directory (path/join directory part))
                        (os/mkdir directory)
                        (assert (= directory (os/realpath directory)) "state directories cannot contain links")))
                    (assert (not (os/lstat (config key))) "init requires a fresh instance"))
                  (with-dyns [:zinc/config config]
                    (def root (path/dirname (config :world)))
                    (store/git root ["init" "--quiet"])
                    (def initial (repl/execute nil {} "" {:settings {} :resources {}} {} "" {:world (config :world-bytes) :output (config :response-bytes)} {} (fn [&] (error "initialization cannot invoke host functions")) (config :seconds)))
                    (spit (config :world) (initial :image) :wb)
                    (store/git root ["add" "--" (path/basename (config :world))])
                    (store/git root ["commit" "--quiet" "-m" "Initialize world image"])))
                (def s (unless (index-of operation ["describe" "instructions" "models"]) (store/open config (and (= operation "self") (= false (get value :persist true))))))
                (defer (when s (store/close s))
                  (with-dyns [:zinc/config config]
                    (when (and s (index-of operation ["self" "task" "resume" "observe" "world" "init"]) (= "{}" (((store/query s "SELECT origin FROM main.world WHERE id=1") 0) :origin)))
                      (def origin (repl/image config))
                      (store/query s "UPDATE main.world SET origin=? WHERE id=1 AND origin='{}'" [(string (json/encode origin))]))
                    (def output (cond
                                  (= operation "describe") (describe config)
                                  (= operation "init") {:world (repl/world s {:action "view"})}
                                  (= operation "join")
                                  (with-dyns [:zinc/execute execute] (wait s {}))
                                  (= operation "instructions")
                                  (let [bindings (repl/definitions config (spec :bindings))]
                                    (repl/instructions config (spec :document) bindings (repl/public config (spec :schema) bindings)))
                                  (= operation "models") (map |{:ref ($ :ref) :name ($ :name)} (model/catalogue config (get value :role "chat")))
                                  (= operation "record") {:events (store/record s (value :records))}
                                  (= operation "world")
                                  (if (= "view" (value :action)) (repl/world s value)
                                    (do
                                      (assert (index-of (value :action) ["save" "discard" "switch" "remove"]) "unknown world action")
                                      (put config :agent nil)
                                      (def name (string "world/" (value :action)))
                                      (assert ((repl/definitions config (spec :bindings)) name)
                                              {:code "WorldBindingNotGranted" :message (string name " is not granted; add it to the executing profile's repl.bindings.")})
                                      (run s @{:code (string "(world/" (value :action)
                                                            (case (value :action)
                                                              "save" (string " " (string/format "%q" (value :message)))
                                                              "switch" (string " " (string/format "%q" (value :commit)))
                                                              "remove" (do (assert (string? (value :name)) "binding name required") (string " (symbol " (string/format "%q" (value :name)) ")")) "") ")")
                                              :author (string "system:" (config :identity))
                                              :at (((store/query s "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now') at") 0) :at)} "self")
                                      (repl/world s {:action "view"} true)))
                                  (index-of operation ["views" "render"])
                                  (do
                                    (assert (and (int? (value :event)) (> (value :event) 0)) "choose a model-admission event")
                                    (def row (store/event s {:first 1 :last 9007199254740991} (value :event)))
                                    (assert (= "model-admission" (row :kind)) "point must identify a model-admission event")
                                    (def data (json/decode (row :data) true true))
                                    (assert (get-in data [:request :body]) "exact request was not recorded")
                                    (def call (store/call s (row :task)))
                                    (def report {:event (row :id) :run (row :run) :branch (row :branch) :author (row :author) :at (row :at)
                                                 :world (data :world) :memory_range {:start (call :first) :end (call :last)}})
                                    (def body (json/decode (get-in data [:request :body]) true true))
                                    (if (= operation "render")
                                      (merge report {:summary (string "Prompt #" (row :id) " · call " (row :branch)) :request (data :request)
                                                     :text (markdown/render
                                                       {:name (string "Prompt #" (row :id)) :level 1
                                                        :content [(string (get-in data [:request :method]) " " (get-in data [:request :url]))
                                                          {:name "Request parameters" :level 2 :content [(schema/project body [:messages] true)]}
                                                          (seq [[index message] :pairs (body :messages)]
                                                            (def metadata (schema/project message [:role :content] true))
                                                            {:name (string "Message " index " · " (message :role)) :level 2
                                                             :content [(when (> (length metadata) 0) metadata) (message :content)]})]})})
                                      (let [windows (data :views)]
                                        (assert windows "this request has no chronological or semantic windows")
                                        (each key [:chronological :semantic]
                                          (put (windows key) :text (if-let [index (get-in windows [key :message])] (get-in body [:messages index :content]) "")))
                                        (def summary (string "Prompt #" (row :id) " · " (length (get-in windows [:chronological :records])) " chronological · "
                                                             (length (get-in windows [:semantic :records])) " retrieved"))
                                        (merge report {:summary summary :views windows
                                                       :text (string "# Memory views · prompt #" (row :id) "\n\nCall " (row :branch) " · Through #" (windows :through)
                                                         "\n\n" summary "\n\n" (get-in windows [:chronological :text]) "\n\n" (get-in windows [:semantic :text])
                                                         "\n\n## Retrieval candidates\n\n" (length (get-in windows [:semantic :candidates])) " candidates · Cutoff: " (get-in windows [:semantic :cutoff])
                                                         "\n\n| Record | Score | Rerank request | Included |\n| --- | ---: | --- | --- |\n"
                                                         (string/join (seq [candidate :in (get-in windows [:semantic :candidates])]
                                                           (string "| #" (candidate :id) " | " (candidate :score) " | #" (candidate :rerank) " | "
                                                             (if (find |(= ($ :id) (candidate :id)) (get-in windows [:semantic :records])) "yes" "no") " |")) "\n"))}))))
                                  (= operation "invalidate") {:event ((memory/invalidate s (value :event)) :id)}
                                  (= operation "abort") (store/abort s value)
                                  (run s value operation)))
                    (if (= operation "instructions") output (string (json/encode output))))))))
