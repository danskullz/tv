// Implementation of ctorrent_shim.h on top of libtorrent-rasterbar 2.0.
//
// Threading model: libtorrent runs its own network thread(s). This file adds exactly one thread of
// its own, the "alert thread". libtorrent calls our alert-notify hook (on its network thread, with
// internal locks held) whenever the alert queue becomes non-empty; the hook only flips a flag and
// signals a condition variable. The alert thread sleeps on that condition variable (no timers, no
// polling), then drains the queue with pop_alerts() and forwards each interesting alert to the
// registered C callback.

#if !__has_include(<marquee_libtorrent_config.h>)
#error "libtorrent is not built: run scripts/build-libtorrent.sh"
#endif
// Must stay the first libtorrent-related include: it carries the definitions libtorrent was built
// with, which change the layout of its public types.
#include <marquee_libtorrent_config.h>

#include "ctorrent_shim.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <pthread.h>

#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace lt = libtorrent;

// ---------------------------------------------------------------------------------------------
// Session object
// ---------------------------------------------------------------------------------------------

struct mq_session {
  lt::session ses;
  mq_event_fn callback = nullptr;
  void* context = nullptr;

  // Alert thread state.
  std::mutex wake_mutex;
  std::condition_variable wake;
  bool pending = false;
  bool stopping = false;
  std::thread alert_thread;

  // torrent_handle::id() -> our hex id, so per-piece alerts do not need a synchronous round trip
  // into libtorrent's network thread just to learn which torrent they belong to.
  std::mutex ids_mutex;
  std::unordered_map<std::uint32_t, std::string> ids;

  explicit mq_session(lt::session_params&& params) : ses(std::move(params)) {}
};

