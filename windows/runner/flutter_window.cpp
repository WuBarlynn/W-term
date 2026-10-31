#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "desktop_multi_window/desktop_multi_window_plugin.h"

namespace {

int CALLBACK CollectFontFamily(const LOGFONTW* logfont, const TEXTMETRICW*,
                               DWORD, LPARAM lparam) {
  auto* families = reinterpret_cast<std::vector<std::string>*>(lparam);
  if (logfont->lfFaceName[0] == L'@') {
    return 1;
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, logfont->lfFaceName, -1,
                                       nullptr, 0, nullptr, nullptr);
  if (size > 1) {
    std::string name(static_cast<size_t>(size - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, logfont->lfFaceName, -1, name.data(), size,
                        nullptr, nullptr);
    if (std::find(families->begin(), families->end(), name) ==
        families->end()) {
      families->push_back(name);
    }
  }
  return 1;
}

std::vector<std::string> ListFontFamilies() {
  std::vector<std::string> families;
  HDC dc = GetDC(nullptr);
  if (dc != nullptr) {
    LOGFONTW filter = {};
    filter.lfCharSet = DEFAULT_CHARSET;
    EnumFontFamiliesExW(dc, &filter,
                        reinterpret_cast<FONTENUMPROCW>(CollectFontFamily),
                        reinterpret_cast<LPARAM>(&families), 0);
    ReleaseDC(nullptr, dc);
  }
  std::sort(families.begin(), families.end());
  return families;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  font_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "dev.wterm/fonts",
          &flutter::StandardMethodCodec::GetInstance());
  font_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "listFamilies") {
          result->NotImplemented();
          return;
        }
        flutter::EncodableList values;
        for (const auto& family : ListFontFamilies()) {
          values.push_back(flutter::EncodableValue(family));
        }
        result->Success(flutter::EncodableValue(values));
      });
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterPlugins(flutter_view_controller->engine());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  // Fixed global shortcut; a second registration (detached window) fails
  // harmlessly because the main window owns the shortcut.
  RegisterHotKey(GetHandle(), 1, MOD_CONTROL | MOD_ALT, VK_SPACE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  UnregisterHotKey(GetHandle(), 1);
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == WM_HOTKEY && wparam == 1) {
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
