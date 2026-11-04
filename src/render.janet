(import spork/json :as json)

(defn render [node]
  (cond
    (string? node) node
    (indexed? node) (string/join (map render node) "\n\n")
    (dictionary? node)
    (cond
      (has-key? node :content) (string (when (node :name) (string (string/repeat "#" (node :level)) " " (node :name) "\n\n")) (render (node :content)))
      (has-key? node :text) (if (node :language)
        (let [runs (peg/match ~(any (choice (capture (some "`")) 1)) (node :text))
              fence (string/repeat "`" (max 3 (+ 1 (max 0 ;(map length runs)))))]
          (string fence (node :language) "\n" (node :text) "\n" fence)) (node :text))
      (render {:language "json" :text (string (json/encode node "  " "\n"))})) ""))
