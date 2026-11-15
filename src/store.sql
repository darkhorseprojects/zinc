CREATE TABLE journal(
  id INTEGER PRIMARY KEY,
  parent INTEGER REFERENCES journal(id),
  data TEXT NOT NULL CHECK(json_valid(data)),
  image BLOB
) STRICT;
CREATE TABLE heads(
  id INTEGER PRIMARY KEY,
  name TEXT UNIQUE,
  point INTEGER REFERENCES journal(id),
  run BLOB,
  CHECK(name IS NULL OR run IS NULL)
) STRICT;
CREATE INDEX journal_request ON journal(json_extract(data,'$.request'),id);
PRAGMA user_version=1;
