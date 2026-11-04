(import jurl/native :as curl)
(import spork/path :as path)
(import spork/utf8 :as utf8)
(import spork/json :as json)
(import sqlite3 :as sql)
(import ./store)

(defn process [argv environment input limit seconds &opt diagnostics]
  (def child (os/spawn argv :pe (merge environment {:in :pipe :out :pipe :err (if diagnostics :pipe :out)})))
  (defer (do (when (nil? (get child :return-code)) (try (os/proc-kill child) ([err] nil))) (os/proc-close child))
    (def output @"") (var size 0)
    (def [_ _ _ status] (ev/with-deadline (if (= seconds 0) math/inf seconds)
      (ev/gather
        (defer (ev/close (child :in)) (when input (ev/write (child :in) input)))
        (do (var chunk nil)
          (while (set chunk (ev/read (child :out) 4096))
            (+= size (length chunk))
            (assert (<= size limit) "process output byte ceiling")
            (buffer/push-string output chunk)))
        (when diagnostics
          (var chunk nil)
          (while (set chunk (ev/read (child :err) 4096))
            (+= size (length chunk))
            (assert (<= size limit) "process output byte ceiling")
            (buffer/push-string diagnostics chunk)))
        (os/proc-wait child))))
    {:exit status :output (string output)}))

