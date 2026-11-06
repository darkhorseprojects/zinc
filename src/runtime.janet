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
                ["array/" "buffer/" "tuple/" "table/" "struct/" "string/" "math/" "peg/" "parser/" "ev/" "fiber/"]))]
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
            (put available qualified (merge binding
              {:doc (string/replace-all (string "(" name) (string "(" qualified) (binding :doc))})))))
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

(defn- evaluate [[code input instructions public bindings setup events notices stop limit seconds]]
  (def native (make-env))
  (def env @{:redef true})
  (var output-size 0)
  (each port [:out :err]
    (put env port (fn [text]
      (+= output-size (length text))
      (assert (<= output-size limit) "script output byte ceiling")
      (when (> (length text) 0)
        (ev/go (fn [] (ev/give events {:kind :output :port (string port) :text (string text)}) nil))))))
  (each [name binding] (pairs bindings)
    (put env (or (binding :local) (symbol name))
      (if (binding :local) (native (binding :local))
        @{:doc (binding :doc) :value (fn [& args]
          (schema/encode args)
          (def reply (ev/thread-chan 1))
          (defer (ev/chan-close reply)
            (ev/give events {:kind :call :name name :args args :reply reply})
            (def outcome (ev/take reply))
            (when (outcome :error) (error (outcome :error)))
            (outcome :value)))})))
  (each [name documentation value]
    [['input "(input) returns script input." (fn [] input)]
     ['self/document "(self/document) returns execution instructions." (fn [] instructions)]
     ['settings "(settings) returns exposed settings." (fn [] (public :settings))]
     ['resources "(resources) returns exposed resource grants." (fn [] (public :resources))]]
    (put env name @{:doc documentation :value value}))
  (def options (if setup ((module/value (require setup) 'configure) env) {}))
  (each key (keys options) (assert (= key :expander) "setup supports only :expander"))
  (put env *module-paths* []) (put env *module-cache* @{})
  (def forms (parse-all code))
  (sandbox :fs :net :subprocess :ffi :modules :env :asm :unmarshal :exit :locale :signal :chroot :sandbox)
  (def owner (fiber/root))
  (when (> seconds 0) (ev/deadline seconds owner owner true))
  (def stopped (ev/chan 1))
  (def watcher (ev/go (fn []
    (ev/take stop)
    (each fiber (ev/all-tasks) (unless (= fiber (fiber/root)) (ev/cancel fiber :execution-ended)))) nil stopped))
  (defer (do
    (each fiber (ev/all-tasks)
      (unless (or (= fiber owner) (= fiber watcher)) (ev/cancel fiber :execution-ended)))
    (when (fiber/can-resume? watcher) (ev/cancel watcher :finished))
    (ev/take stopped))
    (ev/go (fiber/new (fn []
      (def outcome (try
        (do
          (var value nil)
          (each [index form] (pairs forms)
            (def thunk (compile (if (options :expander) ((options :expander) form) form) env))
            (when (dictionary? thunk)
              (error {:code "CompileFailed" :message (thunk :error)
                      :context (schema/project thunk [:line :column])}))
            (set value (thunk))
            (ev/give events {:kind :progress :form (+ index 1)}))
          (schema/encode value)
          (assert (<= (length (schema/encode value)) limit) "script result byte ceiling")
          {:state "done" :value (if (nil? value) :null value)
           :text (if (string? value) value (schema/encode value))})
        ([err fiber] {:state "failed" :error (schema/diagnostic "ExecutionFailed" err fiber)
                      :text (get (schema/diagnostic "ExecutionFailed" err) :message)})))
      (ev/go (fn [] (ev/give events (merge outcome {:kind :return})) nil)) nil) :t env) nil notices)
    (while (> (length (ev/all-tasks)) 2) (ev/sleep store/interval))))

(defn run [s script bindings]
  (def config (s :config))
  (def events (ev/thread-chan (config :task-quota)))
  (def notices (ev/thread-chan (config :task-quota)))
  (def stop (ev/thread-chan 1)) (def finished (ev/chan 1))
  (def waiting @{})
  (var joined false) (var sequence 0)
  (def seconds (min (if (= 0 (config :seconds)) math/inf (config :seconds))
    (- (or (get-in script [:data :expires]) math/inf) (os/clock))))
  (def arguments [(get-in script [:data :input :code]) (get-in script [:data :input])
    (instructions config bindings) (public config bindings)
    (tabseq [[name binding] :pairs bindings] name (schema/project binding [:local :doc]))
    (get-in config [:janet :setup]) events notices stop (config :response-bytes)
    (if (= seconds math/inf) 0 (max 0.001 seconds))])
  (def worker (ev/go (fn [] (with-env @{} (ev/thread evaluate arguments (keyword "") notices))) nil finished))
  (def owner (fiber/root)) (def checked (ev/chan 1))
  (def checker (ev/go (fn []
    (try (while true (store/check s (script :id)) (ev/sleep store/interval))
      ([err] (unless (= err :finished) (ev/cancel owner err))))) nil checked))
  (defer (do
    (ev/cancel checker :finished) (ev/take checked) (ev/chan-close checked)
    (unless joined
      (ev/give stop true)
      (ev/take finished))
    (each [fiber done] (pairs waiting)
      (when (fiber/can-resume? fiber) (ev/cancel fiber :execution-ended))
      (ev/take done))
    (each channel [events notices stop finished] (ev/chan-close channel)))
    (while (or (not joined) (> (ev/count events) 0) (> (ev/count notices) 0))
      (def [_ channel packet] (ev/select events notices finished))
      (cond
        (= channel finished)
        (do (set joined true)
          (assert (= :ok (packet 0)) (schema/diagnostic "ExecutorFailed" (fiber/last-value worker) worker)))
        (= channel notices)
        (when (or (not= :ok (packet 0)) (not (nil? (packet 1))))
          (store/append s (script :id) (if (= :ok (packet 0)) "fiber" "diagnostic")
            (if (= :ok (packet 0)) {:text (string/format "%n" (packet 1))}
              {:error (schema/diagnostic "FiberFailed" (packet 1)) :text (string/format "%n" (packet 1))})))
        (= :call (packet :kind))
        (do
          (++ sequence)
          (def admission (store/append s (script :id) "operation"
            (merge (schema/project (script :data) [:world :epoch :expires :memory_range :call])
              {:name (packet :name) :arguments (packet :args)})
            (string "operation:" (script :id) ":" sequence) (script :image)))
          (def done (ev/chan 1))
          (def waiter (ev/go (fn [[id reply]]
            (var outcome nil)
            (while (not (set outcome (store/result s id))) (ev/sleep store/interval))
            (ev/give reply (outcome :data))) [(admission :id) (packet :reply)] done))
          (put waiting waiter done))
        (= :progress (packet :kind))
        (store/advance s {:started true :form (packet :form)})
        (= :return (packet :kind))
        (store/append s (script :id) "return" (schema/project packet [:kind] true) (string "return:" (script :id)))
        (= :output (packet :kind))
        (store/append s (script :id) "output" (schema/project packet [:kind] true))))
    (def returned (store/outcome s (script :id)))
    (assert returned "VM exited without a root outcome")
    (returned :data)))