namespace {

// ---- small helpers --------------------------------------------------------------------------

char* dup_string(std::string const& s) {
  char* p = static_cast<char*>(std::malloc(s.size() + 1));
  if (p) std::memcpy(p, s.c_str(), s.size() + 1);
  return p;
}

void set_error(char** error, std::string const& message) {
  if (error) *error = dup_string(message);
}

template <class F>
int guarded(char** error, F&& body) {
  try {
    return body();
  } catch (std::exception const& e) {
    set_error(error, e.what());
  } catch (...) {
    set_error(error, "unknown error");
  }
  return MQ_ERR_LIBTORRENT;
}

std::string to_hex(lt::sha1_hash const& h) {
  static const char digits[] = "0123456789abcdef";
  std::string out(40, '0');
  char const* raw = h.data();
  for (int i = 0; i < 20; ++i) {
    auto byte = static_cast<unsigned char>(raw[i]);
    out[i * 2] = digits[byte >> 4];
    out[i * 2 + 1] = digits[byte & 0xf];
  }
  return out;
}

bool from_hex(char const* id, lt::sha1_hash& out) {
  if (!id || std::strlen(id) != 40) return false;
  char raw[20];
  for (int i = 0; i < 20; ++i) {
    int v[2];
    for (int j = 0; j < 2; ++j) {
      char c = id[i * 2 + j];
      if (c >= '0' && c <= '9') v[j] = c - '0';
      else if (c >= 'a' && c <= 'f') v[j] = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') v[j] = c - 'A' + 10;
      else return false;
    }
    raw[i] = static_cast<char>((v[0] << 4) | v[1]);
  }
  out = lt::sha1_hash(raw);
  return true;
}

// The id is the v1 info-hash when there is one, otherwise the truncated v2 hash, so a torrent
// gets the same id whether it was added as a magnet, a .torrent file, or hybrid metadata.
std::string id_of(lt::info_hash_t const& ih) {
  return to_hex(ih.has_v1() ? ih.v1 : lt::sha1_hash(ih.v2.data()));
}

std::string id_of(lt::torrent_handle const& h) { return id_of(h.info_hashes()); }

lt::torrent_handle find(mq_session* s, char const* id) {
  lt::sha1_hash hash;
  if (!s || !from_hex(id, hash)) return {};
  return s->ses.find_torrent(hash);
}

#define MQ_REQUIRE_TORRENT(handle, s, id)                  \
  lt::torrent_handle handle = find((s), (id));             \
  if (!handle.is_valid()) return MQ_ERR_NOT_FOUND

int32_t state_code(lt::torrent_status::state_t st) {
  switch (st) {
    case lt::torrent_status::checking_files: return MQ_STATE_CHECKING_FILES;
    case lt::torrent_status::downloading_metadata: return MQ_STATE_DOWNLOADING_METADATA;
    case lt::torrent_status::downloading: return MQ_STATE_DOWNLOADING;
    case lt::torrent_status::finished: return MQ_STATE_FINISHED;
    case lt::torrent_status::seeding: return MQ_STATE_SEEDING;
    case lt::torrent_status::checking_resume_data: return MQ_STATE_CHECKING_RESUME_DATA;
    default: return MQ_STATE_DOWNLOADING;
  }
}

int32_t listen_kind(lt::socket_type_t t) {
  switch (t) {
    case lt::socket_type_t::tcp: return 0;
    case lt::socket_type_t::utp: return 1;
    case lt::socket_type_t::tcp_ssl:
    case lt::socket_type_t::utp_ssl: return 2;
    default: return 3;
  }
}

// ---- alert dispatch -------------------------------------------------------------------------

std::string torrent_id_for(mq_session* s, lt::torrent_alert const* a) {
  std::uint32_t key = a->handle.id();
  {
    std::lock_guard<std::mutex> lock(s->ids_mutex);
    auto it = s->ids.find(key);
    if (it != s->ids.end()) return it->second;
  }
  std::string id = id_of(a->handle);  // not one of ours (should not happen); resolve once
  std::lock_guard<std::mutex> lock(s->ids_mutex);
  s->ids[key] = id;
  return id;
}

void emit(mq_session* s, mq_event& ev) { s->callback(s->context, &ev); }

void dispatch(mq_session* s, lt::alert* a) {
  using namespace lt;
  mq_event ev{};
  ev.piece = -1;
  std::string id, text;

  auto with_torrent = [&](mq_event_type type, torrent_alert const* ta) {
    ev.type = type;
    id = torrent_id_for(s, ta);
    ev.torrent_id = id.c_str();
  };

  switch (a->type()) {
    case listen_succeeded_alert::alert_type: {
      auto* x = static_cast<listen_succeeded_alert*>(a);
      ev.type = MQ_EVENT_LISTEN_SUCCEEDED;
      ev.value = x->port;
      ev.flags = listen_kind(x->socket_type);
      text = x->address.to_string();
      ev.message = text.c_str();
      break;
    }
    case listen_failed_alert::alert_type: {
      auto* x = static_cast<listen_failed_alert*>(a);
      ev.type = MQ_EVENT_LISTEN_FAILED;
      ev.value = x->port;
      ev.flags = listen_kind(x->socket_type);
      text = x->error.message();
      ev.message = text.c_str();
      break;
    }
    case torrent_removed_alert::alert_type: {
      auto* x = static_cast<torrent_removed_alert*>(a);
      id = id_of(x->info_hashes);
      {
        std::lock_guard<std::mutex> lock(s->ids_mutex);
        for (auto it = s->ids.begin(); it != s->ids.end();) {
          it = (it->second == id) ? s->ids.erase(it) : std::next(it);
        }
      }
      ev.type = MQ_EVENT_TORRENT_REMOVED;
      ev.torrent_id = id.c_str();
      break;
    }
    case metadata_received_alert::alert_type:
      with_torrent(MQ_EVENT_METADATA_RECEIVED, static_cast<torrent_alert*>(a));
      break;
    case metadata_failed_alert::alert_type: {
      auto* x = static_cast<metadata_failed_alert*>(a);
      with_torrent(MQ_EVENT_METADATA_FAILED, x);
      text = x->error.message();
      ev.message = text.c_str();
      break;
    }
    case torrent_checked_alert::alert_type:
      with_torrent(MQ_EVENT_TORRENT_CHECKED, static_cast<torrent_alert*>(a));
      break;
    case state_changed_alert::alert_type: {
      auto* x = static_cast<state_changed_alert*>(a);
      with_torrent(MQ_EVENT_STATE_CHANGED, x);
      ev.value = state_code(x->state);
      break;
    }
    case piece_finished_alert::alert_type: {
      auto* x = static_cast<piece_finished_alert*>(a);
      with_torrent(MQ_EVENT_PIECE_FINISHED, x);
      ev.piece = static_cast<int>(x->piece_index);
      break;
    }
    case hash_failed_alert::alert_type: {
      auto* x = static_cast<hash_failed_alert*>(a);
      with_torrent(MQ_EVENT_HASH_FAILED, x);
      ev.piece = static_cast<int>(x->piece_index);
      break;
    }
    case file_completed_alert::alert_type: {
      auto* x = static_cast<file_completed_alert*>(a);
      with_torrent(MQ_EVENT_FILE_COMPLETED, x);
      ev.value = static_cast<int>(x->index);
      break;
    }
    case torrent_finished_alert::alert_type:
      with_torrent(MQ_EVENT_TORRENT_FINISHED, static_cast<torrent_alert*>(a));
      break;
    case torrent_paused_alert::alert_type:
      with_torrent(MQ_EVENT_TORRENT_PAUSED, static_cast<torrent_alert*>(a));
      break;
    case torrent_resumed_alert::alert_type:
      with_torrent(MQ_EVENT_TORRENT_RESUMED, static_cast<torrent_alert*>(a));
      break;
    case torrent_error_alert::alert_type: {
      auto* x = static_cast<torrent_error_alert*>(a);
      with_torrent(MQ_EVENT_TORRENT_ERROR, x);
      text = x->error.message();
      ev.message = text.c_str();
      break;
    }
    case file_error_alert::alert_type: {
      auto* x = static_cast<file_error_alert*>(a);
      with_torrent(MQ_EVENT_FILE_ERROR, x);
      text = x->error.message();
      ev.message = text.c_str();
      break;
    }
    case read_piece_alert::alert_type: {
      auto* x = static_cast<read_piece_alert*>(a);
      ev.piece = static_cast<int>(x->piece);
      if (x->error) {
        with_torrent(MQ_EVENT_PIECE_READ_FAILED, x);
        text = x->error.message();
        ev.message = text.c_str();
      } else {
        with_torrent(MQ_EVENT_PIECE_READ, x);
        ev.data = reinterpret_cast<std::uint8_t const*>(x->buffer.get());
        ev.data_len = static_cast<std::size_t>(x->size);
      }
      break;
    }
    case save_resume_data_alert::alert_type: {
      auto* x = static_cast<save_resume_data_alert*>(a);
      with_torrent(MQ_EVENT_RESUME_DATA, x);
      std::vector<char> buf = write_resume_data_buf(x->params);
      ev.data = reinterpret_cast<std::uint8_t const*>(buf.data());
      ev.data_len = buf.size();
      emit(s, ev);  // `buf` must outlive the callback
      return;
    }
    case save_resume_data_failed_alert::alert_type: {
      auto* x = static_cast<save_resume_data_failed_alert*>(a);
      with_torrent(MQ_EVENT_RESUME_DATA_FAILED, x);
      text = x->error.message();
      ev.message = text.c_str();
      break;
    }
    default:
      return;  // alert masked in but not interesting to the app
  }
  emit(s, ev);
}

void alert_loop(mq_session* s) {
  pthread_setname_np("marquee.torrent.alerts");
  std::vector<lt::alert*> alerts;
  for (;;) {
    {
      std::unique_lock<std::mutex> lock(s->wake_mutex);
      s->wake.wait(lock, [s] { return s->pending || s->stopping; });
      if (s->stopping) return;
      s->pending = false;
    }
    alerts.clear();
    s->ses.pop_alerts(&alerts);
    for (lt::alert* a : alerts) {
      try {
        dispatch(s, a);
      } catch (...) {
        // never let an exception escape into the thread; the alert is dropped
      }
    }
  }
}

// ---- settings -------------------------------------------------------------------------------

void apply(mq_session* s, lt::settings_pack&& pack) { s->ses.apply_settings(std::move(pack)); }

template <class Setter>
int set_named(mq_session* s, char const* name, int type_base, Setter&& set) {
  if (!s || !name) return MQ_ERR_INVALID;
  int index = lt::setting_by_name(name);
  if (index < 0 || (index & lt::settings_pack::type_mask) != type_base) return MQ_ERR_INVALID;
  lt::settings_pack pack;
  set(pack, index);
  apply(s, std::move(pack));
  return MQ_OK;
}

// ---- adding ---------------------------------------------------------------------------------

lt::torrent_flags_t add_flags(lt::torrent_flags_t base, int32_t flags) {
  // We run our own queueing; libtorrent's auto-management would pause torrents behind our back.
  base &= ~lt::torrent_flags::auto_managed;
  base &= ~lt::torrent_flags::duplicate_is_error;  // adding an existing torrent returns it
  if (flags & MQ_ADD_PAUSED) base |= lt::torrent_flags::paused;
  else base &= ~lt::torrent_flags::paused;
  if (flags & MQ_ADD_HOLD_DOWNLOAD) base |= lt::torrent_flags::upload_mode;
  if (flags & MQ_ADD_SEQUENTIAL) base |= lt::torrent_flags::sequential_download;
  return base;
}

int do_add(mq_session* s, lt::add_torrent_params& params, char id_out[41], char** error) {
  lt::error_code ec;
  lt::torrent_handle h = s->ses.add_torrent(std::move(params), ec);
  if (ec || !h.is_valid()) {
    set_error(error, ec ? ec.message() : "could not add torrent");
    return MQ_ERR_LIBTORRENT;
  }
  std::string id = id_of(h);
  {
    std::lock_guard<std::mutex> lock(s->ids_mutex);
    s->ids[h.id()] = id;
  }
  if (id_out) std::memcpy(id_out, id.c_str(), 41);
  return MQ_OK;
}

void set_priorities(lt::add_torrent_params& params, std::uint8_t const* prios, std::size_t n) {
  if (!prios || n == 0) return;
  params.file_priorities.reserve(n);
  for (std::size_t i = 0; i < n; ++i) {
    params.file_priorities.push_back(lt::download_priority_t(prios[i] > 7 ? 7 : prios[i]));
  }
}

}  // namespace

