#ifndef SHIYU_ORDINARY_UI_POLICY_H_
#define SHIYU_ORDINARY_UI_POLICY_H_

// Pure closed protocol/policy. No Win32, Flutter, COM or environment discovery.
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace shiyu_ui {
struct PolicyError : std::runtime_error {
  explicit PolicyError(const char* code) : std::runtime_error(code) {}
};
enum class Mode { ordinary, validation, rejected };
struct Options {
  Mode mode = Mode::rejected;
  std::string run, attempt, desktop, error;
};
struct Json {
  enum class Kind { object, array, string, integer, boolean };
  Kind kind = Kind::object;
  std::map<std::u16string, Json> object;
  std::vector<Json> array;
  std::u16string text;
  uint64_t integer = 0;
  bool boolean = false;
  static Json String(const std::u16string& value);
  static Json Integer(uint64_t value);
  static Json Boolean(bool value);
  static Json Object(std::initializer_list<std::pair<const std::u16string, Json>> values);
  static Json Array(const std::vector<Json>& values);
};
bool LowerHex(const std::string& value, size_t length);
bool Identity(const std::u16string& value);
bool Decimal(const std::u16string& value);
bool ValidUtf16(const std::u16string& value);
bool PathBudget(const std::u16string& profile);
bool SafeDesktopAccess(uint32_t mask);
bool DesktopEvidence(const Options& options, const std::string& station,
                     const std::string& desktop, const std::string& input,
                     uint32_t access);
Options ParseOptions(const std::vector<std::wstring>& args, bool parsed,
                     bool debug, bool validation_only);
bool UseConsole(Mode mode);
int AfterGuard(const Options& options, const std::function<int(Mode)>& startup);
std::string Canonical(const Json& value);
Json ParseCanonical(const std::string& bytes, bool file, size_t maximum);
void ExactKeys(const Json& value, std::initializer_list<const char16_t*> keys);
const Json& Field(const Json& value, const char16_t* key);
const std::u16string& Text(const Json& value);
uint64_t Number(const Json& value);
std::string Ascii(const std::u16string& value);
std::u16string U16(const std::string& ascii);
void ValidateAnchor(const Json& value);
void ValidateIntent(const Json& value, const Options& options);
}  // namespace shiyu_ui
#endif
