#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 单实例限制：已有一个 Quarklite 实例在运行时，唤起其主窗口并退出。
  HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Quarklite_SingleInstance_Mutex");
  if (mutex != nullptr && GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
    if (existing != nullptr) {
      ShowWindow(existing, SW_RESTORE);
      SetForegroundWindow(existing);
    }
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Size size(1280, 800);

  // 启动时让窗口位于主屏工作区中央。
  RECT work_area{};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0)) {
    work_area = {0, 0, ::GetSystemMetrics(SM_CXSCREEN),
                 ::GetSystemMetrics(SM_CYSCREEN)};
  }
  // origin 使用逻辑像素，由 Win32Window 按目标显示器 DPI 缩放。
  UINT dpi = 96;
  if (HMODULE user32 = ::GetModuleHandleW(L"User32.dll")) {
    using GetDpiForSystemFn = UINT(WINAPI*)();
    auto get_dpi_for_system = reinterpret_cast<GetDpiForSystemFn>(
        ::GetProcAddress(user32, "GetDpiForSystem"));
    if (get_dpi_for_system != nullptr) {
      dpi = get_dpi_for_system();
    }
  }
  const double scale = dpi / 96.0;
  const int work_width = work_area.right - work_area.left;
  const int work_height = work_area.bottom - work_area.top;
  int centered_x = work_area.left +
                   (work_width - static_cast<int>(size.width * scale)) / 2;
  int centered_y = work_area.top +
                   (work_height - static_cast<int>(size.height * scale)) / 2;
  if (centered_x < work_area.left) centered_x = work_area.left;
  if (centered_y < work_area.top) centered_y = work_area.top;
  Win32Window::Point origin(static_cast<int>(centered_x / scale),
                            static_cast<int>(centered_y / scale));

  if (!window.Create(L"fast-downloader", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
