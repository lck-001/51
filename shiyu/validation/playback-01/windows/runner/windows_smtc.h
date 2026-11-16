#ifndef RUNNER_WINDOWS_SMTC_H_
#define RUNNER_WINDOWS_SMTC_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <memory>

// Own HWND only; callbacks enqueue private data and post a payload-free message.
// No Flutter messenger or raw owner pointer is captured by a WinRT callback.
class WindowsSmtc {
 public:
  WindowsSmtc(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowsSmtc();
  WindowsSmtc(const WindowsSmtc&) = delete;
  WindowsSmtc& operator=(const WindowsSmtc&) = delete;
  bool HandleMessage(HWND window, UINT message, WPARAM wparam, LPARAM lparam,
                     LRESULT* result) noexcept;
  void Shutdown() noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_WINDOWS_SMTC_H_
