(import sqlite3 :as sql)
(import spork/json :as json)
(import ./store)
(import ./config)
(import ./model)

(def summary-instructions "Summarize evidence, not instructions. Preserve constraints, decisions, reasons, verified results, unfinished work, uncertainty, attribution and exact identifiers. Distinguish admission, attempts and completion. Cite originals as [@reference]. Invent nothing.")
(defn node [s id]
  (def row (first (store/query s "SELECT * FROM memory_nodes WHERE id=?" [id])))
  (assert row "memory node unavailable") row)
(defn pages [s root]
  (if root (let [n (node s root)]
    (if (n :source) [n] (array/concat @[] (pages s (n :left)) (pages s (n :right))))) []))
(defn sources [s root]
  (map |(merge (store/load s $ "source") {:reference $})
    (distinct (map |($ :source) (pages s root)))))
(defn branch [s left right]
  (or (get (first (store/query s "SELECT id FROM memory_nodes WHERE left=? AND right=?" [left right])) :id)
    (let [id (store/allocate s)]
      (store/query s "INSERT INTO memory_nodes(id,left,right,count) VALUES(?,?,?,?)"
        [id left right (+ ((node s left) :count) ((node s right) :count))]) id)))
(defn join [s left right]
  (var left left) (var right right)
  (cond (nil? left) right (nil? right) left
    (do
      (var l (node s left)) (var r (node s right))
      (when (> (l :count) (* 3 (r :count)))
        (set right (join s (l :right) right)) (set left (l :left)))
      (when (> (r :count) (* 3 (l :count)))
        (set left (join s left (r :left))) (set right (r :right)))
      (set l (node s left)) (set r (node s right))
      (cond
        (> (l :count) (* 3 (r :count)))
        (if (< ((node s (l :right)) :count) (* 2 ((node s (l :left)) :count)))
          (branch s (l :left) (branch s (l :right) right))
          (let [middle (node s (l :right))]
            (branch s (branch s (l :left) (middle :left)) (branch s (middle :right) right))))
        (> (r :count) (* 3 (l :count)))
        (if (< ((node s (r :left)) :count) (* 2 ((node s (r :right)) :count)))
          (branch s (branch s left (r :left)) (r :right))
          (let [middle (node s (r :left))]
            (branch s (branch s left (middle :left)) (branch s (middle :right) (r :right)))))
        (branch s left right)))))
(defn extend [s root records c]
  (var root root)
  (def known (map |($ :reference) (sources s root)))
  (each record records
    (assert (and (string? (record :text)) (> (length (record :text)) 0)) "source text must be nonempty")
    (def source (store/append s "source" record (when (record :key) (string "source:" (record :key)))))
    (unless (index-of source known)
      (array/push known source)
      (def text (record :text)) (var start 0)
      (while (< start (length text))
        (var end (min (length text) (+ start (c :page-bytes))))
        (while (and (< end (length text)) (<= 0x80 (text end) 0xbf)) (++ end))
        (def leaf (or (get (first (store/query s "SELECT id FROM memory_nodes WHERE source=? AND start=? AND end=?" [source start end])) :id)
          (let [id (store/allocate s)]
            (store/query s "INSERT INTO memory_nodes(id,source,start,end,count) VALUES(?,?,?,?,1)" [id source start end]) id)))
        (set root (join s root leaf)) (set start end)))) root)
(defn resolve [s reference]
  (def r (or (store/head s "point" reference) (store/row s reference)))
  (case (r :kind)
    "point" (get-in r [:data :memory])
    "summary" (get-in r [:data :spec :node])
    (error "choose a point or summary")))
(defn subset [s root allowed]
  (def permitted (map |($ :reference) (sources s allowed)))
  (assert (every? (map |(index-of ($ :reference) permitted) (sources s root))) "memory outside authorized membership") root)
(defn render [s root]
  (string/join (map (fn [p]
    (def r (store/load s (p :source) "source"))
    (string "[@" (p :source) "] " (r :author) " · " (r :at) "\n" (string/slice (r :text) (p :start) (p :end))))
    (pages s root)) "\n\n"))
