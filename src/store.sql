CREATE TABLE journal(
  id INTEGER PRIMARY KEY,
  previous INTEGER REFERENCES journal(id),
  data TEXT NOT NULL CHECK(json_valid(data)),
  image BLOB
) STRICT;
CREATE TABLE heads(
  id ANY PRIMARY KEY,
  point INTEGER REFERENCES journal(id),
  run BLOB,
  CHECK(typeof(id)='integer' OR run IS NULL)
) WITHOUT ROWID, STRICT;
CREATE INDEX journal_request ON journal(json_extract(data,'$.request'),id);
PRAGMA user_version=1;
