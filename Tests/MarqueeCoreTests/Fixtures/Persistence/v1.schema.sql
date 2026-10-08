CREATE INDEX blocklistEntry_infoHash ON blocklistEntry(infoHash) WHERE infoHash IS NOT NULL;

CREATE INDEX blocklistEntry_titleId ON blocklistEntry(titleId);

CREATE INDEX episode_absolute ON episode(titleId, absoluteNumber) WHERE absoluteNumber IS NOT NULL;

CREATE INDEX episode_airDate ON episode(airDate) WHERE monitored = 1;

CREATE INDEX episode_seasonId ON episode(seasonId);

CREATE INDEX grab_infoHash ON grab(infoHash) WHERE infoHash IS NOT NULL;

CREATE INDEX grab_titleId_createdAt ON grab(titleId, createdAt);

CREATE INDEX healthIssue_open ON healthIssue(severity) WHERE resolvedAt IS NULL;

CREATE INDEX historyEvent_entity ON historyEvent(entityType, entityId, occurredAt);

CREATE INDEX historyEvent_occurredAt ON historyEvent(occurredAt);

CREATE INDEX historyEvent_titleId ON historyEvent(titleId, occurredAt) WHERE titleId IS NOT NULL;

CREATE INDEX indexerTag_tagId ON indexerTag(tagId);

CREATE INDEX mediaFileEpisode_episodeId ON mediaFileEpisode(episodeId);

CREATE INDEX mediaFile_titleId ON mediaFile(titleId);

CREATE INDEX release_createdAt ON release(createdAt);

CREATE INDEX release_infoHash ON release(infoHash) WHERE infoHash IS NOT NULL;

CREATE INDEX release_titleId_score ON release(titleId, score);

CREATE INDEX streamSession_infoHash ON streamSession(infoHash);

CREATE INDEX streamSession_startedAt ON streamSession(startedAt);

CREATE INDEX subtitleTrack_mediaFileId ON subtitleTrack(mediaFileId) WHERE mediaFileId IS NOT NULL;

CREATE INDEX subtitleTrack_titleId ON subtitleTrack(titleId);

CREATE INDEX titleTag_tagId ON titleTag(tagId);

CREATE INDEX title_addedAt ON title(addedAt) WHERE deletedAt IS NULL;

CREATE INDEX title_deletedAt ON title(deletedAt) WHERE deletedAt IS NOT NULL;

CREATE INDEX title_kind_sortTitle ON title(kind, sortTitle) WHERE deletedAt IS NULL;

CREATE UNIQUE INDEX title_tmdb ON title(kind, tmdbId) WHERE tmdbId IS NOT NULL AND deletedAt IS NULL;

CREATE UNIQUE INDEX title_tvdb ON title(kind, tvdbId) WHERE tvdbId IS NOT NULL AND deletedAt IS NULL;

CREATE INDEX torrent_state ON torrent(state);

CREATE INDEX torrent_titleId ON torrent(titleId) WHERE titleId IS NOT NULL;

CREATE INDEX watchState_inProgress ON watchState(updatedAt) WHERE watched = 0;

CREATE INDEX watchState_titleId ON watchState(titleId);

CREATE TABLE blocklistEntry (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    episodeId BLOB REFERENCES episode(id) ON DELETE SET NULL,
    indexerId BLOB REFERENCES indexer(id) ON DELETE SET NULL,
    releaseTitle TEXT NOT NULL,
    infoHash TEXT,
    reason TEXT NOT NULL,
    createdAt DATETIME NOT NULL
);

