(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "A Janet agent with independent source branches and durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/darkhorseprojects/portable-agents.git" :tag "63a6d52583abea43d5473ff8a84c5e07ad9d4119"}
   {:repo "https://github.com/janet-lang/sqlite3.git" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/CosmicToast/jurl.git" :tag "e620ee820d50585c0efecfff2c2d580b5ac18213"}
   {:repo "https://github.com/janet-lang/spork.git" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(declare-source :source ["src" "zinc.md" "models.ini" "models.lock"] :prefix "zinc")
(declare-source :source ["data/stopwords-iso.json"] :prefix "zinc/data")
(declare-source :source ["tools/cygnet_index.py"] :prefix "zinc/tools")

(task "package" ["build"]
      (def system (get {:linux "linux" :macos "macos" :windows "windows"} (os/which)))
      (def architecture (get {:x64 "x86_64" :aarch64 "aarch64"} (os/arch)))
      (assert (and system architecture) "unsupported runtime target")
      (def version ((dyn :project) :version))
      (def ref (os/getenv "GITHUB_REF"))
      (when (and ref (string/has-prefix? "refs/tags/" ref))
        (assert (= ref (string "refs/tags/v" version)) "tag does not match project version"))
      (def directory (string (find-build-dir) "package"))
      (def staging (string directory "/zinc"))
      (rm staging)
      (each name ["zinc.md" "models.ini" "models.lock" "README.md" "LICENSE" "NOTICE" "data/stopwords-iso.json"]
        (def destination (string staging "/" name))
        (create-dirs destination)
        (copyfile name destination))
      (copy "src" staging)
      (each name (array/concat @["portable-agents/markdown.janet" "portable-agents/protocol.janet" "spork/path.janet"]
                               (map |(string $ (dyn :modext)) ["spork/base64" "spork/json" "spork/utf8" "sqlite3" "jurl/native"]))
        (def destination (string staging "/lib/" name))
        (create-dirs destination)
        (copyfile (string (dyn :modpath) "/" name) destination))
      (module/add-syspath (dyn :modpath))
      (require "remarkable/lib/remarkable")
      (def parser-root ((module/value (require "spork/path") 'dirname) (first (module/find "remarkable/lib/remarkable"))))
      (each [source _] (pairs module/cache)
        (when (and (string? source) (string/has-prefix? parser-root source))
          (def destination (string staging "/lib/remarkable/lib/" (string/slice source (length parser-root))))
          (create-dirs destination)
          (copyfile source destination)))
      (os/mkdir "dist")
      (def archive (string "dist/zinc-v" version "-" system "-" architecture (if (= system "windows") ".zip" ".tar.gz")))
      (tar (if (= system "windows") "-acf" "-czf") archive "-C" directory "zinc")
      (print archive))
