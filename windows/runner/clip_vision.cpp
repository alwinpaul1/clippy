#include "clip_vision.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace clip_vision {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

constexpr UINT kVisionDone = WM_APP + 0x43;

struct Done {
  std::unique_ptr<Result> result;
  bool ok = false;
  std::string text;
};

std::mutex g_mutex;
std::deque<Done> g_done;
HWND g_window = nullptr;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

std::string Utf8(const winrt::hstring& s) {
  if (s.empty()) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, s.c_str(),
                                    static_cast<int>(s.size()), nullptr, 0,
                                    nullptr, nullptr);
  std::string out(static_cast<size_t>(n), '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.c_str(), static_cast<int>(s.size()),
                      out.data(), n, nullptr, nullptr);
  return out;
}

// Runs on a worker thread (MTA), where blocking on .get() is allowed.
bool Recognize(const std::vector<uint8_t>& bytes, std::string& text) {
  namespace imaging = winrt::Windows::Graphics::Imaging;
  namespace ocr = winrt::Windows::Media::Ocr;
  namespace streams = winrt::Windows::Storage::Streams;
  try {
    // Uses the OCR languages of the user's Windows display languages.
    ocr::OcrEngine engine =
        ocr::OcrEngine::TryCreateFromUserProfileLanguages();
    if (!engine) {
      text.clear();  // no OCR language installed: nothing to find, not an error
      return true;
    }
    streams::InMemoryRandomAccessStream stream;
    streams::DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<const uint8_t>(
        bytes.data(), bytes.data() + bytes.size()));
    writer.StoreAsync().get();
    writer.DetachStream();
    stream.Seek(0);

    imaging::BitmapDecoder decoder =
        imaging::BitmapDecoder::CreateAsync(stream).get();
    const uint32_t w = decoder.PixelWidth();
    const uint32_t h = decoder.PixelHeight();
    const uint32_t max_side = ocr::OcrEngine::MaxImageDimension();
    imaging::BitmapTransform transform;
    if (w > max_side || h > max_side) {
      const double k = static_cast<double>(max_side) / (std::max)(w, h);
      transform.ScaledWidth(static_cast<uint32_t>(w * k));
      transform.ScaledHeight(static_cast<uint32_t>(h * k));
    }
    imaging::SoftwareBitmap bitmap =
        decoder
            .GetSoftwareBitmapAsync(imaging::BitmapPixelFormat::Bgra8,
                                    imaging::BitmapAlphaMode::Premultiplied,
                                    transform,
                                    imaging::ExifOrientationMode::
                                        RespectExifOrientation,
                                    imaging::ColorManagementMode::
                                        DoNotColorManage)
            .get();
    ocr::OcrResult result = engine.RecognizeAsync(bitmap).get();
    std::string out;
    for (const auto& line : result.Lines()) {
      if (!out.empty()) out += '\n';
      out += Utf8(line.Text());
    }
    text = std::move(out);
    return true;
  } catch (...) {
    return false;
  }
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "clippy/vision", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<Result> result) {
        if (call.method_name() != "analyze") {
          result->NotImplemented();
          return;
        }
        std::vector<uint8_t> bytes;
        if (const auto* args = std::get_if<EncodableMap>(call.arguments())) {
          auto it = args->find(EncodableValue("bytes"));
          if (it != args->end()) {
            if (const auto* b = std::get_if<std::vector<uint8_t>>(&it->second)) {
              bytes = *b;
            }
          }
        }
        if (bytes.empty()) {
          result->Error("args", "bytes missing");
          return;
        }
        std::thread([r = std::move(result), b = std::move(bytes)]() mutable {
          winrt::init_apartment(winrt::apartment_type::multi_threaded);
          Done done;
          done.ok = Recognize(b, done.text);
          done.result = std::move(r);
          winrt::uninit_apartment();
          {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_done.push_back(std::move(done));
          }
          PostMessage(g_window, kVisionDone, 0, 0);
        }).detach();
      });
}

bool HandleMessage(UINT message) {
  if (message != kVisionDone) return false;
  std::deque<Done> done;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    done.swap(g_done);
  }
  for (auto& d : done) {
    if (d.ok) {
      // Windows has no built-in image classifier, so no labels: on Windows
      // photos are found by their text and their kind, not by content.
      EncodableMap out{{EncodableValue("text"), EncodableValue(d.text)},
                       {EncodableValue("labels"), EncodableValue(EncodableList{})}};
      d.result->Success(EncodableValue(out));
    } else {
      d.result->Error("vision", "analysis failed");
    }
  }
  return true;
}

}  // namespace clip_vision
