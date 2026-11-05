(import ./schema)
(import ./store)
(import ./io)

(def- asynchronous ["ev/go" "ev/spawn" "ev/go-gather" "ev/gather" "ev/sleep" "ev/chan" "ev/take" "ev/give" "ev/count" "ev/chan-close" "ev/cancel"])

(defn definitions [config supplied]
  (if-not (config :janet) {}
    (let [base (make-env)
          available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)
            :unless (and (string/has-prefix? "ev/" (string name)) (not (index-of (string name) asynchronous)))]
            (cond (= name '*) "core/multiply" (string/find "/" (string name)) (string name) (string "core/" name))
            (cond
              (index-of name ['os/clock 'os/date 'os/time 'os/cryptorand]) (base name)
              (index-of (string name) asynchronous) (merge (base name) {:local name})
              {:local name}))
          imports (get config :imports {})
          cache (merge module/cache)
          paths (array/concat @[] module/paths)]
      (each [namespace spec] (pairs imports)
        (put cache (string namespace)
          (tabseq [[name documentation] :pairs (spec :exports)]
            (symbol name) @{:doc documentation :value (fn [& args]
              (io/call spec (string name) args (dyn :zinc/operation) (config :response-bytes)))})))
      (array/insert paths 0 [(fn [name] (when (get imports (keyword name)) name)) :preload])
      (put base *module-cache* cache) (put base *module-paths* paths)
      (put base *module-make-env* (partial make-env base))
      (merge-into available supplied)
      (each [namespace module] (pairs (get-in config [:janet :imports]))
        (each [name binding] (pairs (with-env base (require (module :module))))
          (when (and (symbol? name) (not (binding :private)) (not (binding :macro))
                     (index-of (type (binding :value)) [:function :cfunction])
                     (or (nil? (module :export)) (= (string name) (module :export))))
            (def qualified (if (module :export) (string namespace) (string namespace "/" name)))
            (assert (and (not (available qualified)) (string? (binding :doc))) "invalid or undocumented host binding")
            (put available qualified binding))))
      (def selected (schema/select (keys available) (get-in config [:janet :bindings])))
      (put (config :janet) :bindings selected)
      (tabseq [name :in selected] name (available name)))))

(defn public [config bindings]
  {:settings (schema/project config (map keyword (get-in config [:janet :values] [])))
   :resources (tabseq [[key field] :pairs schema/fields :when (field :public)
     :let [grants (tabseq [[name grant] :pairs (config key)
       :let [functions (sorted (seq [[name binding] :pairs bindings :when (= key (binding :resource))
         :when (or (not (binding :permission)) (grant (binding :permission)))] name))]
       :when (> (length functions) 0)] name (merge (schema/project grant (field :public)) {:functions functions}))]
     :when (> (length grants) 0)] key grants)})

(defn instructions [config bindings]
  (string (slurp (config :instructions))
    (when (config :janet)
      (string "\n\n## Execution\n\nself admits independent work and returns its handle. task/wait suspends the caller without restarting its source. Locals, closures and managed ev fibers resume from committed VM images. Checkpoints and operation identities are automatic. Use world/commit only to publish shared values; it is not a save command. Uncertain external operations must be checked before task/resolve records their outcome. Temporary sessions do not promise restart durability.\n"
        "\n## Settings and resources\n\n" (schema/encode (public config bindings))
        "\n\n## Host bindings\n\n" (string/join (seq [[_ binding] :in (sorted (pairs bindings)) :unless (binding :local)] (binding :doc)) "\n\n")))))

