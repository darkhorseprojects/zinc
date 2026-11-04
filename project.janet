(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "Independent Janet tasks with committed state and durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/janet-lang/sqlite3.git" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/darkhorseprojects/jurl.git" :tag "0a1aa237e4e1941cd6d15018a81d03052050ecef"}
   {:repo "https://github.com/janet-lang/spork.git" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(task "assets" [] (os/execute [(or (os/getenv "PYTHON") "python3") "tools/assets.py"] :px))
