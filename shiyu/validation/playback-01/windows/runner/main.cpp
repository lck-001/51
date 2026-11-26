#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <algorithm>

#include "flutter_window.h"
#include "utils.h"
#include "ordinary_ui_startup.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::wstring> wide_arguments;
  unsigned long parse_error = 0;
  bool parsed = GetCommandLineArgumentsWide(&wide_arguments, &parse_error);
  std::vector<std::string> command_line_arguments;
  if (parsed) {
    for (const auto& value : wide_arguments) {
      std::string converted;
      if (!Utf8FromUtf16Strict(value, &converted, &parse_error)) {
        parsed = false; break;
      }
      command_line_arguments.push_back(std::move(converted));
    }
  }
  if (!parsed) shiyu_ui::NativeStartupFailure("command-line-extraction", parse_error);
  const auto gate = shiyu_ui::GuardNativeStartup(wide_arguments, parsed);
  if (gate.mode == shiyu_ui::Mode::rejected) return 64;

  return shiyu_ui::AfterGuard(gate, [&](shiyu_ui::Mode mode) {
  // Validation never attaches or allocates a console, including under a native
  // debugger. Ordinary user startup keeps its prior console behavior.
  if (shiyu_ui::UseConsole(mode) &&
      !::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  const HRESULT initialized = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(initialized)) {
    shiyu_ui::NativeStartupFailure("CoInitializeEx", static_cast<uint32_t>(initialized), true);
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, true);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  const bool window_created = window.Create(L"shiyu_playback_probe", origin, size);
  if (!window_created) {
    if (mode == shiyu_ui::Mode::ordinary) {
      ::CoUninitialize(); return EXIT_FAILURE;
    }
    // Controller/Dart initialization may already have accepted work. Keep the
    // partial native object in this owning scope rather than fast-exit/GC it.
    shiyu_ui::NativeStartupFailure("window-create-resources-unknown", 0);
  }
  window.SetQuitOnClose(window_created);
  const auto main_hwnd = reinterpret_cast<uintptr_t>(window.GetHandle());
  try { if (window_created) shiyu_ui::NativeWindowCreated(main_hwnd, GetCurrentThreadId()); }
  catch (...) {
    // Resource startup may already be running in Dart. Retain this owning
    // message loop; a missing proof is failure, never permission for fast exit.
    shiyu_ui::NativeStartupFailure("native-window-proof", 0);
  }

  ::MSG msg;
  int message_result = 0;
  while ((message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  if (message_result < 0) {
    const DWORD error = GetLastError(); shiyu_ui::NativeStartupFailure("GetMessageW", error);
    if (mode == shiyu_ui::Mode::validation) { for (;;) Sleep(INFINITE); }
    ::CoUninitialize(); return EXIT_FAILURE;
  }
  try { shiyu_ui::NativeLoopEnded(main_hwnd, message_result); }
  catch (...) {
    shiyu_ui::NativeStartupFailure("native-loop-proof", 0);
    if (mode == shiyu_ui::Mode::validation) { for (;;) Sleep(INFINITE); }
    ::CoUninitialize(); return EXIT_FAILURE;
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
  });
}
