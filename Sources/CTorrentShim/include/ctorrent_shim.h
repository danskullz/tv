/*
 * ctorrent_shim.h - a small, pure-C facade over libtorrent-rasterbar 2.0.
 *
 * Why C and not Swift C++ interop: the API surface is small, libtorrent's headers (Boost.Asio,
 * templates, std::function) are hostile to the Swift importer and would force
 * `-cxx-interoperability-mode` on every module that imports us. A C header keeps the Swift side
 * trivially importable, keeps libtorrent/Boost headers out of every Swift compile, and the same
 * API can sit behind XPC in the helper later.
 *
 * Conventions
 *  - A torrent is identified by its info-hash as a 40-character lowercase hex string (the v1 hash,
 *    or the truncated v2 hash for v2-only torrents).
 *  - Functions returning int return 0 (MQ_OK) or a negative MQ_ERR_* code. Functions with a
 *    `char **error` parameter store a malloc'd message there on failure (free with mq_free).
 *  - All functions are thread-safe. Strings/buffers returned through out-parameters are malloc'd
 *    and owned by the caller (free with mq_free / the matching *_free function).
 *  - Events are delivered on ONE dedicated thread owned by the session, woken by libtorrent's
 *    alert notification (no polling timers). Pointers inside an mq_event are valid only for the
 *    duration of the callback; copy what you need. The callback must not call mq_session_destroy.
 */
#ifndef CTORRENT_SHIM_H
#define CTORRENT_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct mq_session mq_session;

enum {
  MQ_OK = 0,
  MQ_ERR_NOT_FOUND = -1,    /* unknown torrent id */
  MQ_ERR_INVALID = -2,      /* bad argument */
  MQ_ERR_NO_METADATA = -3,  /* torrent metadata (info dictionary) not available yet */
  MQ_ERR_LIBTORRENT = -4,   /* libtorrent reported an error; see the error message */
  MQ_ERR_DUPLICATE = -5     /* the info-hash is already in the session and is being removed */
};

/* Why a torrent left the engine.
 *
 * libtorrent 2.0 no longer tells us: torrent_removed_alert carried a reason enum (explicit_remove,
 * duplicate_torrent, ratio_limit_reached, ...) up to 1.2, but 2.0 replaced it with just the info
 * hashes and the client data set at add time. The one distinction that matters is still available
 * to us, because every removal Marquee performs goes through this shim: did we ask for it? */
typedef enum {
  MQ_REMOVED_BY_ENGINE = 0,       /* nothing asked for it: libtorrent dropped it on its own */
  MQ_REMOVED_BY_SHIM,             /* mq_torrent_remove was called */
  MQ_REMOVED_BY_SHIM_DELETING     /* ... with delete_files */
} mq_remove_reason;

/* ---- events ---------------------------------------------------------------------------- */

typedef enum {
  MQ_EVENT_LISTEN_SUCCEEDED = 1, /* value = port, message = local address */
  MQ_EVENT_LISTEN_FAILED,        /* value = port, message = error text */
  MQ_EVENT_TORRENT_REMOVED,      /* value = mq_remove_reason */
  MQ_EVENT_METADATA_RECEIVED,
  MQ_EVENT_METADATA_FAILED,      /* message = error text */
  MQ_EVENT_TORRENT_CHECKED,      /* initial file check finished */
  MQ_EVENT_STATE_CHANGED,        /* value = mq_torrent_state */
  MQ_EVENT_PIECE_FINISHED,       /* piece = index of a piece that was downloaded and verified */
  MQ_EVENT_HASH_FAILED,          /* piece */
  MQ_EVENT_FILE_COMPLETED,       /* value = file index */
  MQ_EVENT_TORRENT_FINISHED,     /* every wanted piece is done */
  MQ_EVENT_TORRENT_PAUSED,
  MQ_EVENT_TORRENT_RESUMED,
  MQ_EVENT_TORRENT_ERROR,        /* message = error text */
  MQ_EVENT_FILE_ERROR,           /* value = file index, message = error text */
  MQ_EVENT_PIECE_READ,           /* piece, data/data_len = piece contents (mq_torrent_read_piece) */
  MQ_EVENT_PIECE_READ_FAILED,    /* piece, message */
  MQ_EVENT_RESUME_DATA,          /* data/data_len = bencoded resume data */
  MQ_EVENT_RESUME_DATA_FAILED    /* message */
} mq_event_type;

typedef struct {
  int32_t type;                /* mq_event_type */
  const char *torrent_id;      /* NULL for session-level events */
  int32_t piece;               /* -1 when not applicable */
  int32_t value;
  /* LISTEN_*: socket kind, 0 = TCP, 1 = UDP (uTP/DHT), 2 = TLS, 3 = other. Otherwise 0. */
  int32_t flags;
  const char *message;         /* NULL when not applicable */
  const uint8_t *data;         /* NULL when not applicable */
  size_t data_len;
} mq_event;

