(import ./schema)
(import ./protocol)

(defn definitions [config supplied]
  (if-not (config :janet) {}
    (let [base (make-env)
          available (tabseq [name :in (all-bindings base) :unless (get (base name) :private)]
            (cond (= name '*) "core/multiply" (string/find "/" (string name)) (string name) (string "core/" name)) {:local name})
          imports (get config :imports {})
          cache (merge module/cache)
          paths (array/concat @[] module/paths)]
      (each [namespace spec] (pairs imports)
        (put cache (string namespace)
          (tabseq [[name documentation] :pairs (spec :exports)]
            (symbol name) @{:doc documentation :value (fn [& args]
              (protocol/call spec (string name) args (dyn :zinc/operation) (config :response-bytes)))})))
      (array/insert paths 0 [(fn [name] (when (get imports (keyword name)) name)) :preload])
      (put base *module-cache* cache)
      (put base *module-paths* paths)
      (put base *module-make-env* (partial make-env base))
      (merge-into available supplied)
      (each [namespace module] (pairs (get-in config [:janet :imports]))
        (each [name binding] (pairs (with-env base (require (module :module))))
          (when (and (symbol? name) (not (binding :private)) (not (binding :macro))
                     (index-of (type (binding :value)) [:function :cfunction])
                     (or (nil? (module :export)) (= (string name) (module :export))))
            (def qualified (if (module :export) (string namespace) (string namespace "/" name)))
            (assert (and (not (available qualified)) (string? (binding :doc))) "invalid or undocumented host binding")
            (put available qualified (merge binding {:doc (string (binding :doc) " Append {:operation stable-key} at this host boundary.")})))))
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
      (string "\n\n## Execution\n\nScripts execute independently. self admits a task and returns its handle, not its result. Native ev concurrency remains available within a script. Use independent tasks for independent lifetimes. Locals, closures and fibers are not durable state. Read task/checkpoint at entry and guard completed steps. task/commit atomically stores a checkpoint and explicit shared values. Prior commits survive failure. No script or observer collects sibling results.\nself and external host calls require a final options map containing only :operation with a stable string key. Reusing a key with different arguments is an error. An admitted external call without a recorded outcome must be reconciled, never blindly repeated. Temporary sessions cannot promise restart durability.\n"
        "\n## Settings and resources\n\n" (schema/encode (public config bindings))
        "\n\n## Host bindings\n\n" (string/join (seq [[_ binding] :in (sorted (pairs bindings)) :unless (binding :local)] (binding :doc)) "\n\n")))))

(defn- evaluate [[code id input instructions public bindings setup events stop limit seconds]]
  (math/seedrandom (os/cryptorand 32))
  (def native (make-env))
  (def output @"")
  (def env @{:redef true})
  (def emit (fn [bytes] (buffer/push-string output bytes) (assert (<= (length output) limit) "script output byte ceiling")))
  (put env :out emit) (put env :err emit)
  (each [name binding] (pairs bindings)
    (put env (or (binding :local) (symbol name))
      (if (binding :local) (native (binding :local))
        @{:doc (binding :doc) :value (fn [& args]
          (def reply (ev/thread-chan 1))
          (ev/give events [name args reply])
          (def outcome (ev/take reply))
          (when (outcome :error) (error (outcome :error)))
          (outcome :value))})))
  (each [name value] [['input (fn [] input)] ['self/document (fn [] instructions)]
                    ['settings (fn [] (public :settings))] ['resources (fn [] (public :resources))]]
    (put env name @{:value value}))
  (def options (if setup ((module/value (require setup) 'configure) env) {}))
  (each key (keys options) (assert (index-of key [:parser :read :expander]) "unsupported evaluator option"))
  (put env *module-paths* []) (put env *module-cache* @{})
  (sandbox :fs :net :subprocess :ffi :modules :threads :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (when (> seconds 0) (ev/deadline seconds (fiber/root) (fiber/root) true))
  (var chunk code) (var value nil)
  (def driver (fiber/root))
  (def stopped (ev/chan 1))
  (def watcher (ev/go (fn [] (ev/take stop) (ev/cancel driver :execution-ended)) nil stopped))
  (defer (do (ev/cancel watcher :finished) (ev/take stopped))
  (run-context (merge options {:env env :source (string "script/" id) :fiber-flags :yi
    :chunks (fn [buffer &] (when chunk (buffer/push-string buffer chunk) (set chunk nil)))
    :on-status (fn [fiber value] (unless (= :dead (fiber/status fiber)) (propagate value fiber)))
    :on-compile-error (fn [message fiber source line column] (error (string source ":" line ":" column ": " message)))
    :on-parse-error (fn [parser source] (error (string source ":" (string/join (map string (:where parser)) ":") ": " (:error parser))))
    :evaluator (fn [thunk &] (with-env env (set value (thunk))))}))
  (def result (string output (if (string? value) value (string/format "%n" value))))
  (assert (<= (length result) limit) "script result byte ceiling")
  result))

(defn run [s task bindings handler]
  (def config (s :config))
  (def events (ev/thread-chan 1))
  (def stop (ev/thread-chan 1))
  (def finished (ev/thread-chan 1))
  (def pending @{})
  (var joined false)
  (def seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds))
                   (- (or (get-in task [:data :expires]) math/inf) (os/clock))))
  (ev/thread evaluate [(get-in task [:data :input :code]) (task :id) (get-in task [:data :input])
    (instructions config bindings) (public config bindings)
    (tabseq [[name binding] :pairs bindings] name (schema/project binding [:local :doc]))
    (get-in config [:janet :setup]) events stop (config :response-bytes) (if (= seconds math/inf) 0 (max 0.001 seconds))] :n finished)
  (defer (do
    (ev/give stop true)
    (each [fiber done] (pairs (merge pending)) (when (fiber/can-resume? fiber) (ev/cancel fiber :script-ended)) (ev/take done))
    (ev/chan-close events)
    (unless joined (ev/take finished))
    (ev/chan-close finished)
    (ev/chan-close stop))
    (label done (while true
      (def [_ channel packet] (ev/select events finished))
      (if (= channel finished)
        (do (set joined true) (assert (= :ok (packet 0)) (packet 1)) (return done (packet 1)))
        (let [[name args reply] packet
              stopped (ev/chan 1)
              fiber (ev/go (fn []
                (defer (put pending (fiber/root) nil)
                  (ev/give reply (try {:value (handler name args)}
                    ([err fiber] {:error (protocol/diagnostic "OperationFailed" err fiber)}))))) nil stopped)]
          (put pending fiber stopped)))))))