// ---------------------------------------------------------------------------------------------
// C API
// ---------------------------------------------------------------------------------------------

extern "C" {

mq_session* mq_session_create(mq_session_config const* config, mq_event_fn callback,
                              void* context, char** error) {
  if (!config || !callback) {
    set_error(error, "invalid session configuration");
    return nullptr;
  }
  try {
    lt::settings_pack pack;
    if (config->listen_interfaces) pack.set_str(lt::settings_pack::listen_interfaces, config->listen_interfaces);
    if (config->outgoing_interfaces) pack.set_str(lt::settings_pack::outgoing_interfaces, config->outgoing_interfaces);
    if (config->user_agent) pack.set_str(lt::settings_pack::user_agent, config->user_agent);
    pack.set_bool(lt::settings_pack::enable_dht, config->enable_dht != 0);
    pack.set_bool(lt::settings_pack::enable_lsd, config->enable_lsd != 0);
    pack.set_bool(lt::settings_pack::enable_upnp, config->enable_upnp != 0);
    pack.set_bool(lt::settings_pack::enable_natpmp, config->enable_natpmp != 0);

    switch (config->encryption_mode) {
      case 1:  // required: only RC4-obfuscated connections, in and out
        pack.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_forced);
        pack.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_forced);
        pack.set_int(lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_rc4);
        break;
      case 2:  // disabled
        pack.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_disabled);
        pack.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_disabled);
        break;
      default:  // prefer encryption, fall back to plaintext
        pack.set_int(lt::settings_pack::out_enc_policy, lt::settings_pack::pe_enabled);
        pack.set_int(lt::settings_pack::in_enc_policy, lt::settings_pack::pe_enabled);
        pack.set_int(lt::settings_pack::allowed_enc_level, lt::settings_pack::pe_both);
        break;
    }

    // Only the categories the shim translates; everything else would be allocated for nothing.
    pack.set_int(lt::settings_pack::alert_mask,
                 lt::alert_category::error | lt::alert_category::status |
                     lt::alert_category::storage | lt::alert_category::file_progress |
                     lt::alert_category::piece_progress);

    lt::session_params params(std::move(pack));
    auto session = std::make_unique<mq_session>(std::move(params));
    session->callback = callback;
    session->context = context;

    mq_session* raw = session.get();
    session->ses.set_alert_notify([raw] {
      {
        std::lock_guard<std::mutex> lock(raw->wake_mutex);
        raw->pending = true;
      }
      raw->wake.notify_one();
    });
    session->alert_thread = std::thread(alert_loop, raw);
    // Alerts posted before the notify hook existed (e.g. listen_succeeded) would never wake us.
    {
      std::lock_guard<std::mutex> lock(raw->wake_mutex);
      raw->pending = true;
    }
    raw->wake.notify_one();
    return session.release();
  } catch (std::exception const& e) {
    set_error(error, e.what());
  } catch (...) {
    set_error(error, "unknown error");
  }
  return nullptr;
}