typedef void (*mq_event_fn)(void *context, const mq_event *event);

/* ---- session --------------------------------------------------------------------------- */

typedef struct {
  /* libtorrent `listen_interfaces` syntax, e.g. "0.0.0.0:6881,[::]:6881" or "127.0.0.1:0".
     NULL keeps libtorrent's default. */
  const char *listen_interfaces;
  /* Comma-separated device names or IPs outgoing connections are bound to (VPN binding).
     NULL/empty = no binding. */
  const char *outgoing_interfaces;
  /* NULL keeps the default user agent. */
  const char *user_agent;
  int32_t enable_dht;
  int32_t enable_lsd;
  int32_t enable_upnp;
  int32_t enable_natpmp;
  /* 0 = prefer encrypted, accept plaintext; 1 = require encryption; 2 = disable encryption. */
  int32_t encryption_mode;
} mq_session_config;

/* Creates a session and starts the event thread. Returns NULL (and sets *error) on failure. */
mq_session *mq_session_create(const mq_session_config *config, mq_event_fn callback,
                              void *context, char **error);

/* Stops the event thread (no more callbacks after this returns) and shuts the session down,
   blocking until libtorrent has finished (can take a couple of seconds). */
void mq_session_destroy(mq_session *session);

/* Generic libtorrent settings_pack access by name (e.g. "allow_multiple_connections_per_ip",
   "connections_limit", "download_rate_limit"). Returns MQ_ERR_INVALID for unknown names. */
int mq_session_set_bool(mq_session *s, const char *name, int32_t value);
int mq_session_set_int(mq_session *s, const char *name, int32_t value);
int mq_session_set_string(mq_session *s, const char *name, const char *value);

/* ---- adding torrents ------------------------------------------------------------------- */

enum {
  MQ_ADD_PAUSED = 1 << 0,
  /* Start in "upload mode": peers, metadata and trackers work but no pieces are requested, so
     file priorities can be set before any data is downloaded. Release with
     mq_torrent_start_download. */
  MQ_ADD_HOLD_DOWNLOAD = 1 << 1,
  MQ_ADD_SEQUENTIAL = 1 << 2
};

/* On success writes the 40-char id (+ NUL) into id_out, which must hold 41 bytes. For
   mq_session_add_torrent_data and mq_session_add_resume_data, `file_priorities` (one byte per
   file, 0-7; may be NULL) is applied while adding. */
int mq_session_add_magnet(mq_session *s, const char *magnet_uri, const char *save_path,
                          int32_t flags, char id_out[41], char **error);
int mq_session_add_torrent_data(mq_session *s, const uint8_t *data, size_t len,
                                const char *save_path, int32_t flags,
                                const uint8_t *file_priorities, size_t file_priority_count,
                                char id_out[41], char **error);
/* `save_path_override` may be NULL to use the path stored in the resume data. */
int mq_session_add_resume_data(mq_session *s, const uint8_t *data, size_t len,
                               const char *save_path_override, int32_t flags, char id_out[41],
                               char **error);

/* ---- torrent control ------------------------------------------------------------------- */

int mq_torrent_pause(mq_session *s, const char *id);
int mq_torrent_resume(mq_session *s, const char *id);
int mq_torrent_start_download(mq_session *s, const char *id); /* leaves MQ_ADD_HOLD_DOWNLOAD */
/* Asynchronous: the torrent stays findable until libtorrent's own thread runs the removal, and
   MQ_EVENT_TORRENT_REMOVED (with mq_remove_reason) arrives afterwards. Re-adding the same
   info-hash in that window returns MQ_ERR_DUPLICATE rather than the dying torrent. */
int mq_torrent_remove(mq_session *s, const char *id, int32_t delete_files);
/* Direct peer connection ("host" is an IP literal), used for tests and manual peers. */
int mq_torrent_connect_peer(mq_session *s, const char *id, const char *host, uint16_t port);
/* Per-torrent rate limits in bytes/second (0 = unlimited). Unlike the session-wide limits these also
 * apply to loopback/LAN peers, which libtorrent 2.x exempts from the global limits. */
int mq_torrent_set_upload_limit(mq_session *s, const char *id, int32_t bytes_per_second);
int mq_torrent_set_download_limit(mq_session *s, const char *id, int32_t bytes_per_second);
/* Asynchronously produces MQ_EVENT_RESUME_DATA (or ..._FAILED) for this torrent. */
int mq_torrent_request_resume_data(mq_session *s, const char *id);

