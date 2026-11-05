(import ./schema)
(import ./store)
(import ./io)

(defn definitions [config supplied]
  (if-not (config :janet) {}
    (let [base (make-env)
          available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)
            :unless (index-of name ['make-env 'env-lookup 'root-env 'debugger-env 'stdin 'stdout 'stderr
              'make-image 'make-image-dict 'load-image 'load-image-dict 'eval 'eval-string 'run-context 'compile
              'curenv 'with-env 'setdyn 'with-dyns 'defdyn 'all-dynamics 'native 'require 'import 'import* 'use])
            :unless (string/has-prefix? "*module" (string name))
            :when (or (not (string/find "/" (string name)))
              (index-of name ['os/clock 'os/date 'os/time 'os/cryptorand])
              (some |(string/has-prefix? $ (string name))
                ["array/" "buffer/" "tuple/" "table/" "struct/" "string/" "math/" "peg/" "parser/"]))]
            (cond (= name '*) "core/multiply" (string/find "/" (string name)) (string name) (string "core/" name))
            (if (index-of name ['os/clock 'os/date 'os/time 'os/cryptorand]) (base name) {:local name}))
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
      (string "\n\n## Settings and resources\n\n" (schema/encode (public config bindings))
        "\n\n## Host bindings\n\n" (string/join (seq [[_ binding] :in (sorted (pairs bindings)) :unless (binding :local)] (binding :doc)) "\n\n")))))

(defn- evaluate [[code input instructions public bindings setup events inbox stop limit seconds pure]]
  (def native (make-env))
  (def env @{:redef true})
  (def output @"")
  (put env :out (fn [text] (buffer/push-string output text) (assert (<= (length output) limit) "script output byte ceiling")))
  (put env :err (env :out))
  (each [name binding] (pairs bindings)
    (put env (or (binding :local) (symbol name))
      (if (binding :local) (native (binding :local))
        @{:doc (binding :doc) :value (fn [& args]
          (assert (not pure) "computation stages cannot call host bindings")
          (def reply (debug {:name name :args args}))
          (when (reply :error) (error (reply :error))) (reply :value))})))
  (def random @[(math/rng (os/cryptorand 32))])
  (when (bindings "math/random")
    (put env 'math/random @{:doc "(math/random) returns a task-local random value." :value (fn [] (math/rng-uniform (random 0)))}))
  (when (bindings "math/seedrandom")
    (put env 'math/seedrandom @{:doc "(math/seedrandom seed) resets the task-local random generator."
      :value (fn [seed] (put random 0 (math/rng seed)) nil)}))
  (each [name documentation value]
    [['input "(input) returns task input or the results of declared stage dependencies." (fn [] input)]
     ['self/document "(self/document) returns task instructions." (fn [] instructions)]
     ['settings "(settings) returns exposed settings." (fn [] (public :settings))]
     ['resources "(resources) returns exposed resource grants." (fn [] (public :resources))]]
    (put env name @{:doc documentation :value value}))
  (def options (if setup ((module/value (require setup) 'configure) env) {}))
  (each key (keys options) (assert (= key :expander) "setup supports only :expander"))
  (put env *module-paths* []) (put env *module-cache* @{})
  (def forms (parse-all code))
  (def root (fiber/new (fn []
    (var value nil)
    (each form forms
      (def thunk (compile (if (options :expander) ((options :expander) form) form) env))
      (when (dictionary? thunk)
        (error {:code "CompileFailed" :message (thunk :error)
                :context (schema/project thunk [:line :column])}))
      (set value (thunk)))
    value) :a env))
  (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (when (> seconds 0) (ev/deadline seconds (fiber/root) (fiber/root) true))
  (def owner (fiber/root)) (def stopped (ev/chan 1))
  (def watcher (ev/go (fn [] (ev/take stop) (ev/cancel owner :execution-ended)) nil stopped))
  (defer (do (ev/cancel watcher :finished) (ev/take stopped))
    (var reply nil)
    (label done (while true
      (def value (resume root reply))
      (case (fiber/status root)
        :dead (do
          (schema/encode value)
          (def result (if (or pure (= 0 (length output))) value
            (string output (when (not (nil? value)) (if (string? value) value (string/format "%n" value))))))
          (assert (<= (length (schema/encode result)) limit) "script result byte ceiling")
          (return done result))
        :debug (do (assert (not pure) "computation stages cannot signal host calls")
          (ev/give events value) (set reply (ev/take inbox)))
        (error (schema/diagnostic "ExecutionFailed" value root)))))))

(defn run [s task bindings handler source input pure]
  (def config (s :config))
  (def events (ev/thread-chan 1)) (def inbox (ev/thread-chan 1))
  (def stop (ev/thread-chan 1)) (def finished (ev/thread-chan 1))
  (var joined false) (var sequence 0)
  (def seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds))
    (- (or (get-in task [:data :expires]) math/inf) (os/clock))))
  (def arguments [source input (instructions config bindings) (public config bindings)
    (tabseq [[name binding] :pairs bindings] name (schema/project binding [:local :doc]))
    (get-in config [:janet :setup]) events inbox stop (config :response-bytes)
    (if (= seconds math/inf) 0 (max 0.001 seconds)) pure])
  (with-env @{} (ev/thread evaluate arguments :n finished))
  (defer (do (ev/give stop true) (unless joined (ev/take finished))
    (each channel [events inbox stop finished] (ev/chan-close channel)))
    (label done (while true
      (def [_ channel packet] (ev/select events finished))
      (if (= channel finished)
        (do (set joined true) (assert (= :ok (packet 0)) (packet 1)) (return done (packet 1)))
        (do
          (++ sequence)
          (def admission (store/append s (task :id) "operation"
            {:name (packet :name) :arguments (packet :args)} (string "operation:" (task :id) ":" sequence)))
          (def outcome (try {:value (handler admission)} ([err fiber]
            (when (index-of (get err :code) ["Yield" "Blocked" "TaskClosed" "TaskReplaced" "CapabilityOwnerLost"]) (error err))
            {:error (schema/diagnostic "OperationFailed" err fiber)})))
          (ev/give inbox outcome)))))))
