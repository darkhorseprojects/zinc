(import pa)
(import spork/json :as json)
(import spork/path :as path)
(import ./config)
(import ./store)
(import ./vm)
(import ./model)
(import ./memory)
(import ./effects)

(def directory (path/dirname (dyn :source)))
(def runtime (store/digest (string janet/version janet/build janet/config-bits
  (string/join (map |(slurp (path/join directory $))
    ["../project.janet" "main.janet" "config.janet" "store.janet" "store.sql" "vm.janet" "agent.janet" "model.janet" "memory.janet" "effects.janet"])))))
(defn storage [host c &opt initialize]
  (def key (if (c :ephemeral) (string "ram:" (c :profile)) (c :store)))
  (or (get-in host [:stores key])
    (let [s (store/open c initialize)] (put s :frame-limit (host :limit)) (put (host :stores) key s) s)))
(defn configured [host profile &opt options]
  (def original (get (host :profiles) (keyword (or profile (host :profile)))))
  (assert original "unknown profile")
  (def c (merge original))
  (each [k value] (pairs (or options {}))
    (assert (index-of k [:chat :thinking :rounds :queue :path :from :memory]) (string "unknown option " k))
    (when (index-of k [:chat :thinking]) (assert (string? value) "option must be text") (put c k value))
    (when (= k :rounds) (assert (and (int? value) (<= 1 value (original :rounds))) "round limit exceeds grant") (put c k value))) c)
(defn authorized-view [s reference author]
  (def row (store/row s reference))
  (when (= "point" (row :kind)) (store/require-access s reference author))
  (def selected (memory/resolve s reference))
  (unless (= author (get-in s [:config :handle]))
    (def allowed (distinct (catseq [p :in (store/query s "SELECT * FROM journal WHERE kind='point'")
      :when (store/accessible? s (p :key) author)]
      (map |($ :reference) (memory/sources s (store/load s (get-in p [:data :view]) "view"))))))
    (assert (every? (map |(index-of ($ :reference) allowed) (memory/sources s selected))) "memory outside authorized membership"))
  (store/append s "view" selected))
(defn author [s request]
  (var r (store/load s request "input"))
  (while (r :owner) (set r (store/load s (r :owner) "input"))) (r :author))
(defn policy [host s request]
  (def saved (store/load s ((store/load s request "input") :policy) "policy"))
  (config/authorize (configured host (saved :profile)) saved))
(defn definitions [host c]
  (config/registry c (host :imports)))

