(import spork/json :as json)
(import spork/path :as path)
(import ./executor)
(import ./policy)
(import ./store)
(import ./vm)
(import ./model)
(import ./memory)
(import ./effects)
(def directory (path/dirname (dyn :source)))
(def runtime (store/digest (string janet/version janet/build janet/config-bits (slurp (path/join directory "../project.janet"))
  (string/join (map |(slurp (path/join directory $)) ["main.janet" "policy.janet" "executor.janet" "request.janet" "store.janet" "store.sql" "vm.janet" "agent.janet" "model.janet" "memory.janet" "effects.janet"])))))
(defn settings [supplied] (policy/parse supplied (dyn :pa/handle) runtime))
(def options
  {"chat.model" {:type "string" :description "Chat model"}
   "chat.thinking" {:type "string" :description "Chat reasoning effort"}
   "rerank.model" {:type "string" :description "Rerank model"}
   "summary.model" {:type "string" :description "Summary model"}
   "summary.thinking" {:type "string" :description "Summary reasoning effort"}
   "rounds" {:type "integer" :minimum 1 :description "Maximum model rounds"}
   "context-percent" {:type "integer" :minimum 1 :maximum 100 :description "Shared memory allowance"}
   "path" {:type "integer" :description "Continue an exact path"}
   "from" {:type "integer" :description "Fork an exact event"}
   "memory" {:type "integer" :description "Select exact memory"}
   "queue" {:type "boolean" :description "Queue on a busy path"}
   "temporary" {:type "boolean" :description "Use RAM only"}})
(def reference {:name "reference" :type "integer" :description "Selected ancestry point"})
(def subtree {:name "node" :type "string" :description "Exact subtree address: event:slot"})
(def commands
  {"models" {:description "List available models" :options [{:name "role" :type "string" :description "chat, rerank or summary"}]}
   "world-point" {:inspect true :description "Show the selected event" :read (fn [_ point _ _ _] (or point "No event selected."))}
   "world-view" {:inspect true :description "Render world source" :options [reference]
     :read (fn [s point _ c _] {:point point :language "clojure" :text (vm/view (store/image s point) c)})}
   "world-inspect" {:inspect true :description "Inspect evidence" :options [reference]
     :read (fn [s point _ _ _] (assert point {:code "NoPoint" :message "No event selected."}) {:point point :event ((store/row s point) :data)})}
   "render" {:inspect true :description "Inspect the assembled model prompt" :options [reference]}
   "memory-expand" {:inspect true :description "Read original evidence" :options [reference subtree]
     :read (fn [s point roots c node] {:point point :sources (if node (memory/render s node) (memory/sources s roots c))})}
   "memory-summarize" {:binding "memory/summarize" :description "Install a subtree summary" :options [reference subtree
     {:name "text" :type "string" :description "Optional replacement summary"}]}
   "memory-invalidate" {:inspect true :binding "memory/invalidate" :description "Invalidate a subtree summary" :options [reference subtree]
     :read (fn [s _ roots c node] (assert node "supply an exact subtree address") (store/transact s (memory/invalidate s node roots c)))}})
(defn exposed? [c spec]
  (and spec (or (not (spec :inspect)) (c :inspect)) (or (not (spec :binding))
    (policy/selected? (spec :binding) (get-in c [:vm :user :bindings])))))
(defn describe [supplied]
  (def c (settings supplied))
  {:schema (tabseq [name :in (c :writable)] name (assert (options name) "unknown writable setting"))
   :commands (seq [[name spec] :in (sorted (pairs commands)) :when (exposed? c spec)]
     {:name name :description (spec :description) :options (get spec :options [])})
   :intake {:max_records (c :history-records) :image_bytes (c :image-bytes)}})