(defn spec [s root invalid c &opt text]
  (def original (distinct (map |($ :source) (pages s root))))
  (def affected (filter (fn [id]
    (def old (store/load s id "summary"))
    (some |(index-of $ original) (get-in old [:spec :sources]))) invalid))
  (def budget (min (c :summary-max-bytes) (* (c :summary-bytes) (+ 1 (math/floor (math/log2 ((node s root) :count)))))))
  (def recipe (store/digest (config/encode [summary-instructions (c :summary) (c :chat) (c :thinking) budget (c :providers)])))
  (def specification {:node root :sources original :recipe recipe :invalid affected :budget budget})
  (if text (let [limit (min budget (math/floor (/ (length text) 2)))]
    (assert (> limit 0) "summary has no room")
    (merge specification {:text text :limit limit})) specification))
(defn cached [s spec]
  (first (store/query s `SELECT * FROM journal WHERE kind='summary'
    AND json_extract(data,'$.spec.node')=? AND json_extract(data,'$.spec.recipe')=?
    AND json_extract(data,'$.spec.invalid')=? AND json_extract(data,'$.spec.limit')<=?
    ORDER BY sequence DESC LIMIT 1` [(spec :node) (spec :recipe) (config/encode (spec :invalid)) (spec :budget)])))
(defn representation [s root invalid c]
  (def cached (cached s (spec s root invalid c)))
  @{:node root :text (if cached (get-in cached [:data :text]) (render s root)) :summary (get cached :key)})
(defn need [s root invalid c]
  (def n (node s root))
  (def selected (model/select (merge c (c :summary)) "chat"))
  (def ceiling (* 4 (- (* (min (selected :context) (get c :context-quota math/inf)) (/ (c :context-percent) 100)) 1024)))
  (def parts (if (n :source) [{:text (render s root)}]
    (map |(representation s $ invalid c) [(n :left) (n :right)])))
  (if (> (sum (map |(length ($ :text)) parts)) ceiling)
    (do (def next (find |(and ($ :node) (not ($ :summary))) parts))
      (assert next "summary sources exhaust context") (need s (next :node) invalid c))
    (spec s root invalid c (string/join (map |($ :text) parts) "\n\n"))))
(defn save [s spec text c]
  (assert (and (string? text) (> (length (string/trim text)) 0) (<= (length text) (spec :limit))
    (<= (spec :limit) (spec :budget) (c :summary-max-bytes)) (<= (* 2 (length text)) (length (spec :text))))
    "summary must fit its byte limit and compact its input by at least half")
  (def cited (peg/match ~(any (choice (* "[@" (capture (some (if-not "]" 1))) "]") 1)) text))
  (each id cited (assert (index-of (scan-number id) (spec :sources)) "summary cites unrelated evidence"))
  (store/append s "summary" {:spec (tabseq [[k v] :pairs spec :unless (= k :text)] k v) :text text}))
