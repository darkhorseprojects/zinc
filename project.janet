(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "Durable Janet execution, binding worlds and selected memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/darkhorseprojects/portable-agents.git" :tag "dabf4adab8000696228923e0231e454513a1e7de"}
   {:repo "sqlite3" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/llmII/jsec.git" :tag "08a92f6336f283097298c0f0f917a0fabd2040c8"}
   {:repo "spork" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(def prefix (string (os/getenv (if (index-of (os/which) [:windows :mingw]) "USERPROFILE" "HOME")) "/.local"))
(def modules (or (os/getenv "JANET_MODPATH") (string prefix "/lib/janet")))
(def flags
  [(string "--modpath=" modules)
   (string "--binpath=" (or (os/getenv "JANET_BINPATH") (string prefix "/bin")))
   (string "--manpath=" (or (os/getenv "JANET_MANPATH") (string prefix "/share/man/man1")))])
(def environment (merge (os/environ) {"JANET_PATH" modules "JANET_SYSTEM_SQLITE" "0"}))

(task "dependencies" []
  (os/execute (array/concat @["jpm"] flags
    [(if (index-of (os/which) [:windows :mingw])
       "--cflags=/nologo,/MD,/DSQLITE_ENABLE_FTS5,/DSQLITE_USE_URI=1"
       "--cflags=-std=c99,-DSQLITE_ENABLE_FTS5,-DSQLITE_USE_URI=1") "deps"])
    :pxe environment))

(task "tls" ["dependencies"]
  (def dependency (find |(= ($ :repo) "https://github.com/llmII/jsec.git") ((dyn :project) :dependencies)))
  (def directory (string modules "/.cache/git_" (dependency :tag) "_https___github.com_llmII_jsec.git"))
  (def source (string directory "/src/jtls/state_machine.c"))
  (def before "case JANET_ASYNC_EVENT_DEINIT:\n            /* Nothing to do */")
  (def after "case JANET_ASYNC_EVENT_DEINIT:\n            fiber->ev_state = NULL;")
  (def contents (slurp source))
  (def patched (string/replace-all before after contents))
  (assert (string/find after patched) "TLS cancellation patch does not match the pinned dependency")
  (unless (= contents patched) (spit source patched))
  (os/execute (array/concat @["janet" "-E"
    `(do (os/cd $0) (each command ["build" "install"]
       (os/execute (array/concat @["jpm"] $& [command]) :px)))` directory] flags) :pxe environment))

(def python (or (os/getenv "PYTHON") (if (index-of (os/which) [:windows :mingw]) "python" "python3")))
(task "assets" [] (os/execute [python "tools/assets.py"] :px))

(task "build" ["tls" "assets"])

(task "init" [] (os/execute ["janet" "tools/init.janet"] :pxe environment))
