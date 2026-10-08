#include "ime_rebuilder.h"

#include <imm.h>

#include <string>
#include <unordered_set>

namespace {

constexpr DWORD kGcsCompstr = 0x0008;

// Minimum interval between rebuilds while the current context is already
// self-created. WM_ACTIVATE and the Dart watchdog can both post on one focus
// return (within ~1ms), and focus flicker can otherwise trigger a rebuild per
// second. After a detach the context falls back to the thread default, which
// is never throttled.
constexpr DWORD kRebuildCooldownMs = 3000;

// Contexts created by this process via ImmCreateContext; the thread-default
// context must never be destroyed.
std::unordered_set<HIMC>& OwnedContexts() {
  static std::unordered_set<HIMC> contexts;
  return contexts;
}

DWORD& LastRebuildTick() {
  static DWORD tick = 0;
  return tick;
}

// UTF-8 diagnostic log next to the executable.
void LogLine(const std::string& message) {
  wchar_t exe_path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
  std::wstring path(exe_path);
  size_t pos = path.find_last_of(L"\\/");
  if (pos != std::wstring::npos) {
    path.resize(pos + 1);
  }
  path += L"ime_rebuild.log";

  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                            nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }

  SYSTEMTIME st;
  GetLocalTime(&st);
  char stamp[64];
  sprintf_s(stamp, "%04d-%02d-%02d %02d:%02d:%02d.%03d ", st.wYear,
            st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
            st.wMilliseconds);

  std::string line = std::string(stamp) + message + "\r\n";
  DWORD written = 0;
  WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
            nullptr);
  CloseHandle(file);
}

}  // namespace

void DetachImeContext(HWND hwnd) {
  if (!hwnd) {
    return;
  }
  HIMC himc = ImmGetContext(hwnd);
  if (!himc) {
    LogLine("detach: no current context");
    return;
  }
  LONG composing = ImmGetCompositionStringW(himc, kGcsCompstr, nullptr, 0);
  ImmReleaseContext(hwnd, himc);
  if (composing > 0) {
    LogLine("detach: skipped (composition in progress)");
    return;
  }
  BOOL ok = ImmAssociateContextEx(hwnd, nullptr, 0);
  char msg[128];
  sprintf_s(msg, "detach: hwnd=%p ImmAssociateContextEx->%ld", hwnd, ok);
  LogLine(msg);
}

void RebuildImeContext(HWND hwnd, bool force) {
  if (!hwnd) {
    return;
  }

  HIMC current = ImmGetContext(hwnd);
  BOOL open = FALSE;
  DWORD conversion = 0;
  DWORD sentence = 0;
  bool current_is_owned = false;
  if (current) {
    current_is_owned = OwnedContexts().count(current) > 0;
    open = ImmGetOpenStatus(current);
    ImmGetConversionStatus(current, &conversion, &sentence);
    ImmReleaseContext(hwnd, current);
  }

  DWORD now = GetTickCount();
  if (!force && current_is_owned &&
      now - LastRebuildTick() < kRebuildCooldownMs) {
    LogLine("rebuild: skipped (throttled)");
    return;
  }

  HIMC created = ImmCreateContext();
  if (!created) {
    LogLine("rebuild: ImmCreateContext failed");
    return;
  }

  if (open) {
    ImmSetOpenStatus(created, open);
  }
  if (conversion != 0 || sentence != 0) {
    ImmSetConversionStatus(created, conversion, sentence);
  }

  HIMC previous = ImmAssociateContext(hwnd, created);
  auto& owned = OwnedContexts();
  owned.insert(created);
  if (previous && owned.erase(previous) > 0) {
    ImmDestroyContext(previous);
  }
  LastRebuildTick() = now;

  char msg[192];
  sprintf_s(msg,
            "rebuild: hwnd=%p new=%p previous=%p open=%ld conv=%lu sentence=%lu",
            hwnd, created, previous, open, conversion, sentence);
  LogLine(msg);
}

void ShutdownImeContexts(HWND hwnd) {
  if (hwnd) {
    ImmAssociateContextEx(hwnd, nullptr, IACE_DEFAULT);
  }
  auto& owned = OwnedContexts();
  for (HIMC context : owned) {
    ImmDestroyContext(context);
  }
  size_t count = owned.size();
  owned.clear();
  char msg[96];
  sprintf_s(msg, "shutdown: hwnd=%p destroyed=%zu", hwnd, count);
  LogLine(msg);
}
