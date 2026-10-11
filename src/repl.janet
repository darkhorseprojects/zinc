(when (dyn :library) (module/add-syspath (dyn :library)))

(import spork/json :as json)
(import spork/base64 :as base64)
(import portable-agents/src/protocol :as wire)
(import ./config :as settings)

(defn- exchange [operation & arguments]
  (def current (dyn :zinc/evaluation))
  (assert current "operation requires an evaluation")
  (ev/with-lock (current :lock)
                (wire/send (current :stream) {"type" "call" "operation" operation "arguments" (string (json/encode arguments))})
                (def reply (wire/record (wire/receive (current :stream)) ["type" "output"] []))
                (assert (= "reply" (reply "type")) "invalid REPL reply")
                (def outcome (json/decode (reply "output") true true))
                (assert (outcome :ok) (outcome :error))
                (outcome :value)))

(defn serve [bytes opaque]
  (assert (= "" bytes) "serve takes empty input")
  (def config (settings/validate settings/resident opaque))
  (def listener (net/listen :unix (config :socket)))
  (os/chmod (config :socket) 8r600)
  (def env (make-env))
  (def limits (struct ;(kvs (dyn :pa/limits))))
  (put env :pa/limits limits)
  (put env :current-file (config :file))
  (put env :redef true)
  (put env 'world @{:value env})
  (put env 'self @{:value (partial exchange "spawn")})
  (put env 'self/member @{:value exchange})
  (put env 'self/document @{:value (fn [] ((dyn :zinc/evaluation) :document))})
  (put env 'input @{:value (fn [] ((dyn :zinc/evaluation) :input))})
  (put env 'await @{:value (fn [handle]
                             (def result (exchange "await" handle))
                             (if (handle :bytes) (base64/decode (result :data)) result))})
  (put env 'pa/imports @{:value (fn [] ((dyn :zinc/evaluation) :imports))})
  (put env 'pa/import @{:value (fn [name]
                                 (assert (index-of name ((dyn :zinc/evaluation) :imports)) "Import not granted")
                                 (fn [input &named member]
                                   (def handle (exchange "import" {:name name :member (or member "call") :data (base64/encode (string input))}))
                                   (base64/decode ((exchange "await" handle) :data))))})
  (sandbox ;(map keyword (config :forbid)))
  (with-env env (eval-string (slurp (config :file)) env))
  (defer (ev/close listener)
    (net/accept-loop listener
                     (fn [peer]
                       (with-dyns [:pa/limits limits]
                         (defer (ev/close peer)
                           (def packet (wire/record (wire/receive peer) ["type"] ["code" "input" "document" "imports" "source-bytes" "response-bytes"]))
                           (case (packet "type")
                             "document"
                             (do
                               (def instructions (module/value env 'instructions))
                               (assert (or (nil? instructions) (string? instructions)) "instructions must be a string")
                               (wire/send peer {"type" "result" "output" (wire/json {"file" (config :file) "forbid" (config :forbid)
                                                                                     "instructions" (or instructions "")})}))
                             "eval"
                             (do
                               (assert (and (string? (packet "code")) (int? (packet "source-bytes"))
                                            (<= 1 (length (packet "code")) (packet "source-bytes"))
                                            (int? (packet "response-bytes")) (> (packet "response-bytes") 0)) "invalid evaluation")
                               (def output @"")
                               (def outcome
                                 (with-env env
                                   (with-dyns [:zinc/evaluation {:stream peer :lock (ev/lock) :input (json/decode (packet "input") true true)
                                                                 :document (packet "document") :imports (packet "imports")}
                                               :out (fn [text]
                                                      (assert (<= (+ (length output) (length text)) (packet "response-bytes")) "REPL output byte ceiling")
                                                      (buffer/push-string output text))]
                                     (try
                                       (let [result (eval-string (packet "code") env)
                                             text (string output (if (string? result) result (string/format "%p" result)))]
                                         (assert (<= (length text) (packet "response-bytes")) "REPL result byte ceiling")
                                         {"value" text})
                                       ([err] {"error" (string err)})))))
                               (wire/send peer {"type" "result" "output" (wire/json outcome)}))
                             (error "unknown REPL operation")))))))
  "")

(defn- receipt [value operation & fields]
  (def result (wire/json
                (((module/value (curenv) 'pa/import true) "ledger")
                  (wire/json (merge {"task" (value "task") "token" (value "token")
                                     "owner" (value "owner") "generation" (value "generation")
                                     "operation" operation} (struct ;fields)))
                  :member "receipt") true))
  (assert (result "ok") (result "error"))
  (result "value"))

(defn eval [bytes opaque]
  (def config (settings/validate settings/relay opaque))
  (def value (wire/json bytes true))
  (receipt value "renew")
  (def peer (net/connect :unix (config :socket)))
  (def heartbeat (ev/go (fn []
                          (try
                            (while true
                              (ev/sleep (/ (value "lease-seconds") 3))
                              (receipt value "renew"))
                            ([err] (ev/close peer))))))
  (var position 0)
  (defer (do (ev/cancel heartbeat "evaluation finished") (ev/close peer))
    (wire/send peer {"type" "eval" "code" (value "code") "input" (wire/json (value "input"))
                     "document" (value "document") "imports" (value "imports")
                     "source-bytes" (value "source-bytes") "response-bytes" (value "response-bytes")})
    (while true
      (def packet (wire/receive peer))
      (assert packet "REPL connection lost; effects may have happened")
      (case (packet "type")
        "result"
        (do
          (wire/record packet ["type" "output"] [])
          (def outcome (wire/record (wire/json (packet "output") true) [] ["value" "error"]))
          (assert (not= (has-key? outcome "value") (has-key? outcome "error")) "invalid evaluation outcome")
          (ev/cancel heartbeat "evaluation finished")
          (receipt value "complete" "value" (outcome "value") "error" (outcome "error"))
          (break))
        "call"
        (do
          (wire/record packet ["type" "operation" "arguments"] [])
          (assert (not (index-of (packet "operation") ["renew" "complete"])) "private receipt operation")
          (def reply (try
                       {"ok" true "value" (receipt value (packet "operation") "position" (++ position)
                                                   "arguments" (wire/json (packet "arguments") true))}
                       ([err] {"ok" false "error" (string err)})))
          (wire/send peer {"type" "reply" "output" (wire/json reply)}))
        (error "invalid REPL frame"))))
  "")

(defn describe [bytes opaque]
  (assert (= "" bytes) "describe takes empty input")
  (settings/validate settings/relay opaque true)
  (json/encode {:schema {:config settings/relay :resident settings/resident}}))

(defn document [bytes opaque]
  (assert (= "" bytes) "document takes empty input")
  (def config (settings/validate settings/relay opaque))
  (def peer (net/connect :unix (config :socket)))
  (defer (ev/close peer)
    (wire/send peer {"type" "document"})
    (def reply (wire/record (wire/receive peer) ["type" "output"] []))
    (assert (= "result" (reply "type")) "invalid document reply")
    (reply "output")))