(defn local [host s p c request binding args]
  (def actor (author s request))
  (case binding
    "path/point" ((store/head s "point" (p :path)) :key)
    "self" (let [input (first args)]
      (when (input :memory) (authorized-view s (input :memory) actor))
      (when (input :from) (store/require-access s (input :from) actor))
      (when (input :path) (store/require-access s (input :path) actor))
      (store/admit s input c (c :handle) ((store/load s request "input") :context) request
        (unless (or (input :from) (input :path)) ((store/head s "point" (p :path)) :key))))
    "result" (let [ref (first args) id (if (dictionary? ref) (ref :request) ref)
      target (store/load s id "input")]
      (store/require-access s (target :path) actor) (store/receipt s id))
    "cancel" (let [ref (first args) id (if (dictionary? ref) (ref :request) ref)
      target (store/load s id "input")]
      (store/require-access s (target :path) actor) (store/cancel s id))
    "time/now" (os/clock)
    "random/bytes" (do (assert (and (= 1 (length args)) (int? (first args)) (<= 1 (first args) 4096)) "invalid random byte count")
      (string/join (map |(string/format "%02x" $) (string/bytes (os/cryptorand (first args))))))
    "world/view" {:world (p :world-name) :revision (p :world) :definitions (get p :definitions [])}
    "world/set" (let [input (first args) selected (store/point s (input :point)) world (get input :world (p :world-name))]
      (assert (and (c :rewind) (index-of world (c :worlds))) "world rewind not granted")
      (store/require-access s (selected :key) actor)
      (store/append s "world" {:world world :from (selected :key) :definitions (get-in selected [:data :definitions])}
        (string (s :identity) "/world/" (store/nonce)) (store/image s (selected :key))))
    "memory/view" (let [refs ((first args) :include)]
      (assert (indexed? refs) "memory/view requires an include array")
      (each ref refs (authorized-view s ref actor)) (memory/view s refs))
    "memory/expand" (let [ref (or (first args) (p :view)) selected (authorized-view s ref actor)]
      (memory/sources s (store/load s selected "view")))
    "memory/invalidate" (let [id (first args) old (store/load s id "summary")
      v (store/load s (p :view) "view")]
      (memory/subset s (memory/resolve s id) v)
      (if (index-of id (v :invalid)) false
        (do (put p :view (store/append s "view" (merge v {:invalid (array/concat @[] (v :invalid) [id])})))
          (store/append s "invalidate" {:path (p :path) :summary id}) true)))
    "presentation/tool" (do
      (def output (first args))
      (store/emit s request output)
      (store/close-output s request (args 1) (output :id)) true)
    "memory/record" (do
      (put p :view (memory/extend s (store/load s (p :view) "view")
        [(merge (first args) {:author (c :handle) :at (os/clock)})] c)) true)
    "memory/plan" (apply memory/plan s p c args)
    "memory/save" (do
      (memory/subset s {:roots [((first args) :node)] :invalid []} (store/load s (p :view) "view"))
      (memory/save s (first args) (args 1) c))
    "memory/finish" (memory/finish (first args) (args 1) c)
    (error (string "unknown local operation " binding))))

(defn fail [s request failure]
  (unless (store/receipt s request)
    (store/transact s
      (def input (store/load s request "input")) (def c (store/load s (input :policy) "policy"))
      (def old (store/head s "point" (input :path))) (def p (merge (old :data)))
      (put p :view (memory/extend s (store/load s (p :view) "view")
        [{:key (string request ":failure") :author (c :handle) :at (os/clock) :text (config/encode failure)}] c))
      (each effect (store/unfinished s "effect")
        (when (and (= request (get-in effect [:data :owner]))
          (not (first (store/query s "SELECT key FROM journal WHERE key=?" [(string "dispatch:" (effect :key))]))))
          (store/finish s (effect :key) {:status "cancelled" :error {:code "RequestClosed" :message "Owning request failed before dispatch."}})))
      (store/finish s request {:status "error" :error failure})
      (when (= request (p :active)) (put p :active nil) (put p :ready false) (put p :waits []))
      (store/checkpoint s p (old :image) (old :key))
      (store/emit s request {:type "response" :format "json" :text (config/encode failure) :done false})
      (store/close-output s request "error" nil {:path (p :path)}))))