/* ---- queries --------------------------------------------------------------------------- */

typedef enum {
  MQ_STATE_CHECKING_FILES = 1,
  MQ_STATE_DOWNLOADING_METADATA,
  MQ_STATE_DOWNLOADING,
  MQ_STATE_FINISHED,   /* all wanted pieces downloaded, not seeding (some files skipped) */
  MQ_STATE_SEEDING,
  MQ_STATE_CHECKING_RESUME_DATA
} mq_torrent_state;

typedef struct {
  int32_t state;             /* mq_torrent_state */
  int32_t paused;
  int32_t has_metadata;
  int32_t has_error;
  float progress;            /* 0..1 over wanted data */
  int64_t total_wanted;
  int64_t total_wanted_done;
  int64_t total_payload_download;
  int64_t total_payload_upload;
  int32_t download_rate;     /* payload bytes/s */
  int32_t upload_rate;
  int32_t num_peers;
  int32_t num_seeds;
  int32_t num_pieces_have;
  int32_t num_pieces;        /* 0 until metadata is known */
} mq_torrent_status;

int mq_torrent_get_status(mq_session *s, const char *id, mq_torrent_status *out);
/* NULL if the torrent has no error. */
char *mq_torrent_error_message(mq_session *s, const char *id);

typedef struct {
  char *name;                /* malloc'd; free with mq_free */
  int64_t total_size;
  int32_t piece_length;
  int32_t num_pieces;
  int32_t num_files;
} mq_torrent_info;

/* MQ_ERR_NO_METADATA until the info dictionary is available. */
int mq_torrent_get_info(mq_session *s, const char *id, mq_torrent_info *out);

typedef struct {
  char *path;                /* path relative to the save path, malloc'd */
  int64_t size;
  int64_t offset;            /* byte offset of the file within the torrent's piece space */
  int32_t priority;          /* 0 = skip, 1..7 */
} mq_file_entry;

int mq_torrent_get_files(mq_session *s, const char *id, mq_file_entry **files_out,
                         size_t *count_out);
void mq_files_free(mq_file_entry *files, size_t count);

/* Bytes downloaded per file; `out` must hold file-count entries. */
int mq_torrent_get_file_progress(mq_session *s, const char *id, int64_t *out, size_t count);
/* Packed bitfield, bit (i & 7) of byte (i >> 3) is set when piece i is complete. */
int mq_torrent_get_have_pieces(mq_session *s, const char *id, uint8_t **bits_out,
                               size_t *byte_count_out, int32_t *piece_count_out);

/* ---- priorities and streaming ---------------------------------------------------------- */

/* priorities: one byte per file, 0 skip .. 7 highest. */
int mq_torrent_set_file_priorities(mq_session *s, const char *id, const uint8_t *priorities,
                                   size_t count);
int mq_torrent_set_piece_priority(mq_session *s, const char *id, int32_t piece, int32_t priority);
/* Ask libtorrent to have `piece` within deadline_ms (time-critical, streaming mode). */
int mq_torrent_set_piece_deadline(mq_session *s, const char *id, int32_t piece,
                                  int32_t deadline_ms);
int mq_torrent_clear_piece_deadline(mq_session *s, const char *id, int32_t piece);
/* Batched forms of the two calls above: one lookup for the whole batch instead of one per piece, which
 * matters when a seek replaces hundreds of deadlines. Out-of-range pieces are skipped. */
int mq_torrent_set_piece_deadlines(mq_session *s, const char *id, const int32_t *pieces,
                                   const int32_t *deadlines_ms, size_t count);
int mq_torrent_clear_piece_deadlines(mq_session *s, const char *id, const int32_t *pieces, size_t count);
int mq_torrent_clear_all_piece_deadlines(mq_session *s, const char *id);
/* Asynchronously reads a complete piece -> MQ_EVENT_PIECE_READ / ..._FAILED. */
int mq_torrent_read_piece(mq_session *s, const char *id, int32_t piece);

/* ---- helpers --------------------------------------------------------------------------- */

/* Builds a .torrent for a file or directory (used by tests and future "create torrent"). */
int mq_create_torrent(const char *path, int32_t piece_size, uint8_t **data_out,
                      size_t *len_out, char **error);

/* The info-hash a `.torrent` file's metadata resolves to, written as 40 hex chars into `out`.
   Lets a caller recognise a download before adding it -- indexers often publish no hash at all
   for a `.torrent` link, and two releases are only the same download once the bytes are read. */
int mq_torrent_info_hash(const uint8_t *data, size_t len, char out[41], char **error);

const char *mq_libtorrent_version(void); /* static string */
void mq_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif /* CTORRENT_SHIM_H */
