#ifndef RUNNER_CLIP_VISION_H_
#define RUNNER_CLIP_VISION_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// On-device OCR for image search ("clippy/vision"), using Windows.Media.Ocr.
// Recognition runs on a worker thread; the reply is posted back to the
// window so Flutter only ever hears from its platform thread.
namespace clip_vision {

void Register(flutter::BinaryMessenger* messenger, HWND window);

// Call from the top-level window's message handler. True when [message] was
// a finished recognition (already answered).
bool HandleMessage(UINT message);

}  // namespace clip_vision

#endif  // RUNNER_CLIP_VISION_H_