(defn commit-step [host s old request packet ticket]
  (unless (store/receipt s request)
    (store/transact s
      (assert (= (old :key) ((store/head s "point" (get-in old [:data :path])) :key)) {:code "ReferenceChanged" :message "Path advanced during computation."})
      (def c (policy host s request)) (def p (merge (old :data))) (var expected (old :key))
      (def failure (packet :failure))
      (when failure (fail s request failure) (break))
      (put p :starting nil) (put p :ready (packet :ready)) (put p :waits (packet :waits))
      (put p :definitions (packet :definitions))
      (each ref (packet :waits)
        (unless (= ref ticket)
          (def target (store/row s ref))
          (assert (index-of (target :kind) ["input" "effect"]) "await expects work")
          (store/require-access s (get-in target [:data :path]) (author s request))
          (unless (store/receipt s ref)
            (assert (not (store/depends? s ref request)) {:code "WaitCycle" :message "Await would create a cycle through waits or queued work."}))))
      (when-let [operation (packet :operation)]
        (def binding (operation :binding)) (def args (operation :arguments))
        (when (index-of binding ["self" "path/point"])
          (set expected (store/checkpoint s p (packet :image) expected)))
        (def spec ((definitions host c) binding)) (assert spec "binding revoked")
        (def payload (cond (index-of binding ["model/chat" "model/rerank"])
          [(merge (model/prepare c (first args) (= binding "model/rerank")) (if (= binding "model/chat") {:output ticket} {}))]
          (= binding "sleep") (do (assert (and (= 1 (length args)) (number? (first args)) (<= 0 (first args) 31536000)) "invalid sleep duration") [(+ (os/clock) (first args))])
          args))
        (def cache (when (= binding "model/rerank")
          (store/digest (config/encode [payload (get-in c [:providers (keyword ((first payload) :provider))])]))))
        (store/append s "effect" {:path (p :path) :owner request :binding binding :arguments payload :cache cache} ticket)
        (when (and (= "external" (spec :class)) (not (spec :private)))
          (store/emit s request {:id (string ticket "/call") :type "tool-call" :format "json"
            :text (config/encode {:binding binding :arguments args}) :done true}))
        (when cache
          (when-let [prior (first (store/query s `SELECT r.data FROM journal e JOIN journal r ON r.key='receipt:'||e.key
            WHERE e.kind='effect' AND json_extract(e.data,'$.cache')=? AND json_extract(r.data,'$.status')='ok'
            ORDER BY e.sequence DESC LIMIT 1` [cache]))]
            (store/finish s ticket (prior :data))))
        (when (= "local" (spec :class))
          (unless (= binding "sleep")
            (store/finish s ticket (try {:status "ok" :value (local host s p c request binding args)}
              ([err fiber] {:status "error" :error (config/diagnostic err fiber)}))))))
      (when (> (length (packet :output)) 0)
        (put p :view (memory/extend s (store/load s (p :view) "view")
          [{:author (c :handle) :at (os/clock) :text (packet :output)}] c))
        (store/emit s request {:type "response" :format "markdown" :text (packet :output) :done true}))
      (var terminal nil)
      (when (packet :settled)
        (var outcome (packet :settled))
        (when (and (packet :changed) (= "ok" (outcome :status)))
          (def world (store/head s "world" (p :world-name)))
          (if (= (world :key) (p :world))
            (put p :world (store/append s "world" {:world (p :world-name) :path (p :path) :request request :definitions (p :definitions)}
              (string (s :identity) "/world/" (store/nonce)) (packet :world-image)))
            (do
              (def candidate (store/append s "candidate" {:path (p :path) :expected (p :world) :actual (world :key)} nil (packet :world-image)))
              (set outcome {:status "error" :error {:code "WorldChanged" :message "World changed; candidate retained without replaying effects." :context {:candidate candidate}}}))))
        (put p :view (memory/extend s (store/load s (p :view) "view")
          [{:key (string request ":result") :author (c :handle) :at (os/clock) :text (config/encode outcome)}] c))
        (store/finish s request outcome) (put p :active nil) (put p :ready false) (put p :waits [])
        (set terminal (outcome :status))
        (unless (and (= "ok" terminal) (packet :result-output))
          (def value (if (= "ok" terminal) (outcome :value) (outcome :error)))
          (store/emit s request {:type "response" :format (if (string? value) "markdown" "json")
            :text (if (string? value) value (config/encode value)) :done false})))
      (store/checkpoint s p (packet :image) expected)
      (when terminal
        (store/close-output s request (unless (and (= terminal "ok") (packet :result-output)) terminal) nil {:path (p :path)})))))

