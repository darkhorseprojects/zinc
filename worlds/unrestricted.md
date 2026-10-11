# Unrestricted world

This world inherits the same agent schema and opaque configuration as the configured world. It requests filesystem, process and arbitrary HTTP members on `self`. Each requires an explicit invoker grant.

Unlike configured and empty, this world may request agent-triggered merging. The invoker must separately grant `merge`; proposals are still validated before acceptance. Model code never receives ledger access or provider credentials.

## Definition

The configured world is reused through ordinary Janet module composition. Filesystem operations here accept an explicit root; `http/request` accepts an HTTP(S) URL.

```janet
(import spork/path :as path)
(import spork/utf8 :as utf8)

(import ../src/model)
(import ../src/world)
(import ./configured)

(def operations
  (merge configured/operations
         {"fs/read"
          {:policy "safe"
           :description "(self/fs/read root path) reads bounded UTF-8 file text."

           :function
           (fn [s view root relative]
             (def config (s :config))
             (def target (path/join root relative))

             (assert (= :file (os/stat target :mode))
                     "read requires a regular file")

             (def bytes @"")

             (with [file (file/open target :rb)]
               (file/read file (+ 1 (config :response-bytes)) bytes))

             (assert (and (<= (length bytes) (config :response-bytes))
                          (utf8/is-valid? bytes))
                     "file exceeds byte ceiling or is not UTF-8")

             (string bytes))}

          "fs/write"
          {:policy "irreversible"
           :description "(self/fs/write root path text) replaces a file."

           :function
           (fn [s view root relative text]
             (assert (and (string? text)
                          (utf8/is-valid? text)
                          (<= (length text) ((s :config) :request-bytes)))
                     "write requires bounded UTF-8 text")

             (spit (path/join root relative) text)
             "written")}

          "process/run"
          {:policy "irreversible"
           :description "(self/process/run executable arguments input) returns {status,out,err}."

           :function
           (fn [s view executable arguments &opt input]
             (assert (and (string? executable)
                          (path/abspath? executable)
                          (array? arguments))
                     "invalid process request")

             (each argument arguments
               (assert (string? argument) "process arguments must be strings"))

             (def result (world/process (s :config)
                                      [executable ;arguments]
                                      input))

             (assert (and (utf8/is-valid? (result :out))
                          (utf8/is-valid? (result :err)))
                     "process output is not UTF-8; effects may have happened")

             result)}

          "http/request"
          {:policy "irreversible"
           :description "(self/http/request url method body headers) performs a bounded HTTP(S) request."

           :function
           (fn [s view url method &opt body headers]
             (assert (peg/match
                       ~(* (choice "https://" "http://")
                           (some (if-not (set "#@ \t\r\n") 1))
                           -1)
                       url)
                     "invalid HTTP URL")

             (assert (index-of method ["GET" "HEAD" "POST" "PUT" "PATCH" "DELETE"])
                     "unsupported HTTP method")

             (model/collect-http (model/http-request (s :config)
                                        url
                                        method
                                        body
                                        (or headers {}))))}}))

(def definition
  (merge configured/definition
         {:name "unrestricted"

          :nested ["unrestricted" "configured" "empty"]

          :requested (sorted (keys operations))

          :operations operations

          :agent-merge true

          :document (pa/document)}))
```
