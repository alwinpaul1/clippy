#include "clip_vision.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.AI.MachineLearning.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <cmath>
#include <deque>
#include <fstream>
#include <memory>
#include <mutex>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

namespace clip_vision {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Result = flutter::MethodResult<EncodableValue>;

namespace imaging = winrt::Windows::Graphics::Imaging;
namespace ml = winrt::Windows::AI::MachineLearning;
namespace ocr = winrt::Windows::Media::Ocr;
namespace streams = winrt::Windows::Storage::Streams;

constexpr UINT kVisionDone = WM_APP + 0x43;

struct Done {
  std::unique_ptr<Result> result;
  bool ok = false;
  std::string text;
  std::vector<std::string> labels;  // ImageNet names, most likely first
  std::vector<int32_t> classes;     // their ImageNet indices
};

std::mutex g_mutex;
std::deque<Done> g_done;
HWND g_window = nullptr;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

// The image classifier: MobileNetV2 (ImageNet, 1000 classes) run through
// Windows ML, which ships with Windows 10 1809 and later. The model file is
// fetched at build time (windows/runner/CMakeLists.txt) and installed under
// data/vision; without it, classification is skipped and OCR still works.
constexpr uint32_t kSide = 224;
constexpr float kMinProbability = 0.2f;
constexpr size_t kMaxLabels = 3;

std::mutex g_model_mutex;  // a LearningModelSession is not thread-safe
bool g_model_tried = false;
ml::LearningModelSession g_session{nullptr};
winrt::hstring g_input_name;
winrt::hstring g_output_name;
std::vector<std::string> g_label_names;

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

std::wstring VisionDir() {
  wchar_t path[MAX_PATH];
  const DWORD n = GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring dir(path, n);
  dir = dir.substr(0, dir.find_last_of(L"\\/"));
  return dir + L"\\data\\vision\\";
}

// Loads the model once per run. Caller holds g_model_mutex.
bool EnsureModel() {
  if (g_model_tried) return static_cast<bool>(g_session);
  g_model_tried = true;
  try {
    const std::wstring dir = VisionDir();
    std::ifstream labels(dir + L"imagenet_labels.txt");
    std::string line;
    while (std::getline(labels, line)) g_label_names.push_back(line);
    if (g_label_names.size() != 1000) return false;
    ml::LearningModel model =
        ml::LearningModel::LoadFromFilePath(dir + L"mobilenetv2-7.onnx");
    g_input_name = model.InputFeatures().GetAt(0).Name();
    g_output_name = model.OutputFeatures().GetAt(0).Name();
    g_session = ml::LearningModelSession(
        model, ml::LearningModelDevice(ml::LearningModelDeviceKind::Cpu));
    return true;
  } catch (...) {
    g_session = nullptr;
    return false;
  }
}

std::string Recognize(const ocr::OcrEngine& engine,
                      const imaging::SoftwareBitmap& bitmap) {
  ocr::OcrResult result = engine.RecognizeAsync(bitmap).get();
  std::string out;
  for (const auto& line : result.Lines()) {
    if (!out.empty()) out += '\n';
    out += Utf8(line.Text());
  }
  return out;
}

void Classify(const imaging::BitmapDecoder& decoder, Done& done) {
  std::lock_guard<std::mutex> lock(g_model_mutex);
  if (!EnsureModel()) return;
  imaging::BitmapTransform transform;
  transform.ScaledWidth(kSide);
  transform.ScaledHeight(kSide);
  transform.InterpolationMode(imaging::BitmapInterpolationMode::Linear);
  imaging::SoftwareBitmap small =
      decoder
          .GetSoftwareBitmapAsync(imaging::BitmapPixelFormat::Bgra8,
                                  imaging::BitmapAlphaMode::Ignore, transform,
                                  imaging::ExifOrientationMode::
                                      RespectExifOrientation,
                                  imaging::ColorManagementMode::
                                      DoNotColorManage)
          .get();
  streams::Buffer buffer(kSide * kSide * 4);
  small.CopyToBuffer(buffer);
  const uint8_t* px = buffer.data();

  // NCHW, RGB, ImageNet mean/std: what MobileNetV2 was trained on.
  constexpr float kMean[3] = {0.485f, 0.456f, 0.406f};
  constexpr float kStd[3] = {0.229f, 0.224f, 0.225f};
  const size_t plane = static_cast<size_t>(kSide) * kSide;
  std::vector<float> input(3 * plane);
  for (size_t i = 0; i < plane; ++i) {
    // Pixels are B, G, R, A; the model wants R, G, B planes.
    for (size_t c = 0; c < 3; ++c) {
      const float v = px[i * 4 + (2 - c)] / 255.0f;
      input[c * plane + i] = (v - kMean[c]) / kStd[c];
    }
  }
  ml::LearningModelBinding binding(g_session);
  binding.Bind(g_input_name,
               ml::TensorFloat::CreateFromArray(
                   std::vector<int64_t>{1, 3, kSide, kSide}, input));
  ml::LearningModelEvaluationResult result =
      g_session.Evaluate(binding, L"clippy");
  auto scores = result.Outputs()
                    .Lookup(g_output_name)
                    .as<ml::TensorFloat>()
                    .GetAsVectorView();
  std::vector<float> p(scores.Size());
  for (uint32_t i = 0; i < scores.Size(); ++i) p[i] = scores.GetAt(i);
  if (p.size() != g_label_names.size()) return;
  // The model outputs logits; softmax them into probabilities.
  const float top = *std::max_element(p.begin(), p.end());
  float sum = 0;
  for (float& v : p) {
    v = std::exp(v - top);
    sum += v;
  }
  for (float& v : p) v /= sum;
  std::vector<int32_t> order(p.size());
  std::iota(order.begin(), order.end(), 0);
  std::partial_sort(order.begin(), order.begin() + kMaxLabels, order.end(),
                    [&](int32_t a, int32_t b) { return p[a] > p[b]; });
  for (size_t k = 0; k < kMaxLabels; ++k) {
    if (p[order[k]] < kMinProbability) break;
    done.classes.push_back(order[k]);
    done.labels.push_back(g_label_names[order[k]]);
  }
}

// Runs on a worker thread (MTA), where blocking on .get() is allowed.
bool Analyze(const std::vector<uint8_t>& bytes, Done& done) {
  try {
    streams::InMemoryRandomAccessStream stream;
    streams::DataWriter writer(stream);
    writer.WriteBytes(winrt::array_view<const uint8_t>(
        bytes.data(), bytes.data() + bytes.size()));
    writer.StoreAsync().get();
    writer.DetachStream();
    stream.Seek(0);
    imaging::BitmapDecoder decoder =
        imaging::BitmapDecoder::CreateAsync(stream).get();

    // Text. Uses the OCR languages of the user's Windows display languages;
    // with none installed there is simply no text to find.
    ocr::OcrEngine engine =
        ocr::OcrEngine::TryCreateFromUserProfileLanguages();
    if (engine) {
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
      done.text = Recognize(engine, bitmap);
    }

    // Content labels. A failure here must not lose the text.
    try {
      Classify(decoder, done);
    } catch (...) {
      done.labels.clear();
      done.classes.clear();
    }
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
          done.ok = Analyze(b, done);
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
      EncodableList labels;
      EncodableList classes;
      for (const auto& l : d.labels) labels.emplace_back(l);
      for (int32_t c : d.classes) classes.emplace_back(c);
      EncodableMap out{{EncodableValue("text"), EncodableValue(d.text)},
                       {EncodableValue("labels"), EncodableValue(labels)},
                       {EncodableValue("imagenet"), EncodableValue(classes)}};
      d.result->Success(EncodableValue(out));
    } else {
      d.result->Error("vision", "analysis failed");
    }
  }
  return true;
}

}  // namespace clip_vision
