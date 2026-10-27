// A small C API over libtorrent, so Swift can use it without C++ interop (which would put all of
// CourtsideCore in C++ mode). Only what Courtside needs: add a .torrent, pick files, stream a byte
// range with piece deadlines, progress, upload limit, remove. Swift wraps it in Torrent/*.swift.
//
// Errors: functions that can fail take `char *err, size_t errlen` and return NULL/-1 with a
// message written there. Strings returned through buffers are UTF-8 and NUL-terminated.

#ifndef TORRENT_BRIDGE_H
#define TORRENT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tb_session tb_session;
typedef struct tb_torrent tb_torrent;

// ---- session ----

/// listen: e.g. "0.0.0.0:6881,[::]:6881". upload_bps: 0 = unlimited.
tb_session *tb_session_new(const char *listen, int upload_bps, char *err, size_t errlen);
void tb_session_free(tb_session *s);
void tb_session_set_upload_limit(tb_session *s, int upload_bps);
void tb_session_set_download_limit(tb_session *s, int download_bps);  // 0 = unlimited; applies to local peers too
int tb_session_listen_port(tb_session *s);  // the TCP port peers connect to (0 if not listening)

enum {
  TB_EVENT_PIECE_FINISHED = 1,  // piece = the piece that passed its hash check
  TB_EVENT_TORRENT_FINISHED = 2,  // all wanted pieces are here
  TB_EVENT_ERROR = 3,  // torrent or file error; message says what
  TB_EVENT_HASH_FAILED = 4,  // piece failed its hash check (will be re-downloaded)
  TB_EVENT_CHECKED = 5,  // data already on disk was checked (no piece events for those pieces)
};
typedef void (*tb_event_cb)(void *ctx, int kind, uint32_t torrent_id, int piece, const char *message);

/// Block up to timeout_ms for libtorrent events, then deliver all pending ones to `cb` (on the
/// calling thread). Returns the number delivered. Run this in a loop on one background thread.
int tb_session_poll(tb_session *s, int timeout_ms, tb_event_cb cb, void *ctx);

// ---- torrents ----

/// Add a torrent from .torrent file bytes, saving into save_path. All files start unselected
/// (priority 0) when select_none != 0, otherwise all selected.
tb_torrent *tb_add(tb_session *s, const void *data, size_t len, const char *save_path, int select_none,
                   char *err, size_t errlen);
/// Remove from the session (delete_files != 0 also deletes downloaded data), then free.
void tb_remove(tb_session *s, tb_torrent *t, int delete_files);

uint32_t tb_id(const tb_torrent *t);  // unique in its session; matches tb_event_cb's torrent_id
size_t tb_name(const tb_torrent *t, char *buf, size_t len);
size_t tb_info_hash(const tb_torrent *t, char *buf, size_t len);  // hex

int tb_num_files(const tb_torrent *t);
size_t tb_file_path(const tb_torrent *t, int file, char *buf, size_t len);  // relative to save_path
int64_t tb_file_size(const tb_torrent *t, int file);
int64_t tb_file_offset(const tb_torrent *t, int file);  // offset in the torrent's byte stream
int tb_piece_length(const tb_torrent *t);
int tb_num_pieces(const tb_torrent *t);

/// 0 = don't download, 1 = low, 4 = default, 7 = top.
void tb_file_priority(tb_torrent *t, int file, int priority);

/// Pieces covering [offset, offset+length) of a file. Returns 0, or -1 for an empty/out-of-range span.
int tb_file_range_pieces(const tb_torrent *t, int file, int64_t offset, int64_t length, int *first, int *last);
int tb_have_piece(const tb_torrent *t, int piece);
/// Connect to a peer directly (e.g. a seeder on this Mac, without a tracker). 0, or -1 for a bad address.
int tb_connect_peer(tb_torrent *t, const char *ip, int port);
/// Ask for these pieces first, in order, each wanted within deadline_ms (+ step per piece).
void tb_set_deadlines(tb_torrent *t, int first, int last, int deadline_ms, int step_ms);
void tb_clear_deadlines(tb_torrent *t);
/// Piece priority (0…7) for pieces first…last. New requests go to higher priorities first, so
/// raising a window and lowering the rest focuses bandwidth on what's about to play.
void tb_set_piece_priorities(tb_torrent *t, int first, int last, int priority);

typedef struct {
  int state;               // lt::torrent_status::state_t
  int paused;
  double progress;         // 0…1 of the wanted (selected) data
  int64_t wanted;          // bytes selected
  int64_t wanted_done;     // bytes of those verified on disk
  int download_bps;
  int upload_bps;
  int peers;
  int seeds;
  int64_t uploaded;        // all-time payload uploaded this session
} tb_status;
void tb_get_status(const tb_torrent *t, tb_status *out);

/// Verified bytes per file; fills up to n entries, returns the file count.
int tb_file_progress(const tb_torrent *t, int64_t *out, int n);

#ifdef __cplusplus
}
#endif

#endif
