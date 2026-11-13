(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "Host-owned Janet execution, effects and memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "sqlite3" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/llmII/jsec.git" :tag "08a92f6336f283097298c0f0f917a0fabd2040c8"}
   {:repo "spork" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(task "tls" []
  (def dependency (find |(= ($ :repo) "https://github.com/llmII/jsec.git") ((dyn :project) :dependencies)))
  (def directory (string (dyn :modpath) "/.cache/git_" (dependency :tag) "_https___github.com_llmII_jsec.git"))
  (def source (string directory "/src/jtls/state_machine.c"))
  (def before "case JANET_ASYNC_EVENT_DEINIT:\n            /* Nothing to do */")
  (def after "case JANET_ASYNC_EVENT_DEINIT:\n            fiber->ev_state = NULL;")
  (def contents (slurp source))
  (def patched (string/replace-all before after contents))
  (assert (string/find after patched) "TLS cancellation patch does not match the pinned dependency")
  (unless (= contents patched) (spit source patched))
  (def flags (map |(string "--" $ "=" (dyn $)) [:modpath :binpath :manpath]))
  (os/execute (array/concat @["janet" "-E"
    `(do (os/cd $0) (each command ["build" "install"]
       (os/execute (array/concat @["jpm"] $& [command]) :px)))` directory] flags) :px))

(task "assets" [] (os/execute [(or (os/getenv "PYTHON") "python3") "tools/assets.py"] :px))

(task "build" ["tls" "assets"])
