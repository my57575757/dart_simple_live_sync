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
// Creates a brand-new IMM input context (copying open/conversion/sentence
// state from the current one) and associates it with |hwnd|, destroying the
// replaced context if it was self-created. Forces Windows to establish a new
// IMM32<->TSF session. Works around the stale-session bug described in
// flutter/flutter #190042, for which IACE_DEFAULT is a no-op.
//
// |force| bypasses the rebuild cooldown. Used for text-client switches
// (flutter/flutter #191196), where a fresh context is required even when the
// previous rebuild happened within the cooldown window.
void RebuildImeContext(HWND hwnd, bool force = false);

// Must be called on the thread that owns |hwnd|, before the window/engine is
// destroyed. Restores the default context and destroys every self-created
// context so the active IME TIP does not outlive its target.
void ShutdownImeContexts(HWND hwnd);

#endif  // RUNNER_IME_REBUILDER_H_