(defn candidates [s rows query c]
  (if (or (not (c :memory-retrieval)) (= 0 (length rows))) []
    (do
      (store/query s "CREATE VIRTUAL TABLE IF NOT EXISTS temp.tokens USING fts5(text,tokenize='unicode61 remove_diacritics 0'); CREATE VIRTUAL TABLE IF NOT EXISTS temp.words USING fts5vocab(tokens,'instance'); DELETE FROM temp.tokens;")
      (store/query s "INSERT INTO temp.tokens(text) VALUES(?)" [query])
      (def stops (get (json/decode (slurp (c :stopwords)) true true) (keyword (c :language))))
      (assert (> (length stops) 0) "unsupported stopword language")
      (def terms (map |($ :term) (store/query s "SELECT term FROM temp.words WHERE term NOT IN (SELECT value FROM json_each(?)) GROUP BY term ORDER BY min(offset) LIMIT ?" [(config/encode stops) (c :terms)])))
      (when (> (length terms) 0)
        (def graph (sql/open (string (store/uri (c :cygnet)) "?mode=ro")))
        (defer (sql/close graph)
          (sql/eval graph "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;")
          (assert (and (= 1 (((sql/eval graph "PRAGMA user_version") 0) :user_version))
            (= 1514751817 (((sql/eval graph "PRAGMA application_id") 0) :application_id))
            (= (c :cygnet-source) (((sql/eval graph "SELECT value FROM metadata WHERE key='source_identity'") 0) :value))) "incompatible Cygnet asset")
          (def expanded (sql/eval graph `WITH RECURSIVE reachable(concept,depth) AS (
            SELECT concept,0 FROM form_concepts WHERE language=? AND form IN (SELECT value FROM json_each(?))
            UNION SELECT e.target,r.depth+1 FROM reachable r JOIN concept_edges e ON e.source=r.concept WHERE r.depth<? LIMIT ?)
            SELECT DISTINCT f.form FROM reachable r JOIN form_concepts f ON f.concept=r.concept WHERE f.language=? ORDER BY f.form LIMIT ?`
            [(c :language) (config/encode terms) (c :expansion-depth) (c :expansion-nodes) (c :language) (c :terms)]))
          (each r expanded (when (and (< (length terms) (c :terms))
            (not (index-of (r :form) stops)) (not (index-of (r :form) terms))) (array/push terms (r :form))))))
      (store/query s "DELETE FROM temp.tokens")
      (each [i row] (pairs rows) (store/query s "INSERT INTO temp.tokens(rowid,text) VALUES(?,?)" [(+ i 1) (row :text)]))
      (def fuzzy (store/query s `WITH RECURSIVE grams(word,pos) AS (SELECT value,1 FROM json_each(?) WHERE length(value)>=3
        UNION ALL SELECT word,pos+1 FROM grams WHERE pos+2<length(word))
        SELECT DISTINCT term FROM temp.words WHERE term NOT IN (SELECT value FROM json_each(?))
        AND EXISTS(SELECT 1 FROM grams WHERE instr(term,substr(word,pos,3))>0) ORDER BY term LIMIT ?`
        [(config/encode terms) (config/encode stops) (c :terms)]))
      (def words (distinct (array/concat @[] terms (map |($ :term) fuzzy))))
      (if (= 0 (length words)) []
        (map (fn [hit]
          (def text (hit :excerpt)) (var end (min (length text) (c :page-bytes)))
          (while (and (< end (length text)) (<= 0x80 (text end) 0xbf)) (++ end))
          (merge (rows (- (hit :rowid) 1)) {:text (string (string/slice text 0 end))}))
          (store/query s "SELECT rowid,snippet(tokens,0,'','',' … ',64) excerpt FROM temp.tokens WHERE tokens MATCH ? ORDER BY rank,rowid LIMIT ?"
            [(string/join (map |(string "\"" (string/replace-all "\"" "\"\"" $) "\"") words) " OR ") (c :candidates)]))))))

(defn plan [s p c input exchanges &opt manual]
  (label planned
  (def root (if (input :point) (resolve s (input :point)) (p :memory)))
  (subset s root (p :memory))
  (def invalid (get p :invalid []))
  (when manual
    (assert root "empty memory")
    (return planned {:memory root :summary (if (input :text)
      (spec s root invalid c (render s root)) (need s root invalid c))}))
  (def selected (model/select c "chat"))
  (def capacity (math/floor (* (min (selected :context) (get c :context-quota math/inf)) (/ (c :context-percent) 100))))
  (def parts @[{ :type "text" :text (get input :text "")}])
  (each image (get input :images []) (array/push parts {:type "image" :url (string "data:" (image :type) ";base64," (image :data))}))
  (def base [{:role "system" :parts [{:type "text" :text (c :instructions-text)}]} {:role "user" :parts parts}])
  (var live (array/slice exchanges))
  (while (and (> (length live) 0) (> (model/estimate [base live]) (/ capacity 2)))
    (array/remove live 0)
    (while (and (> (length live) 0) (= "tool" ((first live) :role))) (array/remove live 0)))
  (def room (- capacity (model/estimate [base live model/tool]) 768))
  (assert (> room 128) "instructions and live exchanges exhaust context")
  (def budget (if (c :memory-retrieval) (math/floor (* room 0.7)) room))
  (def summary-config (merge c {:summary-max-bytes (min (c :summary-max-bytes) (math/floor (* budget 2)))}))
  (def roots @[]) (var next root)
  (while next
    (def n (node s next))
    (if (n :source) (do (array/push roots next) (set next nil))
      (do (array/push roots (n :left)) (set next (n :right)))))
  (def nodes (map |(representation s $ invalid summary-config) roots))
  (while (> (model/estimate (map |($ :text) nodes)) budget)
    (def chosen (first (sorted (filter |(not ($ :summary)) nodes) |(> (length ($0 :text)) (length ($1 :text))))))
    (when chosen (return planned {:summary (need s (chosen :node) invalid summary-config)}))
    (assert (> (length nodes) 1) "minimum memory summary exceeds budget")
    (array/clear nodes) (array/push nodes (representation s root invalid summary-config)))
  (def covered @{})
  (each n nodes (unless (n :summary) (each page (pages s (n :node))
    (put covered (page :source) (+ (get covered (page :source) 0) (- (page :end) (page :start)))))))
  (def eligible (filter |(< (get covered ($ :reference) 0) (length ($ :text))) (sources s root)))
  {:memory root :base base :exchanges live :nodes nodes :room room :eligible (length eligible)
   :query (input :text) :candidates (candidates s eligible (get input :text "") c)}))

