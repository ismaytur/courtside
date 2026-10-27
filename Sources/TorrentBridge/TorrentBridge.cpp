// libtorrent behind the C API in include/TorrentBridge.h. Every entry point catches C++
// exceptions: one escaping into Swift would abort the app.

#include "TorrentBridge.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/address.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

#include <algorithm>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace lt = libtorrent;

struct tb_session {
  lt::session ses;
  explicit tb_session(lt::session_params p) : ses(std::move(p)) {}
};

struct tb_torrent {
  lt::torrent_handle h;
  std::shared_ptr<const lt::torrent_info> ti;
};

namespace {

void set_err(char *err, size_t errlen, const std::string &msg) {
  if (err && errlen) {
    std::strncpy(err, msg.c_str(), errlen - 1);
    err[errlen - 1] = 0;
  }
}

size_t copy_out(const std::string &s, char *buf, size_t len) {
  if (buf && len) {
    size_t n = std::min(s.size(), len - 1);
    std::memcpy(buf, s.data(), n);
    buf[n] = 0;
  }
  return s.size();
}

lt::settings_pack base_settings(const char *listen, int upload_bps) {
  lt::settings_pack p;
  p.set_str(lt::settings_pack::listen_interfaces, listen && *listen ? listen : "0.0.0.0:6881,[::]:6881");
  p.set_int(lt::settings_pack::alert_mask,
            lt::alert_category::status | lt::alert_category::error | lt::alert_category::piece_progress |
                lt::alert_category::storage | lt::alert_category::file_progress);
  p.set_int(lt::settings_pack::upload_rate_limit, std::max(0, upload_bps));
  p.set_str(lt::settings_pack::user_agent, "Courtside/0.1 libtorrent/" LIBTORRENT_VERSION);
  // Streaming: don't let a slow peer hold a piece the player is waiting for. With 10 s a seek
  // regularly stalled ~10 s on one piece while the rest of the swarm delivered 12 MB/s.
  p.set_int(lt::settings_pack::request_timeout, 4);
  p.set_int(lt::settings_pack::piece_timeout, 4);
  return p;
}

}  // namespace

extern "C" {

tb_session *tb_session_new(const char *listen, int upload_bps, char *err, size_t errlen) {
  try {
    lt::session_params params(base_settings(listen, upload_bps));
    return new tb_session(std::move(params));
  } catch (std::exception const &e) {
    set_err(err, errlen, e.what());
    return nullptr;
  }
}

void tb_session_free(tb_session *s) { delete s; }

int tb_session_listen_port(tb_session *s) {
  try {
    return s->ses.listen_port();
  } catch (...) {
    return 0;
  }
}

void tb_session_set_upload_limit(tb_session *s, int upload_bps) {
  try {
    lt::settings_pack p;
    p.set_int(lt::settings_pack::upload_rate_limit, std::max(0, upload_bps));
    s->ses.apply_settings(std::move(p));
  } catch (...) {
  }
}

void tb_session_set_download_limit(tb_session *s, int download_bps) {
  try {
    lt::settings_pack p;
    p.set_int(lt::settings_pack::download_rate_limit, std::max(0, download_bps));
    s->ses.apply_settings(std::move(p));
    // Peers on the local network (a test seeder on this Mac) are in their own, unlimited class;
    // the cap is for tests, so it covers them too.
    lt::peer_class_info local = s->ses.get_peer_class(lt::session::local_peer_class_id);
    local.download_limit = std::max(0, download_bps);
    s->ses.set_peer_class(lt::session::local_peer_class_id, local);
  } catch (...) {
  }
}

int tb_session_poll(tb_session *s, int timeout_ms, tb_event_cb cb, void *ctx) {
  try {
    if (!s->ses.wait_for_alert(lt::milliseconds(timeout_ms))) return 0;
    std::vector<lt::alert *> alerts;
    s->ses.pop_alerts(&alerts);
    int n = 0;
    for (lt::alert *a : alerts) {
      if (auto *p = lt::alert_cast<lt::piece_finished_alert>(a)) {
        cb(ctx, TB_EVENT_PIECE_FINISHED, p->handle.id(), static_cast<int>(p->piece_index), "");
      } else if (auto *f = lt::alert_cast<lt::torrent_finished_alert>(a)) {
        cb(ctx, TB_EVENT_TORRENT_FINISHED, f->handle.id(), -1, "");
      } else if (auto *c = lt::alert_cast<lt::torrent_checked_alert>(a)) {
        cb(ctx, TB_EVENT_CHECKED, c->handle.id(), -1, "");
      } else if (auto *h = lt::alert_cast<lt::hash_failed_alert>(a)) {
        cb(ctx, TB_EVENT_HASH_FAILED, h->handle.id(), static_cast<int>(h->piece_index), "");
      } else if (auto *e = lt::alert_cast<lt::torrent_error_alert>(a)) {
        cb(ctx, TB_EVENT_ERROR, e->handle.id(), -1, e->message().c_str());
      } else if (auto *fe = lt::alert_cast<lt::file_error_alert>(a)) {
        cb(ctx, TB_EVENT_ERROR, fe->handle.id(), -1, fe->message().c_str());
      } else {
        continue;
      }
      n++;
    }
    return n;
  } catch (...) {
    return 0;
  }
}

tb_torrent *tb_add(tb_session *s, const void *data, size_t len, const char *save_path, int select_none,
                   char *err, size_t errlen) {
  try {
    auto ti = std::make_shared<lt::torrent_info>(
        lt::span<char const>(static_cast<char const *>(data), static_cast<std::ptrdiff_t>(len)), lt::from_span);
    lt::add_torrent_params atp;
    atp.ti = ti;
    atp.save_path = save_path;
    // Not auto-managed: Courtside decides what runs; libtorrent's queue would otherwise pause
    // games beyond its active-download limit.
    atp.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused);
    if (select_none) atp.file_priorities.assign(static_cast<size_t>(ti->num_files()), lt::dont_download);
    lt::error_code ec;
    lt::torrent_handle h = s->ses.add_torrent(std::move(atp), ec);
    if (ec) {
      set_err(err, errlen, ec.message());
      return nullptr;
    }
    return new tb_torrent{h, ti};
  } catch (std::exception const &e) {
    set_err(err, errlen, e.what());
    return nullptr;
  }
}

