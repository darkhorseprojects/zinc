(import jurl/native :as curl)
(import spork/utf8 :as utf8)
(import sqlite3 :as sql)

(defn- transfer [[config endpoint method suffix body current stream]]
  (def db (when current (sql/open (config :store))))
  (when db (sql/eval db "PRAGMA busy_timeout=5000;"))
  (def client (curl/new))
  (def bytes @"")
  (var size 0) (var next-check 0)
  (var permitted true)
  (defer (do (curl/reset client) (when db (sql/close db)))
    (def check (fn [& counts]
                 (when (and current (>= (os/clock) next-check))
                   (set next-check (+ (os/clock) 0.1))
                   (set permitted (not (nil? (first
                     (sql/eval db "SELECT id FROM live_calls WHERE id=? AND owner=?"
                               [(current :id) (current :owner)]))))))
                 permitted))
    (assert (check) "HTTP job fenced")
    (def token (when (endpoint :token-env) (os/getenv (endpoint :token-env))))
    (when (endpoint :token-env) (assert token "provider credential is not configured"))
    (def bound (min (if (= 0 (config :http-ms)) math/inf (config :http-ms))
                    (if (get current :expires) (max 1 (math/floor (* 1000 (- (current :expires) (os/clock))))) math/inf)))
    (def timeout (if (= bound math/inf) 0 bound))
    (each [key value]
      (pairs {:url (string (endpoint :url) suffix) :customrequest method :postfields body
              :httpheader (array/concat @["Content-Type: application/json" (if stream "Accept: text/event-stream" "Accept: application/json")]
                                       (if token [(string "Authorization: Bearer " token)] []))
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
    {:status (client :response-code) :body (string bytes)}))

(defn request [config endpoint method suffix &opt body consume]
  (assert endpoint "HTTP endpoint is not configured")
  (def current (dyn :zinc/call))
  (def finished (ev/thread-chan (+ 1 (config :response-bytes))))
  (ev/thread transfer [(tabseq [key :in [:store :response-bytes :http-ms]] key (config key)) endpoint method suffix body
                       (when current {:id (current :id) :owner (current :owner) :expires (get-in current [:scope :expires])}) (not (nil? consume))] :n finished)
  (defer (ev/chan-close finished)
    (label done (while true
                  (def [status result] (ev/take finished))
                  (if (= :stdout status) (consume result)
                    (do (assert (= :ok status) result) (return done result)))))))
