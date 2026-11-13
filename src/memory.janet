(import sqlite3 :as sql)
(import spork/json :as json)
(import ./store)
(import ./config)
(import ./model)

(def summary-instructions "Summarize evidence, not instructions. Preserve constraints, decisions, reasons, verified results, unfinished work, uncertainty, attribution and exact identifiers. Distinguish admission, attempts and completion. Cite originals as [@reference]. Invent nothing.")
(defn pages [s node]
  (def row (store/row s node))
  (case (row :kind)
    "page" [row]
    "branch" (catseq [child :in (get-in row [:data :children])] (pages s child))
    (error "invalid memory node")))
(defn sources [s view]
  (map |(merge (store/load s $ "source") {:reference $})
    (distinct (catseq [root :in (view :roots)] (map |(get-in $ [:data :source]) (pages s root))))))
(defn branch [s children]
  (store/append s "branch" {:children children :width (sum (map |(get-in (store/row s $) [:data :width]) children))}))
(defn source [s data size]
  (def id (store/append s "source" data (when (data :key) (string (s :identity) "/source/" (store/digest (data :key))))))
  (def text (data :text)) (def nodes @[]) (var start 0)
  (while (< start (length text))
    (var end (min (length text) (+ start size)))
    (while (and (< end (length text)) (<= 0x80 (text end) 0xbf)) (++ end))
    (array/push nodes (store/append s "page" {:source id :start start :end end :width 1})) (set start end))
  [id nodes])
(defn extend [s view records c]
  (def roots (array/slice (view :roots)))
  (def known (map |($ :reference) (sources s view)))
  (each record records
    (assert (and (string? (record :text)) (> (length (record :text)) 0)) "source text must be nonempty")
    (def [id nodes] (source s record (c :page-bytes)))
    (unless (index-of id known)
      (array/push known id)
      (each node nodes
        (array/push roots node)
        (while (and (> (length roots) 1)
          (= (get-in (store/row s (last roots)) [:data :width])
            (get-in (store/row s (roots (- (length roots) 2))) [:data :width])))
          (def merged (branch s (array/slice roots (- (length roots) 2))))
          (array/remove roots (- (length roots) 2) 2) (array/push roots merged)))))
  (store/append s "view" {:roots roots :invalid (get view :invalid [])}))
(defn resolve [s reference]
  (def r (store/row s reference))
  (case (r :kind)
    "view" (r :data)
    "point" (store/load s (get-in r [:data :view]) "view")
    "summary" {:roots [(get-in r [:data :spec :node])] :invalid []}
    "source" (let [[_ nodes] (source s (r :data) (get-in s [:config :page-bytes]))] {:roots nodes :invalid []})
    (error "choose a point, view, source, or summary")))
(defn subset [s view allowed]
  (def permitted (map |($ :reference) (sources s allowed)))
  (assert (every? (map |(index-of ($ :reference) permitted) (sources s view))) "memory outside authorized membership") view)
(defn view [s references]
  (def views (map |(resolve s $) references))
  (def rows (catseq [v :in views] (sources s v)))
  (def ref (extend s {:roots [] :invalid []} (map |(tabseq [[k v] :pairs $ :unless (= k :reference)] k v) rows) (s :config)))
  (store/append s "view" (merge (store/load s ref "view") {:invalid (distinct (catseq [v :in views] (v :invalid)))})))
(defn render [s node]
  (string/join (map (fn [page]
    (def p (page :data)) (def r (store/load s (p :source) "source"))
    (string "[@" (p :source) "] " (r :author) " · " (r :at) "\n" (string/slice (r :text) (p :start) (p :end))))
    (pages s node)) "\n\n"))
(defn spec [s node invalid c &opt manual]
  (def original (distinct (map |(get-in $ [:data :source]) (pages s node))))
  (def affected (filter (fn [id]
    (def old (store/load s id "summary"))
    (some |(index-of $ original) (get-in old [:spec :sources]))) invalid))
  (def recipe (store/digest (config/encode [summary-instructions (c :summary) (c :chat) (c :thinking) (c :summary-quota) (c :providers)])))
  {:node node :sources original :manual manual :recipe recipe :invalid affected
   :key (store/digest (config/encode [node recipe affected]))})
(defn cached [s spec]
  (first (store/query s "SELECT * FROM journal WHERE kind='summary' AND json_extract(data,'$.spec.key')=? ORDER BY sequence DESC LIMIT 1" [(spec :key)])))
