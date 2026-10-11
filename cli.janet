#!/usr/bin/env janet

(import zinc/src/repl :as repl)
(import spork/json :as json)
(import portable-agents/src/protocol :as wire)
(import portable-agents/src/pa :as pa)

(defn main [_ command file & args]
  (assert (and file (index-of command ["serve" "repl" "ask"])) "usage: zinc serve|repl|ask CONFIG.json [QUESTION]")
  (def source (slurp file))
  (def limits ((json/decode source true true) :limits))
  (with-dyns [:pa/limits (wire/limits (table ;(catseq [[key value] :in (pairs limits)] [(string key) value])))]
    (def config (wire/json source true))
    (if (= command "serve")
      (do
        (wire/record config ["limits" "config"] [])
        (repl/serve "" (wire/json (config "config"))))
      (do
        (wire/record config ["program" "limits" "config"] ["spawn" "imports"])
        (def grants (get config "imports" []))
        (def private (wire/json (merge (config "config")
                                       {"imports" (tabseq [grant :in grants] (grant "name") (grant "members"))})))
        (def imports (map (fn [grant]
                            (if (= "self" (grant "program"))
                              (do
                                (assert (not (has-key? grant "config")) "self Import must inherit its configuration")
                                (merge grant {"program" (config "program") "config" private}))
                              (merge grant {"config" (wire/json (grant "config"))}))) grants))
        (defn submit [member value]
          (def result (pa/invoke (config "program") (wire/json value) private
                                 {:limits (config "limits") :spawn (get config "spawn" []) :imports imports :member member}))
          (print ((wire/json result true) "text")))
        (if (= command "ask")
          (submit "call" {"text" (string/join args " ")})
          (do
            (var parser (parser/new))
            (def pending @"")
            (var line nil)
            (while (> (length (set line (getline (if (= 0 (length pending)) "zinc> " "...> ")))) 0)
              (try
                (if (and (= 0 (length pending)) (string/has-prefix? "/ask " line))
                  (submit "call" {"text" (string/trim (string/slice line 5))})
                  (do
                    (buffer/push-string pending line "\n")
                    (parser/consume parser line)
                    (parser/consume parser "\n")
                    (assert (not= :error (parser/status parser)) (parser/error parser))
                    (when (= :root (parser/status parser))
                      (unless (= "" (string/trim pending))
                        (submit "invoke" {"code" (string pending)}))
                      (buffer/clear pending)
                      (set parser (parser/new)))))
                ([err]
                  (eprint err)
                  (buffer/clear pending)
                  (set parser (parser/new)))))))))))
