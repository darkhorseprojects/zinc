(module/add-syspath (dyn :library))

(import spork/json :as json)
(import spork/path :as path)
(import ./config :as settings)

(defn- execute [member bytes opaque]
  (def config (settings/validate settings/git opaque))
  (def value (json/decode bytes true true))
  (assert (dictionary? value) "invalid Git request")
  (each key (keys value) (assert (index-of key [:paths :message]) "unknown Git request field"))
  (def paths (value :paths))
  (assert (and (indexed? paths) (> (length paths) 0)) "select explicit repository paths")
  (each file paths
    (assert (and (string? file) (not (path/abspath? file)) (not (string/find "\\" file)) (not (string/find "\0" file))) "invalid Git path")
    (each part (string/split "/" file)
      (assert (not (index-of part ["" "." ".." ".git"])) "invalid Git path component")))
  (when (= member "commit")
    (assert (and (string? (value :message)) (<= 1 (length (value :message)) 2048)) "commit requires a message"))
  (def arguments (case member
                   "status" ["status" "--short"]
                   "diff" ["diff" "HEAD" "--no-ext-diff" "--no-textconv"]
                   "add" ["add"]
                   "commit" ["commit" "--only" "--message" (value :message)]))
  (def child (os/spawn [(config :executable) "-C" (config :repo) "--no-pager" "--literal-pathspecs"
                       "-c" "core.hooksPath=/dev/null" "-c" "core.fsmonitor=false" ;arguments "--" ;paths]
                      :pe {"PATH" "/usr/bin:/bin" "HOME" "/nonexistent" "GIT_CONFIG_NOSYSTEM" "1"
                           "GIT_CONFIG_GLOBAL" "/dev/null" :in :pipe :out :pipe :err :pipe}))
  (ev/close (child :in))
  (def channel (ev/chan 2))
  (var waited false)
  (ev/with-deadline (config :seconds)
    (defer (unless waited (try (os/proc-kill child true) ([err] nil)))
      (each key [:out :err]
        (ev/go (fn []
                 (def output @"")
                 (def outcome (try
                                (do
                                  (var chunk nil)
                                  (while (set chunk (ev/read (child key) 4096 nil (config :seconds)))
                                    (assert (<= (+ (length output) (length chunk)) (config :response-bytes)) "Git output byte ceiling")
                                    (buffer/push-string output chunk))
                                  {:key key :text (string output)})
                                ([err] {:error (string err)})))
                 (ev/close (child key))
                 (ev/give channel outcome))))
      (def a (ev/take channel))
      (def b (ev/take channel))
      (def status (os/proc-wait child))
      (set waited true)
      (assert (not (or (a :error) (b :error))) (or (a :error) (b :error)))
      (assert (= 0 status) (if (= :err (a :key)) (a :text) (b :text)))
      (if (= :out (a :key)) (a :text) (b :text)))))

(defn describe [bytes opaque]
  (assert (= "" bytes) "describe takes empty input")
  (settings/validate settings/git opaque true)
  (json/encode {:schema {:config settings/git}}))

(def status (partial execute "status"))
(def diff (partial execute "diff"))
(def add (partial execute "add"))
(def commit (partial execute "commit"))
