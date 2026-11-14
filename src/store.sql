CREATE TABLE ids(id INTEGER PRIMARY KEY) STRICT;
CREATE TABLE journal(
  sequence INTEGER PRIMARY KEY REFERENCES ids(id),
  token TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,
  data TEXT NOT NULL CHECK(json_valid(data)),
  image BLOB
) STRICT;
CREATE TABLE paths(id INTEGER PRIMARY KEY REFERENCES ids(id), head INTEGER REFERENCES journal(sequence)) STRICT;
CREATE TABLE worlds(name TEXT PRIMARY KEY, head INTEGER NOT NULL REFERENCES journal(sequence)) STRICT;
CREATE TABLE memory_nodes(
  id INTEGER PRIMARY KEY REFERENCES ids(id),
  source INTEGER REFERENCES journal(sequence),
  start INTEGER,
  end INTEGER,
  left INTEGER REFERENCES memory_nodes(id),
  right INTEGER REFERENCES memory_nodes(id),
  count INTEGER NOT NULL CHECK(count>0),
  CHECK((source IS NOT NULL AND start IS NOT NULL AND end IS NOT NULL AND start>=0 AND end>start AND left IS NULL AND right IS NULL AND count=1)
    OR (source IS NULL AND start IS NULL AND end IS NULL AND left IS NOT NULL AND right IS NOT NULL)),
  UNIQUE(source,start,end),
  UNIQUE(left,right)
) STRICT;
CREATE TABLE invalidations(
  point INTEGER NOT NULL REFERENCES journal(sequence),
  summary INTEGER NOT NULL REFERENCES journal(sequence),
  PRIMARY KEY(point,summary)
) WITHOUT ROWID, STRICT;
CREATE INDEX journal_path ON journal(kind,json_extract(data,'$.path'),sequence);
CREATE INDEX journal_owner ON journal(kind,json_extract(data,'$.owner'),sequence);
CREATE INDEX journal_output ON journal(json_extract(data,'$.output.id'),sequence) WHERE kind='output';
CREATE INDEX journal_summary ON journal(json_extract(data,'$.spec.node'),json_extract(data,'$.spec.recipe'),json_extract(data,'$.spec.invalid'),sequence) WHERE kind='summary';
PRAGMA user_version=1;
