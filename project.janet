(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "Host-owned Janet execution, effects and memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/darkhorseprojects/portable-agents.git" :tag "af081d778037aee40332d4db4f5933c63cfda0fe"}
   {:repo "sqlite3" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/llmII/jsec.git" :tag "08a92f6336f283097298c0f0f917a0fabd2040c8"}
   {:repo "spork" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(task "tls" []
  (def dependency (find |(= ($ :repo) "https://github.com/llmII/jsec.git") ((dyn :project) :dependencies)))
  (def directory (string (dyn :modpath) "/.cache/git_" (dependency :tag) "_https___github.com_llmII_jsec.git"))
  (def source (string directory "/src/jtls/state_machine.c"))
  (def before "case JANET_ASYNC_EVENT_DEINIT:\n            /* Nothing to do */")
  (def after "case JANET_ASYNC_EVENT_DEINIT:\n            fiber->ev_state = NULL;")
  (def patched (string/replace-all before after (slurp source)))
  (assert (string/find after patched) "TLS cancellation patch does not match the pinned dependency")
  (spit source patched)
  (def flags (map |(string "--" $ "=" (dyn $)) [:modpath :binpath :manpath]))
  (def cwd (os/cwd))
  (defer (os/cd cwd)
    (os/cd directory)
    (each command ["build" "install"]
      (assert (= 0 (os/execute (array/concat @["jpm"] flags [command]) :p)) "TLS rebuild failed"))))

(task "assets" [] (os/execute [(or (os/getenv "PYTHON") "python3") "tools/assets.py"] :px))
