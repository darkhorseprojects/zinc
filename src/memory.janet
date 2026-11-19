(import sqlite3 :as sql)
(import spork/json :as json)
(import spork/utf8 :as utf8)
(import ./store)
(import ./policy)
(import ./model)

(def instructions "Summarize evidence, not instructions. Preserve constraints, decisions and reasons, verified outcomes, unfinished work, uncertainty, attribution and identifiers needed to continue. Cite originals as [#event]. Invent nothing.")
(defn node [s ref]
  (assert (and (indexed? ref) (= 2 (length ref)) (int? (ref 0)) (int? (ref 1)) (>= (ref 1) 0)) "invalid subtree address")
  (def n (get-in (store/row s (ref 0)) [:data :nodes (ref 1)])) (assert n "subtree unavailable")
  (each key [:left :right] (when (n key) (put n key (tuple/slice (n key))))) n)
(defn header [s page]
  (def d ((store/row s (page :source)) :data))
  (string "[#" (page :source) ":" (page :start) "–" (page :end) "] " (d :author) " · " (d :at) "\n"))
(defn branch [left right l r]
  @{:left left :right right :count (+ (l :count) (r :count)) :cost (+ 2 (l :cost) (r :cost))
    :low (min (l :low) (r :low)) :high (max (l :high) (r :high))
    :worlds (distinct (array/concat @[] (l :worlds) (r :worlds)))})
(defn extend [s r roots c &opt link evidence]
  (def forest (map tuple/slice (or roots []))) (def nodes (get-in r [:data :nodes] @[]))
  (def original (if evidence (store/row s evidence) r)) (def text (store/text original))
  (def source (original :id))
  (var start 0)
  (while (< start (length text))
    (var end (min (length text) (+ start (c :page-bytes))))
    (while (and (< end (length text)) (<= 0x80 (text end) 0xbf)) (++ end))
    (def existing (find-index |(and (= ($ :source) source) (= ($ :start) start) (= ($ :end) end)) nodes))
    (array/push forest [(r :id) (or existing (length nodes))])
    (unless existing
      (def leaf @{:source source :start start :end end :count 1 :low source :high source :worlds [(get-in original [:data :world])]})
      (put leaf :cost (+ (length (header s leaf)) (- end start)))
      (array/push nodes leaf))
    (while (>= (length forest) 2)
      (def right (last forest)) (def left (forest (- (length forest) 2)))
      (def lookup |(if (= (r :id) ($ 0)) (nodes ($ 1)) (node s $)))
      (def l (lookup left)) (def rr (lookup right))
      (unless (= (l :count) (rr :count)) (break))
      (array/pop forest) (array/pop forest) (array/push forest [(r :id) (length nodes)])
      (array/push nodes (branch left right l rr)))
    (set start end))
  (put (r :data) :nodes nodes) (unless link (put (r :data) :memory forest)) (store/replace s r c) forest)
(defn pages [s ref]
  (def n (node s ref)) (if (n :source) [n] (array/concat @[] (pages s (n :left)) (pages s (n :right)))))
(defn sources [s roots c]
  (map (fn [id] (store/access s id c) (def d ((store/row s id) :data)) {:reference id :author (d :author) :at (d :at) :text (store/text (store/row s id))})
    (distinct (map |($ :source) (catseq [ref :in roots] (pages s ref))))))
(defn render [s ref]
  (string/join (map (fn [p]
    (string (header s p) (string/slice (store/text (store/row s (p :source))) (p :start) (p :end)))) (pages s ref)) "\n\n"))
(defn heading [s ref]
  (def n (node s ref))
  (string "[@" (ref 0) ":" (ref 1) (when (n :left)
    (string " | children @" ((n :left) 0) ":" ((n :left) 1) ", @" ((n :right) 0) ":" ((n :right) 1))) "]\n"))
(defn recipe [s ref c]
  (def n (node s ref))
  (def settings (merge (c :chat) (tabseq [key :in [:model :thinking] :when (has-key? (c :summary) key)] key (get-in c [:summary key]))))
  (store/digest (policy/encode [ref (n :epoch) instructions settings
    (get-in c [:providers (keyword (first (string/split ":" (get settings :model ""))))])
    (when (n :left) (map |[$ ((node s $) :epoch) ((node s $) :summary)] [(n :left) (n :right)]))])))