CREATE TABLE customFormat (
    id BLOB PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    specs TEXT NOT NULL DEFAULT '[]',
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE delayProfile (
    id BLOB PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    sortOrder INTEGER NOT NULL DEFAULT 0,
    delayMinutes INTEGER NOT NULL DEFAULT 0,
    bypassIfHighestQuality BOOLEAN NOT NULL DEFAULT 1,
    bypassIfScoreAtLeast INTEGER,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE episode (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    seasonId BLOB NOT NULL REFERENCES season(id) ON DELETE CASCADE,
    seasonNumber INTEGER NOT NULL,
    episodeNumber INTEGER NOT NULL,
    absoluteNumber INTEGER,
    airDate DATETIME,
    monitored BOOLEAN NOT NULL DEFAULT 1,
    title TEXT,
    runtime INTEGER,
    tvdbId INTEGER,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL,
    UNIQUE (titleId, seasonNumber, episodeNumber)
);

CREATE TABLE grab (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    episodeId BLOB REFERENCES episode(id) ON DELETE SET NULL,
    releaseId BLOB REFERENCES release(id) ON DELETE SET NULL,
    releaseTitle TEXT NOT NULL,
    infoHash TEXT,
    origin TEXT NOT NULL,
    outcome TEXT NOT NULL,
    score INTEGER,
    reason TEXT NOT NULL DEFAULT '{}',
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE healthIssue (
    id BLOB PRIMARY KEY NOT NULL,
    code TEXT NOT NULL,
    severity TEXT NOT NULL,
    message TEXT NOT NULL,
    fixAction TEXT,
    entityId TEXT,
    resolvedAt DATETIME,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE historyEvent (
    id BLOB PRIMARY KEY NOT NULL,
    type TEXT NOT NULL,
    entityType TEXT NOT NULL,
    entityId TEXT,
    titleId BLOB REFERENCES title(id) ON DELETE SET NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    occurredAt DATETIME NOT NULL
);

CREATE TABLE indexer (
    id BLOB PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    implementation TEXT NOT NULL DEFAULT 'torznab',
    baseURL TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    priority INTEGER NOT NULL DEFAULT 25,
    minimumSeeders INTEGER NOT NULL DEFAULT 1,
    categories TEXT NOT NULL DEFAULT '[]',
    credentialRef TEXT,
    failureCount INTEGER NOT NULL DEFAULT 0,
    disabledUntil DATETIME,
    lastSuccessAt DATETIME,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE indexerTag (
    indexerId BLOB NOT NULL REFERENCES indexer(id) ON DELETE CASCADE,
    tagId BLOB NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (indexerId, tagId)
);

CREATE TABLE mediaFile (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    path TEXT NOT NULL UNIQUE,
    size INTEGER NOT NULL DEFAULT 0,
    qualityName TEXT,
    resolution INTEGER,
    source TEXT,
    videoCodec TEXT,
    audioCodec TEXT,
    releaseGroup TEXT,
    customFormatScore INTEGER,
    mediaInfo TEXT,
    importedAt DATETIME NOT NULL,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE mediaFileEpisode (
    mediaFileId BLOB NOT NULL REFERENCES mediaFile(id) ON DELETE CASCADE,
    episodeId BLOB NOT NULL REFERENCES episode(id) ON DELETE CASCADE,
    PRIMARY KEY (mediaFileId, episodeId)
);

CREATE TABLE packFileMapping (
    infoHash TEXT NOT NULL,
    fileIndex INTEGER NOT NULL,
    path TEXT NOT NULL,
    size INTEGER NOT NULL DEFAULT 0,
    role TEXT NOT NULL DEFAULT 'episode',
    episodeIds TEXT NOT NULL DEFAULT '[]',
    userCorrected BOOLEAN NOT NULL DEFAULT 0,
    confidence REAL,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL,
    PRIMARY KEY (infoHash, fileIndex)
);

CREATE TABLE qualityProfile (
    id BLOB PRIMARY KEY NOT NULL,
    name TEXT NOT NULL UNIQUE,
    items TEXT NOT NULL DEFAULT '[]',
    cutoff TEXT,
    upgradeAllowed BOOLEAN NOT NULL DEFAULT 1,
    minFormatScore INTEGER NOT NULL DEFAULT 0,
    cutoffFormatScore INTEGER NOT NULL DEFAULT 0,
    formatScores TEXT NOT NULL DEFAULT '{}',
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE release (
    id BLOB PRIMARY KEY NOT NULL,
    indexerId BLOB REFERENCES indexer(id) ON DELETE SET NULL,
    titleId BLOB REFERENCES title(id) ON DELETE CASCADE,
    guid TEXT NOT NULL,
    title TEXT NOT NULL,
    infoHash TEXT,
    downloadURL TEXT,
    size INTEGER NOT NULL DEFAULT 0,
    seeders INTEGER,
    leechers INTEGER,
    publishedAt DATETIME,
    resolution INTEGER,
    source TEXT,
    releaseGroup TEXT,
    seasonNumber INTEGER,
    isSeasonPack BOOLEAN NOT NULL DEFAULT 0,
    score INTEGER,
    parsed TEXT NOT NULL DEFAULT '{}',
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL,
    UNIQUE (indexerId, guid)
);

CREATE TABLE rootFolder (
    id BLOB PRIMARY KEY NOT NULL,
    path TEXT NOT NULL UNIQUE,
    mediaKind TEXT,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE season (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    seasonNumber INTEGER NOT NULL,
    monitored BOOLEAN NOT NULL DEFAULT 1,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL,
    UNIQUE (titleId, seasonNumber)
);

CREATE TABLE streamSession (
    id BLOB PRIMARY KEY NOT NULL,
    infoHash TEXT NOT NULL REFERENCES torrent(infoHash) ON DELETE CASCADE,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    episodeId BLOB REFERENCES episode(id) ON DELETE SET NULL,
    fileIndex INTEGER NOT NULL,
    state TEXT NOT NULL,
    startedAt DATETIME NOT NULL,
    endedAt DATETIME,
    firstFrameMs INTEGER,
    stallCount INTEGER NOT NULL DEFAULT 0,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE subtitleTrack (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    episodeId BLOB REFERENCES episode(id) ON DELETE CASCADE,
    mediaFileId BLOB REFERENCES mediaFile(id) ON DELETE CASCADE,
    language TEXT NOT NULL,
    format TEXT NOT NULL,
    origin TEXT NOT NULL,
    provider TEXT,
    path TEXT,
    embeddedIndex INTEGER,
    isForced BOOLEAN NOT NULL DEFAULT 0,
    isHearingImpaired BOOLEAN NOT NULL DEFAULT 0,
    score INTEGER,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE tag (
    id BLOB PRIMARY KEY NOT NULL,
    label TEXT NOT NULL UNIQUE COLLATE NOCASE,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE title (
    id BLOB PRIMARY KEY NOT NULL,
    kind TEXT NOT NULL,
    tmdbId INTEGER,
    tvdbId INTEGER,
    imdbId TEXT,
    title TEXT NOT NULL,
    sortTitle TEXT NOT NULL,
    year INTEGER,
    overview TEXT,
    status TEXT,
    monitored BOOLEAN NOT NULL DEFAULT 1,
    monitorMode TEXT NOT NULL DEFAULT 'all',
    minimumAvailability TEXT,
    qualityProfileId BLOB REFERENCES qualityProfile(id) ON DELETE SET NULL,
    rootFolderId BLOB REFERENCES rootFolder(id) ON DELETE SET NULL,
    path TEXT,
    seriesType TEXT,
    addedAt DATETIME NOT NULL,
    posterPath TEXT,
    backdropPath TEXT,
    deletedAt DATETIME,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE VIRTUAL TABLE titleSearch USING fts5(
    titleId UNINDEXED, title, sortTitle, overview,
    tokenize = 'unicode61 remove_diacritics 2', prefix = '2 3'
);

CREATE TABLE 'titleSearch_config'(k PRIMARY KEY, v) WITHOUT ROWID;

CREATE TABLE 'titleSearch_content'(id INTEGER PRIMARY KEY, c0, c1, c2, c3);

CREATE TABLE 'titleSearch_data'(id INTEGER PRIMARY KEY, block BLOB);

CREATE TABLE 'titleSearch_docsize'(id INTEGER PRIMARY KEY, sz BLOB);

CREATE TABLE 'titleSearch_idx'(segid, term, pgno, PRIMARY KEY(segid, term)) WITHOUT ROWID;

CREATE TABLE titleTag (
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    tagId BLOB NOT NULL REFERENCES tag(id) ON DELETE CASCADE,
    PRIMARY KEY (titleId, tagId)
);

CREATE TABLE torrent (
    infoHash TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    state TEXT NOT NULL,
    savePath TEXT NOT NULL,
    size INTEGER,
    progress REAL NOT NULL DEFAULT 0,
    titleId BLOB REFERENCES title(id) ON DELETE SET NULL,
    isStreaming BOOLEAN NOT NULL DEFAULT 0,
    keepAfterStream BOOLEAN NOT NULL DEFAULT 1,
    lastError TEXT,
    addedAt DATETIME NOT NULL,
    completedAt DATETIME,
    createdAt DATETIME NOT NULL,
    updatedAt DATETIME NOT NULL
);

CREATE TABLE watchState (
    id BLOB PRIMARY KEY NOT NULL,
    titleId BLOB NOT NULL REFERENCES title(id) ON DELETE CASCADE,
    positionSeconds REAL NOT NULL DEFAULT 0,
    durationSeconds REAL,
    watched BOOLEAN NOT NULL DEFAULT 0,
    updatedAt DATETIME NOT NULL
);

CREATE TRIGGER title_search_delete AFTER DELETE ON title BEGIN
    DELETE FROM titleSearch WHERE titleId = old.id;
END;

CREATE TRIGGER title_search_insert AFTER INSERT ON title BEGIN
    INSERT INTO titleSearch(titleId, title, sortTitle, overview)
    VALUES (new.id, new.title, new.sortTitle, COALESCE(new.overview, ''));
END;

CREATE TRIGGER title_search_update AFTER UPDATE OF title, sortTitle, overview ON title
WHEN old.title IS NOT new.title OR old.sortTitle IS NOT new.sortTitle OR old.overview IS NOT new.overview BEGIN
    DELETE FROM titleSearch WHERE titleId = old.id;
    INSERT INTO titleSearch(titleId, title, sortTitle, overview)
    VALUES (new.id, new.title, new.sortTitle, COALESCE(new.overview, ''));
END;