(defn- transfer [[config endpoint method suffix body current stream]]
  (def db (when current (sql/open (string (current :database) (if (string/find "?" (current :database)) "&" "?") "mode=ro"))))
  (when db (sql/eval db "PRAGMA busy_timeout=5000; PRAGMA query_only=ON;"))
  (def client (curl/new))
  (def bytes @"")
  (var size 0) (var next-check 0)
  (var permitted true)
  (defer (do (curl/reset client) (when db (sql/close db)))
    (def check (fn [& counts]
                 (when (and current (>= (os/clock) next-check))
                   (set next-check (+ (os/clock) store/interval))
                   (set permitted (not (nil? (first
                     (sql/eval db `SELECT c.task FROM claims c WHERE c.task=? AND c.token=? AND c.expires>?
                       AND NOT EXISTS(SELECT 1 FROM events r WHERE r.parent=c.task AND r.kind='result')`
                               [(current :id) (current :owner) (os/clock)]))))))
                 permitted))
    (assert (check) "HTTP job fenced")
    (def deadline (min (if (= 0 (config :http-ms)) math/inf (+ (os/clock) (/ (config :http-ms) 1000)))
                       (or (get current :expires) math/inf)))
    (def headers (merge (get endpoint :headers {})))
    (def secrets @[])
    (when (endpoint :token-env)
      (def token (os/getenv (endpoint :token-env)))
      (assert (and token (> (length token) 0)) "provider credential is not configured")
      (put headers :Authorization (string "Bearer " token))
      (array/push secrets token))
    (when-let [command (endpoint :credential-command)]
      (def diagnostics @"")
      (def owner (fiber/root))
      (def stopped (ev/chan 1))
      (def watcher (ev/go (fn [] (try (while true (assert (check) "HTTP job fenced") (ev/sleep store/interval))
                                  ([err] (unless (= err :finished) (ev/cancel owner err))))) nil stopped))
      (def result (defer (do (ev/cancel watcher :finished) (ev/take stopped))
                    (process command (os/environ) nil 16384
                                   (max 0.001 (min 30 (- deadline (os/clock)))) diagnostics)))
      (unless (= 0 (result :exit))
        (error {:code "CredentialCommandFailed"
                :message (string "provider credential command exited " (result :exit))
                :detail (string diagnostics)
                :context {:executable (first command) :exit (result :exit)}}))
      (def supplied (try (json/decode (result :output) true true) ([err] (error "invalid credential command response"))))
      (assert (dictionary? supplied) "credential command must return headers")
      (each value (values supplied)
        (assert (and (string? value) (> (length value) 0)) "invalid credential header")
        (array/push secrets value)
        (when (and (string/has-prefix? "Bearer " value) (> (length value) 7)) (array/push secrets (string/slice value 7))))
      (merge-into headers supplied))
    (assert (and (check) (< (os/clock) deadline)) "HTTP job expired or fenced")
    (def timeout (if (= deadline math/inf) 0 (max 1 (math/floor (* 1000 (- deadline (os/clock)))))))
    (each [key value]
      (pairs {:url (string (endpoint :url) suffix) :customrequest method :postfields body
              :httpheader (array/concat @["Content-Type: application/json" (if stream "Accept: text/event-stream" "Accept: application/json")]
                                       (seq [[name value] :pairs headers]
                                         (assert (and (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")) -1) (string name))
                                                      (string? value) (not (string/find "\r" value)) (not (string/find "\n" value))) "invalid HTTP header")
                                         (string name ": " value)))
              :writefunction (fn [chunk]
                               (+= size (length chunk))
                               (assert (<= size (config :response-bytes)) "HTTP response exceeds byte limit")
                               (if (and stream (<= 200 (client :response-code) 299))
                                 (when (> (length chunk) 0) (ev/give-supervisor :stdout (string chunk)))
                                 (buffer/push-string bytes chunk)))
              :proxy "" :nobody (= method "HEAD") :followlocation false :ssl-verifypeer true :ssl-verifyhost 2
              :timeout-ms timeout :connecttimeout-ms 10000
              :protocols "http,https" :noprogress false :xferinfofunction check})
      (unless (nil? value) (put client key value)))
    (def status (:perform client))
    (assert (= :ok status) (string "HTTP transfer failed: " status "; effects may have happened"))
    (assert (utf8/is-valid? bytes) "HTTP response is not UTF-8")
    {:status (client :response-code)
     :body (if (<= 200 (client :response-code) 299) (string bytes)
               (reduce (fn [text secret] (string/replace-all secret "[redacted]" text)) (string bytes) secrets))}))

(defn request [config endpoint method suffix &opt body consume]
  (assert endpoint "HTTP endpoint is not configured")
  (def current (dyn :zinc/call))
  (def finished (ev/thread-chan (+ 1 (config :response-bytes))))
  (ev/thread transfer [(tabseq [key :in [:response-bytes :http-ms]] key (config key)) endpoint method suffix body
                       (when current {:database (current :database) :id (current :id) :owner (current :owner) :expires (get-in current [:scope :expires])}) (not (nil? consume))] :n finished)
  (defer (ev/chan-close finished)
    (label done (while true
                  (def [status result] (ev/take finished))
                  (if (= :stdout status) (consume result)
                    (do (assert (= :ok status) result) (return done result)))))))

(defn invoke [config name args]
  (cond
    (index-of name ["fs/list" "fs/read" "fs/write"])
    (do
      (assert (= (length args) (if (= name "fs/write") 3 2)) "invalid filesystem arity")
      (def [root relative text] args)
      (def grant (get-in config [:fs (keyword root)]))
      (assert (and grant (grant (if (= name "fs/write") :write :read))) "filesystem operation is not granted")
      (assert (and (string? relative) (> (length relative) 0) (not (string/find "\0" relative))
                   (not (string/find "\\" relative)) (not (string/find ":" relative)) (not (path/abspath? relative))) "invalid relative path")
      (var target (os/realpath (grant :root)))
      (each part (array/concat @[""] (if (= relative ".") [] (string/split "/" relative)))
        (unless (= part "")
          (assert (not (index-of part ["." ".."])) "invalid path component")
          (when (index-of (os/which) [:windows :mingw])
            (assert (and (not (index-of (last part) [32 46]))
                         (not (peg/match ~(* (choice "CON" "PRN" "AUX" "NUL" (* (choice "COM" "LPT") (range "19"))) -1)
                                         (string/ascii-upper (first (string/split "." part)))))) "invalid Windows path component"))
          (set target (path/join target part)))
        (assert (if (index-of (os/which) [:windows :mingw])
                  (let [attributes (ffi/call (ffi/lookup (ffi/native "kernel32.dll") "GetFileAttributesA") (ffi/signature :default :uint32 :string) target)]
                    (or (= attributes 0xffffffff) (= 0 (band attributes 0x400))))
                  (not= :link (os/lstat target :mode))) "filesystem links are not permitted"))
      (case name
        "fs/list" (do (assert (= :directory (os/stat target :mode)) "directory required")
                    (def names (os/dir target))
                    (assert (<= (sum (map length names)) (config :response-bytes)) "directory result exceeds limit")
                    (sorted names))
        "fs/read" (do (assert (= :file (os/stat target :mode)) "regular file required")
                    (with [file (file/open target :rbn)]
                      (def bytes (or (file/read file (+ 1 (config :response-bytes))) ""))
                      (assert (and (<= (length bytes) (config :response-bytes)) (utf8/is-valid? bytes)) "file exceeds limit or is not UTF-8")
                      (string bytes)))
        (do (assert (and (string? text) (utf8/is-valid? text) (<= (length text) (config :response-bytes))) "invalid file contents")
          (assert (or (nil? (os/stat target)) (= :file (os/stat target :mode))) "regular file required")
          (spit target text :wb) nil)))
    (= name "http/request")
    (do
      (assert (= 4 (length args)) "invalid HTTP arity")
      (def [root method segments body] args)
      (def grant (get-in config [:http (keyword root)]))
      (assert (and grant (index-of method (grant :methods))) "HTTP operation is not granted")
      (assert (and (indexed? segments) (every? (map |(and (string? $) (not (index-of $ ["." ".."]))
                                                          (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~.")) -1) $)) segments))) "invalid HTTP path")
      (assert (or (nil? body) (string? body)) "HTTP body must be text or nil")
      (request config grant method (string/join segments "/") body))
    (= name "process/run")
    (do
      (assert (= 1 (length args)) "invalid process arity")
      (def command (get-in config [:processes (keyword (first args))]))
      (assert command "process is not granted")
      (def result (process (command :argv) (tabseq [[k v] :pairs (command :env)] (string k) v) nil (config :response-bytes) 0))
      (assert (utf8/is-valid? (result :output)) "process output is not UTF-8")
      result)))