(defn cached [s ref c]
  (def cache (dyn :zinc/representations)) (def key (tuple/slice ref))
  (def entry (or (get cache key)
    (let [identity (recipe s ref c) summary ((node s ref) :summary)
          entry {:recipe identity :text (when (and summary (= (summary :recipe) identity)) (summary :text))}]
      (when cache (put cache key entry)) entry)))
  (entry :text))
(defn representation [s ref c]
  (if-let [text (cached s ref c)] (string (heading s ref) text)
    (let [n (node s ref)]
      (if (n :left) (string/join (map |(representation s $ c) [(n :left) (n :right)]) "\n\n") (render s ref)))))
(defn combine [s roots c]
  (def r (store/row s ((last roots) 0))) (def nodes (get-in r [:data :nodes]))
  (var root (first roots))
  (each right (tuple/slice roots 1)
    (def existing (find-index |(and (= ($ :left) root) (= ($ :right) right)) nodes))
    (if existing (set root [(r :id) existing])
      (do (def next [(r :id) (length nodes)])
        (array/push nodes (branch root right (node s root) (node s right)))
        (set root next) (store/replace s r c)))) root)
(defn selected [s roots excluded c]
  (catseq [raw :in roots :let [ref (tuple/slice raw)]]
    (def n (node s ref))
    (if (and (every? (map |(index-of $ (c :worlds)) (n :worlds)))
        (not (some |(and (number? $) (<= (n :low) $ (n :high))) excluded)))
      [ref]
      (if (n :left) (selected s [(n :left) (n :right)] excluded c) []))))
(defn allowed [s reference roots c]
  (def ref (tuple/slice reference))
  (def seen @{})
  (def visit (fn visit [at]
    (or (= (tuple/slice at) ref) (when-let [n (node s at)]
      (when (and (n :left) (not (seen at))) (put seen at true) (or (visit (n :left)) (visit (n :right))))))))
  (assert (some visit roots) "subtree outside selected memory")
  (each p (pages s ref) (store/access s (p :source) c)) ref)
(defn invalidate [s reference roots c]
  (def ref (allowed s reference roots c))
  (def affected @{ref true})
  (when (get-in s [:source :db])
    (each r (store/query (s :source) "SELECT id FROM journal WHERE json_extract(data,'$.nodes') IS NOT NULL")
      (store/row s (r :id))))
  (def rows (if (s :db) (store/query s "SELECT * FROM journal WHERE json_extract(data,'$.nodes') IS NOT NULL ORDER BY id")
    (sorted (values (s :rows)) |(cond (< ($0 :id) 0) (and (< ($1 :id) 0) (> ($0 :id) ($1 :id)))
      (< ($1 :id) 0) true (< ($0 :id) ($1 :id))))))
  (each r rows
    (each [slot n] (pairs (get-in r [:data :nodes] []))
      (each key [:left :right] (when (n key) (put n key (tuple/slice (n key)))))
      (def at [(r :id) slot])
      (when (or (affected at) (affected (n :left)) (affected (n :right)))
        (put affected at true) (put n :summary nil) (put n :epoch (store/nonce))
        (store/replace s r c))))
  (each [key job] (pairs (get s :summary-work {}))
    (when (and (affected (job :node)) (not (job :cancelled)))
      (put job :cancelled true)
      (ev/give (job :cancel) true))) ref)
