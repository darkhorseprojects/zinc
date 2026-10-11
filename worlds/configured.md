# Configured world

This world inherits Zinc's opaque configuration and schema, including its named roots, HTTP actions and search executable. The world owns the corresponding `self` members; there is no second detached filesystem interface.

Operations require invoker grants. Working environment changes can be proposed, but only the user can merge them into this world's origin.

## Files

`self/fs/read` and `self/fs/write` use a named root and a relative path. Reads are bounded UTF-8 text. Writes replace regular files beneath the root; symbolic-link targets are rejected.

## Network

`self/http/call` invokes an exact configured action. `self/search/web` uses the configured search action and query parameter. `self/search/text` and `self/search/files` invoke the configured search executable beneath a named root. Network responses are bounded; binary bodies are returned as Base64.

## Definition

```janet
(import spork/path :as path)
(import spork/utf8 :as utf8)
(import spork/base64 :as base64)
(import jurl/native :as curl)

(import ../src/model)
(import ../src/world)
(import ./empty)

(def operations
  {"fs/read"
   {:policy "safe"
    :description "(self/fs/read root path) reads bounded UTF-8 text beneath a named root."

    :function
    (fn [s view name relative]
      (def config (s :config))
      (def base ((config :roots) (keyword name)))

      (assert (and base (string? relative) (not (path/abspath? relative)))
              "invalid named-root path")

      (def target (os/realpath (path/join base relative)))

      (assert (and (string/has-prefix? (string base "/") target)
                   (= :file (os/stat target :mode)))
              "file outside root grant")

      (def bytes @"")

      (with [file (file/open target :rb)]
        (file/read file (+ 1 (config :response-bytes)) bytes))

      (assert (and (<= (length bytes) (config :response-bytes))
                   (utf8/is-valid? bytes))
              "file exceeds byte ceiling or is not UTF-8")

      (string bytes))}

   "fs/write"
   {:policy "irreversible"
    :description "(self/fs/write root path text) replaces a named-root file."

    :function
    (fn [s view name relative text]
      (def config (s :config))
      (def base ((config :roots) (keyword name)))

      (assert (and base
                   (string? relative)
                   (not (path/abspath? relative))
                   (string? text)
                   (utf8/is-valid? text)
                   (<= (length text) (config :request-bytes)))
              "invalid file write")

      (def parent (os/realpath (path/dirname (path/join base relative))))

      (assert (or (= base parent)
                  (string/has-prefix? (string base "/") parent))
              "parent outside root grant")

      (def target (path/join parent (path/basename relative)))

      (assert (or (not (os/lstat target))
                  (= :file (os/lstat target :mode)))
              "write target must not be a symlink")

      (spit target text)
      "written")}

   "http/call"
   {:policy "irreversible"
    :description "(self/http/call action body headers) returns {status,body}, or Base64 data for binary output."

    :function
    (fn [s view name body &opt headers]
      (def action (((s :config) :actions) (keyword name)))

      (assert (and action (string? body)) "invalid HTTP action/body")

      (model/collect-http (model/http-request (s :config)
                                 (string (action :origin) (action :path))
                                 (action :method)
                                 body
                                 (or headers {}))))}

   "search/web"
   {:policy "safe"
    :description "(self/search/web query) searches the invoker-configured endpoint."

    :function
    (fn [s view query]
      (def config (s :config))
      (def search (config :search))
      (def action ((config :actions) (keyword (search :action))))

      (assert (and action
                   (= "GET" (action :method))
                   (string? query)
                   (< 0 (length query) (config :request-bytes)))
              "invalid configured search")

      (def separator (if (string/find "?" (action :path)) "&" "?"))
      (def url (string (action :origin)
                       (action :path)
                       separator
                       (curl/escape (search :query-key))
                       "="
                       (curl/escape query)))

      (model/collect-http (model/http-request config url "GET" nil {})))}

   "search/text"
   {:policy "safe"
    :description "(self/search/text root query) returns matching lines beneath a named root."

    :function
    (fn [s view name query]
      (def config (s :config))
      (def root ((config :roots) (keyword name)))
      (assert (and root (string? query)) "invalid root/search query")

      (def result (world/process config
                                [((config :search) :executable) "--no-follow" "--" query root]))
      (assert (and (index-of (result :status) [0 1]) (utf8/is-valid? (result :out)))
              (result :err))
      (result :out))}

   "search/files"
   {:policy "safe"
    :description "(self/search/files root) lists files beneath a named root."

    :function
    (fn [s view name]
      (def config (s :config))
      (def root ((config :roots) (keyword name)))
      (assert root "unknown root")

      (def result (world/process config
                                [((config :search) :executable) "--no-follow" "--files" "--" root]))
      (assert (and (= 0 (result :status)) (utf8/is-valid? (result :out))) (result :err))
      (result :out))}})

(def definition
  (merge empty/definition
         {:name "configured"

          :nested ["configured" "empty"]

          :requested (sorted (keys operations))

          :operations operations

          :agent-merge false

          :document (pa/document)}))
```