void mq_session_destroy(mq_session* s) {
  if (!s) return;
  s->ses.set_alert_notify([] {});
  {
    std::lock_guard<std::mutex> lock(s->wake_mutex);
    s->stopping = true;
  }
  s->wake.notify_one();
  if (s->alert_thread.joinable()) s->alert_thread.join();
  delete s;  // ~session blocks until libtorrent has shut down
}

int mq_session_set_bool(mq_session* s, char const* name, int32_t value) {
  return guarded(nullptr, [&]() -> int {
    return set_named(s, name, lt::settings_pack::bool_type_base,
                     [&](lt::settings_pack& p, int i) { p.set_bool(i, value != 0); });
  });
}

int mq_session_set_int(mq_session* s, char const* name, int32_t value) {
  return guarded(nullptr, [&]() -> int {
    return set_named(s, name, lt::settings_pack::int_type_base,
                     [&](lt::settings_pack& p, int i) { p.set_int(i, value); });
  });
}

int mq_session_set_string(mq_session* s, char const* name, char const* value) {
  return guarded(nullptr, [&]() -> int {
    if (!value) return static_cast<int>(MQ_ERR_INVALID);
    return set_named(s, name, lt::settings_pack::string_type_base,
                     [&](lt::settings_pack& p, int i) { p.set_str(i, value); });
  });
}

