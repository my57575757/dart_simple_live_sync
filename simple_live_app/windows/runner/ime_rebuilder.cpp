#include "ime_rebuilder.h"

#include <imm.h>

#include <string>
#include <unordered_set>

namespace {

constexpr DWORD kGcsCompstr = 0x0008;

// Contexts created by this process via ImmCreateContext; the thread-default
// context must never be destroyed.
std::unordered_set<HIMC>& OwnedContexts() {
  static std::unordered_set<HIMC> contexts;
  return contexts;
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

// Preventive lifecycle (flutter/flutter #190042, draft PR #190043): attach a
// self-owned context that is already OPEN and in native (Chinese) conversion
// mode whenever a text input client starts. Replacing the HIMC only AFTER the
// IMM32<->TSF session is stale has been proven not to repair it, so this runs
// up front instead of after the fact. Idempotent: re-attach while the current
// context is already self-owned only forces it open.
void AttachImeContext(HWND hwnd) {
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
    if (current_is_owned) {
      // Keep the existing session; just guarantee open + Chinese mode.
      ImmSetOpenStatus(current, TRUE);
      if ((conversion & IME_CMODE_NATIVE) == 0) {
        ImmSetConversionStatus(current, IME_CMODE_NATIVE, sentence);
      }
    }
    ImmReleaseContext(hwnd, current);
  }

  if (current && current_is_owned) {
    char msg[160];
    sprintf_s(msg,
              "attach: hwnd=%p himc=%p existing-owned open=%ld conv=%lu",
              hwnd, current, open, conversion);
    LogLine(msg);
    return;
  }

  HIMC created = ImmCreateContext();
  if (!created) {
    LogLine("attach: ImmCreateContext failed");
    return;
  }
  // Set open + Chinese BEFORE associating. The old rebuild path left the new
  // context open=0, which is the defect that reproduced the input failure.
  ImmSetOpenStatus(created, TRUE);
  DWORD target_sentence = sentence != 0 ? sentence : 8;
  ImmSetConversionStatus(created, IME_CMODE_NATIVE, target_sentence);

  // |previous| is the thread-default context here; never destroy it.
  HIMC previous = ImmAssociateContext(hwnd, created);
  OwnedContexts().insert(created);

  char msg[192];
  sprintf_s(msg,
            "attach: hwnd=%p new=%p previous=%p open=1 conv=NATIVE sentence=%lu",
            hwnd, created, previous, target_sentence);
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
