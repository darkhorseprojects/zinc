(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "Independent Janet tasks with committed state and durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "sqlite3" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "spork" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}
   {:repo "jurl" :tag "e620ee820d50585c0efecfff2c2d580b5ac18213"}])

(task "assets" [] (os/execute [(or (os/getenv "PYTHON") "python3") "tools/assets.py"] :px))
