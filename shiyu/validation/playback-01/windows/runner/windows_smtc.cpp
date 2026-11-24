#include "windows_smtc.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <SystemMediaTransportControlsInterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>

#include <algorithm>
#include <cstdint>
#include <deque>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <stdexcept>
#include <variant>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Media;
constexpr UINT kDrainCommands = WM_APP + 0x350;
constexpr char kChannel[] = "shiyu/windows_playback_host";

const EncodableValue* Field(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}
std::optional<int64_t> Number(const EncodableValue* value) {
  if (!value) return std::nullopt;
  if (const auto* v = std::get_if<int32_t>(value)) return *v;
  if (const auto* v = std::get_if<int64_t>(value)) return *v;
  return std::nullopt;
}
std::optional<std::string> Text(const EncodableValue* value) {
  if (!value) return std::nullopt;
  if (const auto* v = std::get_if<std::string>(value)) return *v;
  return std::nullopt;
}
bool Flag(const EncodableMap& map, const char* key) {
  const auto* value = Field(map, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

struct Scope {
  std::string owner, item, revision;
  int64_t generation = 0, epoch = 0;
  bool operator==(const Scope& other) const {
    return owner == other.owner && item == other.item &&
        revision == other.revision && generation == other.generation && epoch == other.epoch;
  }
  static std::optional<Scope> Parse(const EncodableValue* value) {
    const auto* map = value ? std::get_if<EncodableMap>(value) : nullptr;
    if (!map) return std::nullopt;
    const auto owner = Text(Field(*map, "ownerId"));
    const auto item = Text(Field(*map, "itemId"));
    const auto revision = Text(Field(*map, "itemRevision"));
    const auto generation = Number(Field(*map, "generation"));
    const auto epoch = Number(Field(*map, "commandEpoch"));
    if (!owner || !item || !revision || !generation || !epoch) {
      return std::nullopt;
    }
    return Scope{*owner, *item, *revision, *generation, *epoch};
  }
  EncodableMap Encode() const {
    return {{EncodableValue("ownerId"), EncodableValue(owner)},
            {EncodableValue("itemId"), EncodableValue(item)},
            {EncodableValue("itemRevision"), EncodableValue(revision)},
            {EncodableValue("generation"), EncodableValue(generation)},
            {EncodableValue("commandEpoch"), EncodableValue(epoch)}};
  }
};
struct NativeCommand {
  std::string action;
  Scope scope;
  int64_t position_ms = 0;
};
struct CallbackState {
  std::mutex mutex;
  bool alive = true;
  HWND window = nullptr;
  bool allow_play = false, allow_pause = false, allow_stop = false,
       allow_seek = false;
  std::optional<Scope> scope;
  uint64_t registration = 0;
  std::deque<NativeCommand> queue;
};

void Enqueue(const std::weak_ptr<CallbackState>& weak, uint64_t registration, std::string action,
             int64_t position_ms = 0) noexcept {
  try {
    const auto state = weak.lock();
    if (!state) return;
    HWND window = nullptr;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->alive || !state->scope || state->registration != registration) return;
      if ((action == "play" && !state->allow_play) ||
          (action == "pause" && !state->allow_pause) ||
          (action == "stop" && !state->allow_stop) ||
          (action == "seek" && !state->allow_seek)) return;
      NativeCommand command{action, *state->scope, position_ms};
      if (action == "stop") {
        state->queue.clear();
        state->queue.push_front(std::move(command));
      } else {
        if (action == "seek") {
          state->queue.erase(std::remove_if(state->queue.begin(), state->queue.end(),
              [](const NativeCommand& queued) { return queued.action == "seek"; }),
              state->queue.end());
        }
        if (state->queue.size() >= 64) return;
        state->queue.push_back(std::move(command));
      }
      window = state->window;
    }
    // No pointer in w/lParam. A forged message can only drain our own queue.
    if (window && IsWindow(window)) PostMessage(window, kDrainCommands, 0, 0);
  } catch (...) {
    // A WinRT callback must never unwind into the native event source.
  }
}
}  // namespace