(defn commit-receipt [host s id receipt]
  (store/transact s
    (def effect (store/load s id "effect"))
    (def input (store/load s (effect :owner) "input"))
    (def c (store/load s (input :policy) "policy"))
    (def prior (store/receipt s id))
    (if prior (store/append s "observation" {:path (effect :path) :call id :receipt receipt}) (store/finish s id receipt))
    (def spec ((definitions host c) (effect :binding)))
    (when (and spec (not (spec :private)))
      (def old (store/head s "point" (effect :path))) (def p (merge (old :data)))
      (put p :view (memory/extend s (store/load s (p :view) "view")
        [{:author (c :handle) :at (os/clock) :text (config/encode {:binding (effect :binding) :arguments (effect :arguments) :receipt receipt})}] c))
      (store/checkpoint s p (old :image) (old :key)))
    (when (and (not prior) (not (store/receipt s (effect :owner)))
      (= "model/chat" (effect :binding)) (not (get-in effect [:arguments 0 :summary]))
      (= "ok" (receipt :status)) (index-of (get-in receipt [:value :stop]) ["tools" "continue" "answer" "refused"]))
      (store/close-output s (effect :owner) (get-in receipt [:value :stop]) id))))

(defn schedule [host]
  (var pending false)
  (each s (values (host :stores))
    (def requests (store/unfinished s "input"))
    (when (> (length requests) 0) (set pending true))
    (each r requests
      (def request (r :key)) (def path (get-in r [:data :path]))
      (when-let [deadline (get-in r [:data :deadline])]
        (when (<= deadline (os/clock)) (fail s request {:code "DeadlineExceeded" :message "Request deadline expired."})))
      (unless (or (get-in host [:active path]) (store/receipt s request))
        (try (do
          (def c (policy host s request))
          (put s :config c)
          (when-let [deadline (get-in r [:data :deadline])]
            (put c :seconds (max 0.001 (min (- deadline (os/clock)) (if (= 0 (c :seconds)) math/inf (c :seconds))))))
          (when (empty? (store/blocked-by s r))
            (var old (store/head s "point" path))
            (var p (merge (old :data)))
            (unless (= request (p :active))
              (def input (get-in r [:data :payload]))
              (store/transact s
                (when (input :memory) (put p :view (authorized-view s (input :memory) (author s request))))
                (put p :view (memory/extend s (store/load s (p :view) "view")
                  (array/concat @[] (get input :records [])
                    [{:key request :author (get-in r [:data :author]) :at (get input :at (os/clock)) :text (or (input :text) (input :code))}]) c))
                (put p :active request) (put p :starting true) (put p :ready true) (put p :waits [])
                (set old (store/row s (store/checkpoint s p (old :image) (old :key)) "point"))))
            (when (or (p :ready) (find |(store/receipt s $) (p :waits)))
              (when (< (length (host :active)) (c :parallel))
                (def receipts (tabseq [ref :in (p :waits) :let [receipt (store/receipt s ref)] :when receipt] ref receipt))
                (def ticket (string (s :identity) "/effect/" (store/nonce)))
                (def seed (store/image s (old :key)))
                (put (host :active) path true)
                (ev/go (fn []
                  (def result (ev/thread-chan 1))
                  (defer (ev/chan-close result)
                    (ev/thread (fn [[arguments result]] (ev/give result (vm/step arguments)))
                      [[seed (p :starting) (get-in r [:data :payload]) c (definitions host c) receipts ticket request] result] :n)
                    (ev/give (host :events) {:type "step" :store s :old old :request request :ticket ticket :packet (ev/take result)}))))))))
          ([err fiber]
            (unless (= "ReferenceChanged" (get err :code))
              (fail s request (config/diagnostic err fiber)))))))
    (def effects (store/unfinished s "effect"))
    (when (> (length effects) 0) (set pending true))
    (each r effects
      (def id (r :key)) (def d (r :data))
      (unless (get-in host [:effects id])
        (try (do
          (def c (policy host s (d :owner))) (def spec ((definitions host c) (d :binding)))
          (assert spec "binding revoked")
          (if (= "sleep" (d :binding))
            (when (<= ((d :arguments) 0) (os/clock)) (store/finish s id {:status "ok"}))
            (when (= "external" (spec :class))
              (if (first (store/query s "SELECT key FROM journal WHERE key=?" [(string "dispatch:" id)]))
                (commit-receipt host s id {:status "unknown" :error {:code "EffectOutcomeUnknown" :message "Dispatched effect has no committed receipt; it was not retried." :context {:effect id}}})
                (when (< (length (host :effects)) (c :parallel))
                  (store/append s "dispatch" {:call id} (string "dispatch:" id))
                  (put (host :effects) id true)
                  (ev/go (fn []
                    (def result (try (do
                      (def value (if (spec :import)
                        (do
                          (assert (= 1 (length (d :arguments))) "imports take one argument")
                          (def reply (ev/chan 1)) (def transport (store/nonce))
                          (put (host :pending) transport reply)
                          (ev/give (host :outgoing) {:type "call" :id transport :caller (host :handle) :method (d :binding) :params ((d :arguments) 0)})
                          (defer (ev/chan-close reply)
                            (def response (ev/take reply)) (when (response :error) (error (response :error))) (response :value)))
                        (let [reply (ev/thread-chan 16)]
                          (defer (ev/chan-close reply)
                            (ev/thread (fn [[c spec binding args reply]]
                              (def packet (try (let [value (effects/invoke c spec binding args reply)]
                                (config/encode value) {:value value})
                                ([err fiber] {:error (config/diagnostic err fiber)})))
                              (ev/give reply packet)) [c spec (d :binding) (d :arguments) reply] :n)
                            (var packet nil)
                            (while (nil? packet)
                              (def update (ev/take reply))
                              (if (= "output" (update :type))
                                (ev/give (host :events) {:type "output" :store s :effect id :output (update :output)})
                                (set packet update)))
                            (when (packet :error) (error (packet :error))) (packet :value)))))
                      (assert (<= (length (config/encode value)) (c :response-bytes)) "effect response limit")
                      {:status "ok" :value value})
                      ([err fiber] {:status (get-in err [:context :outcome] "error") :error (config/diagnostic err fiber)})))
                    (ev/give (host :events) {:type "receipt" :store s :id id :receipt result}))))))))
          ([err fiber] (commit-receipt host s id {:status "error" :error (config/diagnostic err fiber)})))))
    (when (has-key? s :cursor)
      (each row (store/query s "SELECT * FROM journal WHERE kind='output' AND sequence>? ORDER BY sequence" [(s :cursor)])
        (ev/give (host :outgoing) {:type "event" :value (merge (row :data) {:stream (s :identity) :cursor (row :key)})})
        (put s :cursor (row :sequence)))))
  pending)