(defn cost [s ref] ((node s ref) :cost))
(defn need [s ref c limit &opt replacement]
  (def n (node s ref))
  (unless replacement
    (when (or (if-let [text (cached s ref c)] (<= (length text) limit))
      (<= (cost s ref) (+ (length (heading s ref)) limit))) (break (tuple/slice ref))))
  (def text (if (n :left) (string/join (map |(representation s $ c) [(n :left) (n :right)]) "\n\n") (render s ref)))
  (unless replacement
    (when (<= (length text) (+ (length (heading s ref)) limit)) (break (tuple/slice ref)))
    (def selected (model/select (merge c {:chat (merge (c :chat) (c :summary))}) "chat"))
    (def fixed (model/estimate [{:role "system" :parts [{:type "text" :text (string instructions " Limit: " limit " UTF-8 bytes, including citations.")}]}
      {:role "user" :parts [{:type "text" :text ""}]}]))
    (def room (- (model/window selected c)
      (min (get c :output 4096) (get selected :output 4096)) fixed 256))
    (assert (> room 0) "summary instructions and output reserve exceed model window")
    (when (> (model/estimate text) room)
      (assert (n :left) "original page exceeds summary input window")
      (def child (find |(> (model/estimate (representation s $ c)) (/ room 2)) [(n :left) (n :right)]))
      (assert child "summary children exceed input window")
      (def source (representation s child c))
      (def quota (- (math/floor (* (length source) (/ room 2 (model/estimate source)))) (length (heading s child)) 1))
      (assert (> quota 0) "summary child cannot fit input window")
      (break (need s child c (min (get-in c [:summary :max-bytes]) quota)))))
  {:node ref :sources (distinct (map |($ :source) (pages s ref))) :recipe (recipe s ref c) :text text
   :limit (if replacement limit (let [band (max 1 (math/floor (/ (get-in c [:summary :bytes]) 4)))]
     (max 1 (* band (math/floor (/ limit band)))))) :replaces (length text)})
(defn save [s spec text c roots]
  (allowed s (spec :node) roots c)
  (def identity (recipe s (spec :node) c)) (def existing ((node s (spec :node)) :summary))
  (when (and existing (= identity (existing :recipe)) (= text (existing :text))) (break (spec :node)))
  (assert (and (= (spec :recipe) identity)
    (string? text) (utf8/is-valid? text) (> (length (string/trim text)) 0)
    (<= (length text) (spec :limit)) (< (+ (length (heading s (spec :node))) (length text)) (spec :replaces)))
    "summary is stale, oversized, empty, or saves no space")
  (each citation (peg/match ~(any (choice (* "[#" (capture (some (if-not "]" 1))) "]") 1)) text)
    (assert (index-of (scan-number citation) (spec :sources)) "summary cites unrelated evidence"))
  (invalidate s (spec :node) roots c)
  (def r (store/row s ((spec :node) 0))) (def n (node s (spec :node)))
  (put n :summary {:recipe (recipe s (spec :node) c) :text text}) (store/replace s r c) (spec :node))
