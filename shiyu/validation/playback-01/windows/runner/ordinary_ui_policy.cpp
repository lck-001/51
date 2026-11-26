#include "ordinary_ui_policy.h"
#include <algorithm>
#include <limits>
#include <regex>
#include <set>

namespace shiyu_ui {
namespace {
constexpr uint64_t kMaximum = 9007199254740991ULL;
void Require(bool ok, const char* code) { if (!ok) throw PolicyError(code); }
bool Prefix(const std::wstring& value, const wchar_t* prefix) {
  return value.compare(0, std::wstring(prefix).size(), prefix) == 0;
}
std::string Narrow(const std::wstring& value) {
  std::string result;
  for (wchar_t ch : value) { Require(static_cast<uint32_t>(ch) <= 127, "non-ascii-option"); result.push_back(static_cast<char>(ch)); }
  return result;
}
void HashField(const Json& value, const char16_t* field) { Require(LowerHex(Ascii(Text(Field(value, field))), 64), "hash-shape"); }
void IdentityField(const Json& value, const char16_t* field) { Require(Identity(Text(Field(value, field))), "identity-shape"); }
std::string Quote(const std::u16string& value) {
  Require(ValidUtf16(value), "invalid-utf16");
  constexpr char hex[] = "0123456789abcdef";
  std::string result = "\"";
  for (char16_t ch : value) {
    switch (ch) {
      case u'"': result += "\\\""; break; case u'\\': result += "\\\\"; break;
      case u'\b': result += "\\b"; break; case u'\f': result += "\\f"; break;
      case u'\n': result += "\\n"; break; case u'\r': result += "\\r"; break; case u'\t': result += "\\t"; break;
      default:
        if (ch < 32 || ch > 126) {
          result += "\\u";
          for (int shift = 12; shift >= 0; shift -= 4) result += hex[(ch >> shift) & 15];
        } else result += static_cast<char>(ch);
    }
  }
  return result + '"';
}
class Parser {
 public:
  explicit Parser(const std::string& input) : input_(input) {}
  Json Parse() { auto value = Value(0); Require(at_ == input_.size(), "json-trailing"); return value; }
 private:
  const std::string& input_; size_t at_ = 0;
  char Next() { Require(at_ < input_.size(), "json-eof"); return input_[at_++]; }
  char Peek() const { Require(at_ < input_.size(), "json-eof"); return input_[at_]; }
  unsigned Hex() {
    const char ch = Next();
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    throw PolicyError("json-hex");
  }
  std::u16string String() {
    Require(Next() == '"', "json-string"); std::u16string result;
    while (true) {
      char ch = Next(); if (ch == '"') break;
      Require(static_cast<unsigned char>(ch) >= 32 && static_cast<unsigned char>(ch) <= 126, "json-ascii");
      if (ch != '\\') { result += static_cast<char16_t>(ch); continue; }
      switch (Next()) {
        case '"': result += u'"'; break; case '\\': result += u'\\'; break;
        case 'b': result += u'\b'; break; case 'f': result += u'\f'; break; case 'n': result += u'\n'; break;
        case 'r': result += u'\r'; break; case 't': result += u'\t'; break;
        case 'u': { unsigned code = 0; for (int i = 0; i < 4; ++i) code = code * 16 + Hex(); result += static_cast<char16_t>(code); break; }
        default: throw PolicyError("json-escape");
      }
    }
    Require(ValidUtf16(result), "invalid-utf16"); return result;
  }
  Json Value(unsigned depth) {
    Require(depth <= 8, "json-depth"); char ch = Peek();
    if (ch == '"') return Json::String(String());
    if (ch == '{') {
      Next(); Json result;
      if (Peek() == '}') { Next(); return result; }
      do {
        auto key = String(); Require(Next() == ':', "json-colon");
        Require(result.object.emplace(key, Value(depth + 1)).second, "json-duplicate-key");
        ch = Next(); if (ch == '}') return result; Require(ch == ',', "json-comma");
      } while (true);
    }
    if (ch == '[') {
      Next(); std::vector<Json> values;
      if (Peek() == ']') { Next(); return Json::Array(values); }
      do { values.push_back(Value(depth + 1)); ch = Next(); if (ch == ']') return Json::Array(values); Require(ch == ',', "json-comma"); } while (true);
    }
    if (ch == 't' || ch == 'f') {
      const std::string word = ch == 't' ? "true" : "false";
      Require(input_.compare(at_, word.size(), word) == 0, "json-bool"); at_ += word.size(); return Json::Boolean(ch == 't');
    }
    Require(ch >= '0' && ch <= '9', "json-type"); uint64_t number = 0; size_t begin = at_;
    while (at_ < input_.size() && input_[at_] >= '0' && input_[at_] <= '9') {
      const unsigned digit = input_[at_++] - '0'; Require(number <= (kMaximum - digit) / 10, "json-integer-bound"); number = number * 10 + digit;
    }
    Require(at_ - begin == 1 || input_[begin] != '0', "json-leading-zero"); return Json::Integer(number);
  }
};
}  // namespace

Json Json::String(const std::u16string& value) { Json j; j.kind = Kind::string; j.text = value; return j; }
Json Json::Integer(uint64_t value) { Require(value <= kMaximum, "json-integer-bound"); Json j; j.kind = Kind::integer; j.integer = value; return j; }
Json Json::Boolean(bool value) { Json j; j.kind = Kind::boolean; j.boolean = value; return j; }
Json Json::Object(std::initializer_list<std::pair<const std::u16string, Json>> values) { Json j; j.object = values; return j; }
Json Json::Array(const std::vector<Json>& values) { Json j; j.kind = Kind::array; j.array = values; return j; }
bool LowerHex(const std::string& value, size_t length) { return value.size() == length && std::all_of(value.begin(), value.end(), [](char ch) { return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'); }); }
bool Identity(const std::u16string& value) { auto s = Ascii(value); return s.size() == 33 && s[16] == ':' && LowerHex(s.substr(0, 16), 16) && LowerHex(s.substr(17), 16); }
bool Decimal(const std::u16string& value) { return !value.empty() && value[0] >= u'1' && value[0] <= u'9' && std::all_of(value.begin(), value.end(), [](char16_t ch) { return ch >= u'0' && ch <= u'9'; }); }
bool ValidUtf16(const std::u16string& value) {
  for (size_t i = 0; i < value.size(); ++i) {
    if (value[i] >= 0xd800 && value[i] <= 0xdbff) { if (++i >= value.size() || value[i] < 0xdc00 || value[i] > 0xdfff) return false; }
    else if (value[i] >= 0xdc00 && value[i] <= 0xdfff) return false;
  }
  return true;
}
bool PathBudget(const std::u16string& profile) { return ValidUtf16(profile) && profile.size() <= 104 && profile.size() + 155 <= 259; }
bool SafeDesktopAccess(uint32_t mask) { return (mask & 0x83) == 0x83 && (mask & ~0x20087u) == 0; }
bool DesktopEvidence(const Options& options, const std::string& station,
                     const std::string& desktop, const std::string& input,
                     uint32_t access) {
  return options.mode == Mode::validation && station == "WinSta0" && desktop == options.desktop &&
      !input.empty() && input != desktop && SafeDesktopAccess(access);
}
Options ParseOptions(const std::vector<std::wstring>& args, bool parsed, bool debug, bool validation_only) {
  Options result;
  try {
    Require(parsed, "command-line-parse-failed"); bool intent = validation_only;
    for (const auto& value : args) {
      Require(ValidUtf16(std::u16string(value.begin(), value.end())), "invalid-option-utf16");
      if (Prefix(value, L"--background-regression") || Prefix(value, L"--silent-validation")) throw PolicyError("legacy-validation-flag");
      intent = intent || Prefix(value, L"--shiyu-ui");
    }
    if (!intent) { result.mode = Mode::ordinary; return result; }
    Require(debug, "validation-debug-required"); Require(validation_only, "validation-build-marker-required");
    Require(args.size() == 5, "validation-options-count"); std::map<std::string, std::string> values;
    for (const auto& arg : args) {
      auto text = Narrow(arg); auto at = text.find('='); Require(at != std::string::npos && at + 1 < text.size(), "validation-option-value");
      Require(values.emplace(text.substr(0, at), text.substr(at + 1)).second, "validation-duplicate-option");
    }
    const std::set<std::string> keys = {"--shiyu-ui-validation", "--shiyu-ui-run", "--shiyu-ui-attempt", "--shiyu-ui-desktop", "--shiyu-ui-silent"};
    for (const auto& pair : values) Require(keys.count(pair.first) == 1, "validation-unknown-option");
    Require(values.at("--shiyu-ui-validation") == "ordinary-empty-ui" && values.at("--shiyu-ui-silent") == "true", "validation-mode-or-silent");
    result.run = values.at("--shiyu-ui-run"); result.attempt = values.at("--shiyu-ui-attempt"); result.desktop = values.at("--shiyu-ui-desktop");
    Require(result.run.size() == 11 && result.run.substr(0, 3) == "ui-" && LowerHex(result.run.substr(3), 8), "validation-run");
    Require(LowerHex(result.attempt, 32), "validation-attempt");
    Require(result.desktop.size() == 41 && result.desktop.substr(0, 9) == "ShiyuIso_" && LowerHex(result.desktop.substr(9), 32), "validation-desktop");
    result.mode = Mode::validation;
  } catch (const PolicyError& error) { result.mode = Mode::rejected; result.error = error.what(); }
  catch (...) { result.mode = Mode::rejected; result.error = "validation-options-shape"; }
  return result;
}
bool UseConsole(Mode mode) { return mode == Mode::ordinary; }
int AfterGuard(const Options& options, const std::function<int(Mode)>& startup) { return options.mode == Mode::rejected ? 64 : startup(options.mode); }
std::string Canonical(const Json& value) {
  if (value.kind == Json::Kind::string) return Quote(value.text);
  if (value.kind == Json::Kind::integer) return std::to_string(value.integer);
  if (value.kind == Json::Kind::boolean) return value.boolean ? "true" : "false";
  std::string result; bool first = true;
  if (value.kind == Json::Kind::object) {
    result = "{"; for (const auto& pair : value.object) { if (!first) result += ','; first = false; result += Quote(pair.first) + ':' + Canonical(pair.second); } return result + '}';
  }
  result = "["; for (const auto& item : value.array) { if (!first) result += ','; first = false; result += Canonical(item); } return result + ']';
}
Json ParseCanonical(const std::string& bytes, bool file, size_t maximum) {
  Require(!bytes.empty() && bytes.size() <= maximum, "json-byte-bound");
  if (file) Require(bytes.back() == '\n', "file-final-lf");
  const auto content = file ? bytes.substr(0, bytes.size() - 1) : bytes;
  auto result = Parser(content).Parse(); Require(Canonical(result) + (file ? "\n" : "") == bytes, "json-not-canonical"); return result;
}
void ExactKeys(const Json& value, std::initializer_list<const char16_t*> keys) {
  Require(value.kind == Json::Kind::object && value.object.size() == keys.size(), "closed-object");
  for (auto key : keys) Require(value.object.count(key) == 1, "closed-object");
}
const Json& Field(const Json& value, const char16_t* key) { Require(value.kind == Json::Kind::object && value.object.count(key) == 1, "missing-field"); return value.object.at(key); }
const std::u16string& Text(const Json& value) { Require(value.kind == Json::Kind::string, "string-required"); return value.text; }
uint64_t Number(const Json& value) { Require(value.kind == Json::Kind::integer, "integer-required"); return value.integer; }
std::string Ascii(const std::u16string& value) { std::string result; for (auto ch : value) { Require(ch <= 127, "ascii-required"); result += static_cast<char>(ch); } return result; }
std::u16string U16(const std::string& value) { std::u16string result; for (unsigned char ch : value) { Require(ch <= 127, "ascii-required"); result += ch; } return result; }
void ValidateAnchor(const Json& value) {
  ExactKeys(value, {u"protocol",u"purpose",u"ownerSid",u"workspacePath",u"basePath",u"workspaceIdentity",u"baseIdentity",u"sourceSha256",u"bundleSha256",u"commonSha256"});
  Require(Number(Field(value,u"protocol")) == 1 && Text(Field(value,u"purpose")) == u"ordinary-empty-ui-anchor", "anchor-version");
  Require(std::regex_match(Ascii(Text(Field(value,u"ownerSid"))), std::regex("S-1-[0-9]+(-[0-9]+)+")), "owner-sid-shape");
  for (auto key : {u"workspaceIdentity",u"baseIdentity"}) IdentityField(value,key);
  for (auto key : {u"sourceSha256",u"bundleSha256",u"commonSha256"}) HashField(value,key);
  for (auto key : {u"workspacePath",u"basePath"}) Require(!Text(Field(value,key)).empty() && ValidUtf16(Text(Field(value,key))), "anchor-path");
}
void ValidateIntent(const Json& value, const Options& options) {
  ExactKeys(value,{u"protocol",u"role",u"runId",u"attempt",u"desktopNonce",u"ownerSid",u"workspaceIdentity",u"baseIdentity",u"runIdentity",u"profileLeaf",u"stdoutIdentity",u"stderrIdentity",u"anchorSha256",u"imageSha256",u"bundleSha256",u"commonSha256"});
  Require(Number(Field(value,u"protocol")) == 1 && Text(Field(value,u"role")) == u"ordinary-empty-ui" && Text(Field(value,u"profileLeaf")) == u"profile", "intent-version");
  Require(Text(Field(value,u"runId")) == U16(options.run) && Text(Field(value,u"attempt")) == U16(options.attempt) && Text(Field(value,u"desktopNonce")) == U16(options.desktop), "intent-options-mismatch");
  Require(std::regex_match(Ascii(Text(Field(value,u"ownerSid"))), std::regex("S-1-[0-9]+(-[0-9]+)+")), "owner-sid-shape");
  for (auto key : {u"workspaceIdentity",u"baseIdentity",u"runIdentity",u"stdoutIdentity",u"stderrIdentity"}) IdentityField(value,key);
  for (auto key : {u"anchorSha256",u"imageSha256",u"bundleSha256",u"commonSha256"}) HashField(value,key);
}
}  // namespace shiyu_ui
