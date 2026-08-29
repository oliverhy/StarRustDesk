#include "software_av1_decoder.h"

#include "diagnostic_log.h"
#include "video_render.h"
#include "xcomponent_render.h"

#include <algorithm>
#include <aom/aomdx.h>
#include <hilog/log.h>
#include <libyuv/convert_argb.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskSoftAV1"

namespace {
constexpr size_t MAX_QUEUED_FRAMES = 90;

int highBitStride(int byteStride) {
    return byteStride / static_cast<int>(sizeof(uint16_t));
}
}

SoftwareAV1Decoder& SoftwareAV1Decoder::instance() {
    static SoftwareAV1Decoder decoder;
    return decoder;
}

SoftwareAV1Decoder::SoftwareAV1Decoder() : worker_(&SoftwareAV1Decoder::workerLoop, this) {}

SoftwareAV1Decoder::~SoftwareAV1Decoder() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        frames_.clear();
    }
    condition_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

void SoftwareAV1Decoder::decodeFrame(const uint8_t* data, int length, bool key, int64_t pts) {
    if (data == nullptr || length <= 0) {
        return;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    queuedFrames_ += 1;
    if (frames_.size() >= MAX_QUEUED_FRAMES) {
        frames_.clear();
        waitingForKeyframe_ = true;
        overflowDrops_ += 1;
        if (overflowDrops_ == 1 || overflowDrops_ % 30 == 0) {
            DiagnosticLog::instance().append("W", "av1_software",
                "queue_overflow waiting_for_keyframe count=" + std::to_string(overflowDrops_));
        }
    }
    if (waitingForKeyframe_ && !key) {
        return;
    }
    if (key) {
        waitingForKeyframe_ = false;
    }
    frames_.push_back(EncodedFrame {std::vector<uint8_t>(data, data + length), key, pts, generation_});
    condition_.notify_one();
}

void SoftwareAV1Decoder::release() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (queuedFrames_ > 0 || decodedFrames_.load() > 0 || initialized_.load()) {
        DiagnosticLog::instance().append("I", "av1_software",
            "release queued=" + std::to_string(queuedFrames_) +
            " decoded=" + std::to_string(decodedFrames_.load()) +
            " errors=" + std::to_string(decodeErrors_.load()));
    }
    generation_ += 1;
    frames_.clear();
    resetRequested_ = true;
    waitingForKeyframe_ = false;
    queuedFrames_ = 0;
    decodedFrames_ = 0;
    decodeErrors_ = 0;
    overflowDrops_ = 0;
    condition_.notify_one();
}

bool SoftwareAV1Decoder::initializeDecoder() {
    aom_codec_dec_cfg_t config {};
    const unsigned int hardwareThreads = std::thread::hardware_concurrency();
    config.threads = std::max(2u, std::min(8u, hardwareThreads == 0 ? 4u : hardwareThreads));
    config.allow_lowbitdepth = 1;
    aom_codec_err_t result = aom_codec_dec_init(&codec_, aom_codec_av1_dx(), &config, 0);
    if (result != AOM_CODEC_OK) {
        DiagnosticLog::instance().append("E", "av1_software",
            "decoder_init_failed code=" + std::to_string(static_cast<int>(result)));
        return false;
    }
    initialized_.store(true);
    DiagnosticLog::instance().append("I", "av1_software",
        "decoder_started libaom threads=" + std::to_string(config.threads));
    return true;
}

void SoftwareAV1Decoder::destroyDecoder() {
    if (initialized_.load()) {
        aom_codec_destroy(&codec_);
        codec_ = {};
        initialized_.store(false);
    }
}