(defn- initialize [code id input instructions public bindings setup limit]
  (def native (make-env))
  (def env @{:redef true})
  (def output @"")
  (put env :out (fn [text] (buffer/push-string output text) (assert (<= (length output) limit) "script output byte ceiling")))
  (put env :err (env :out))
  (each [name binding] (pairs bindings)
    (put env (or (binding :local) (symbol name))
      (if (and (binding :local) (not (index-of name asynchronous))) (native (binding :local))
        @{:doc (binding :doc) :value (fn [& args]
          (when (= name "ev/sleep")
            (assert (and (= 1 (length args)) (number? (first args)) (< (math/abs (first args)) math/inf)) "ev/sleep expects finite seconds"))
          (def reply (debug {:kind :call :name name :args args}))
          (when (reply :error) (error (reply :error))) (reply :value))})))
  (def random @[(math/rng (os/cryptorand 32))])
  (when (bindings "math/random") (put env 'math/random @{:value (fn [] (math/rng-uniform (random 0)))}))
  (when (bindings "math/seedrandom") (put env 'math/seedrandom @{:value (fn [seed] (put random 0 (math/rng seed)) nil)}))
  (when (bindings "ev/spawn")
    (put env 'ev/spawn @{:macro true :value (fn [& body] ~(ev/go (fn [] ,;body)))}))
  (when (bindings "ev/gather")
    (put env 'ev/gather @{:macro true :value (fn [& bodies] ~(ev/go-gather ,(map |~(fn [] ,$) bodies)))}))
  (each [name value] [['input (fn [] input)] ['self/document (fn [] instructions)]
                    ['settings (fn [] (public :settings))] ['resources (fn [] (public :resources))]]
    (put env name @{:value value}))
  (when (bindings "fiber/root") (put env 'fiber/root @{:value (fn [] (dyn :zinc/root))}))
  (def options (if setup ((module/value (require setup) 'configure) env) {}))
  (each key (keys options) (assert (= key :expander) "durable evaluation supports an expander, not a live parser or reader"))
  (put env *module-paths* []) (put env *module-cache* @{})
  (def forms (parse-all code))
  (def root (fiber/new (fn []
      (var value nil)
      (each form forms
        (def expanded (if (options :expander) ((options :expander) form) form))
        (def thunk (compile expanded env (string "script/" id)))
        (debug {:kind :checkpoint})
        (set value (thunk))
        (debug {:kind :checkpoint})) value) :ade env))
  @{:root root :ready @[[root nil]] :waiting @{} :supervisors @{} :sequence 0 :output output})

(defn- evaluate [[code id input instructions public bindings setup bytes events inbox stop limit seconds]]
  (def lookup (env-lookup (make-env)))
  (def graph (if bytes (unmarshal bytes lookup) (initialize code id input instructions public bindings setup limit)))
  (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (when (> seconds 0) (ev/deadline seconds (fiber/root) (fiber/root) true))
  (def owner (fiber/root))
  (def stopped (ev/chan 1))
  (def watcher (ev/go (fn [] (ev/take stop) (ev/cancel owner :execution-ended)) nil stopped))
  (defer (do (ev/cancel watcher :finished) (ev/take stopped))
    (each [_ wait] (pairs (graph :waiting))
      (when (= :host (wait :kind)) (ev/give events {:kind :resume :call wait})))
    (label complete (while true
      (each [fiber wait] (pairs (merge (graph :waiting)))
        (when (get (graph :waiting) fiber)
        (var reply nil)
        (case (wait :kind)
          :join (when (every? (map |(= :dead (fiber/status $)) (wait :fibers)))
            (set reply {:value (map fiber/last-value (wait :fibers))}))
          :take (let [channel (wait :channel)]
            (cond
              (channel :closed) (set reply {:value nil})
              (> (length (channel :items)) 0)
              (do
                (set reply {:value (first (channel :items))}) (array/remove (channel :items) 0)
                (when (> (length (channel :writers)) 0)
                  (def writer (first (channel :writers))) (array/remove (channel :writers) 0)
                  (put (graph :waiting) writer nil) (array/push (graph :ready) [writer {:value channel}])))))
          :give (when (get-in wait [:channel :closed]) (set reply {:value nil})) nil)
        (when reply (put (graph :waiting) fiber nil) (array/push (graph :ready) [fiber reply]))))
      (when (and (= 0 (length (graph :ready))) (= 0 (length (graph :waiting))))
        (def value (fiber/last-value (graph :root)))
        (def result (string (graph :output) (if (string? value) value (string/format "%n" value))))
        (assert (<= (length result) limit) "script result byte ceiling") (return complete result))
      (if (= 0 (length (graph :ready)))
        (let [ack (ev/thread-chan 1)]
          (ev/give events {:kind :idle :reply ack})
          (when (= :yield (ev/take ack)) (return complete :yield))
          (def reply (ev/take inbox))
          (unless (reply :blocked)
            (def fiber (find |(= (get (get (graph :waiting) $) :key) (reply :key)) (keys (graph :waiting))))
            (when fiber (put (graph :waiting) fiber nil) (array/push (graph :ready) [fiber (reply :outcome)]))))
        (let [[fiber reply] (first (graph :ready))]
          (array/remove (graph :ready) 0)
          (unless (fiber/getenv fiber) (fiber/setenv fiber (fiber/getenv (graph :root))))
          (put (fiber/getenv fiber) :zinc/root fiber)
          (def packet (resume (fiber/new (fn []
            (if (and (dictionary? reply) (has-key? reply :cancel)) (cancel fiber (reply :cancel)) (resume fiber reply))) :a)))
          (def status (fiber/status fiber))
          (def supervisor (get (graph :supervisors) fiber))
          (when (and supervisor (index-of status [:dead :error]))
            (array/push (supervisor :items) [(if (= :dead status) :ok :error) fiber]) (put (graph :supervisors) fiber nil))
          (when (and (= status :error) (not supervisor)) (error (schema/diagnostic "ExecutionFailed" packet fiber)))
          (var call nil)
          (case status
            :dead nil
            :error nil
            :debug
            (if (= :checkpoint (packet :kind)) (array/push (graph :ready) [fiber nil])
              (let [[a b c] (packet :args)]
                (case (packet :name)
                  "ev/go" (let [child (if (fiber? a) a (fiber/new a :ade (fiber/getenv fiber)))]
                    (when c (put (graph :supervisors) child c))
                    (array/push (graph :ready) [child b])
                    (array/push (graph :ready) [fiber {:value child}]))
                  "ev/go-gather" (let [children (map |(fiber/new $ :ade (fiber/getenv fiber)) a)]
                    (each child children (array/push (graph :ready) [child nil]))
                    (put (graph :waiting) fiber {:kind :join :fibers children}))
                  "ev/chan" (do (assert (or (nil? a) (and (int? a) (>= a 0))) "invalid channel capacity")
                    (array/push (graph :ready) [fiber {:value @{:items @[] :writers @[] :capacity (or a 0) :closed false}}]))
                  "ev/take" (put (graph :waiting) fiber {:kind :take :channel a})
                  "ev/give" (if (a :closed)
                    (array/push (graph :ready) [fiber {:error {:code "ChannelClosed" :message "Channel is closed."}}])
                    (do (array/push (a :items) b)
                      (if (<= (length (a :items)) (a :capacity)) (array/push (graph :ready) [fiber {:value a}])
                        (do (array/push (a :writers) fiber) (put (graph :waiting) fiber {:kind :give :channel a})))))
                  "ev/count" (array/push (graph :ready) [fiber {:value (length (a :items))}])
                  "ev/chan-close" (do (put a :closed true) (array/push (graph :ready) [fiber {:value a}]))
                  "ev/cancel" (do
                    (when-let [channel (get-in graph [:waiting a :channel])]
                      (put channel :writers (filter |(not= a $) (channel :writers))))
                    (put (graph :waiting) a nil) (put graph :ready (filter |(not= a ($ 0)) (graph :ready)))
                    (when (fiber/can-resume? a) (array/push (graph :ready) [a {:cancel b}]))
                    (array/push (graph :ready) [fiber {:value a}]))
                  (do
                    (put graph :sequence (+ 1 (graph :sequence)))
                    (set call {:kind :host :key (graph :sequence) :name (packet :name) :args (packet :args)})
                    (put (graph :waiting) fiber call)))))
            (error "unhandled script signal"))
          (def ack (ev/thread-chan 1))
          (def encoded (try (marshal graph (invert lookup)) ([err f] (error (schema/diagnostic "SnapshotFailed" err f)))))
          (ev/give events {:kind :save :image encoded :call call :reply ack})
          (ev/take ack)))))))

(defn run [s task bindings handler]
  (def config (s :config))
  (def events (ev/thread-chan 1)) (def inbox (ev/thread-chan (config :task-quota)))
  (def stop (ev/thread-chan 1)) (def finished (ev/thread-chan 1))
  (def pending @{}) (def blocked @{})
  (var idle nil) (var joined false) (var bytes nil)
  (when-let [hash (get (store/progress s (task :id)) :image)]
    (def row (first (store/query s "SELECT * FROM images WHERE hash=?" [hash])))
    (assert (= (row :runtime) (s :runtime)) {:code "RuntimeChanged" :message "Execution image requires its original runtime and bindings."})
    (set bytes (row :bytes)))
  (def seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds))
    (- (or (get-in task [:data :expires]) math/inf) (os/clock))))
  (def arguments [(get-in task [:data :input :code]) (task :id) (get-in task [:data :input])
    (instructions config bindings) (public config bindings) (tabseq [[name binding] :pairs bindings] name (schema/project binding [:local :doc]))
    (get-in config [:janet :setup]) bytes events inbox stop (config :response-bytes) (if (= seconds math/inf) 0 (max 0.001 seconds))])
  (with-env @{} (ev/thread evaluate arguments :n finished))
  (defer (do
    (ev/give stop true)
    (each [_ worker] (pairs (merge pending)) (when (fiber/can-resume? (worker :fiber)) (ev/cancel (worker :fiber) :script-ended)) (ev/take (worker :done)))
    (unless joined (ev/take finished))
    (each channel [events inbox stop finished] (ev/chan-close channel)))
    (label done (while true
      (def [_ channel packet] (ev/select events finished))
      (if (= channel finished)
        (do (set joined true) (assert (= :ok (packet 0)) (packet 1))
          (if (= :yield (packet 1)) (error {:code "Yield" :message "Execution suspended."}) (return done (packet 1))))
        (do
          (when (= :idle (packet :kind)) (set idle (packet :reply)))
          (when (= :save (packet :kind))
            (set bytes (packet :image))
            (store/transact s
              (when-let [call (packet :call)]
                (store/append s (task :id) "operation" {:name (call :name) :arguments (store/display (call :args))
                  :until (when (= "ev/sleep" (call :name)) (+ (os/clock) (first (call :args))))}
                  (string "operation:" (task :id) ":" (call :key)) (store/image s (call :args))))
              (store/advance s {} bytes))
            (ev/give (packet :reply) true))
          (when (or (= :resume (packet :kind)) (and (= :save (packet :kind)) (packet :call)))
            (def call (packet :call))
            (def admission (first (store/query s "SELECT * FROM events WHERE key=?" [(string "operation:" (task :id) ":" (call :key))])))
            (def stopped (ev/chan 1))
            (def worker (ev/go (fn []
              (def outcome (try {:value (handler admission)} ([err fiber]
                (if (or (index-of (get err :code) ["Yield" "Blocked"]) (= "unknown" (get-in err [:context :outcome])))
                  {:wait (get-in err [:context :wait] {:operations [(admission :id)]}) :diagnostic (unless (= "Yield" (get err :code)) err)}
                  {:error (schema/diagnostic "OperationFailed" err fiber)}))))
              (ev/give events {:kind :outcome :key (call :key) :outcome outcome})) nil stopped))
            (put pending (call :key) {:fiber worker :done stopped}))
          (when (= :outcome (packet :kind))
            (ev/take (get-in pending [(packet :key) :done])) (put pending (packet :key) nil)
            (def outcome (packet :outcome))
            (when-let [failure (outcome :diagnostic)]
              (def key (string "blocked:" (task :id) ":" (packet :key)))
              (unless (first (store/query s "SELECT id FROM events WHERE key=?" [key]))
                (store/append s (task :id) "diagnostic" {:error failure :text (failure :message)} key)))
            (if (outcome :wait) (put blocked (packet :key) (outcome :wait))
              (ev/give inbox {:key (packet :key) :outcome outcome})))
          (when idle
            (cond
              (> (ev/count inbox) 0) (do (ev/give idle :continue) (set idle nil))
              (= 0 (length pending))
              (do
                (assert (> (length blocked) 0) "managed fibers are deadlocked")
                (store/advance s {:wait {:any (values blocked)}} bytes)
                (ev/give idle :yield) (set idle nil))))))))))
