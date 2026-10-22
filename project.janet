(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "A Janet agent with independent source branches and durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/darkhorseprojects/portable-agents.git" :tag "5b096511204a1fe6d9968a69c2334a567853c568"}
   {:repo "https://github.com/janet-lang/sqlite3.git" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/CosmicToast/jurl.git" :tag "e620ee820d50585c0efecfff2c2d580b5ac18213"}
   {:repo "https://github.com/janet-lang/spork.git" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(declare-source :source ["src" "zinc.md" "models.ini" "models.lock"] :prefix "zinc")
(declare-source :source ["data/stopwords-iso.json"] :prefix "zinc/data")
(declare-source :source ["tools/cygnet_index.py"] :prefix "zinc/tools")