struct WindowsSmtc::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  std::shared_ptr<CallbackState> callbacks = std::make_shared<CallbackState>();
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_token{}, position_token{};
  bool ro_initialized = false, button_registered = false,
       position_registered = false, stopped = false,
       client_ready = false, enabled = false, suspended = false,
       close_pending = false, close_ready = false;
  int64_t close_ticket = 0;

  Impl(HWND hwnd, flutter::BinaryMessenger* messenger) : window(hwnd) {
    callbacks->window = window;
    channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, kChannel, &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call, auto result) {
      HandleCall(call, std::move(result));
    });
  }

  bool Bind() {
    if (stopped || !IsWindow(window)) return false;
    if (controls) return true;
    if (!ro_initialized) {
      const auto hr = RoInitialize(RO_INIT_SINGLETHREADED);
      if (FAILED(hr)) return false;
      ro_initialized = true;
    }
    try {
      const auto factory = winrt::get_activation_factory<
          SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(factory->GetForWindow(
          window, winrt::guid_of<SystemMediaTransportControls>(),
          winrt::put_abi(controls)));
      controls.IsEnabled(false);
      return true;
    } catch (...) {
      Revoke();
      return false;
    }
  }

  void RegisterCallbacks(uint64_t registration) {
      UnregisterCallbacks();
      const std::weak_ptr<CallbackState> weak = callbacks;
      button_token = controls.ButtonPressed([weak, registration](auto const&, auto const& args) {
        try {
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play: Enqueue(weak, registration, "play"); break;
            case SystemMediaTransportControlsButton::Pause: Enqueue(weak, registration, "pause"); break;
            case SystemMediaTransportControlsButton::Stop: Enqueue(weak, registration, "stop"); break;
            default: break; // Record/other controls cannot start capture.
          }
        } catch (...) {}
      });
      button_registered = true;
      position_token = controls.PlaybackPositionChangeRequested(
          [weak, registration](auto const&, auto const& args) {
            try {
              const auto ticks = args.RequestedPlaybackPosition().count();
              if (ticks >= 0) Enqueue(weak, registration, "seek", ticks / 10000);
            } catch (...) {}
          });
      position_registered = true;
  }

  void UnregisterCallbacks() noexcept {
    if (controls) {
      if (button_registered) {
        try { controls.ButtonPressed(button_token); } catch (...) {}
      }
      if (position_registered) {
        try { controls.PlaybackPositionChangeRequested(position_token); } catch (...) {}
      }
    }
    button_registered = false;
    position_registered = false;
  }

  void Revoke() noexcept {
    UnregisterCallbacks();
    if (controls) {
      try { controls.IsEnabled(false); } catch (...) {}
      controls = nullptr;
    }
    enabled = false;
  }

  EncodableMap Status() {
    bool bound = false;
    bool generic_metadata = false, metadata_cleared = false, metadata_read = false;
    int32_t metadata_error = 0;
    int32_t playback_status = 0;
    try {
      if (!stopped && IsWindow(window) && controls) {
        const auto actual_enabled = controls.IsEnabled();
        playback_status = static_cast<int32_t>(controls.PlaybackStatus());
        enabled = actual_enabled;
        bound = true;
        try {
          const auto updater = controls.DisplayUpdater();
          const auto music = updater.MusicProperties();
          const auto title = music.Title();
          const auto artist = music.Artist();
          const auto album = music.AlbumTitle();
          const auto app_media_id = updater.AppMediaId();
          const bool no_thumbnail = !updater.Thumbnail();
          metadata_read = true;
          generic_metadata = title == L"拾语音频" && artist == L"拾语" &&
              album.empty() && app_media_id.empty() && no_thumbnail;
          metadata_cleared = title.empty() && artist.empty() && album.empty() &&
              app_media_id.empty() && no_thumbnail;
        } catch (const winrt::hresult_error& error) {
          metadata_error = error.code().value;
        } catch (...) {
          metadata_error = -1;
        }
      }
    } catch (...) { bound = false; }
    return {{EncodableValue("configured"), EncodableValue(bound)},
            {EncodableValue("windowAlive"), EncodableValue(!stopped && IsWindow(window) != FALSE)},
            {EncodableValue("windowVisible"), EncodableValue(IsWindowVisible(window) != FALSE)},
            {EncodableValue("windowFocused"), EncodableValue(GetForegroundWindow() == window)},
            {EncodableValue("genericMetadata"), EncodableValue(generic_metadata)},
            {EncodableValue("metadataCleared"), EncodableValue(metadata_cleared)},
            {EncodableValue("metadataReadable"), EncodableValue(metadata_read)},
            {EncodableValue("metadataErrorCode"), EncodableValue(metadata_error)},
            {EncodableValue("playbackStatus"), EncodableValue(playback_status)},
            {EncodableValue("enabled"), EncodableValue(bound && enabled)},
            {EncodableValue("suspended"), EncodableValue(suspended)},
            {EncodableValue("foreground"), EncodableValue(GetForegroundWindow() == window)}};
  }

  void Retire() noexcept {
    {
      std::lock_guard<std::mutex> lock(callbacks->mutex);
      callbacks->scope.reset();
      ++callbacks->registration;
      callbacks->queue.clear();
      callbacks->allow_play = callbacks->allow_pause =
          callbacks->allow_stop = callbacks->allow_seek = false;
    }
    UnregisterCallbacks();
    if (controls) {
      try {
        controls.IsPlayEnabled(false);
        controls.IsPauseEnabled(false);
        controls.IsStopEnabled(false);
        controls.PlaybackStatus(MediaPlaybackStatus::Stopped);
        controls.IsEnabled(false);
        auto updater = controls.DisplayUpdater();
        updater.ClearAll();
        updater.Type(MediaPlaybackType::Music);
        // ClearAll clears publication flags; clear typed property values too,
        // so no stale metadata survives a later reuse or property readback.
        updater.MusicProperties().Title(L"");
        updater.MusicProperties().Artist(L"");
        updater.MusicProperties().AlbumTitle(L"");
        updater.AppMediaId(L"");
        updater.Thumbnail(nullptr);
        updater.Update();
      } catch (...) {}
    }
    enabled = false;
  }

  void Publish(const EncodableMap& data) {
    if (!controls || stopped || !IsWindow(window)) {
      throw std::runtime_error("smtc_unavailable");
    }
    const auto scope = Scope::Parse(Field(data, "scope"));
    if (!scope) throw std::runtime_error("invalid_scope");
    const bool active = Flag(data, "enabled");
    const bool can_play = active && Flag(data, "allowPlay");
    const bool can_pause = active && Flag(data, "allowPause");
    const bool can_stop = active && Flag(data, "allowStop");
    bool changed_scope = false;
    uint64_t registration = 0;
    {
      std::lock_guard<std::mutex> lock(callbacks->mutex);
      changed_scope = !callbacks->scope || !(*callbacks->scope == *scope);
      if (changed_scope) {
        ++callbacks->registration;
        callbacks->queue.clear();
      }
      registration = callbacks->registration;
      callbacks->scope = scope;
      callbacks->allow_play = can_play;
      callbacks->allow_pause = can_pause;
      callbacks->allow_stop = can_stop;
      callbacks->allow_seek = active && Flag(data, "allowSeek");
    }
    // Pin each callback registration to its original published scope. A late
    // callback from A cannot read B's scope and masquerade as a new command.
    if (changed_scope) RegisterCallbacks(registration);
    auto updater = controls.DisplayUpdater();
    updater.ClearAll();
    updater.Type(MediaPlaybackType::Music);
    updater.MusicProperties().Title(L"拾语音频");
    updater.MusicProperties().Artist(L"拾语");
    updater.Update();
    controls.IsPlayEnabled(can_play);
    controls.IsPauseEnabled(can_pause);
    controls.IsStopEnabled(can_stop);
    controls.IsRecordEnabled(false);
    controls.IsNextEnabled(false);
    controls.IsPreviousEnabled(false);
    controls.IsFastForwardEnabled(false);
    controls.IsRewindEnabled(false);
    const auto status = Text(Field(data, "actual"));
    const bool really_playing = Flag(data, "reallyPlaying");
    controls.PlaybackStatus(!Flag(data, "engineAvailable") ? MediaPlaybackStatus::Changing
        : really_playing ? MediaPlaybackStatus::Playing
        : status == "paused" ? MediaPlaybackStatus::Paused
        : status == "idle" || status == "ended" ? MediaPlaybackStatus::Stopped
        : MediaPlaybackStatus::Changing);
    const int64_t max_ms = std::numeric_limits<int64_t>::max() / 10000;
    auto position = Number(Field(data, "positionMs")).value_or(0);
    auto duration = Number(Field(data, "durationMs")).value_or(0);
    duration = std::clamp<int64_t>(duration, 0, max_ms);
    position = std::clamp<int64_t>(position, 0, duration);
    SystemMediaTransportControlsTimelineProperties timeline;
    timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.EndTime(winrt::Windows::Foundation::TimeSpan{duration * 10000});
    timeline.MinSeekTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.MaxSeekTime(winrt::Windows::Foundation::TimeSpan{duration * 10000});
    timeline.Position(winrt::Windows::Foundation::TimeSpan{position * 10000});
    controls.UpdateTimelineProperties(timeline);
    controls.IsEnabled(active);
    enabled = active;
  }

  // Both call sites run on this HWND's owning UI thread. Never accept a
  // caller-supplied ticket or wrap the monotonically increasing native value.
  std::optional<int64_t> EnsureCloseTicket() noexcept {
    if (stopped || !client_ready || close_ready || !IsWindow(window)) {
      return std::nullopt;
    }
    if (!close_pending) {
      if (close_ticket == std::numeric_limits<int64_t>::max()) {
        return std::nullopt;
      }
      ++close_ticket;
      close_pending = true;
    }
    return close_ticket;
  }

  void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    try {
      const auto* data = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
      if (call.method_name() == "create") {
        client_ready = true;
        (void)Bind();
        result->Success(EncodableValue(Status()));
      } else if (call.method_name() == "hostStatus") {
        result->Success(EncodableValue(Status()));
      } else if (call.method_name() == "publish") {
        if (!data) { result->Error("invalid_arguments"); return; }
        Publish(*data);
        result->Success(EncodableValue(Status()));
      } else if (call.method_name() == "retire") {
        Retire();
        result->Success();
      } else if (call.method_name() == "beginProgrammaticClose") {
        if (stopped || !client_ready || close_ready || !IsWindow(window)) {
          result->Error("close_unavailable"); return;
        }
        if (!close_pending && close_ticket == std::numeric_limits<int64_t>::max()) {
          result->Error("close_ticket_exhausted"); return;
        }
        const auto ticket = EnsureCloseTicket();
        if (!ticket) { result->Error("close_unavailable"); return; }
        result->Success(EncodableValue(EncodableMap{
            {EncodableValue("ticket"), EncodableValue(*ticket)}}));
      } else if (call.method_name() == "detachDrainedFailedStartup") {
        if (stopped || !client_ready || close_ready || !IsWindow(window)) {
          result->Error("close_unavailable"); return;
        }
        // Explicit AppOwner failed-startup cleanup boundary only. Generic
        // Retire/Stop must retain the ordinary WM_CLOSE safety handshake.
        Retire();
        client_ready = false;
        close_pending = false;
        result->Success();
      } else if (call.method_name() == "closeReady") {
        const auto ticket = data ? Number(Field(*data, "ticket")) : std::nullopt;
        if (!close_pending || !ticket || *ticket != close_ticket || !IsWindow(window)) {
          result->Error("close_not_pending"); return;
        }
        Retire();
        close_ready = true;
        close_pending = false;
        if (!PostMessage(window, WM_CLOSE, 0, 0)) {
          close_ready = false;
          result->Error("close_post_failed"); return;
        }
        result->Success();
      } else if (call.method_name() == "cancelClose") {
        const auto ticket = data ? Number(Field(*data, "ticket")) : std::nullopt;
        const bool cancelled = ticket && *ticket == close_ticket && !close_ready;
        if (cancelled) close_pending = false;
        result->Success(EncodableValue(EncodableMap{
            {EncodableValue("cancelled"), EncodableValue(cancelled)}}));
      } else {
        result->NotImplemented();
      }
    } catch (...) {
      result->Error("smtc_unavailable", "Windows media binding is unavailable.");
    }
  }

  void Drain() {
    std::deque<NativeCommand> queue;
    {
      std::lock_guard<std::mutex> lock(callbacks->mutex);
      if (!callbacks->alive) return;
      queue.swap(callbacks->queue);
    }
    for (const auto& command : queue) {
      if (stopped || !client_ready || !IsWindow(window)) return;
      EncodableMap args{{EncodableValue("action"), EncodableValue(command.action)},
                        {EncodableValue("scope"), EncodableValue(command.scope.Encode())},
                        {EncodableValue("positionMs"), EncodableValue(command.position_ms)}};
      // Only reached from our owning HWND's UI message handler.
      channel->InvokeMethod("systemCommand", std::make_unique<EncodableValue>(args));
    }
  }

  bool Handle(HWND hwnd, UINT message, LRESULT* result) {
    if (stopped || hwnd != window) return false;
    if (message == kDrainCommands) { Drain(); *result = 0; return true; }
    if (message == WM_CLOSE && client_ready && !close_ready) {
      if (!close_pending) {
        // Exhaustion must keep the gate closed; never let the outer
        // exception fallback dispatch WM_CLOSE to DefWindowProc.
        if (close_ticket == std::numeric_limits<int64_t>::max()) {
          *result = 0;
          return true;
        }
        const auto ticket = EnsureCloseTicket();
        if (!ticket) { *result = 0; return true; }
        channel->InvokeMethod("windowCloseRequested", std::make_unique<EncodableValue>(
            EncodableMap{{EncodableValue("ticket"), EncodableValue(*ticket)}}));
      }
      *result = 0;
      return true;
    }
    return false;
  }

  void Power(WPARAM event) {
    if (stopped || !client_ready) return;
    if (event == PBT_APMSUSPEND) {
      suspended = true;
      channel->InvokeMethod("suspended", nullptr);
    } else if (event == PBT_APMRESUMEAUTOMATIC || event == PBT_APMRESUMESUSPEND) {
      suspended = false;
      channel->InvokeMethod("resumed", nullptr);
    }
  }

  void Shutdown() noexcept {
    if (stopped) return;
    stopped = true;
    {
      std::lock_guard<std::mutex> lock(callbacks->mutex);
      callbacks->alive = false;
      callbacks->window = nullptr;
      callbacks->queue.clear();
      callbacks->scope.reset();
    }
    Revoke();
    if (channel) channel->SetMethodCallHandler(nullptr);
    channel.reset();
    if (ro_initialized) { RoUninitialize(); ro_initialized = false; }
  }
};

WindowsSmtc::WindowsSmtc(HWND window, flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(window, messenger)) {}
WindowsSmtc::~WindowsSmtc() { Shutdown(); }
void WindowsSmtc::Shutdown() noexcept { if (impl_) impl_->Shutdown(); }
bool WindowsSmtc::HandleMessage(HWND window, UINT message, WPARAM wparam,
                                LPARAM, LRESULT* result) noexcept {
  try {
    if (!impl_) return false;
    if (message == WM_POWERBROADCAST) impl_->Power(wparam);
    return impl_->Handle(window, message, result);
  } catch (...) { return false; }
}