(defn prepare [base context overlay overrides input]
  (def c (settings base))
  (def config (merge base {:conversation (context :conversation) :request (context :request) :scope (context :scope)}))
  (when (input :passive) (break {:config config :input :null :options {} :history (not (c :temporary))}))
  (def command (get-in context [:command :name]))
  (when command (assert (exposed? c (commands command)) "command not granted"))
  (def operation (or command "submit"))
  (def arguments (if (= operation "submit") @{} (merge (get-in context [:command :arguments] {}))))
  (each [id value] (pairs arguments)
    (def field (find |(= (string id) ($ :name)) (get-in commands [command :options] [])))
    (assert (and field (case (field :type) "string" (string? value) "integer" (int? value) false)) "invalid command argument"))
  (when-let [node (arguments :node)]
    (assert (and (string? node) (peg/match ~(* (? "-") (some :d) ":" (some :d) -1) node)) "Subtree addresses are event:slot")
    (put arguments :node (map scan-number (string/split ":" node))))
  (when (arguments :reference) (put arguments :point (arguments :reference)))
  (assert (not (and (overrides :from) (overrides :path))) "path and from are mutually exclusive")
  (def effective (merge overlay overrides))
  (when (overrides :from) (put effective :path nil))
  (when (overrides :path) (put effective :from nil))
  (var catalogue nil)
  (each [name value] (pairs effective)
    (def name (string name))
    (def field (get options name))
    (assert (and field (index-of name (c :writable))) "option is not exposed")
    (def location (map keyword (string/split "." name)))
    (assert (case (field :type) "string" (and (string? value) (> (length value) 0)) "boolean" (boolean? value)
      "integer" (and (int? value) (<= (get field :minimum (- math/inf)) value (get field :maximum math/inf)))) "invalid option value")
    (when (and (not= "models" operation) (string/has-suffix? ".model" name))
      (unless catalogue (set catalogue (effects/catalogue c @{})))
      (model/select (merge c {:catalogue catalogue}) (if (= name "rerank.model") "rerank" "chat") value))
    (when (= name "path") (put config :from nil))
    (when (= name "from") (put config :path nil))
    (when (= 2 (length location)) (put config (location 0) (merge (get config (location 0) {}))))
    (put-in config location value))
  (def kind (get config :input "text"))
  (def text (get input :text ""))
  (def body (if (and (= kind "json") (= operation "submit") (not (empty? text)))
    (merge (json/decode text true true))
    @{(if (and (= kind "code") (= operation "submit")) :code :text) text}))
  (when (not (empty? (get input :images []))) (put body :images (input :images)))
  (put body :at (input :at)) (put body :source {:key (input :key)})
  (merge-into config {:operation operation :arguments arguments :input "json"})
  {:config config :input body :options effective
   :history (and (= operation "submit") (not (get config :temporary false)))})

(defn append-evidence [host s c batch]
  (def records (batch :records)) (def scan (batch :scan))
  (assert (and (s :db) (indexed? records) (<= (length records) (c :history-records))) "evidence batch limit")
  (each source records
    (assert (and (dictionary? source) (string? (source :key)) (string? (source :author)) (source :at)
      (string? (source :text)) (<= 1 (length (source :text)) (c :source-bytes))) "invalid evidence"))
  (when scan (assert (and (string? (scan :through)) (or (nil? (scan :after)) (string? (scan :after)))) "invalid coverage"))
  (store/transact s
    (def h (store/selected host s c))
    (def intake (store/intake s (h :point) (c :conversation) (map |($ :key) records)))
    (def through (get (find |($ :through) intake) :through))
    (when (and scan (not= through (scan :after)))
      (error {:code "HistoryMoved" :message "Conversation coverage advanced."}))
    (def seen (tabseq [r :in intake :when (r :key)] (r :key) true))
    (each source records (unless (seen (source :key))
      (put seen (source :key) true)
      (def base (store/anchor host s h c))
      (def r (store/append s h (merge base {:kind "evidence"
        :source {:key (source :key) :conversation (c :conversation)} :author (source :author)
        :at (source :at) :text (source :text)}) c))
      (def roots (memory/extend s r (base :memory) c))
      (when (get-in h [:run :active]) (put-in h [:run :memory] roots))))
    (when scan (store/append s h (merge (store/anchor host s h c) {:kind "coverage"
      :coverage {:conversation (c :conversation) :through (scan :through)}}) c))
    (store/save s h c)
    true))