void tb_remove(tb_session *s, tb_torrent *t, int delete_files) {
  try {
    s->ses.remove_torrent(t->h, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
  } catch (...) {
  }
  delete t;
}

uint32_t tb_id(const tb_torrent *t) { return t->h.id(); }

size_t tb_name(const tb_torrent *t, char *buf, size_t len) { return copy_out(t->ti->name(), buf, len); }

size_t tb_info_hash(const tb_torrent *t, char *buf, size_t len) {
  static char const digits[] = "0123456789abcdef";
  lt::sha1_hash h = t->ti->info_hashes().get_best();
  std::string hex;
  for (char c : h) {
    hex += digits[(static_cast<unsigned char>(c) >> 4) & 0xf];
    hex += digits[static_cast<unsigned char>(c) & 0xf];
  }
  return copy_out(hex, buf, len);
}

int tb_num_files(const tb_torrent *t) { return t->ti->num_files(); }

size_t tb_file_path(const tb_torrent *t, int file, char *buf, size_t len) {
  return copy_out(t->ti->files().file_path(lt::file_index_t{file}), buf, len);
}

int64_t tb_file_size(const tb_torrent *t, int file) { return t->ti->files().file_size(lt::file_index_t{file}); }

int64_t tb_file_offset(const tb_torrent *t, int file) { return t->ti->files().file_offset(lt::file_index_t{file}); }

int tb_piece_length(const tb_torrent *t) { return t->ti->piece_length(); }

int tb_num_pieces(const tb_torrent *t) { return t->ti->num_pieces(); }

void tb_file_priority(tb_torrent *t, int file, int priority) {
  try {
    t->h.file_priority(lt::file_index_t{file}, lt::download_priority_t{static_cast<std::uint8_t>(priority)});
  } catch (...) {
  }
}

int tb_file_range_pieces(const tb_torrent *t, int file, int64_t offset, int64_t length, int *first, int *last) {
  auto const &fs = t->ti->files();
  if (file < 0 || file >= fs.num_files() || length <= 0 || offset < 0) return -1;
  int64_t size = fs.file_size(lt::file_index_t{file});
  if (offset >= size) return -1;
  length = std::min(length, size - offset);
  int64_t start = fs.file_offset(lt::file_index_t{file}) + offset;
  int64_t plen = t->ti->piece_length();
  *first = static_cast<int>(start / plen);
  *last = static_cast<int>((start + length - 1) / plen);
  return 0;
}

int tb_connect_peer(tb_torrent *t, const char *ip, int port) {
  try {
    lt::error_code ec;
    auto addr = lt::make_address(ip, ec);
    if (ec) return -1;
    t->h.connect_peer(lt::tcp::endpoint(addr, static_cast<std::uint16_t>(port)));
    return 0;
  } catch (...) {
    return -1;
  }
}

int tb_have_piece(const tb_torrent *t, int piece) {
  try {
    return t->h.have_piece(lt::piece_index_t{piece}) ? 1 : 0;
  } catch (...) {
    return 0;
  }
}

void tb_set_deadlines(tb_torrent *t, int first, int last, int deadline_ms, int step_ms) {
  try {
    for (int p = first; p <= last; p++) {
      if (t->h.have_piece(lt::piece_index_t{p})) continue;
      t->h.set_piece_deadline(lt::piece_index_t{p}, deadline_ms + (p - first) * step_ms);
    }
  } catch (...) {
  }
}

void tb_clear_deadlines(tb_torrent *t) {
  try {
    t->h.clear_piece_deadlines();
  } catch (...) {
  }
}

void tb_set_piece_priorities(tb_torrent *t, int first, int last, int priority) {
  try {
    std::vector<std::pair<lt::piece_index_t, lt::download_priority_t>> v;
    for (int p = std::max(0, first); p <= last && p < t->ti->num_pieces(); p++)
      v.emplace_back(lt::piece_index_t{p}, lt::download_priority_t{static_cast<std::uint8_t>(priority)});
    t->h.prioritize_pieces(v);
  } catch (...) {
  }
}

void tb_get_status(const tb_torrent *t, tb_status *out) {
  std::memset(out, 0, sizeof(*out));
  try {
    lt::torrent_status st = t->h.status();
    out->state = static_cast<int>(st.state);
    out->paused = (st.flags & lt::torrent_flags::paused) ? 1 : 0;
    out->progress = st.progress;
    out->wanted = st.total_wanted;
    out->wanted_done = st.total_wanted_done;
    out->download_bps = st.download_payload_rate;
    out->upload_bps = st.upload_payload_rate;
    out->peers = st.num_peers;
    out->seeds = st.num_seeds;
    out->uploaded = st.all_time_upload;
  } catch (...) {
  }
}

int tb_file_progress(const tb_torrent *t, int64_t *out, int n) {
  try {
    std::vector<std::int64_t> p = t->h.file_progress(lt::torrent_handle::piece_granularity);
    for (int i = 0; i < n && i < static_cast<int>(p.size()); i++) out[i] = p[static_cast<size_t>(i)];
    return static_cast<int>(p.size());
  } catch (...) {
    return 0;
  }
}

}  // extern "C"