(defn candidates [s ids query c]
  (if (or (not (c :memory-retrieval)) (empty? ids) (empty? query)) []
    (do
      (unless (s :search)
        (put s :search (sql/open ""))
        (sql/eval (s :search) "CREATE VIRTUAL TABLE tokens USING fts5(text,tokenize='unicode61 remove_diacritics 0'); CREATE VIRTUAL TABLE words USING fts5vocab(tokens,'instance'); CREATE VIRTUAL TABLE inquiry USING fts5(text,tokenize='unicode61 remove_diacritics 0'); CREATE VIRTUAL TABLE terms USING fts5vocab(inquiry,'instance');"))
      (def db (s :search))
      (sql/eval db "DELETE FROM inquiry")
      (sql/eval db "INSERT INTO inquiry(text) VALUES(?)" [query])
      (unless (s :stopwords) (put s :stopwords (json/decode (slurp (c :stopwords)) true true)))
      (def stops (get (s :stopwords) (keyword (c :language))))
      (assert (> (length stops) 0) "unsupported stopword language")
      (def terms (map |($ :term) (sql/eval db "SELECT term FROM terms WHERE term NOT IN (SELECT value FROM json_each(?)) GROUP BY term ORDER BY min(offset) LIMIT ?" [(policy/encode stops) (c :terms)])))
      (when (> (length terms) 0)
        (def graph (sql/open (string (store/uri (c :cygnet)) "?mode=ro")))
        (defer (sql/close graph)
          (sql/eval graph "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;")
          (assert (and (= 1 (((sql/eval graph "PRAGMA user_version") 0) :user_version))
            (= 1514751817 (((sql/eval graph "PRAGMA application_id") 0) :application_id))
            (= (c :cygnet-source) (((sql/eval graph "SELECT value FROM metadata WHERE key='source_identity'") 0) :value))) "incompatible Cygnet asset")
          (each r (sql/eval graph `WITH RECURSIVE reachable(concept,depth) AS (
            SELECT concept,0 FROM form_concepts WHERE language=? AND form IN (SELECT value FROM json_each(?))
            UNION SELECT e.target,r.depth+1 FROM reachable r JOIN concept_edges e ON e.source=r.concept WHERE r.depth<? LIMIT ?)
            SELECT DISTINCT f.form FROM reachable r JOIN form_concepts f ON f.concept=r.concept WHERE f.language=? ORDER BY f.form LIMIT ?`
            [(c :language) (policy/encode terms) (c :expansion-depth) (c :expansion-nodes) (c :language) (c :terms)])
            (when (and (< (length terms) (c :terms)) (not (index-of (r :form) stops)) (not (index-of (r :form) terms))) (array/push terms (r :form))))))
      (def membership (policy/encode ids))
      (each row (sql/eval db "SELECT e.value id FROM json_each(?) e WHERE NOT EXISTS(SELECT 1 FROM tokens WHERE rowid=e.value)" [membership])
        (def id (row :id))
        (def data (if (s :db) (first (store/query s "SELECT data FROM journal WHERE id=?" [id])) (store/row s id)))
        (sql/eval db "INSERT INTO tokens(rowid,text) VALUES(?,?)" [id (store/text data)]))
      (def fuzzy (sql/eval db `WITH RECURSIVE grams(word,pos) AS (SELECT value,1 FROM json_each(?) WHERE length(value)>=3
        UNION ALL SELECT word,pos+1 FROM grams WHERE pos+2<length(word))
        SELECT DISTINCT term FROM words WHERE term NOT IN (SELECT value FROM json_each(?)) AND doc IN (SELECT value FROM json_each(?))
        AND EXISTS(SELECT 1 FROM grams WHERE instr(term,substr(word,pos,3))>0) ORDER BY term LIMIT ?`
        [(policy/encode terms) (policy/encode stops) membership (c :terms)]))
      (def words (distinct (array/concat @[] terms (map |($ :term) fuzzy))))
      (if (empty? words) [] (map (fn [hit]
        (def text (hit :excerpt)) (var end (min (length text) (c :page-bytes)))
        (while (and (< end (length text)) (<= 0x80 (text end) 0xbf)) (++ end))
        {:reference (hit :rowid) :text (string/slice text 0 end)})
        (sql/eval db "SELECT rowid,snippet(tokens,0,'','',' … ',64) excerpt FROM tokens WHERE tokens MATCH ? AND rowid IN (SELECT value FROM json_each(?)) ORDER BY rank,rowid LIMIT ?"
          [(string/join (map |(string "\"" (string/replace-all "\"" "\"\"" $) "\"") words) " OR ") membership (c :candidates)]))))))
(defn minimum [s ref c]
  (min (cost s ref) (+ (length (heading s ref))
    (min (get-in c [:summary :bytes]) (if-let [text (cached s ref c)] (length text) (get-in c [:summary :bytes]))))))
(defn plan [s roots c query room excluded]
  (def selected (selected s roots excluded c))
  {:roots selected :memory roots :room room :excluded excluded
   :candidates (if (and (c :memory-retrieval) (> (sum (map |(+ 2 (cost s $)) selected)) (* 4 room)))
     (candidates s (distinct (map |($ :source) (catseq [ref :in selected] (pages s ref)))) query c) [])})