int mq_session_add_magnet(mq_session* s, char const* uri, char const* save_path, int32_t flags,
                          char id_out[41], char** error) {
  return guarded(error, [&]() -> int {
    if (!s || !uri || !save_path) return static_cast<int>(MQ_ERR_INVALID);
    lt::error_code ec;
    lt::add_torrent_params params = lt::parse_magnet_uri(uri, ec);
    if (ec) {
      set_error(error, ec.message());
      return static_cast<int>(MQ_ERR_INVALID);
    }
    params.save_path = save_path;
    params.flags = add_flags(params.flags, flags);
    return do_add(s, params, id_out, error);
  });
}

int mq_session_add_torrent_data(mq_session* s, uint8_t const* data, size_t len,
                                char const* save_path, int32_t flags,
                                uint8_t const* file_priorities, size_t file_priority_count,
                                char id_out[41], char** error) {
  return guarded(error, [&]() -> int {
    if (!s || !data || !save_path) return static_cast<int>(MQ_ERR_INVALID);
    lt::add_torrent_params params = lt::load_torrent_buffer(
        lt::span<char const>(reinterpret_cast<char const*>(data), static_cast<long>(len)));
    params.save_path = save_path;
    params.flags = add_flags(params.flags, flags);
    set_priorities(params, file_priorities, file_priority_count);
    return do_add(s, params, id_out, error);
  });
}

