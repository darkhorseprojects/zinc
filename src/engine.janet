(import ./store)
(import ./model)
(import ./memory)
(import ./schema)
(import ./runtime)
(import ./io)

(def bindings
  {"self" {:arity [1 1] :doc "(self request) admits an independent execution. Supply exactly one of :text or :code. Returns a handle, not completion. Descendants inherit persistence."}
   "self/status" {:arity [1 1] :doc "(self/status handle) reads a script's root outcome and unresolved effect attempts."}
   "self/wait" {:arity [1 1] :doc "(self/wait handle) suspends only the calling fiber for a descendant's root outcome. Returns an outcome object; read :value."}
   "self/cancel" {:arity [1 1] :doc "(self/cancel handle) cancels a descendant execution tree without undoing effects."}
   "effect/resolve" {:arity [2 2] :doc "(effect/resolve attempt outcome) resolves the latest unresolved uncertain attempt. outcome contains :evidence and exactly one of :value, :error, or :retry true. :error requires string :code and :message fields. :evidence is a nonblank string or nonempty object recording verification. Retry retains the logical effect identity."}
   "world/view" {:arity [0 1] :doc "(world/view &opt point) reports a world publication and its complete defining source."}
   "world/remove" {:arity [1 1] :doc "(world/remove name) removes a local world binding; name is a symbol."}
   "memory/expand" {:arity [1 2] :doc "(memory/expand id &opt byte-offset) reads an original record within granted history."}
   "fs/list" {:arity [2 2] :resource :fs :permission :read :doc "(fs/list resource relative-path) lists a granted directory. Both arguments are strings. Paths are grant-relative; \".\" selects the grant root. Absolute paths and traversal are rejected."}
   "fs/read" {:arity [2 2] :resource :fs :permission :read :doc "(fs/read resource relative-path) reads a granted UTF-8 file. Both arguments are strings. Paths are grant-relative; \".\" selects the grant root. Absolute paths and traversal are rejected."}
   "fs/write" {:arity [3 3] :resource :fs :permission :write :doc "(fs/write resource relative-path text) writes UTF-8 text to a granted file. All arguments are strings. Paths are grant-relative; \".\" selects the grant root. Absolute paths and traversal are rejected."}
   "http/request" {:arity [4 4] :resource :http :doc "(http/request resource method segments body) requests a granted endpoint."}
   "process/run" {:arity [1 1] :resource :processes :doc "(process/run resource) executes granted argv/env."}})

(defn- ready? [s execution]
  (def state (store/progress s (execution :id)))
  (def wait (get-in state [:data :wait]))
  (def scope (if (get-in execution [:data :input :recovery]) ((store/root s (execution :id)) :id) (execution :id)))
  (cond
    (nil? wait) true
    (wait :tasks) (every? (map |(store/outcome s $) (wait :tasks)))
    (wait :operations) (every? (map |(store/result s $) (wait :operations)))
    (wait :changes) (or (first (store/changes s scope (get-in state [:data :after] 0)))
      (and (get-in state [:data :final]) (not (store/busy? s scope))))
    (error "unsupported stored wait condition")))

