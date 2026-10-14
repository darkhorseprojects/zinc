(defn- request [name args]
  (def reply (ev/thread-chan 1))
  (ev/give (dyn :zinc/requests) [name args reply])
  (def outcome (ev/take reply))
  (assert (and outcome (outcome :ok)) (get outcome :error "Execution closed"))
  (outcome :value))

(defn- evaluate [[file source code input document bindings requests forbid ceiling]]
  (def env (make-env))
  (table/clear module/cache)
  (put env :current-file file)
  (put env :redef true)
  (put env 'stdout @{:value stderr})
  (put env 'world @{:value env})
  (put env 'input @{:value (fn [] input) :doc "(input) — Current inquiry."})
  (put env 'self @{:value (fn [value] (request "self" [value])) :doc "(self request) — Spawn an agent branch; await its handle."})
  (put env 'await @{:value (fn [handle] (request "await" [handle])) :doc "(await handle) — Read a descendant result."})
  (put env 'self/document @{:value (fn [] document) :doc "(self/document) — Current instructions and callable interfaces."})
  (each binding bindings
    (def name (binding :name))
    (def metadata @{:value (fn [& args] (request name args)) :doc (binding :doc)})
    (put env (symbol name) metadata)
    (when (binding :module)
      (def split (string/find "/" name))
      (def namespace (string/slice name 0 split))
      (def module (or (module/cache (binding :module)) (make-env)))
      (put module (symbol (string/slice name (+ split 1))) metadata)
      (put module/cache (binding :module) module)
      (put env (keyword namespace) (binding :module))))
  (module/add-paths "" :source)
  (sandbox ;(map keyword forbid))
  (with-env env
    (def output @"")
    (with-dyns [:zinc/requests requests
                :out (fn [bytes]
                  (assert (<= (+ (length output) (length bytes)) ceiling) "execution output byte ceiling")
                  (buffer/push-string output bytes))]
      (eval-string source env)
      (let [result (eval-string code env)]
        (string output (if (string? result) result (string/format "%p" result)))))))

(defn execute [file source code input document bindings handler seconds forbid ceiling]
  (def requests (ev/thread-chan 1))
  (def finished (ev/thread-chan 1))
  (ev/thread evaluate [file source code input document bindings requests forbid ceiling] :n finished)
  (var result nil)
  (ev/with-deadline seconds
    (defer (do (ev/chan-close requests) (ev/chan-close finished))
      (while true
        (def [status channel packet] (ev/select requests finished))
        (assert (= status :take) "Execution closed")
        (if (= channel finished)
          (do
            (assert (= :ok (packet 0)) (string (packet 1)))
            (set result (packet 1))
            (break))
          (do
            (def [name args reply] packet)
            (def outcome (try {:ok true :value (handler name args)} ([err] {:ok false :error (string err)})))
            (ev/give reply outcome))))
      result)))