(defn same-source? [a c caller]
  (and a (= caller (a :author)) (= (policy/encode (c :scope)) (policy/encode (get-in a [:policy :scope])))))
(defn enter [host bytes c caller attachment]
  (def operation (c :operation))
  (def started (os/clock))
  (def spec (commands operation))
  (when spec (assert (exposed? c spec) "command not granted"))
  (when (= operation "render")
    (def source (store/storage host (merge c {:temporary false})))
    (def h (store/selected host source c true))
    (def point (when (h :point) (store/nearest source (h :point) (get-in c [:arguments :reference]) c)))
    (put c :temporary true) (put c :path nil) (put c :from point))
  (def s (store/storage host c)) (put attachment :store s)
  (policy/trace c "storage" {:operation operation :temporary (c :temporary) :ms (* 1000 (- (os/clock) started))})
  (when (c :initialize) (break {:done true :value true}))
  (def args (c :arguments))
  (when (index-of operation ["read" "cancel" "resume"])
    (def work (c :work))
    (store/permit s (store/head s (work :path)) c)
    (assert (same-source? (store/admission s work) c caller) {:code "NotAuthorized" :message "Work belongs to another source."})
    (case operation
      "read" (break {:done true :value (store/result s work)})
      "cancel" (break {:done true :value (executor/cancel host s work c)})))
  (when-let [read (get spec :read)]
    (def h (store/selected host s c true))
    (def exact (if (= operation "memory-invalidate") (store/access s (or (args :reference) (h :point)) c)
      (when (h :point) (store/nearest s (h :point) (args :reference) c))))
    (def roots (when exact (get-in (store/row s exact) [:data :memory])))
    (when (args :node) (memory/allowed s (args :node) roots c))
    (break {:done true :value (read s exact roots c (args :node))}))
  (assert (index-of operation ["submit" "resume" "memory-summarize" "render"]) "unknown Zinc operation")
  (when (= operation "memory-summarize")
    (assert (get-in c [:registry :user "memory/summarize"]) "summary generation not granted")
    (when (args :point) (put c :memory (store/access s (args :point) c))))
  (def cursor (store/cursor s))
  (def work (if (= operation "resume") (c :work)
    (let [input (if (index-of operation ["memory-summarize" "render"]) {:code "nil"}
      (merge (if (= "json" (c :input)) (postwalk |(if (= $ :null) nil $) (json/decode bytes true true)) {(keyword (c :input)) bytes})))]
      (each key [:request :path :from :memory] (when (c key) (put input key (c key))))
      (executor/submit host s input c caller))))
  (assert (not (get-in host [:owners [(s :identity) (work :request)] :open])) "request already has a live observer")
  (put (host :owners) [(s :identity) (work :request)] attachment)
  (put attachment :work work) (put attachment :requests @{(work :request) true})
  (each a (sorted (store/pending s) |(< ($0 :depth) ($1 :depth)))
    (def key [(s :identity) (a :request)])
    (when (and (not (get-in host [:owners key :open])) (same-source? a c caller)
      ((attachment :requests) (a :owner)))
      (put (attachment :requests) (a :request) true)
      (put (host :owners) key attachment)))
  (policy/trace c "admit" {:request (work :request) :path (work :path) :cursor cursor :ms (* 1000 (- (os/clock) started))})
  {:work work :cursor cursor})