bool SoftwareAV1Decoder::convertFrame(aom_image_t* image, std::vector<uint8_t>& bgra) {
    if (image == nullptr || image->d_w == 0 || image->d_h == 0) {
        return false;
    }
    const int width = static_cast<int>(image->d_w);
    const int height = static_cast<int>(image->d_h);
    bgra.resize(static_cast<size_t>(width) * static_cast<size_t>(height) * 4);

    const int format = image->fmt & ~(AOM_IMG_FMT_HIGHBITDEPTH | AOM_IMG_FMT_UV_FLIP);
    const bool highBitDepth = (image->fmt & AOM_IMG_FMT_HIGHBITDEPTH) != 0;
    const uint8_t* y = image->planes[AOM_PLANE_Y];
    const uint8_t* u = image->planes[AOM_PLANE_U];
    const uint8_t* v = image->planes[AOM_PLANE_V];
    const int yStride = image->stride[AOM_PLANE_Y];
    const int uStride = image->stride[AOM_PLANE_U];
    const int vStride = image->stride[AOM_PLANE_V];
    int result = -1;

    if (!highBitDepth) {
        if (format == AOM_IMG_FMT_I420 || format == (AOM_IMG_FMT_YV12 & ~AOM_IMG_FMT_UV_FLIP) ||
            format == AOM_IMG_FMT_AOMI420 || format == (AOM_IMG_FMT_AOMYV12 & ~AOM_IMG_FMT_UV_FLIP)) {
            result = libyuv::I420ToARGB(y, yStride, u, uStride, v, vStride,
                bgra.data(), width * 4, width, height);
        } else if (format == AOM_IMG_FMT_I422) {
            result = libyuv::I422ToARGB(y, yStride, u, uStride, v, vStride,
                bgra.data(), width * 4, width, height);
        } else if (format == AOM_IMG_FMT_I444) {
            result = libyuv::I444ToARGB(y, yStride, u, uStride, v, vStride,
                bgra.data(), width * 4, width, height);
        } else if (format == AOM_IMG_FMT_NV12) {
            result = libyuv::NV12ToARGB(y, yStride, u, uStride,
                bgra.data(), width * 4, width, height);
        }
    } else {
        const auto* y16 = reinterpret_cast<const uint16_t*>(y);
        const auto* u16 = reinterpret_cast<const uint16_t*>(u);
        const auto* v16 = reinterpret_cast<const uint16_t*>(v);
        if (format == AOM_IMG_FMT_I420) {
            result = libyuv::I010ToARGB(y16, highBitStride(yStride), u16, highBitStride(uStride),
                v16, highBitStride(vStride), bgra.data(), width * 4, width, height);
        } else if (format == AOM_IMG_FMT_I422) {
            result = libyuv::I210ToARGB(y16, highBitStride(yStride), u16, highBitStride(uStride),
                v16, highBitStride(vStride), bgra.data(), width * 4, width, height);
        }
    }

    if (result != 0) {
        DiagnosticLog::instance().append("E", "av1_software",
            "unsupported_output_format fmt=" + std::to_string(image->fmt) +
            " bit_depth=" + std::to_string(image->bit_depth) +
            " size=" + std::to_string(width) + "x" + std::to_string(height));
        return false;
    }
    return true;
}

void SoftwareAV1Decoder::workerLoop() {
    std::vector<uint8_t> bgra;
    while (true) {
        EncodedFrame frame;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            condition_.wait(lock, [this]() { return stopping_ || resetRequested_ || !frames_.empty(); });
            if (stopping_) {
                break;
            }
            if (resetRequested_) {
                resetRequested_ = false;
                lock.unlock();
                destroyDecoder();
                continue;
            }
            frame = std::move(frames_.front());
            frames_.pop_front();
        }

        if (!initialized_.load() && !initializeDecoder()) {
            continue;
        }
        aom_codec_err_t result = aom_codec_decode(&codec_, frame.data.data(), frame.data.size(), nullptr);
        if (result != AOM_CODEC_OK) {
            const uint64_t errorCount = decodeErrors_.fetch_add(1) + 1;
            if (errorCount == 1 || errorCount % 60 == 0) {
                const char* detail = aom_codec_error_detail(&codec_);
                DiagnosticLog::instance().append("E", "av1_software",
                    "decode_failed code=" + std::to_string(static_cast<int>(result)) +
                    " count=" + std::to_string(errorCount) +
                    (detail == nullptr ? "" : " detail=" + std::string(detail)));
            }
            continue;
        }

        aom_codec_iter_t iterator = nullptr;
        while (aom_image_t* image = aom_codec_get_frame(&codec_, &iterator)) {
            if (!convertFrame(image, bgra)) {
                continue;
            }
            {
                std::lock_guard<std::mutex> lock(mutex_);
                if (frame.generation != generation_ || resetRequested_) {
                    break;
                }
                decodedFrames_.fetch_add(1);
            }
            XComponentRender::instance().renderBGRAFrame(bgra.data(), static_cast<int>(bgra.size()),
                static_cast<int>(image->d_w), static_cast<int>(image->d_h));
            VideoRender::instance().markDecodedFrame(5,
                static_cast<int>(image->d_w), static_cast<int>(image->d_h), 2);
            if (decodedFrames_.load() == 1) {
                DiagnosticLog::instance().append("I", "av1_software",
                    "first_output_rendered resolution=" + std::to_string(image->d_w) + "x" +
                    std::to_string(image->d_h));
            }
        }
    }
    destroyDecoder();
}