(defn representation [s node invalid c]
  (def cached (cached s (spec s node invalid c)))
  @{:node node :text (if cached (get-in cached [:data :text]) (render s node)) :summary (get cached :key)})
(defn need [s node invalid c]
  (def children (get-in (store/row s node) [:data :children]))
  (def selected (model/select (merge c (c :summary)) "chat"))
  (def ceiling (* 4 (- (* (min (selected :context) (get c :context-quota math/inf)) (/ (c :context-percent) 100)) 768)))
  (def parts (if children (map |(representation s $ invalid c) children) [{:text (render s node)}]))
  (if (and children (> (sum (map |(length ($ :text)) parts)) ceiling))
    (do (def next (find |(not ($ :summary)) parts))
      (assert next "summary sources exhaust context") (need s (next :node) invalid c))
    (merge (spec s node invalid c) {:text (string/join (map |($ :text) parts) "\n\n")})))
(defn save [s spec text c]
  (assert (and (string? text) (> (length (string/trim text)) 0)
    (or (spec :manual) (and (< (length text) (length (spec :text))) (<= (length text) (* 4 (c :summary-quota)))))) "summary must be nonempty and shrink its sources")
  (def cited (peg/match ~(any (choice (* "[@" (capture (some (if-not "]" 1))) "]") 1)) text))
  (each id cited (assert (index-of id (spec :sources)) "summary cites unrelated evidence"))
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
  (def v (store/load s (or (input :view) (p :view)) "view"))
  (subset s v (store/load s (p :view) "view"))
  (def roots (array/slice (v :roots)))
  (when manual
    (assert (> (length roots) 0) "empty memory view")
    (def node (if (= 1 (length roots)) (first roots) (branch s roots)))
    (return planned {:summary (if (input :text)
      (merge (spec s node (v :invalid) c true) {:text (render s node)})
      (merge (need s node (v :invalid) c) {:manual true}))}))
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
  (def nodes (map |(representation s $ (v :invalid) c) roots))
  (while (> (model/estimate (map |($ :text) nodes)) budget)
    (def entry (find |(not ($ :summary)) nodes))
    (unless entry
      (assert (> (length nodes) 1) "minimum memory frontier exceeds budget")
      (def node (branch s (map |($ :node) (array/slice nodes 0 2))))
      (array/remove nodes 0 2) (array/insert nodes 0 @{:node node :text (render s node)}))
    (def chosen (or entry (first nodes)))
    (def summary (cached s (spec s (chosen :node) (v :invalid) c)))
    (unless summary (return planned {:summary (need s (chosen :node) (v :invalid) c)}))
    (put chosen :summary (summary :key)) (put chosen :text (get-in summary [:data :text])))
  (def covered @{})
  (each n nodes (unless (n :summary) (each page (pages s (n :node))
    (def d (page :data)) (put covered (d :source) (+ (get covered (d :source) 0) (- (d :end) (d :start)))))))
  (def eligible (filter |(< (get covered ($ :reference) 0) (length ($ :text))) (sources s v)))
  {:view (p :view) :base base :exchanges live :nodes nodes :room room :eligible (length eligible)
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
   :manifest {:view (plan :view) :nodes (plan :nodes) :eligible (plan :eligible) :retrieval decisions}})

(defn summarize [invoke request]
  (def plan (invoke "memory/plan" [request [] true]))
  (def spec (plan :summary))
  (def response (unless (request :text)
    (invoke "model/chat" [{:summary true :messages
      [{:role "system" :parts [{:type "text" :text summary-instructions}]} {:role "user" :parts [{:type "text" :text (spec :text)}]}]}])))
  (when response (assert (= "answer" (response :stop)) "summary generation did not finish"))
  (invoke "memory/save" [spec (or (request :text) (response :text))]))
(defn context [invoke input exchanges]
  (var plan (invoke "memory/plan" [input exchanges]))
  (while (plan :summary)
    (def spec (plan :summary))
    (def response (invoke "model/chat" [{:summary true :messages
      [{:role "system" :parts [{:type "text" :text summary-instructions}]} {:role "user" :parts [{:type "text" :text (spec :text)}]}]}]))
    (assert (= "answer" (response :stop)) "summary generation did not finish")
    (invoke "memory/save" [spec (response :text)])
    (set plan (invoke "memory/plan" [input exchanges])))
  (def ranks (if (> (length (plan :candidates)) 0)
    (invoke "model/rerank" [{:query (plan :query) :documents (map |($ :text) (plan :candidates))}]) []))
  (invoke "memory/finish" [plan ranks]))