(defn application [host call]
  (def params (call :params)) (def caller (call :caller)) (def method (call :method))
  (assert (dictionary? params) "application arguments must be an object")
  (when (= method "app/open")
    (assert (= caller (host :handle)) "only the connection owner configures the application")
    (def settings (params :settings)) (def profiles @{})
    (put host :imports (get call :imports {}))
    (each [name overrides] (pairs (settings :profiles))
      (def c (config/parse (merge (settings :config) overrides) (host :handle) (string name) runtime))
      (put c :catalogue (effects/catalogue c))
      (def registry (config/registry c (host :imports)))
      (put c :granted (keys registry))
      (put c :instructions-text (string (slurp (c :instructions)) "\n\n" (string/join
        (seq [[name spec] :in (sorted (pairs registry)) :unless (spec :private)] (spec :doc)) "\n")))
      (put profiles name c))
    (put host :profiles profiles) (put host :profile (settings :profile))
    (configured host nil)
    (each c (values profiles) (when (or (params :initialize) (c :ephemeral) (os/stat (c :store)))
      (storage host c (params :initialize))))
    (break {:profiles (tabseq [[name c] :pairs profiles] name
      {:parameters (map |(merge $ {:default (get c (keyword ($ :name)) "automatic")}) config/parameters)
       :commands (filter |(or (= "models" ($ :name)) (and (c :inspect) (not= "rewind" ($ :name)))
         (and (c :rewind) (= "rewind" ($ :name)))) config/commands)
       :history (c :history-records) :retain (not (c :ephemeral)) :inputs (c :accept)})}))
  (def c (configured host (params :profile) (params :options)))
  (def s (storage host c)) (put s :config c)
  (case method
    "app/submit"
    (do
      (def input (merge (params :input)))
      (assert (index-of (if (input :code) "code" "text") (c :accept)) "input kind is not granted")
      (def options (get params :options {}))
      (put input :queue (get options :queue (c :queue)))
      (merge-into input (tabseq [k :in [:queue :path :from :memory] :when (has-key? options k)] k (options k)))
      (when (params :request) (put input :request (params :request)))
      (unless (or (input :from) (input :path)) (when-let [p (get-in params [:state :path])] (put input :path p)))
      (when-let [view (or (input :memory) (get-in params [:state :memory]))]
        (put input :memory (authorized-view s view caller)))
      (store/transact s
        (def work (store/admit s input c caller (params :context)))
        {:work work :state {:path (work :path)}}))
    "app/read" (let [work (params :work) id (work :request)]
      (store/require-access s ((store/load s id "input") :path) caller)
      (when (params :wait) (while (not (store/receipt s id)) (ev/sleep 0.05))) (store/receipt s id))
    "app/cancel" (let [work (params :work) id (work :request)]
      (store/require-access s ((store/load s id "input") :path) caller) (store/transact s (store/cancel s id)))
    "app/observe" (do
      (assert (= caller (host :handle)) "only the connection owner observes output")
      (each store (values (host :stores))
        (def cursor (get (get params :cursors {}) (keyword (store :identity))))
        (put store :cursor (if cursor ((store/row store cursor "output") :sequence) 0))) true)
    "app/append" (do
      (def ref (get-in params [:state :path])) (assert ref "select a path before appending evidence")
      (store/require-access s ref caller)
      (store/transact s (def old (store/point s ref)) (def p (merge (old :data)))
        (assert (<= (length (params :records)) (c :history-records)) "source batch limit")
        (put p :view (memory/extend s (store/load s (p :view) "view") (params :records) c))
        (store/checkpoint s p (old :image) (old :key)) {:state {:path ref}}))
    "app/command"
    (do
      (def command (params :command)) (def args (get params :arguments {}))
      (when (= command "models")
        (def models (filter |(and (= (get args :role "chat") ($ :role))
          (or (not (args :query)) (string/find (string/ascii-lower (args :query)) (string/ascii-lower ($ :ref))))) (c :catalogue)))
        (break (if (params :completion) {:choices (map |{:name ($ :ref) :value ($ :ref)} (take 25 models))} {:value models})))
      (assert (if (= command "rewind") (c :rewind) (c :inspect)) "inspection is not granted")
      (def ref (get-in params [:state :path])) (assert ref "select a path first")
      (store/require-access s ref caller)
      (def old (store/point s ref)) (def p (merge (old :data)))
      (case command
        "point" {:value (old :key)}
        "memory-view" (store/transact s
          (def refs (json/decode (args :include) true true))
          (each r refs (authorized-view s r caller))
          (def view (memory/view s refs)) {:value view :state {:path ref :memory view}})
        "memory-expand" {:value (memory/sources s (memory/resolve s (authorized-view s (or (args :reference) (p :view)) caller)))}
        "memory-invalidate" (store/transact s
          (def id (args :reference)) (memory/subset s (memory/resolve s id) (store/load s (p :view) "view"))
          (def v (store/load s (p :view) "view"))
          (put p :view (store/append s "view" (merge v {:invalid (distinct (array/concat @[] (v :invalid) [id]))})))
          (store/append s "invalidate" {:path ref :summary id}) (store/checkpoint s p (old :image) (old :key)) {:value true})
        "world" {:value {:revision (p :world) :definitions (p :definitions)}}
        "rewind" (store/transact s
          (def selected (store/point s (args :point))) (store/require-access s (selected :key) caller)
          {:value (store/append s "world" {:world (p :world-name) :from (selected :key) :definitions (get-in selected [:data :definitions])}
            (string (s :identity) "/world/" (store/nonce)) (store/image s (selected :key)))})
        "memory-summarize" (store/transact s
          (when (args :view) (authorized-view s (args :view) caller))
          (def work (store/admit s {:code (string "(memory/summarize " (string/format "%q" args) ")") :queue true} c caller (params :context) nil (old :key)))
          {:work work :state {:path (work :path)}})
        "inspect" (let [r (store/row s (args :reference))]
          (def path (or (get-in r [:data :path]) (when-let [owner (get-in r [:data :call])]
            (get-in (store/row s owner) [:data :path]))))
          (assert path "choose a request, effect, receipt, or checkpoint") (store/require-access s path caller)
          {:value {:reference (r :key) :kind (r :kind) :data (r :data)}})
        (error "unknown application command")))
    (error "unknown application method")))