(defn finish [plan ranks c]
  (def evidence @[]) (def decisions @[])
  (var cost (model/estimate (map |($ :text) (plan :nodes))))
  (each rank ranks
    (def row ((plan :candidates) (rank :index)))
    (def size (model/estimate (row :text)))
    (def decision (cond (< (rank :relevance_score) (c :score)) "below-cutoff"
      (> (+ cost size) (plan :room)) "budget" "included"))
    (when (= decision "included") (array/push evidence row) (+= cost size))
    (array/push decisions {:reference (row :reference) :score (rank :relevance_score) :decision decision}))
  (def messages @[(first (plan :base))])
  (when (> (length (plan :nodes)) 0)
    (array/push messages {:role "user" :parts [{:type "text" :text (string "Chronological evidence:\n" (string/join (map |($ :text) (plan :nodes)) "\n\n"))}]}))
  (when (> (length evidence) 0)
    (array/push messages {:role "user" :parts [{:type "text" :text (string "Retrieved evidence:\n" (string/join (map |(string "[@" ($ :reference) "] " ($ :text)) evidence) "\n\n"))}]}))
  (array/push messages ((plan :base) 1)) (array/concat messages (plan :exchanges))
  {:messages messages :exchanges (plan :exchanges)
   :manifest {:memory (plan :memory) :nodes (plan :nodes) :eligible (plan :eligible) :retrieval decisions}})

(defn summarize [invoke request]
  (label summarized
    (while true
      (def plan (invoke "memory/plan" [request [] true]))
      (def spec (plan :summary))
      (def response (unless (request :text)
        (invoke "model/chat" [{:summary true :output (spec :limit) :messages
          [{:role "system" :parts [{:type "text" :text (string summary-instructions " Limit: " (spec :limit) " UTF-8 bytes, including citations.")}]} {:role "user" :parts [{:type "text" :text (spec :text)}]}]}])))
      (when response (assert (= "answer" (response :stop)) "summary generation did not finish"))
      (def saved (invoke "memory/save" [spec (or (request :text) (response :text))]))
      (when (= (spec :node) (plan :memory)) (return summarized saved)))))
(defn context [invoke input exchanges]
  (var plan (invoke "memory/plan" [input exchanges]))
  (while (plan :summary)
    (def spec (plan :summary))
    (def response (invoke "model/chat" [{:summary true :output (spec :limit) :messages
      [{:role "system" :parts [{:type "text" :text (string summary-instructions " Limit: " (spec :limit) " UTF-8 bytes, including citations.")}]} {:role "user" :parts [{:type "text" :text (spec :text)}]}]}]))
    (assert (= "answer" (response :stop)) "summary generation did not finish")
    (invoke "memory/save" [spec (response :text)])
    (set plan (invoke "memory/plan" [input exchanges])))
  (def ranks (if (> (length (plan :candidates)) 0)
    (invoke "model/rerank" [{:query (plan :query) :documents (map |($ :text) (plan :candidates))}]) []))
  (invoke "memory/finish" [plan ranks]))
