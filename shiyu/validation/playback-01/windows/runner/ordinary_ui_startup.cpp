#include "ordinary_ui_startup.h"
#include <windows.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>
#include <algorithm>
#include <iomanip>
#include <memory>
#include <optional>
#include <set>
#include <exception>
#include <sstream>
#include <utility>

namespace shiyu_ui {
namespace {
struct NativeError : PolicyError {
  std::string api; uint32_t code; bool ntstatus;
  NativeError(const char* name, uint32_t error, bool status = false)
      : PolicyError("native-validation-unconfirmed"), api(name), code(error), ntstatus(status) {}
};
void Need(bool value, const char* reason) { if (!value) throw PolicyError(reason); }
void Win(bool value, const char* api) { if (!value) throw NativeError(api, GetLastError()); }
using Cleanup = std::shared_ptr<std::vector<Json>>;
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  std::string name;
  Cleanup cleanup;
  bool attempted = false;
  Handle(HANDLE handle, std::string label, Cleanup facts) : value(handle), name(std::move(label)), cleanup(std::move(facts)) {}
  Handle(const Handle&) = delete;
  ~Handle() {
    if (!attempted && value != nullptr && value != INVALID_HANDLE_VALUE) {
      attempted = true;
      if (!CloseHandle(value)) cleanup->push_back(Json::Object({{u"api",Json::String(u"CloseHandle")},
          {u"resource",Json::String(U16(name))},{u"win32Code",Json::Integer(GetLastError())}}));
    }
  }
};
using Pin = std::shared_ptr<Handle>;
struct State {
  Options options;
  Cleanup cleanup = std::make_shared<std::vector<Json>>();
  std::vector<Pin> pins;
  std::wstring workspace, base, run, profile;
  std::string workspace_id, base_id, run_id, stdout_id, stderr_id;
  std::string sid, anchor_raw, intent_raw, gate_line;
  Json anchor, intent, context;
  bool window_recorded = false, loop_recorded = false;
  bool failed = false;
};
std::shared_ptr<State> active;
std::optional<Json> first_failure;
Cleanup failure_cleanup_source;
size_t failure_cleanup_seen = 0;
std::vector<Json> failure_cleanup;
constexpr uint64_t kMaxInteger = 9007199254740991ULL;
std::u16string U16Path(const std::wstring& path) { return std::u16string(path.begin(), path.end()); }
std::wstring Wide(const std::u16string& value) { return std::wstring(value.begin(), value.end()); }
std::string Hex64(uint64_t value) { std::ostringstream out; out << std::hex << std::setfill('0') << std::setw(16) << value; return out.str(); }
std::wstring Join(const std::wstring& parent, const std::wstring& leaf) { return parent + L"\\" + leaf; }
std::wstring Parent(const std::wstring& path) {
  auto at = path.find_last_of(L"\\"); Need(at != std::wstring::npos && at >= 2, "physical-parent");
  return path.substr(0, at);
}
std::wstring Leaf(const std::wstring& path) { return path.substr(path.find_last_of(L"\\") + 1); }
std::wstring CurrentDirectory() {
  auto length = GetCurrentDirectoryW(0, nullptr); Win(length > 0 && length <= 32768, "GetCurrentDirectoryW.size");
  std::vector<wchar_t> text(length); auto read = GetCurrentDirectoryW(length, text.data());
  Win(read > 0 && read < length, "GetCurrentDirectoryW"); return std::wstring(text.data(), read);
}
std::string FileIdentity(HANDLE file) {
  BY_HANDLE_FILE_INFORMATION info{}; Win(GetFileInformationByHandle(file, &info) != FALSE, "GetFileInformationByHandle");
  return Hex64(info.dwVolumeSerialNumber) + ':' + Hex64((static_cast<uint64_t>(info.nFileIndexHigh) << 32) | info.nFileIndexLow);
}
std::wstring Canonical(HANDLE file) {
  std::vector<wchar_t> text(32768);
  auto length = GetFinalPathNameByHandleW(file, text.data(), static_cast<DWORD>(text.size()), FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  Win(length > 0 && length < text.size(), "GetFinalPathNameByHandleW");
  std::wstring path(text.data(), length);
  if (path.compare(0, 4, L"\\\\?\\") == 0) path.erase(0, 4);
  Need(path.size() >= 3 && path[1] == L':' && path[2] == L'\\' && path[0] != L'\\', "physical-dos-required");
  length = GetLongPathNameW(path.c_str(), text.data(), static_cast<DWORD>(text.size()));
  Win(length > 0 && length < text.size(), "GetLongPathNameW");
  path.assign(text.data(), length);
  while (path.size() > 3 && path.back() == L'\\') path.pop_back();
  Need(ValidUtf16(U16Path(path)), "physical-utf16"); return path;
}
Pin OpenPlain(const std::wstring& path, bool directory, State& state, const char* label, bool read = false) {
  auto handle = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL | (read ? FILE_READ_DATA : 0),
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0), nullptr);
  if (handle == INVALID_HANDLE_VALUE) throw NativeError("CreateFileW.guard", GetLastError());
  auto pin = std::make_shared<Handle>(handle, label, state.cleanup);
  BY_HANDLE_FILE_INFORMATION info{}; Win(GetFileInformationByHandle(handle, &info) != FALSE, "GetFileInformationByHandle.guard");
  Need(!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) &&
      static_cast<bool>(info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == directory, "plain-kind-required");
  return pin;
}
void PlainAncestors(const std::wstring& path, State& state) {
  auto cursor = path;
  while (true) {
    auto pin = OpenPlain(cursor, true, state, "ancestor");
    if (cursor.size() == 3) break;
    cursor = Parent(cursor); if (cursor.size() == 2) cursor += L'\\';
  }
}
std::string SidText(PSID sid) {
  LPSTR text = nullptr; Win(ConvertSidToStringSidA(sid, &text) != FALSE, "ConvertSidToStringSidA");
  std::string value(text); LocalFree(text); return value;
}
std::string CurrentSid(State& state) {
  HANDLE token = nullptr; Win(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) != FALSE, "OpenProcessToken");
  auto owner = std::make_shared<Handle>(token, "current-token", state.cleanup);
  DWORD length = 0; GetTokenInformation(token, TokenUser, nullptr, 0, &length);
  DWORD error = GetLastError(); if (error != ERROR_INSUFFICIENT_BUFFER || length == 0 || length > 65536) throw NativeError("GetTokenInformation.size", error);
  std::vector<uint8_t> bytes(length); Win(GetTokenInformation(token, TokenUser, bytes.data(), length, &length) != FALSE, "GetTokenInformation");
  auto sid = SidText(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid);
  Need(sid != "S-1-5-18", "current-user-required"); return sid;
}
void Private(Pin pin, State& state, bool directory) {
  PSID owner = nullptr; PACL acl = nullptr; PSECURITY_DESCRIPTOR descriptor = nullptr;
  DWORD error = GetSecurityInfo(pin->value, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
      &owner, nullptr, &acl, nullptr, &descriptor);
  if (error != ERROR_SUCCESS) throw NativeError("GetSecurityInfo", error);
  try {
    Need(owner != nullptr && acl != nullptr && SidText(owner) == state.sid, "private-owner");
    SECURITY_DESCRIPTOR_CONTROL control{}; DWORD revision = 0;
    Win(GetSecurityDescriptorControl(descriptor, &control, &revision) != FALSE, "GetSecurityDescriptorControl");
    Need(!directory || (control & SE_DACL_PROTECTED), "private-protected-directory");
    Need(acl->AceCount == 2, "private-two-aces"); std::set<std::string> seen;
    for (DWORD i = 0; i < acl->AceCount; ++i) {
      void* raw = nullptr; Win(GetAce(acl, i, &raw) != FALSE, "GetAce");
      auto ace = static_cast<ACCESS_ALLOWED_ACE*>(raw);
      Need(ace->Header.AceType == ACCESS_ALLOWED_ACE_TYPE && ace->Mask == FILE_ALL_ACCESS, "private-ace-mask");
      auto sid = SidText(reinterpret_cast<PSID>(&ace->SidStart));
      Need((sid == state.sid || sid == "S-1-5-18") && seen.insert(sid).second, "private-ace-identity");
      Need(directory ? ace->Header.AceFlags == (OBJECT_INHERIT_ACE | CONTAINER_INHERIT_ACE) :
          (ace->Header.AceFlags & ~(INHERITED_ACE)) == 0, "private-ace-flags");
    }
  } catch (...) { LocalFree(descriptor); throw; }
  LocalFree(descriptor);
}
std::string Read(Pin pin, size_t maximum) {
  LARGE_INTEGER size{}; Win(GetFileSizeEx(pin->value, &size) != FALSE, "GetFileSizeEx");
  Need(size.QuadPart > 0 && static_cast<uint64_t>(size.QuadPart) <= maximum, "file-byte-bound");
  LARGE_INTEGER zero{}; Win(SetFilePointerEx(pin->value, zero, nullptr, FILE_BEGIN) != FALSE, "SetFilePointerEx");
  std::string raw(static_cast<size_t>(size.QuadPart), '\0'); DWORD count = 0;
  Win(ReadFile(pin->value, raw.data(), static_cast<DWORD>(raw.size()), &count, nullptr) != FALSE, "ReadFile");
  Need(count == raw.size(), "file-read-short"); return raw;
}
std::string Hash(const std::string& raw) {
  BCRYPT_ALG_HANDLE algorithm = nullptr; BCRYPT_HASH_HANDLE hash = nullptr;
  auto status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0);
  if (status < 0) throw NativeError("BCryptOpenAlgorithmProvider", static_cast<uint32_t>(status), true);
  try {
    status = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0);
    if (status < 0) throw NativeError("BCryptCreateHash", static_cast<uint32_t>(status), true);
    status = BCryptHashData(hash, reinterpret_cast<PUCHAR>(const_cast<char*>(raw.data())), static_cast<ULONG>(raw.size()), 0);
    if (status < 0) throw NativeError("BCryptHashData", static_cast<uint32_t>(status), true);
    uint8_t digest[32]{}; status = BCryptFinishHash(hash, digest, 32, 0);
    if (status < 0) throw NativeError("BCryptFinishHash", static_cast<uint32_t>(status), true);
    BCryptDestroyHash(hash); hash = nullptr; BCryptCloseAlgorithmProvider(algorithm, 0); algorithm = nullptr;
    std::ostringstream result; for (auto byte : digest) result << std::hex << std::setfill('0') << std::setw(2) << static_cast<unsigned>(byte);
    return result.str();
  } catch (...) { if (hash) BCryptDestroyHash(hash); if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0); throw; }
}
std::string Base64(const std::string& bytes) {
  constexpr char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::string out;
  for (size_t at = 0; at < bytes.size(); at += 3) {
    uint32_t word = static_cast<uint8_t>(bytes[at]) << 16;
    if (at + 1 < bytes.size()) word |= static_cast<uint8_t>(bytes[at + 1]) << 8;
    if (at + 2 < bytes.size()) word |= static_cast<uint8_t>(bytes[at + 2]);
    out += table[(word >> 18) & 63]; out += table[(word >> 12) & 63];
    out += at + 1 < bytes.size() ? table[(word >> 6) & 63] : '='; out += at + 2 < bytes.size() ? table[word & 63] : '=';
  }
  return out;
}
std::string ObjectName(HANDLE handle) {
  wchar_t value[256]{}; DWORD needed = 0;
  Win(GetUserObjectInformationW(handle, UOI_NAME, value, sizeof(value), &needed) != FALSE, "GetUserObjectInformationW");
  return Ascii(U16Path(value));
}
std::string InputName(State& state) {
  HANDLE input = OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS); Win(input != nullptr,"OpenInputDesktop");
  std::string name; std::exception_ptr primary;
  try { name = ObjectName(input); } catch (...) { primary = std::current_exception(); }
  if (!CloseDesktop(input)) {
    const DWORD error = GetLastError();
    if (!primary) throw NativeError("CloseDesktop.input-query",error);
    state.cleanup->push_back(Json::Object({{u"api",Json::String(u"CloseDesktop.input-query")},{u"win32Code",Json::Integer(error)}}));
  }
  if (primary) std::rethrow_exception(primary);
  return name;
}
uint32_t Access(HANDLE handle) {
  struct Basic { ULONG attributes, access, handles, pointers, reserved[10]; } info{};
  using Query = LONG(NTAPI*)(HANDLE, ULONG, void*, ULONG, ULONG*);
  HMODULE module = GetModuleHandleW(L"ntdll.dll"); Win(module != nullptr, "GetModuleHandleW.ntdll");
  auto query = reinterpret_cast<Query>(GetProcAddress(module, "NtQueryObject")); Win(query != nullptr, "GetProcAddress.NtQueryObject");
  ULONG returned = 0; LONG status = query(handle, 0, &info, sizeof(info), &returned);
  if (status < 0) throw NativeError("NtQueryObject", static_cast<uint32_t>(status), true);
  return info.access;
}
std::string ImageHash(State& state) {
  wchar_t image[32768]{}; DWORD length = GetModuleFileNameW(nullptr, image, 32768);
  Win(length > 0 && length < 32768, "GetModuleFileNameW");
  auto pin = OpenPlain(std::wstring(image, length), false, state, "image", true);
  return Hash(Read(pin, 64 * 1024 * 1024));
}
std::string CreationTime() {
  FILETIME created{}, exited{}, kernel{}, user{};
  Win(GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user) != FALSE, "GetProcessTimes.self");
  auto value = (static_cast<uint64_t>(created.dwHighDateTime) << 32) | created.dwLowDateTime;
  Need(value != 0, "process-creation-time"); return std::to_string(value);
}
void WriteLine(DWORD stream, const std::string& line) {
  Need(line.size() <= 4096, "phase-line-bound"); DWORD written = 0;
  HANDLE output = GetStdHandle(stream); Need(output && output != INVALID_HANDLE_VALUE, "inherited-log-required");
  Win(WriteFile(output, line.data(), static_cast<DWORD>(line.size()), &written, nullptr) != FALSE, "WriteFile.phase");
  Need(written == line.size(), "phase-write-short"); Win(FlushFileBuffers(output) != FALSE, "FlushFileBuffers.phase");
}
Json NativeFact(const NativeError& error) {
  return Json::Object({{u"api",Json::String(U16(error.api))},
      {error.ntstatus ? u"ntstatus" : u"win32Code",Json::Integer(error.code)}});
}
Json PolicyFact(const char* reason) {
  // Existing closed Win32-zero variant: the api namespace explicitly carries
  // policy, not a fabricated Win32 failure. No wire fields are added.
  return Json::Object({{u"api",Json::String(U16(std::string("Policy.") + reason))},
      {u"win32Code",Json::Integer(0)}});
}
void RecordFailure(const Json& fact, const Cleanup& cleanup) {
  if (active) active->failed = true; // Sticky before logging, even if the sink fails.
  if (!first_failure) first_failure = fact;
  if (cleanup) {
    if (failure_cleanup_source != cleanup) {
      failure_cleanup_source = cleanup; failure_cleanup_seen = 0;
    }
    for (; failure_cleanup_seen < cleanup->size(); ++failure_cleanup_seen)
      failure_cleanup.push_back(cleanup->at(failure_cleanup_seen));
  }
  try {
    auto record = *first_failure;
    if (record.object.count(u"hresult") == 0) {
      record.object[u"cleanupFailures"] = Json::Array(failure_cleanup);
    }
    WriteLine(STD_ERROR_HANDLE,"SHIYU_UI_FAILURE " + Canonical(record) + '\n');
    // The existing HRESULT wire shape has no cleanup field. If a later
    // cleanup exists, keep that shape and emit its secondary facts separately.
    if (record.object.count(u"hresult") && !failure_cleanup.empty()) {
      auto secondary = PolicyFact("secondary-cleanup");
      secondary.object[u"cleanupFailures"] = Json::Array(failure_cleanup);
      WriteLine(STD_ERROR_HANDLE,"SHIYU_UI_FAILURE " + Canonical(secondary) + '\n');
    }
  } catch (...) {} // Neither proof output loss nor later errors clear the first cause/sticky state.
}
template <class Read> std::string CaptureReadonlyFailure(Read read) {
  // Ordinary/unarmed calls remain unavailable without changing ordinary state.
  Need(active != nullptr,"validation-not-armed");
  try {
    Need(!active->failed,"native-readonly-after-failure");
    return read();
  } catch (const NativeError& error) {
    RecordFailure(NativeFact(error),active->cleanup); throw;
  } catch (const PolicyError& error) {
    RecordFailure(PolicyFact(error.what()),active->cleanup); throw;
  } catch (...) {
    RecordFailure(PolicyFact("readonly-unconfirmed"),active->cleanup); throw;
  }
}
std::string Phase(State& state, const char* phase, const Json& proof) {
  return "SHIYU_UI_PHASE " + Canonical(Json::Object({{u"phase",Json::String(U16(phase))},{u"context",state.context},{u"proof",proof}})) + '\n';
}
void Fresh(State& state) {
  SetLastError(0); auto attributes = GetFileAttributesW(state.profile.c_str());
  if (attributes != INVALID_FILE_ATTRIBUTES) throw PolicyError("fresh-profile-required");
  DWORD error = GetLastError(); Need(error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND, "profile-absence-unconfirmed");
  Need(PathBudget(U16Path(state.profile)), "physical-profile-budget");
}
std::shared_ptr<State> Validate(const Options& options, const std::shared_ptr<State>& state) {
  state->options = options; state->sid = CurrentSid(*state);
  auto raw_cwd = CurrentDirectory(); PlainAncestors(raw_cwd, *state);
  auto base = OpenPlain(raw_cwd, true, *state, "base"); state->base = Canonical(base->value);
  Need(Leaf(state->base) == L".ui-runs", "fixed-base-name"); state->base_id = FileIdentity(base->value); Private(base,*state,true); state->pins.push_back(base);
  state->workspace = Parent(state->base);
  auto workspace = OpenPlain(state->workspace, true, *state, "workspace"); state->workspace_id = FileIdentity(workspace->value); state->pins.push_back(workspace);
  auto anchor = OpenPlain(Join(state->base,L"anchor.m"), false,*state,"anchor",true); Private(anchor,*state,false);
  state->anchor_raw = Read(anchor,2048); state->anchor = ParseCanonical(state->anchor_raw,true,2048); ValidateAnchor(state->anchor);
  Need(Text(Field(state->anchor,u"ownerSid")) == U16(state->sid) && Text(Field(state->anchor,u"workspaceIdentity")) == U16(state->workspace_id) &&
      Text(Field(state->anchor,u"baseIdentity")) == U16(state->base_id) && Text(Field(state->anchor,u"workspacePath")) == U16Path(state->workspace) &&
      Text(Field(state->anchor,u"basePath")) == U16Path(state->base), "anchor-physical-mismatch"); state->pins.push_back(anchor);
  state->run = Join(state->base,Wide(U16(options.run))); state->profile = Join(state->run,L"profile");
  auto run = OpenPlain(state->run,true,*state,"run"); Need(Canonical(run->value) == state->run,"run-physical-mismatch"); Private(run,*state,true);
  state->run_id = FileIdentity(run->value); state->pins.push_back(run);
  auto intent = OpenPlain(Join(state->run,L"intent.json"),false,*state,"intent",true); Private(intent,*state,false);
  state->intent_raw = Read(intent,8192); state->intent = ParseCanonical(state->intent_raw,true,8192); ValidateIntent(state->intent,options); state->pins.push_back(intent);
  for (auto key : {u"ownerSid",u"workspaceIdentity",u"baseIdentity",u"bundleSha256",u"commonSha256"}) Need(Canonical(Field(state->intent,key)) == Canonical(Field(state->anchor,key)),"intent-anchor-mismatch");
  Need(Text(Field(state->intent,u"runIdentity")) == U16(state->run_id) && Text(Field(state->intent,u"anchorSha256")) == U16(Hash(state->anchor_raw)),"intent-physical-mismatch");
  auto out = OpenPlain(Join(state->run,L"stdout.log"),false,*state,"stdout"); auto err = OpenPlain(Join(state->run,L"stderr.log"),false,*state,"stderr");
  Private(out,*state,false); Private(err,*state,false); state->stdout_id = FileIdentity(out->value); state->stderr_id = FileIdentity(err->value);
  Need(state->stdout_id == Ascii(Text(Field(state->intent,u"stdoutIdentity"))) && state->stderr_id == Ascii(Text(Field(state->intent,u"stderrIdentity"))) &&
      FileIdentity(GetStdHandle(STD_OUTPUT_HANDLE)) == state->stdout_id && FileIdentity(GetStdHandle(STD_ERROR_HANDLE)) == state->stderr_id,"inherited-log-mismatch");
  state->pins.push_back(out); state->pins.push_back(err); Fresh(*state);
  auto desktop = GetThreadDesktop(GetCurrentThreadId()); Win(desktop != nullptr,"GetThreadDesktop");
  const auto station = ObjectName(GetProcessWindowStation());
  const auto actual_name = ObjectName(desktop); const auto input_name = InputName(*state);
  auto access = Access(desktop);
  Need(DesktopEvidence(options,station,actual_name,input_name,access),"desktop-access-or-name-policy");
  auto image = ImageHash(*state); Need(Text(Field(state->intent,u"imageSha256")) == U16(image),"image-mismatch");
  auto root_scope = Hash(Canonical(Json::Array({Json::String(u"ordinary-empty-scope:1"),Json::String(U16(state->sid)),Json::String(U16(state->workspace_id)),
      Json::String(U16(state->base_id)),Json::String(U16(state->run_id)),Json::String(U16Path(state->profile)),Json::String(U16(options.attempt))})));
  state->context = Json::Object({{u"protocol",Json::Integer(1)},{u"role",Json::String(u"ordinary-empty-ui")},{u"runId",Json::String(U16(options.run))},
      {u"attempt",Json::String(U16(options.attempt))},{u"desktopNonce",Json::String(U16(options.desktop))},{u"rootScope",Json::String(U16(root_scope))},
      {u"appPid",Json::Integer(GetCurrentProcessId())},{u"creationFileTime",Json::String(U16(CreationTime()))},{u"imageSha256",Json::String(U16(image))},
      {u"bundleSha256",Field(state->intent,u"bundleSha256")}});
  auto proof = Json::Object({{u"nativeTid",Json::Integer(GetCurrentThreadId())},{u"desktopName",Json::String(U16(options.desktop))},{u"station",Json::String(u"WinSta0")},
      {u"grantedAccess",Json::Integer(access)},{u"intentSha256",Json::String(U16(Hash(state->intent_raw)))},{u"workspaceIdentity",Json::String(U16(state->workspace_id))},
      {u"baseIdentity",Json::String(U16(state->base_id))},{u"runIdentity",Json::String(U16(state->run_id))},{u"stdoutIdentity",Json::String(U16(state->stdout_id))},{u"stderrIdentity",Json::String(U16(state->stderr_id))}});
  Need(state->cleanup->empty(),"prestartup-handle-cleanup-unconfirmed");
  state->gate_line = Phase(*state,"native-gate-accepted",proof); WriteLine(STD_OUTPUT_HANDLE,state->gate_line); return state;
}
void VerifyCurrent(State& state) {
  auto cwd = OpenPlain(CurrentDirectory(),true,state,"cwd-readback");
  Need(FileIdentity(cwd->value) == state.base_id && Canonical(cwd->value) == state.base,"cwd-changed");
  for (size_t index = 0; index < state.pins.size(); ++index) {
    const auto& pin = state.pins[index]; BY_HANDLE_FILE_INFORMATION info{};
    Win(GetFileInformationByHandle(pin->value,&info) != FALSE,"GetFileInformationByHandle.pin");
    Need(!(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT),"pin-reparse");
    // Workspace is an identity anchor, not a domain whose ACL we change or
    // pretend is private. All other retained domain/file pins are rechecked.
    if (index != 1) Private(pin,state,index == 0 || index == 3);
  }
  auto run = OpenPlain(state.run,true,state,"run-readback");
  Need(FileIdentity(run->value) == state.run_id && Canonical(run->value) == state.run,"run-changed");
  Private(run,state,true); Fresh(state);
}
}  // namespace

