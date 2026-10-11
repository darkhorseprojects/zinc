(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "A Janet agent with file-backed resident worlds and durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/darkhorseprojects/portable-agents.git" :tag "e1400d67d3bd91eaa88c7a85f395f5d7c0068c8a"}
   {:repo "https://github.com/janet-lang/sqlite3.git" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/CosmicToast/jurl.git" :tag "e620ee820d50585c0efecfff2c2d580b5ac18213"}
   {:repo "https://github.com/janet-lang/spork.git" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(declare-source :source ["src" "zinc.md"] :prefix "zinc")

(def script (string (find-build-dir) "zinc"))
(rule script ["cli.janet"]
      (create-dirs script)
      (copyfile "cli.janet" script)
      (os/chmod script 8r755))
(task "install" [script])
(declare-binscript :main script :hardcode-syspath true)