(defn- infer [s inquiry available]
  (def config (s :config))
  (def scope-id (if (get-in inquiry [:data :input :recovery]) ((store/root s (inquiry :id)) :id) (inquiry :id)))
  (def pending (first (store/query s `SELECT r.* FROM events m JOIN events r ON r.parent=m.id
    WHERE m.parent=? AND m.kind='model' AND r.kind='result' AND json_extract(m.data,'$.turn')=1
      AND NOT EXISTS(SELECT 1 FROM events a WHERE a.parent=r.id AND a.kind='turn') ORDER BY r.id LIMIT 1` [(inquiry :id)])))
  (if pending
    (store/transact s
      (store/check s (inquiry :id))
      (def response (pending :data))
      (when (response :error) (error (response :error)))
      (var admitted false)
      (each tool (get response :tools [])
        (def receipt (try
          (do
            (when (tool :error) (error (tool :error)))
            (def child (store/start s (merge (schema/project tool [:code])
              {:request (string "tool:" (pending :id) ":" (tool :id)) :call (tool :id)}) config (pending :id)))
            (set admitted true) {:script (child :id) :status "accepted"})
          ([err fiber] {:status "rejected" :error (schema/diagnostic "AdmissionRejected" err fiber)})))
        (store/append s (pending :id) "receipt"
          {:tool (tool :id) :error (receipt :error)
           :message {:role "tool" :tool_call_id (tool :id) :content (schema/encode receipt)}}
          (string "receipt:" (pending :id) ":" (tool :id))))
      (store/append s (pending :id) "turn" {} (string "turn:" (pending :id)))
      (def after (get-in (store/event s (pending :parent)) [:data :views :after] 0))
      (def final (index-of (response :status) ["complete" "refused" "blocked"]))
      (if (and final (not (store/busy? s scope-id))
        (= 0 (length (store/changes s scope-id after))))
        (store/finish s (inquiry :id) "done" {:text (response :text) :status (response :status)})
        (if (or admitted final)
          (store/advance s (merge {:wait {:changes true} :after after}
            (if final {:final {:text (response :text) :status (response :status)}} {})))
          (store/advance s {}))))
    (label turn (do
      (def state (get (store/progress s (inquiry :id)) :data))
      (when (and (state :final) (not (store/busy? s scope-id))
        (= 0 (length (store/changes s scope-id (state :after)))))
        (return turn (store/finish s (inquiry :id) "done" (state :final))))
      (when-let [unknown (first (store/query s `SELECT m.* FROM events m WHERE m.parent=? AND m.kind='model' AND json_extract(m.data,'$.turn')=1
        AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=m.id AND r.kind='result') ORDER BY m.id LIMIT 1` [(inquiry :id)]))]
        (if (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='dispatch'" [(unknown :id)]))
          (return turn (store/append s (unknown :id) "result"
            {:type "model" :state "done" :role "chat" :turn true :status "continue" :tools [] :text ""
             :message {:role "assistant" :content "[Inference was interrupted before its response was committed. No tool calls from that response were admitted. Continue from committed execution evidence.]"}}
            (string "result:" (unknown :id))))
          (let [saved (store/restore s (unknown :image))]
            (return turn (model/call s (saved :input) (saved :key) (saved :selected))))))
      (def rounds (((store/query s "SELECT count(*) n FROM events WHERE parent=? AND kind='model' AND json_extract(data,'$.turn')=1" [(inquiry :id)]) 0) :n))
      (assert (< rounds (config :rounds)) "model round limit exhausted")
      (def selected (model/profile s (config :chat) :chat))
      (def tools (filter |(or (config :janet) (not= "function" ($ :type))) (selected :tools)))
      (def system {:role "system" :content (runtime/instructions config available)})
      (def budget @[(config :image-bytes)])
      (def input {:role "user" :content (model/images (get-in inquiry [:data :input])
        (string "Author: " (get-in inquiry [:data :author]) " · Occurred: " (get-in inquiry [:data :at]) "\n\n" (get-in inquiry [:data :input :text])) budget)})
      (def state {:role "user" :content (string "## World source\n\n" ((store/view s (get-in inquiry [:data :world])) :text))})
      (def window (min (get config :context-quota math/inf) (selected :context)))
      (def capacity (math/floor (/ (* window (config :context-percent)) 100)))
      (def scope (store/tree s scope-id))
      (def changes (tabseq [row :in (store/changes s scope-id 0)
        :unless (= "summary" (get-in (store/task s (row :id)) [:data :type]))] (row :id) true))
      (def replay (seq [row :in scope :let [data (row :data)
        message (cond
          (and (index-of (row :kind) ["result" "receipt"])
            (= (inquiry :id) (get (store/task s (row :id)) :id))
            (or (= "receipt" (row :kind)) (and (= "model" (data :type)) (data :turn)))) (data :message)
          (changes (row :id)) {:role "user" :content (string "Committed execution event:\n"
            (memory/render s row)
            (when (= "result" (row :kind)) (let [effect (store/event s (row :parent))]
              (when (= "operation" (effect :kind)) (schema/encode (schema/project (effect :data) [:name :arguments]))))))})]
        :when message] [row message]))
      (sort-by |(let [row ($ 0)] [(if (= "receipt" (row :kind)) (row :parent) (row :id)) (row :id)]) replay)
      (def previous (last (filter |(and (= "model" ($ :kind)) (= (inquiry :id) ($ :parent)) (get-in $ [:data :turn])) scope)))
      (var closed (get-in previous [:data :views :closed] 0))
      (when (>= (+ (model/estimate (array/concat @[system input state] (map |($ 1) (filter |(> (($ 0) :id) closed) replay))) (selected :reference))
        (store/estimate (schema/encode tools)) 768) capacity)
        (def pending (filter |(and (not= (inquiry :id) ($ :id)) (not= "summary" (get-in $ [:data :type]))) (store/pending s scope-id)))
        (each row scope
          (when (and (= "model" (row :kind)) (= (inquiry :id) (row :parent)) (get-in row [:data :turn])
            (not (find |(< ($ :id) (row :id)) pending))) (set closed (row :id))))
        (unless (store/busy? s scope-id) (set closed ((last scope) :id))))
      (def exchanges (map |($ 1) (filter |(> (($ 0) :id) closed) replay)))
      (def room (- capacity (model/estimate (array/concat @[system input state] exchanges) (selected :reference))
        (store/estimate (schema/encode tools)) 512))
      (when (<= room 256)
        (when-let [settling (find |(and (not= (inquiry :id) ($ :id)) (store/outcome s ($ :id))) (store/pending s scope-id))]
          (error {:code "Yield" :message "Waiting for a returned script to settle before compacting its exchange."
            :context {:wait {:operations [(settling :id)]}}})))
      (assert (> room 256)
        {:code "InquiryContextExhausted" :message "Instructions, inquiry, world and live exchanges leave insufficient context."
         :context {:model (selected :reference) :capacity capacity :remaining room}})
      (def context (memory/context s inquiry room (map |($ 0) (filter |(<= (($ 0) :id) closed) replay))))
      (def messages @[system])
      (def views @{:closed closed
        :records (distinct (catseq [row :in (context :nodes)] (if (row :segments) (map |($ 0) (row :segments)) [(row :id)])))
        :eligible (context :eligible) :retrieved (map |($ :id) (context :evidence))
        :candidates (context :candidates) :cutoff (config :score)})
      (each [key title rows] [[:chronological "Chronological memory" (context :nodes)] [:semantic "Retrieved excerpts" (context :evidence)]]
        (when (> (length rows) 0)
          (put views key (length messages))
          (def images @[])
          (each row rows (each source (if (row :segments) (map |(store/event s $) (distinct (map |($ 0) (row :segments)))) [row])
            (array/concat images (get-in source [:data :input :images] []))))
          (array/push messages {:role "user" :content (model/images {:images images} (string "## " title "\n\n" (string/join (map |(memory/render s $) rows))) budget)})))
      (put views :world (length messages)) (array/push messages state)
      (put views :inquiry (length messages)) (array/push messages input)
      (put views :after (if (> (length scope) 0) ((last scope) :id) (inquiry :id)))
      (array/concat messages exchanges)
      (assert (< (+ (model/estimate messages (selected :reference)) (store/estimate (schema/encode tools))) capacity) "inquiry exchanges exhaust context")
      (model/call s {:turn true :messages messages :tools tools :views views} (string "turn:" rounds) selected)))))

(defn- invoke [s effect available]
  (def name (get-in effect [:data :name]))
  (def args (get-in effect [:data :arguments]))
  (def binding (available name))
  (assert (and binding (not (binding :local)))
    {:code "BindingNotGranted" :message (string "Host binding is not granted: " name)})
  (when-let [[minimum maximum] (binding :arity)]
    (assert (<= minimum (length args) maximum)
      {:code "InvalidHostArguments"
       :message (string name " expects " (if (= minimum maximum) minimum (string minimum ".." maximum))
         " arguments; received " (length args) ".")
       :context {:effect (effect :id) :binding name :expected [minimum maximum]
         :received (length args) :signature (binding :doc)}}))
  (def local? (or (= name "self") (string/has-prefix? "world/" name)
    (string/has-prefix? "self/" name) (= name "effect/resolve") (= name "memory/expand")))
  (defn execute []
    (store/check s (effect :id))
    (def script (store/task s (effect :id)))
    (def world (get-in effect [:data :world]))
    (case name
      "world/view" (apply store/view s world args)
      "memory/expand" (apply memory/expand s script args)
      "effect/resolve"
      (let [[id outcome] args]
        (assert (= ((store/root s id) :id) ((store/root s (effect :id)) :id)) "attempt is outside this inquiry")
        (store/resolve s (store/event s id) outcome) outcome)
      "self"
      (let [input (merge (schema/request (first args) [:text :code :parent :memory_range :world]) {:request (effect :key)})
            config (if (input :text) (get (s :config) :agent (s :config)) (s :config))
            child (store/start s input config (effect :id))]
        {:script (child :id) :store (s :identity) :request (effect :key) :persist (not (s :temporary))})
      (if (index-of name ["self/status" "self/wait" "self/cancel"])
        (let [handle (first args) id (if (dictionary? handle) (handle :script) handle)]
          (when (dictionary? handle) (assert (= (handle :store) (s :identity)) "execution belongs to another store"))
          (assert (= "task" ((store/event s id) :kind)) "choose a script or inquiry")
          (assert (= ((store/root s id) :id) ((store/root s (effect :id)) :id)) "execution is outside this inquiry")
          (when (and (not= name "self/status") (not (and (= name "self/wait") (store/outcome s id))))
            (assert (and (not= id (script :id)) (find |(= id ($ :id)) (store/tree s (script :id)))) "choose a descendant"))
          (case name
            "self/cancel" (store/abort s (get-in (store/event s id) [:data :request]) "cancelled by caller")
            "self/status" (merge (get (store/outcome s id) :data {:state "pending"})
              {:script id :uncertain (filter |(and (= "uncertain" ($ :kind)) (not (store/result s ($ :parent)))) (store/tree s id))})
            (or (get (store/outcome s id) :data)
              (error {:code "Yield" :message "Waiting for a descendant." :context {:wait {:tasks [id]}}}))))
        (with-dyns [:zinc/operation (string (s :identity) "/" (effect :id))]
          (if (index-of name ["fs/list" "fs/read" "fs/write" "http/request" "process/run"])
            (io/invoke (s :config) name args) (apply (binding :value) args))))))
  (if local?
    (try (store/transact s (store/settle s effect {:state "done" :value (execute)}))
      ([err fiber]
        (when (index-of (get err :code) ["Yield" "TaskClosed" "TaskReplaced" "DeadlineExceeded"]) (error err))
        (store/settle s effect {:state "failed" :error (schema/diagnostic "OperationFailed" err fiber)})))
    (let [prior (first (store/query s "SELECT * FROM events WHERE parent=? AND kind='attempt' ORDER BY id DESC LIMIT 1" [(effect :id)]))]
      (if (and prior (not (store/result s (prior :id))))
        (do
          (store/uncertain s (prior :id)
            {:code "EffectUncertain" :message "Inspect this effect before resolving it or approving another attempt."
             :context {:effect (effect :id) :attempt (prior :id) :name name :arguments args :operation (string (s :identity) "/" (effect :id))}})
          (store/advance s {:wait {:operations [(prior :id)]}}))
        (let [attempt (store/append s (effect :id) "attempt" {} (string "attempt:" (effect :id) ":" (get prior :id 0)))]
          (store/append s (attempt :id) "dispatch" {})
          (try (store/settle s effect {:state "done" :value (execute)})
            ([err fiber]
              (when (index-of (get err :code) ["TaskClosed" "TaskReplaced" "DeadlineExceeded"]) (error err))
              (def failure (schema/diagnostic "OperationFailed" err fiber))
              (if (= "failed" (get-in failure [:context :outcome]))
                (store/settle s effect {:state "failed" :error failure})
                (do
                  (store/uncertain s (attempt :id)
                    (merge failure {:context (merge (get failure :context {})
                      {:effect (effect :id) :attempt (attempt :id) :name name :arguments args :operation (string (s :identity) "/" (effect :id))})}))
                  (store/advance s {:wait {:operations [(attempt :id)]}}))))))))))

(defn- execute [[config execution claim file signals]]
  (def s (store/open config nil file))
  (defer (store/close s)
    (def saved (store/restore s (execution :image)))
    (put s :signals signals)
    (with-dyns [:zinc/task execution :zinc/token (claim :token) :zinc/call s]
      (try
        (do
          (store/check s (execution :id))
          (def current (if (and (saved :inference) (not (config :inference)) (config :agent)) (config :agent) config))
          (put s :config (schema/authorize current saved))
          (def available (unless (= "summary" (get-in execution [:data :type]))
            (runtime/definitions (s :config) bindings)))
          (if (= "operation" (execution :kind)) (invoke s execution available)
            (case (get-in execution [:data :type])
              "inquiry" (infer s execution available)
              "summary" (store/finish s (execution :id) "done" (memory/summarize s execution))
              "script"
              (if (get-in (store/progress s (execution :id)) [:data :started])
                (do
                  (store/uncertain s (execution :id)
                    {:code "ContinuationLost" :message "The VM was interrupted. Inspect committed effects and source progress, then continue only the remaining work in a new script. Locals and native waits are unknown; do not replay the original source."
                     :context {:script (execution :id) :progress (get (store/progress s (execution :id)) :data)}})
                  (def returned (store/outcome s (execution :id)))
                  (store/finish s (execution :id) "failed" (get-in returned [:data :value])
                    {:code "ContinuationLost" :message "VM settlement and world publication were interrupted. Model-directed continuation required."}))
                (do
                  (store/advance s {:started true :form 0})
                  (def outcome (runtime/run s execution available))
                  (store/finish s (execution :id) (outcome :state) (outcome :value) (outcome :error))))
              (error "unsupported execution type"))))
        ([err fiber]
          (when (and (not (store/result s (execution :id)))
            (first (store/query s "SELECT task FROM claims WHERE task=? AND token=? AND expires>?" [(execution :id) (claim :token) (os/clock)])))
            (cond
              (= "Yield" (get err :code)) (store/advance s {:wait (get-in err [:context :wait])})
              (and (= "inquiry" (get-in execution [:data :type]))
                (= "unknown" (get-in err [:context :outcome]))) (store/advance s {})
              (not (index-of (get err :code) ["TaskClosed" "TaskReplaced"]))
              (store/finish s (execution :id) "failed" nil (schema/diagnostic "ExecutionFailed" err fiber)))))))))

(defn run [config root-id file updates]
  (def s (store/open config nil file))
  (def active @{}) (def finished (ev/chan 1))
  (def wake (ev/thread-chan 1)) (def ticked (ev/chan 1))
  (put s :signals [wake updates])
  (def ticker (ev/go (fn [] (while true (ev/sleep store/interval)
    (each channel (s :signals) (unless (ev/full channel) (ev/give channel true))))) nil ticked))
  (defer (do
    (ev/cancel ticker :finished) (ev/take ticked) (ev/chan-close ticked)
    (each [id running] (pairs active)
      (store/query s "UPDATE claims SET token=NULL,expires=0 WHERE task=? AND token=?" [id (running :token)]))
    (repeat (length active) (ev/take finished))
    (store/close s) (ev/chan-close finished) (ev/chan-close wake))
    (while true
      (def now (os/clock))
      (each [id running] (pairs active)
        (when (and (not (store/result s id)) (>= now (running :renew)))
          (when (first (store/query s "UPDATE claims SET expires=? WHERE task=? AND token=? AND expires>? RETURNING task"
            [(+ now (config :lease-seconds)) id (running :token) now]))
            (put running :renew (+ now (/ (config :lease-seconds) 3))))))
      (def pending (store/pending s root-id))
      (each execution pending
        (def id (execution :id))
        (when-let [deadline (get-in execution [:data :expires])]
          (when (<= deadline now) (store/finish s id "failed" nil {:code "DeadlineExceeded" :message "Execution deadline expired."})))
        (when (and (not (active id)) (not (store/result s id)) (ready? s execution))
          (when-let [claim (store/claim s id)]
            (def worker (ev/go (fn [[execution claim]]
              (def done (ev/thread-chan 1))
              (defer (ev/chan-close done)
                (with-env @{} (ev/thread execute [config execution claim file (s :signals)] (keyword "") done))
                (def packet (ev/take done))
                (assert (= :ok (packet 0)) (packet 1)))
              (execution :id)) [execution claim] finished))
            (put active id @{:token (claim :token) :fiber worker :renew (+ now (/ (config :lease-seconds) 3))}))))
      (when (and (= 0 (length pending)) (= 0 (length active))) (break))
      (def [_ channel packet] (ev/select finished wake))
      (when (= channel finished)
        (def [status fiber] packet)
        (def id (first (find |(= fiber (($ 1) :fiber)) (pairs active))))
        (store/query s "UPDATE claims SET token=NULL,expires=0 WHERE task=? AND token=?" [id ((active id) :token)])
        (put active id nil)
        (assert (= :ok status) (schema/diagnostic "ExecutorFailed" (fiber/last-value fiber) fiber))))))

(defn presentation [s row]
  (when-let [owner (store/task s (row :id))]
    (def root (store/root s (owner :id))) (def data (row :data))
    (def parent (when (row :parent) (store/event s (row :parent))))
    (def source (when (and (= "task" (row :kind)) (= "script" (data :type))) (get-in data [:input :code])))
    (def effect (and (= "result" (row :kind)) (= "operation" (get parent :kind))))
    (def terminal (and (= "result" (row :kind)) (= (owner :id) (row :parent))
      (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='return'
        AND (?='done' OR json_extract(data,'$.state')<>'done')" [(owner :id) (data :state)])))))
    (def body (cond
      (and (= "result" (row :kind)) (= "model" (data :type))
        (= "chat" (data :role)) (not (data :error)))
      (model/render data)
      source source
      (data :error) (schema/encode {:error (data :error)})
      effect nil
      (or terminal (index-of (row :kind) ["return" "fiber"]))
      (when (and (not= "inquiry" (get-in owner [:data :type]))
        (not= :null (data :value))
        (or (string? (data :value)) (nil? (owner :parent)))) (data :text))
      (index-of (row :kind) ["output" "world" "artifact" "uncertain"]) (data :text)))
    (when (and body (not= "summary" (get-in owner [:data :type])))
      {:kind (cond source "script" effect "effect" (= "model" (data :type)) "model" (row :kind))
       :script (if (= "script" (get-in owner [:data :type])) (owner :id) :null) :root (root :id) :store (s :identity)
       :agent (get-in s [:config :identity]) :request (get-in root [:data :request])
       :call (or (data :tool) (get-in owner [:data :call]) :null)
       :parent (or (row :parent) :null) :status (if source "accepted" (get data :status (get data :state "complete"))) :world (get-in owner [:data :world])
       :language (cond (or effect (data :error)) "json" source "clojure"
         (and terminal (= "inquiry" (get-in owner [:data :type]))) :null
         (and (or terminal (= "return" (row :kind))) (not (string? (data :value)))) "json"
         (or terminal (index-of (row :kind) ["return" "output" "fiber"])) "text" :null)
       :persist (not (s :temporary)) :sequence (row :id)
       :body (if (and (data :error) (not effect)) (schema/encode {:error (data :error)}) body) :diagnostic (data :error)})))

(defn observe [s root after emit updates &opt until-done]
  (var cursor after)
  (while true
    (def pending (and until-done (> (length (store/pending s (root :id))) 0)))
    (each row (store/tree s (root :id) cursor)
      (when (and (= (row :parent) (root :id))
        (or (= "return" (row :kind))
          (and (= "result" (row :kind))
            (not (first (store/query s "SELECT id FROM events WHERE parent=? AND kind='return'
              AND (?='done' OR json_extract(data,'$.state')<>'done')" [(root :id) (get-in row [:data :state])]))))))
        (emit (merge {:type "outcome" :script (root :id) :store (s :identity)} (row :data))))
      (when-let [frame (presentation s row)] (emit frame))
      (set cursor (row :id)))
    (when (and until-done (not pending)) (break))
    (ev/take updates))
  (merge {:script (root :id) :store (s :identity)} ((store/result s (root :id)) :data)))

(defn describe [config]
  {:contract "inquiry-v1" :initialize "init" :profile {:field "agent" :inference "inference"}
   :parameters (catseq [[target declarations] :in [[:config schema/fields] [:input schema/inputs]]]
     (seq [[key field] :in (sorted (pairs declarations)) :when (field :option)]
       (merge (schema/project field [:description :minimum :choices :autocomplete])
         {:name (field :option) :path (string target "." key) :type (string (field :type))
          :default (get config key (get field :default "automatic"))}
         (if (and (= target :config) (= :integer (field :type)) (> (get config key 0) 0)) {:maximum (config key)} {}))))})