Options GuardNativeStartup(const std::vector<std::wstring>& args, bool parsed) {
#ifdef _DEBUG
  constexpr bool debug = true;
#else
  constexpr bool debug = false;
#endif
#if defined(SHIYU_UI_VALIDATION_ONLY) && SHIYU_UI_VALIDATION_ONLY
  constexpr bool only = true;
#else
  constexpr bool only = false;
#endif
  auto options = ParseOptions(args,parsed,debug,only);
  if (options.mode == Mode::rejected) {
    RecordFailure(PolicyFact(options.error.c_str()),nullptr); return options;
  }
  if (options.mode == Mode::ordinary) return options;
  auto pending = std::make_shared<State>();
  try { Need(!active,"startup-twice"); active = Validate(options,pending); }
  catch (const NativeError& error) {
    pending->pins.clear(); options.mode = Mode::rejected; options.error = error.api;
    RecordFailure(NativeFact(error),pending->cleanup);
  }
  catch (const PolicyError& error) { pending->pins.clear(); options.mode = Mode::rejected; options.error = error.what(); RecordFailure(PolicyFact(error.what()),pending->cleanup); }
  catch (...) { pending->pins.clear(); options.mode = Mode::rejected; options.error = "native-guard-unconfirmed"; RecordFailure(PolicyFact("native-guard-unconfirmed"),pending->cleanup); }
  return options;
}
bool ValidationArmed() { return active != nullptr; }
void NativeStartupFailure(const char* api, uint32_t code, bool hresult) {
  RecordFailure(Json::Object({{u"api",Json::String(U16(api))},
      {hresult ? u"hresult" : u"win32Code",Json::Integer(code)}}),active ? active->cleanup : nullptr);
}
void NativeWindowCreated(uintptr_t hwnd, uint32_t tid) {
  if (!active) return; Need(!active->window_recorded && hwnd > 0 && hwnd <= kMaxInteger && tid > 0,"native-window-identity");
  DWORD pid = 0; const auto actual_tid = GetWindowThreadProcessId(reinterpret_cast<HWND>(hwnd),&pid);
  Win(actual_tid != 0,"GetWindowThreadProcessId.main");
  wchar_t window_class[256]{}; Win(GetClassNameW(reinterpret_cast<HWND>(hwnd),window_class,256) > 0,"GetClassNameW.main");
  Need(pid == GetCurrentProcessId() && tid == GetCurrentThreadId() && actual_tid == tid &&
      std::wstring(window_class) == L"FLUTTER_RUNNER_WIN32_WINDOW","native-main-owner");
  WriteLine(STD_OUTPUT_HANDLE,Phase(*active,"native-window-created",Json::Object({{u"mainHwnd",Json::Integer(hwnd)},{u"mainTid",Json::Integer(tid)},
      {u"windowClass",Json::String(u"FLUTTER_RUNNER_WIN32_WINDOW")}}))); active->window_recorded = true;
}
void NativeLoopEnded(uintptr_t hwnd, int message_result) {
  if (!active) return; Need(!active->failed && active->window_recorded && !active->loop_recorded && message_result == 0 && hwnd > 0 && hwnd <= kMaxInteger && !IsWindow(reinterpret_cast<HWND>(hwnd)),"native-loop-terminal-unconfirmed");
  WriteLine(STD_OUTPUT_HANDLE,Phase(*active,"native-loop-ended",Json::Object({{u"mainHwnd",Json::Integer(hwnd)},{u"mainAbsent",Json::Boolean(true)},{u"messageLoopExit",Json::Integer(0)}}))); active->loop_recorded = true;
}
static std::string ReadStartupValidationProofBody() {
  Need(active != nullptr,"validation-not-armed"); auto& state = *active; VerifyCurrent(state);
  auto anchor = OpenPlain(Join(state.base,L"anchor.m"),false,state,"anchor-readback",true); Private(anchor,state,false);
  auto intent = OpenPlain(Join(state.run,L"intent.json"),false,state,"intent-readback",true); Private(intent,state,false);
  Need(Read(anchor,2048) == state.anchor_raw && Read(intent,8192) == state.intent_raw,"startup-proof-files-changed");
  auto out = OpenPlain(Join(state.run,L"stdout.log"),false,state,"stdout-readback",true); Private(out,state,false);
  Need(FileIdentity(out->value) == state.stdout_id,"startup-proof-stdout-changed");
  const auto raw = Read(out,262144); Need(raw.find(state.gate_line) != std::string::npos && raw.find(state.gate_line,raw.find(state.gate_line) + 1) == std::string::npos,"native-original-line-missing-or-duplicate");
  const auto result = Canonical(Json::Object({{u"protocol",Json::Integer(1)},{u"c0",state.context},{u"workspacePath",Json::String(U16Path(state.workspace))},
      {u"basePath",Json::String(U16Path(state.base))},{u"runPath",Json::String(U16Path(state.run))},{u"profilePath",Json::String(U16Path(state.profile))},
      {u"workspaceIdentity",Json::String(U16(state.workspace_id))},{u"baseIdentity",Json::String(U16(state.base_id))},{u"runIdentity",Json::String(U16(state.run_id))},
      {u"stdoutIdentity",Json::String(U16(state.stdout_id))},{u"stderrIdentity",Json::String(U16(state.stderr_id))},{u"ownerSid",Json::String(U16(state.sid))},
      {u"cwdMatches",Json::Boolean(true)},{u"plain",Json::Boolean(true)},{u"private",Json::Boolean(true)},{u"profileAbsent",Json::Boolean(true)},
      {u"anchorRawBase64",Json::String(U16(Base64(state.anchor_raw)))},{u"intentRawBase64",Json::String(U16(Base64(state.intent_raw)))},{u"nativeGateLineRawBase64",Json::String(U16(Base64(state.gate_line)))}}));
  anchor.reset(); intent.reset(); out.reset(); Need(state.cleanup->empty(),"readonly-close-unconfirmed"); return result;
}
static std::string ReadStartupCloseGrantProofBody() {
  Need(active != nullptr,"validation-not-armed"); auto& state = *active;
  auto run = OpenPlain(state.run,true,state,"grant-run"); Need(FileIdentity(run->value) == state.run_id,"grant-run-changed"); Private(run,state,true);
  auto grant = OpenPlain(Join(state.run,L"close.grant"),false,state,"close-grant",true); Private(grant,state,false);
  auto raw = Read(grant,4096); ParseCanonical(raw,true,4096);
  const auto result = Canonical(Json::Object({{u"protocol",Json::Integer(1)},{u"attempt",Json::String(U16(state.options.attempt))},{u"rootScope",Field(state.context,u"rootScope")},
      {u"runIdentity",Json::String(U16(state.run_id))},{u"fileIdentity",Json::String(U16(FileIdentity(grant->value)))},{u"plain",Json::Boolean(true)},
      {u"private",Json::Boolean(true)},{u"ownerMatches",Json::Boolean(true)},{u"rawBase64",Json::String(U16(Base64(raw)))}}));
  grant.reset(); run.reset(); Need(state.cleanup->empty(),"readonly-close-unconfirmed"); return result;
}
std::string ReadStartupValidationProof() {
  return CaptureReadonlyFailure([] { return ReadStartupValidationProofBody(); });
}
std::string ReadStartupCloseGrantProof() {
  return CaptureReadonlyFailure([] { return ReadStartupCloseGrantProofBody(); });
}
}  // namespace shiyu_ui
