// Pure-policy executable SOURCE. No Win32/Flutter/COM headers or calls.
// Compile/import inspection only in this work package; do not execute yet.
#include "../ordinary_ui_policy.h"
#include <iostream>
#include <stdexcept>
#include <vector>
#ifndef SHIYU_UI_VECTOR_HEADER
#define SHIYU_UI_VECTOR_HEADER "ordinary_ui_wire_vectors.generated.h"
#endif
#include SHIYU_UI_VECTOR_HEADER

namespace {
int checks = 0;
void Check(bool value) { if (!value) throw std::runtime_error("pure-policy-check"); ++checks; }
template <class F> void Reject(F action) {
  bool rejected = false; try { action(); } catch (const shiyu_ui::PolicyError&) { rejected = true; }
  Check(rejected);
}
std::vector<std::wstring> ValidArgs() {
  return {L"--shiyu-ui-validation=ordinary-empty-ui",L"--shiyu-ui-run=ui-1234abcd",
      L"--shiyu-ui-attempt=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      L"--shiyu-ui-desktop=ShiyuIso_cccccccccccccccccccccccccccccccc",L"--shiyu-ui-silent=true"};
}
void NoResources(const shiyu_ui::Options& decision) {
  int console = 0, com = 0, engine = 0, window = 0;
  const int code = shiyu_ui::AfterGuard(decision,[&](shiyu_ui::Mode mode) {
    if (shiyu_ui::UseConsole(mode)) ++console;
    ++com; ++engine; ++window; return 0;
  });
  Check(code == 64 && console == 0 && com == 0 && engine == 0 && window == 0);
}
}
int main() {
  using namespace shiyu_ui;
  const auto valid = ValidArgs(); const auto accepted = ParseOptions(valid,true,true,true);
  Check(accepted.mode == Mode::validation && !UseConsole(accepted.mode));
  Check(ParseOptions({},true,true,false).mode == Mode::ordinary);
  NoResources(ParseOptions({},true,true,true));
  NoResources(ParseOptions(valid,false,true,true));
  NoResources(ParseOptions(valid,true,false,true));
  NoResources(ParseOptions(valid,true,true,false));
  NoResources(ParseOptions({L"--shiyu-ui"},true,true,false));
  NoResources(ParseOptions({L"--shiyu-ui-unknown=true"},true,true,false));
  for (const auto& old : {L"--background-regression",L"--silent-validation",L"--silent-validation=true"}) {
    NoResources(ParseOptions({old},true,true,false));
    auto args = valid; args.push_back(old); NoResources(ParseOptions(args,true,true,true));
  }
  for (const auto& value : {L"--shiyu-ui-silent=false",L"--shiyu-ui-other=true",L"--shiyu-ui-silent=",L"--shiyu-ui-run=ui-1234abcd"}) {
    auto args = valid; args.back() = value; NoResources(ParseOptions(args,true,true,true));
  }
  auto bad_utf16 = valid; bad_utf16.back() = std::wstring(1,static_cast<wchar_t>(0xd800));
  NoResources(ParseOptions(bad_utf16,true,true,true));
  Check(PathBudget(std::u16string(104,u'x')) && !PathBudget(std::u16string(105,u'x')));
  Check(!PathBudget(std::u16string(1,static_cast<char16_t>(0xd800))));
  Check(SafeDesktopAccess(0x83) && SafeDesktopAccess(0x20087));
  for (uint32_t rights : {0x100u,0x40000u,0x80000u,0x60087u,0x81u,0xf0020087u}) Check(!SafeDesktopAccess(rights));
  Check(DesktopEvidence(accepted,"WinSta0",accepted.desktop,"Default",0x20087));
  Check(!DesktopEvidence(accepted,"WinSta0",accepted.desktop,accepted.desktop,0x20087));
  Check(!DesktopEvidence(accepted,"WinSta0","Default","Default",0x20087));
  Check(!DesktopEvidence(accepted,"Other",accepted.desktop,"Default",0x20087));
  for (const auto& bytes : kCanonicalWireFiles) {
    auto value = ParseCanonical(bytes,true,262144); Check(Canonical(value) + '\n' == bytes);
  }
  auto anchor = ParseCanonical(kAnchorFile,true,2048); ValidateAnchor(anchor);
  auto intent = ParseCanonical(kIntentFile,true,8192); ValidateIntent(intent,accepted);
  anchor.object.emplace(u"unknown",Json::Boolean(true)); Reject([&] { ValidateAnchor(anchor); });
  intent.object[u"protocol"] = Json::Boolean(true); Reject([&] { ValidateIntent(intent,accepted); });
  for (const auto& bytes : {"{\"a\":1,\"a\":2}\n","{\"b\":1,\"a\":2}\n","{\"a\":1.0}\n", "{\"a\":1e0}\n",
       "{\"a\":-0}\n","{\"a\":01}\n","{\"a\":9007199254740992}\n","{\"a\":\"\\ud800\"}\n",
       "{\"a\":\"\\udc00\"}\n","{\"a\":\"\\/\"}\n","{}\n\n","{}", " {}\n"})
    Reject([&] { ParseCanonical(bytes,true,4096); });
  Check(Decimal(u"134000000000000000") && !Decimal(u"0134") && !Decimal(u"0") && !Decimal(u"1x"));
  Reject([&] { Json::Integer(9007199254740992ULL); });
  Check(Json::Integer(9007199254740991ULL).integer == 9007199254740991ULL);
  std::cout << "PURE_POLICY_DECLARED_CHECKS " << checks << '\n';
  return 0;
}
