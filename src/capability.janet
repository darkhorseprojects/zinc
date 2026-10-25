(import spork/path :as path)
(import spork/utf8 :as utf8)
(import ./http)
(import ./store)

(defn- file-path [root relative permission]
  (def grant ((dyn :capability/config) (keyword root)))
  (assert (and grant (grant permission)) "filesystem operation is not granted")
  (assert (and (string? relative) (> (length relative) 0) (not (string/find "\0" relative))
               (not (string/find "\\" relative)) (not (string/find ":" relative)) (not (path/abspath? relative))) "invalid relative path")
  (var target (os/realpath (grant :root)))
  (each part (if (= relative ".") [] (string/split "/" relative))
    (assert (and (> (length part) 0) (not (index-of part ["." ".."]))) "invalid path component")
    (when (index-of (os/which) [:windows :mingw])
      (assert (and (not (index-of (last part) [32 46]))
                   (not (peg/match ~(* (choice "CON" "PRN" "AUX" "NUL" (* (choice "COM" "LPT") (range "19"))) -1)
                                   (string/ascii-upper (first (string/split "." part)))))) "invalid Windows path component"))
    (set target (path/join target part))
    (assert (not= :link (os/lstat target :mode)) "filesystem symlinks are not permitted"))
  target)

(def list
  "(fs/list root relative)\n\nList sorted names under a readable root; relative \".\" selects the root directory."
  (fn list [root relative]
    (def target (file-path root relative :read))
    (assert (= :directory (os/stat target :mode)) "directory required")
    (def names (os/dir target))
    (def config ((first (dyn :zinc/context)) :config))
    (assert (and (<= (length names) (config :history-records))
                 (<= (sum (map length names)) (config :response-bytes))) "directory result exceeds limit")
    (sorted names)))

(def read
  "(fs/read root relative)\n\nRead a UTF-8 file under a readable root."
  (fn read [root relative]
    (def target (file-path root relative :read))
    (assert (= :file (os/stat target :mode)) "regular file required")
    (def maximum (((first (dyn :zinc/context)) :config) :response-bytes))
    (with [file (file/open target :rbn)]
      (def bytes (or (file/read file (+ maximum 1)) ""))
      (assert (<= (length bytes) maximum) "file exceeds byte limit")
      (assert (utf8/is-valid? bytes) "file is not UTF-8")
      (string bytes))))

(def write
  "(fs/write root relative text)\n\nCreate or replace a UTF-8 file under a writable root."
  (fn write [root relative text]
    (def target (file-path root relative :write))
    (assert (and (string? text) (utf8/is-valid? text)
                 (<= (length text) (((first (dyn :zinc/context)) :config) :response-bytes))) "invalid file contents")
    (assert (or (nil? (os/stat target)) (= :file (os/stat target :mode))) "regular file required")
    (with [file (file/open target :wbn)] (file/write file text))
    nil))

(def request
  "(http/request root method segments body)\n\nRequest a named HTTP base without redirects. segments is an array of literal path segments; body is text or nil. Return {:status integer :body text}, including HTTP errors."
  (fn request [root method segments body]
    (def grant ((dyn :capability/config) (keyword root)))
    (assert (and grant (index-of method (grant :methods))) "HTTP operation is not granted")
    (assert (and (indexed? segments) (every? (map |(and (string? $) (not (index-of $ ["." ".."]))
      (peg/match ~(* (some (set "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-~.")) -1) $)) segments))) "invalid HTTP path")
    (assert (or (nil? body) (string? body)) "HTTP body must be text or nil")
    (http/request ((first (dyn :zinc/context)) :config) grant method (string/join segments "/") body)))

(def run
  "(process/run name)\n\nRun a named argv with its configured environment and empty stdin. Return {:exit integer :output text}; stdout/stderr are combined."
  (fn run [name]
    (def command ((dyn :capability/config) (keyword name)))
    (assert command "process is not granted")
    (def s (first (dyn :zinc/context)))
    (store/checkpoint s)
    (def child (os/spawn (command :argv) :e
                         (merge (tabseq [[key value] :in (pairs (command :env))] (string key) value)
                                {:in :pipe :out :pipe :err :out})))
    (def exited (ev/chan 1))
    (ev/go (fn [] (os/proc-wait child)) nil exited)
    (def owner (fiber/current))
    (def watcher (ev/go (fn [] (try (while true (store/checkpoint s) (ev/sleep 0.1))
                                    ([err] (ev/cancel owner err))))))
    (defer (do (ev/cancel watcher "process finished")
               (when (nil? (child :return-code))
                 (try (os/proc-kill child) ([err] nil)) (ev/take exited))
               (ev/close (child :out)))
      (ev/close (child :in))
      (def output @"")
      (var chunk nil)
      (while (set chunk (ev/read (child :out) 4096))
        (assert (<= (+ (length output) (length chunk)) ((s :config) :response-bytes)) "process output exceeds byte limit")
        (buffer/push-string output chunk))
      (ev/take exited)
      (assert (utf8/is-valid? output) "process output is not UTF-8")
      {:exit (child :return-code) :output (string output)})))
