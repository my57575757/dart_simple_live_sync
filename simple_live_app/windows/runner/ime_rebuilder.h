#ifndef RUNNER_IME_REBUILDER_H_
#define RUNNER_IME_REBUILDER_H_

#include <windows.h>

// Must be called on the thread that owns |hwnd|.
//
// Disassociates the current IMM input context. Skipped while a composition is
// in progress to avoid dropping in-flight input.
void DetachImeContext(HWND hwnd);

// Must be called on the thread that owns |hwnd|.
//
// Ensures a self-owned IMM input context that is open and in native (Chinese)
// conversion mode is associated with |hwnd|. Called up front when a text input
// client starts (preventive lifecycle), not after the IMM32<->TSF session has
// gone stale — replacing the HIMC after that point does not recover it
// (flutter/flutter #190042). Idempotent when the current context is already
// self-owned.
void AttachImeContext(HWND hwnd);

// Must be called on the thread that owns |hwnd|, before the window/engine is
// destroyed. Restores the default context and destroys every self-created
// context so the active IME TIP does not outlive its target.
void ShutdownImeContexts(HWND hwnd);

#endif  // RUNNER_IME_REBUILDER_H_