(defn footer [f] (string "#" (f :start) " → #" (f :result) " · " (f :status)))
(defn observe [host entry attachment c imports]
  (def s (attachment :store)) (def work (entry :work)) (var cursor (entry :cursor))
  (def requests (attachment :requests)) (def delivered @{}) (var active nil) (var result nil) (var end nil)
  (while true
    (each r (store/rows s cursor)
      (when (and (requests (get-in r [:data :request])) (get-in r [:data :presentation])
        (not (and (= (work :request) (get-in r [:data :request])) (get-in r [:data :terminal])
          (not= "ok" (get-in r [:data :outcome :status]))))
        (index-of (get-in r [:data :presentation :type]) (c :publish)))
        (when-let [emit (module/value imports 'output)]
          (def output (merge (get-in r [:data :presentation])
            {:text (store/text (if-let [id (get-in r [:data :evidence])] (store/row s id) r))}))
          (when (output :footer) (put output :footer (footer (output :footer))))
          (emit output)
          (when (and (= "response" (output :type)) (not (output :footer))) (put delivered (output :id) (r :id)))))
      (set cursor (r :id)))
    (each [id point] (pairs delivered)
      (def r (store/row s point)) (def f (get-in r [:data :presentation :footer]))
      (when (and (get-in r [:data :terminal]) f)
        ((module/value imports 'output) {:type "metadata" :id id :footer (footer f)}) (put delivered id nil)))
    (def working (some |(requests (get-in $ [:run :active :request])) (values (s :heads))))
    (unless (= active working) (set active working)
      (when-let [emit (module/value imports 'output)] (emit {:type "activity" :active (not (nil? active))})))
    (set result (or (get (host :results) [(s :identity) (work :request)]) (store/result s work)))
    (if result
      (do (unless end (set end (store/cursor s)))
        (when (if (s :db) (>= cursor end) (<= cursor end)) (break)))
      (ev/take (attachment :changed))))
  (put (host :results) [(s :identity) (work :request)] nil)
  (unless (= "ok" (result :status)) (error (get result :error {:code "Cancelled" :message "Work cancelled."})))
  (when (or (not= "submit" (c :operation)) (not (module/value imports 'output)))
    (if (result :output) result (result :value))))

(defn invoke [host bytes supplied imports]
  (def c (settings supplied))
  (when (= "models" (c :operation)) (def failures @{}) (break (model/describe c (effects/catalogue c failures) failures)))
  (put c :registry (tabseq [role :in [:user :agent]] role (vm/registry c role imports)))
  (put c :instructions-text (string (slurp (c :instructions))))
  (def root (dyn :pa/root))
  (merge-into root {:config c :imports imports :changed (ev/chan 1)})
  (put (host :attachments) (root :id) root)
  (defer (do
      (put (host :attachments) (root :id) nil)
      (each [key owner] (pairs (host :owners)) (when (= owner root) (put (host :owners) key nil)))
      (when-let [work (root :work)]
        (def s (root :store)) (put (host :results) [(s :identity) (work :request)] nil)
        (when (and (not (s :db)) (find |(= (work :request) ($ :request)) (store/pending s)))
          (executor/cancel host s work c)))
      (ev/chan-close (root :changed)) (ev/give (host :events) {:type "wake"}))
    (def entry (enter host bytes c (root :caller) root))
    (ev/give (host :events) {:type "wake"})
    (if (entry :done) (let [value (entry :value)]
      (if (and (= "world-view" (c :operation)) (module/value imports 'output))
        (do ((module/value imports 'output) (merge value {:type "tool-result"})) nil) value))
      (observe host entry root c imports))))

(defn activate [host supplied authority]
  (def c (settings supplied))
  (assert (and (= (dyn :pa/handle) ((dyn :pa/root) :caller)) (string? authority)) "invalid local grant")
  (unless (c :temporary)
    (def s (store/storage host c)) (put (host :grants) [(s :identity) authority] {:config c})
    (ev/give (host :events) {:type "wake"}) true))
(defn position [host supplied]
  (def c (settings supplied)) (def s (store/storage host c))
  (assert (s :db) "coverage requires durable history")
  (store/transact s
    (def h (store/selected host s c)) (def target (merge supplied {:path (h :id)})) (put target :from nil)
    {:config target :through (get (find |($ :through) (store/intake s (h :point) (c :conversation) [])) :through :null)}))
(defn append [host supplied batch]
  (def c (settings supplied)) (append-evidence host (store/storage host c) c batch))