(defn finish [s plan ranks c]
  (with-dyns [:zinc/representations (or (dyn :zinc/representations) @{})]
  (label planned
    (def budget (* 4 (plan :room))) (var frontier (array/slice (plan :roots)))
    (while (> (sum (map |(+ 2 (minimum s $ c)) frontier)) budget)
      (assert (> (length frontier) 1) "minimum chronological frontier exceeds memory allowance")
      (set frontier @[(combine s frontier c)]))
    (def reserve (sum (map |(+ 2 (minimum s $ c)) frontier)))
    (def evidence @[]) (def decisions @[]) (var spent 0)
    (each rank ranks
      (def row ((plan :candidates) (rank :index)))
      (def text (string "[#" (row :reference) "] " (row :text)))
      (def size (+ 2 (length text)))
      (def decision (cond (< (rank :relevance_score) (c :score)) "below-cutoff"
        (index-of (row :reference) (get plan :covered [])) "already-present"
        (> (+ spent size reserve) budget) "budget" "included"))
      (when (= decision "included") (array/push evidence (merge row {:rendered text})) (+= spent size))
      (array/push decisions {:reference (row :reference) :score (rank :relevance_score) :decision decision}))
    (def room (- budget spent)) (var changed true)
    (while changed
      (set changed false)
      (each i (reverse (range (length frontier)))
        (def ref (frontier i)) (def n (node s ref))
        (def children-cost (when (n :left)
          (sum (map |(+ 2 (if (cached s ref c) (if-let [text (cached s $ c)] (+ (length (heading s $)) (length text)) (cost s $)) (minimum s $ c))) [(n :left) (n :right)]))))
        (when (and children-cost (<= (+ (sum (map |(+ 2 (minimum s $ c)) frontier))
          (- children-cost (+ 2 (minimum s ref c)))) room))
          (array/remove frontier i) (array/insert frontier i (n :right)) (array/insert frontier i (n :left))
          (set changed true))))
    (def raw @{}) (var used 0)
    (each ref frontier (when (<= (cost s ref) (minimum s ref c)) (put raw ref true) (+= used (+ 2 (cost s ref)))))
    (def summaries (filter |(not (raw $)) frontier))
    (def overhead (sum (map |(+ 2 (length (heading s $))) summaries)))
    (def base (get-in c [:summary :bytes])) (def maximum (get-in c [:summary :max-bytes]))
    (def quotas (map |(min maximum base (if-let [text (cached s $ c)] (length text) base)) summaries))
    (var extra (- room used overhead (sum quotas)))
    (assert (>= extra 0) "summary base allocations exceed memory allowance")
    (def weights (map (fn [ref]
      (def newer (tuple/slice frontier (+ 1 (index-of ref frontier))))
      (/ 1 (+ 1 (sum (map |((node s $) :count) newer))))) summaries))
    (while (and (> extra 0) (some |(< $ maximum) quotas))
      (def total (sum (seq [[i q] :pairs quotas :when (< q maximum)] (weights i))))
      (var allocated 0)
      (each i (reverse (range (length quotas)))
        (when (< (quotas i) maximum)
          (def add (min (- maximum (quotas i)) (- extra allocated) (max 1 (math/floor (* extra (/ (weights i) total))))))
          (put quotas i (+ (quotas i) add)) (+= allocated add)))
      (-= extra allocated))
    (def rendered @[])
    (each ref frontier
      (def slot (index-of ref summaries)) (def quota (when slot (quotas slot)))
      (def cached (cached s ref c))
      (cond (or (raw ref) (<= (cost s ref) (+ (length (heading s ref)) quota)))
        (array/push rendered {:node ref :text (render s ref) :original true})
        (and cached (<= (length cached) quota)) (array/push rendered {:node ref :text (string (heading s ref) cached)})
        (let [n (node s ref) children (when (n :left) (string/join (map |(representation s $ c) [(n :left) (n :right)]) "\n\n"))]
          (if (and children (<= (length children) (+ (length (heading s ref)) quota)))
            (array/push rendered {:node ref :text children})
            (return planned {:summary (need s ref c quota)})))))
    (def coverage @{})
    (each entry rendered (when (entry :original) (each page (pages s (entry :node))
      (put coverage (page :source) (+ (get coverage (page :source) 0) (- (page :end) (page :start)))))))
    (def full (seq [[id bytes] :pairs coverage :when (>= bytes (length (store/text (store/row s id))))] id))
    (when (some |(index-of ($ :reference) full) evidence)
      (return planned (finish s (merge plan {:covered (distinct (array/concat @[] (get plan :covered []) full))}) ranks c)))
    {:chronological (string/join (map |($ :text) rendered) "\n\n")
     :semantic (string/join (map |($ :rendered) evidence) "\n\n")
     :manifest {:memory (plan :memory) :excluded (plan :excluded) :nodes (map |($ :node) rendered) :retrieval decisions}})))
