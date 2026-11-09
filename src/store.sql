CREATE TABLE images(
  hash TEXT PRIMARY KEY,
  bytes BLOB NOT NULL
) STRICT;
CREATE TABLE events(
  id INTEGER PRIMARY KEY AUTOINCREMENT CHECK(id<=9007199254740991),
  parent INTEGER REFERENCES events(id),
  key TEXT UNIQUE,
  kind TEXT NOT NULL,
  data TEXT NOT NULL CHECK(json_valid(data)),
  text TEXT GENERATED ALWAYS AS (coalesce(json_extract(data,'$.text'),json_extract(data,'$.input.text'),json_extract(data,'$.input.code'),json_extract(data,'$.input.stages'))) VIRTUAL,
  image TEXT REFERENCES images(hash),
  created REAL NOT NULL DEFAULT(unixepoch('subsec'))
) STRICT;
CREATE INDEX event_parent ON events(parent,kind,id);
CREATE INDEX event_image ON events(image) WHERE image IS NOT NULL;
CREATE UNIQUE INDEX event_result ON events(parent) WHERE kind='result';
CREATE UNIQUE INDEX event_dispatch ON events(parent) WHERE kind='dispatch';
CREATE TABLE claims(
  task INTEGER PRIMARY KEY REFERENCES events(id),
  token TEXT,
  expires REAL NOT NULL DEFAULT 0,
  data TEXT NOT NULL DEFAULT '{}' CHECK(json_valid(data))
) STRICT;
CREATE TABLE worlds(
  name TEXT PRIMARY KEY,
  head INTEGER NOT NULL REFERENCES events(id),
  epoch INTEGER NOT NULL DEFAULT 0
) STRICT;
PRAGMA user_version=1;
