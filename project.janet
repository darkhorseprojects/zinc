(declare-project
  :name "zinc"
  :version "0.2.0"
  :description "A Janet agent with transactional worlds and durable memory"
  :license "AGPL-3.0-only"
  :dependencies
  [{:repo "https://github.com/darkhorseprojects/portable-agents.git" :tag "4bf5a9ce0ba4d45a138f6cc16a2815fb04f8ff4f"}
   {:repo "https://github.com/janet-lang/sqlite3.git" :tag "9126fe46ff1c7e42ca3d7bb9c8aed95a8236a32c"}
   {:repo "https://github.com/darkhorseprojects/jurl.git" :tag "0a1aa237e4e1941cd6d15018a81d03052050ecef"}
   {:repo "https://github.com/janet-lang/spork.git" :tag "8a87c5ae1cbbf3a0037eeac7f172bd45da4d9910"}])

(declare-source :source ["src" "zinc.md" "design.md" "models.ini" "models.lock"] :prefix "zinc")
(declare-source :source ["build/assets"] :prefix "zinc")

(task "assets" [] (os/execute [(or (os/getenv "PYTHON") "python3") "tools/assets.py"] :px))
(add-dep "install" "assets")

(task "package" ["build" "assets"]
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
      (each name ["zinc.md" "design.md" "models.ini" "models.lock" "README.md" "LICENSE" "NOTICE"]
        (def destination (string staging "/" name))
        (create-dirs destination)
        (copyfile name destination))
      (copy "src" staging)
      (copy "build/assets" staging)
      (each name (array/concat @["portable-agents/markdown.janet" "portable-agents/protocol.janet" "spork/path.janet"]
                               (map |(string $ (dyn :modext)) ["spork/base64" "spork/json" "spork/utf8" "sqlite3" "jurl/native"]))
        (def destination (string staging "/lib/" name))
        (create-dirs destination)
        (copyfile (string (dyn :modpath) "/" name) destination))
      (os/mkdir (string staging "/lib/remarkable"))
      (copy (string (dyn :modpath) "/remarkable/lib") (string staging "/lib/remarkable"))
      (when (= system "windows")
        (def root (os/getenv "CURL_ROOT"))
        (assert root "CURL_ROOT must select the libcurl installation")
        (each name ["bin" "share"] (copy (string root "/" name) staging)))
      (os/mkdir "dist")
      (def archive (string "dist/zinc-v" version "-" system "-" architecture (if (= system "windows") ".zip" ".tar.gz")))
      (tar (if (= system "windows") "-acf" "-czf") archive "-C" directory "zinc")
      (print archive))
