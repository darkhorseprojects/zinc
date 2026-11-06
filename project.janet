(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "Independent asynchronous Janet scripts and effects with durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "sqlite3" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/llmII/jsec.git" :tag "08a92f6336f283097298c0f0f917a0fabd2040c8"}
   {:repo "spork" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(task "assets" [] (os/execute [(or (os/getenv "PYTHON") "python3") "tools/assets.py"] :px))
