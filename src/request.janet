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
(defn fence [source language]
  (def marker (string/repeat "`" (+ 1 (reduce max 2 (map length (peg/match ~(any (choice (capture (some "`")) 1)) source))))))
  (string marker language "\n" source "\n" marker))
(def reference {:name "reference" :type "integer" :description "Selected ancestry point"})
(def subtree {:name "node" :type "string" :description "Exact subtree address: event:slot"})
(def commands
  {"models" {:description "List available models" :options [{:name "role" :type "string" :description "chat, rerank or summary"}]}
   "world-point" {:inspect true :description "Show the selected event" :read (fn [_ point _ _ _] (or point "No event selected."))}
   "world-view" {:inspect true :description "Render world source" :options [reference]
     :read (fn [s point _ c _] (fence (vm/view (store/image s point) c) "clojure"))}
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
  {:configSchema policy/schema
   :commands (seq [[name spec] :in (sorted (pairs commands)) :when (exposed? c spec)]
     {:name name :description (spec :description) :options (get spec :options [])})
   :intake {:max_records (c :history-records) :image_bytes (c :image-bytes)}})
(defn prepare [base context input]
  (def c (settings base))
  (def config (merge base {:conversation (context :conversation) :request (context :request) :scope (context :scope)}))
  (when (input :passive) (break {:config config :input :null :history (not (c :temporary))}))
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
  (when (and (= operation "submit") (some |(get-in c [$ :model]) [:chat :summary :rerank]))
    (put c :catalogue (effects/catalogue c))
    (each role [:chat :summary :rerank] (when-let [ref (get-in c [role :model])]
      (model/select c (if (= role :rerank) "rerank" "chat") ref))))
  (def kind (get config :input "text"))
  (def text (get input :text ""))
  (def body (if (and (= kind "json") (= operation "submit") (not (empty? text)))
    (merge (json/decode text true true))
    @{(if (and (= kind "code") (= operation "submit")) :code :text) text}))
  (when (not (empty? (get input :images []))) (put body :images (input :images)))
  (put body :at (input :at)) (put body :source {:key (input :key)})
  (merge-into config {:operation operation :arguments arguments :input "json"})
  {:config config :input body
   :history (and (= operation "submit") (not (get config :temporary false)))})

(defn append [host supplied batch]
  (def c (settings supplied)) (def s (store/storage host c))
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
      (executor/append-event host s h c {:kind "evidence" :source {:key (source :key) :conversation (c :conversation)}
        :author (source :author) :at (source :at) :text (source :text)})))
    (when scan (store/append s h (merge (store/anchor host s h c) {:kind "coverage"
      :coverage {:conversation (c :conversation) :through (scan :through)}}) c))
    (store/save s h c)
    true))
(defn same-source? [a c caller]
  (and a (= caller (a :author)) (= (policy/encode (c :scope)) (policy/encode (get-in a [:policy :scope] (a :scope))))))
(defn enter [host bytes c caller attachment]
  (def operation (c :operation))
  (def spec (commands operation))
  (when spec (assert (exposed? c spec) "command not granted"))
  (when (= operation "render")
    (def source (store/storage host (merge c {:temporary false})))
    (def h (store/selected host source c true))
    (def point (when (h :point) (store/nearest source (h :point) (get-in c [:arguments :reference]) c)))
    (put c :temporary true) (put c :path nil) (put c :from point))
  (def s (store/storage host c)) (put attachment :store s)
  (when (c :initialize) (break {:done true :value true}))
  (def args (c :arguments))
  (when (index-of operation ["read" "cancel" "resume"])
    (def work (c :work))
    (store/permit s (store/head s (work :path)) c)
    (def a (store/admission s (work :request)))
    (assert (and (= (get a :path) (work :path)) (same-source? a c caller)) {:code "NotAuthorized" :message "Work belongs to another source."})
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
  {:work work :cursor cursor})
(defn observe [host entry attachment c imports]
  (def s (attachment :store)) (def work (entry :work)) (var cursor (entry :cursor))
  (def emit (module/value imports 'output)) (var result nil)
  (while true
    (set result (or (get (host :results) [(s :identity) (work :request)]) (store/result s work)))
    (when emit (each r (store/rows s cursor)
      (def d (r :data)) (def kind (d :publish))
      (when (and ((attachment :requests) (d :request)) (index-of kind (c :publish))
        (not (and (= kind "diagnostic") (d :terminal) (= (d :request) (work :request)))))
        (def text (store/text (if-let [id (d :evidence)] (store/row s id) r)))
        (emit (merge {:type "text/markdown" :final true :data (case kind
          "response" text "reasoning" (string "> " (string/replace-all "\n" "\n> " text)) (fence text (get d :language "")))}
          (if (s :db) {:id (string (s :identity) ":" (r :id))
            :reply (when (d :reply) (string (s :identity) ":" (d :reply)))} {}))))
      (set cursor (r :id))))
    (if result (break) (ev/take (attachment :changed))))
  (unless (= "ok" (result :status)) (error (get result :error {:code "Cancelled" :message "Work cancelled."})))
  (when (or (not= "submit" (c :operation)) (not emit))
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
        (do ((module/value imports 'output) {:type "text/markdown" :data value :final true}) nil) value))
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
