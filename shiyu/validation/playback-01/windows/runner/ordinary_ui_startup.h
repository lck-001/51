#ifndef SHIYU_ORDINARY_UI_STARTUP_H_
#define SHIYU_ORDINARY_UI_STARTUP_H_
#include "ordinary_ui_policy.h"
#include <cstdint>
#include <string>
#include <vector>

namespace shiyu_ui {
// Only startup validation metadata is retained here; never a Store, A or Player.
Options GuardNativeStartup(const std::vector<std::wstring>& args, bool parsed);
bool ValidationArmed();
void NativeWindowCreated(uintptr_t hwnd, uint32_t tid);
void NativeLoopEnded(uintptr_t hwnd, int message_result);
// Null arguments only at the existing channel. These do not call Bind/COM.
std::string ReadStartupValidationProof();
std::string ReadStartupCloseGrantProof();
void NativeStartupFailure(const char* api, uint32_t code, bool hresult = false);
}  // namespace shiyu_ui
#endif