int mq_session_add_resume_data(mq_session* s, uint8_t const* data, size_t len,
                               char const* save_path_override, int32_t flags, char id_out[41],
                               char** error) {
  return guarded(error, [&]() -> int {
    if (!s || !data) return static_cast<int>(MQ_ERR_INVALID);
    lt::error_code ec;
    lt::add_torrent_params params = lt::read_resume_data(
        lt::span<char const>(reinterpret_cast<char const*>(data), static_cast<long>(len)), ec);
    if (ec) {
      set_error(error, ec.message());
      return static_cast<int>(MQ_ERR_INVALID);
    }
    if (save_path_override) params.save_path = save_path_override;
    params.flags = add_flags(params.flags, flags);
    return do_add(s, params, id_out, error);
  });
}

int mq_torrent_pause(mq_session* s, char const* id) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    h.unset_flags(lt::torrent_flags::auto_managed);
    h.pause();
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_resume(mq_session* s, char const* id) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    h.unset_flags(lt::torrent_flags::auto_managed);
    h.resume();
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_start_download(mq_session* s, char const* id) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    h.unset_flags(lt::torrent_flags::upload_mode);
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_remove(mq_session* s, char const* id, int32_t delete_files) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    s->ses.remove_torrent(h, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_connect_peer(mq_session* s, char const* id, char const* host, uint16_t port) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    lt::error_code ec;
    lt::address addr = lt::make_address(host ? host : "", ec);
    if (ec) return static_cast<int>(MQ_ERR_INVALID);
    h.connect_peer(lt::tcp::endpoint(addr, port));
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_request_resume_data(mq_session* s, char const* id) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    h.save_resume_data(lt::torrent_handle::save_info_dict);
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_get_status(mq_session* s, char const* id, mq_torrent_status* out) {
  return guarded(nullptr, [&]() -> int {
    if (!out) return static_cast<int>(MQ_ERR_INVALID);
    MQ_REQUIRE_TORRENT(h, s, id);
    lt::torrent_status st = h.status();
    std::memset(out, 0, sizeof *out);
    out->state = state_code(st.state);
    out->paused = (st.flags & lt::torrent_flags::paused) ? 1 : 0;
    out->has_metadata = st.has_metadata ? 1 : 0;
    out->has_error = st.errc ? 1 : 0;
    out->progress = st.progress;
    out->total_wanted = st.total_wanted;
    out->total_wanted_done = st.total_wanted_done;
    out->total_payload_download = st.total_payload_download;
    out->total_payload_upload = st.total_payload_upload;
    out->download_rate = st.download_payload_rate;
    out->upload_rate = st.upload_payload_rate;
    out->num_peers = st.num_peers;
    out->num_seeds = st.num_seeds;
    out->num_pieces_have = st.num_pieces;
    auto ti = h.torrent_file();
    out->num_pieces = ti ? ti->num_pieces() : 0;
    return static_cast<int>(MQ_OK);
  });
}

char* mq_torrent_error_message(mq_session* s, char const* id) {
  try {
    lt::torrent_handle h = find(s, id);
    if (!h.is_valid()) return nullptr;
    lt::torrent_status st = h.status();
    if (!st.errc) return nullptr;
    return dup_string(st.errc.message());
  } catch (...) {
    return nullptr;
  }
}

int mq_torrent_get_info(mq_session* s, char const* id, mq_torrent_info* out) {
  return guarded(nullptr, [&]() -> int {
    if (!out) return static_cast<int>(MQ_ERR_INVALID);
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    out->name = dup_string(ti->name());
    out->total_size = ti->total_size();
    out->piece_length = ti->piece_length();
    out->num_pieces = ti->num_pieces();
    out->num_files = ti->num_files();
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_get_files(mq_session* s, char const* id, mq_file_entry** files_out,
                         size_t* count_out) {
  return guarded(nullptr, [&]() -> int {
    if (!files_out || !count_out) return static_cast<int>(MQ_ERR_INVALID);
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    lt::file_storage const& fs = ti->files();
    std::vector<lt::download_priority_t> prios = h.get_file_priorities();
    std::size_t n = static_cast<std::size_t>(fs.num_files());
    auto* entries = static_cast<mq_file_entry*>(std::calloc(n ? n : 1, sizeof(mq_file_entry)));
    if (!entries) return static_cast<int>(MQ_ERR_LIBTORRENT);
    for (std::size_t i = 0; i < n; ++i) {
      lt::file_index_t fi(static_cast<int>(i));
      entries[i].path = dup_string(fs.file_path(fi));
      entries[i].size = fs.file_size(fi);
      entries[i].offset = fs.file_offset(fi);
      entries[i].priority = i < prios.size() ? static_cast<int32_t>(static_cast<std::uint8_t>(prios[i])) : 4;
    }
    *files_out = entries;
    *count_out = n;
    return static_cast<int>(MQ_OK);
  });
}

void mq_files_free(mq_file_entry* files, size_t count) {
  if (!files) return;
  for (size_t i = 0; i < count; ++i) std::free(files[i].path);
  std::free(files);
}

int mq_torrent_get_file_progress(mq_session* s, char const* id, int64_t* out, size_t count) {
  return guarded(nullptr, [&]() -> int {
    if (!out) return static_cast<int>(MQ_ERR_INVALID);
    MQ_REQUIRE_TORRENT(h, s, id);
    if (!h.torrent_file()) return static_cast<int>(MQ_ERR_NO_METADATA);
    std::vector<std::int64_t> progress = h.file_progress();
    for (size_t i = 0; i < count; ++i) out[i] = i < progress.size() ? progress[i] : 0;
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_get_have_pieces(mq_session* s, char const* id, uint8_t** bits_out,
                               size_t* byte_count_out, int32_t* piece_count_out) {
  return guarded(nullptr, [&]() -> int {
    if (!bits_out || !byte_count_out) return static_cast<int>(MQ_ERR_INVALID);
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    int pieces = ti->num_pieces();
    lt::torrent_status st = h.status(lt::torrent_handle::query_pieces);
    size_t bytes = static_cast<size_t>((pieces + 7) / 8);
    auto* bits = static_cast<uint8_t*>(std::calloc(bytes ? bytes : 1, 1));
    if (!bits) return static_cast<int>(MQ_ERR_LIBTORRENT);
    // `pieces` is empty while checking; report nothing owned rather than guessing.
    if (st.pieces.size() == pieces) {
      for (int i = 0; i < pieces; ++i) {
        if (st.pieces.get_bit(lt::piece_index_t(i))) bits[i >> 3] |= static_cast<uint8_t>(1u << (i & 7));
      }
    }
    *bits_out = bits;
    *byte_count_out = bytes;
    if (piece_count_out) *piece_count_out = pieces;
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_set_file_priorities(mq_session* s, char const* id, uint8_t const* priorities,
                                   size_t count) {
  return guarded(nullptr, [&]() -> int {
    if (!priorities && count) return static_cast<int>(MQ_ERR_INVALID);
    MQ_REQUIRE_TORRENT(h, s, id);
    if (!h.torrent_file()) return static_cast<int>(MQ_ERR_NO_METADATA);
    std::vector<lt::download_priority_t> prios;
    prios.reserve(count);
    for (size_t i = 0; i < count; ++i) prios.push_back(lt::download_priority_t(priorities[i] > 7 ? 7 : priorities[i]));
    h.prioritize_files(prios);
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_set_piece_priority(mq_session* s, char const* id, int32_t piece, int32_t priority) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    if (piece < 0 || piece >= ti->num_pieces()) return static_cast<int>(MQ_ERR_INVALID);
    h.piece_priority(lt::piece_index_t(piece), lt::download_priority_t(priority < 0 ? 0 : (priority > 7 ? 7 : priority)));
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_set_piece_deadline(mq_session* s, char const* id, int32_t piece,
                                  int32_t deadline_ms) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    if (piece < 0 || piece >= ti->num_pieces()) return static_cast<int>(MQ_ERR_INVALID);
    h.set_piece_deadline(lt::piece_index_t(piece), deadline_ms < 0 ? 0 : deadline_ms);
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_clear_piece_deadline(mq_session* s, char const* id, int32_t piece) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    if (piece < 0 || piece >= ti->num_pieces()) return static_cast<int>(MQ_ERR_INVALID);
    h.reset_piece_deadline(lt::piece_index_t(piece));
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_clear_all_piece_deadlines(mq_session* s, char const* id) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    h.clear_piece_deadlines();
    return static_cast<int>(MQ_OK);
  });
}

int mq_torrent_read_piece(mq_session* s, char const* id, int32_t piece) {
  return guarded(nullptr, [&]() -> int {
    MQ_REQUIRE_TORRENT(h, s, id);
    auto ti = h.torrent_file();
    if (!ti) return static_cast<int>(MQ_ERR_NO_METADATA);
    if (piece < 0 || piece >= ti->num_pieces()) return static_cast<int>(MQ_ERR_INVALID);
    h.read_piece(lt::piece_index_t(piece));
    return static_cast<int>(MQ_OK);
  });
}

int mq_create_torrent(char const* path, int32_t piece_size, uint8_t** data_out, size_t* len_out,
                      char** error) {
  return guarded(error, [&]() -> int {
    if (!path || !data_out || !len_out) return static_cast<int>(MQ_ERR_INVALID);
    std::string full(path);
    while (full.size() > 1 && full.back() == '/') full.pop_back();
    lt::file_storage fs;
    lt::add_files(fs, full);
    if (fs.num_files() == 0) {
      set_error(error, "nothing to add to the torrent");
      return static_cast<int>(MQ_ERR_INVALID);
    }
    lt::create_torrent ct(fs, piece_size);
    lt::error_code ec;
    auto slash = full.find_last_of('/');
    std::string parent = slash == std::string::npos ? "." : (slash == 0 ? "/" : full.substr(0, slash));
    lt::set_piece_hashes(ct, parent, ec);
    if (ec) {
      set_error(error, ec.message());
      return static_cast<int>(MQ_ERR_LIBTORRENT);
    }
    std::vector<char> buf;
    lt::bencode(std::back_inserter(buf), ct.generate());
    auto* out = static_cast<uint8_t*>(std::malloc(buf.size()));
    if (!out) return static_cast<int>(MQ_ERR_LIBTORRENT);
    std::memcpy(out, buf.data(), buf.size());
    *data_out = out;
    *len_out = buf.size();
    return static_cast<int>(MQ_OK);
  });
}

char const* mq_libtorrent_version(void) { return LIBTORRENT_VERSION; }

void mq_free(void* pointer) { std::free(pointer); }

}  // extern "C"