(defn main []
  (unless (index-of (os/which) [:windows :mingw]) (os/umask 8r077) (os/sigaction :pipe (fn [])))
  (def limit (scan-number (os/getenv "PA_FRAME_BYTES"))) (def handle (os/getenv "PA_HANDLE"))
  (assert (and (int? limit) (> limit 0) (string? handle) (> (length handle) 0)) "PA_FRAME_BYTES and PA_HANDLE are required")
  (def events (ev/chan 256)) (def incoming (ev/thread-chan 256)) (def outgoing (ev/thread-chan 256))
  (def host @{:handle handle :limit limit :events events :outgoing outgoing :stores @{} :profiles @{} :active @{} :effects @{} :pending @{} :calls @{}})
  (ev/thread (fn [[incoming limit]]
    (try (do (def buffer @"") (var message nil)
      (while (set message (pa/read stdin buffer limit)) (ev/give incoming message)) (os/exit 0 true))
      ([err] (eprint (config/encode (config/diagnostic err))) (os/exit 1 true)))) [incoming limit] :n)
  (ev/thread (fn [[outgoing limit]]
    (try (while true (pa/write stdout (ev/take outgoing) limit))
      ([err] (eprint (config/encode (config/diagnostic err))) (os/exit 1 true)))) [outgoing limit] :n)
  (ev/give outgoing {:type "ready" :handle handle})
  (while true
    (def [_ _ message] (ev/select incoming events))
    (case (message :type)
      "call" (do
        (assert (not (get-in host [:calls (message :id)])) "duplicate outstanding call")
        (put (host :calls) (message :id) true)
        (ev/go (fn []
          (def reply (try (let [result {:type "result" :id (message :id) :value (application host message)}]
            (assert (< (length (config/encode result)) limit) {:code "ResponseLimit" :message "Response exceeds PA_FRAME_BYTES."}) result)
            ([err fiber] {:type "error" :id (message :id) :error (config/diagnostic err fiber)})))
          (ev/give outgoing reply) (put (host :calls) (message :id) nil)
          (ev/give events {:type "wake"}))))
      "step" (do
        (put (host :active) (get-in message [:old :data :path]) nil)
        (try (commit-step host (message :store) (message :old) (message :request) (message :packet) (message :ticket))
          ([err fiber] (unless (= "ReferenceChanged" (get err :code))
            (fail (message :store) (message :request) (config/diagnostic err fiber))))))
      "output" (do
        (def s (message :store)) (def effect (store/load s (message :effect) "effect"))
        (unless (or (store/receipt s (message :effect)) (store/receipt s (effect :owner)))
          (try (store/transact s (store/emit s (effect :owner) (message :output)))
            ([err fiber] (fail s (effect :owner) (config/diagnostic err fiber))))))
      "receipt" (do (put (host :effects) (message :id) nil)
        (commit-receipt host (message :store) (message :id) (message :receipt)))
      "tick" (put host :timer nil)
      "wake" nil
      (do (def reply (get-in host [:pending (message :id)])) (assert reply "unexpected response identity")
        (put (host :pending) (message :id) nil) (ev/give reply message)))
    (when (and (schedule host) (not (host :timer)))
      (put host :timer true)
      (ev/go (fn [] (ev/sleep 0.05) (ev/give events {:type "tick"}))))))
