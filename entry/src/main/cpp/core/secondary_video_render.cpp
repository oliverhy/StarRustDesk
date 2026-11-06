#include "secondary_video_render.h"
#include "diagnostic_log.h"
#include "rustdesk_ffi.h"

#include <new>
#include <utility>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskSecondary"

namespace {
constexpr size_t MAX_FRAME_BYTES = 16 * 1024 * 1024;
constexpr size_t MAX_QUEUE_BYTES = 32 * 1024 * 1024;
constexpr size_t MAX_QUEUE_FRAMES = 48;
constexpr int MAX_DIMENSION = 16384;
constexpr int ERR_DECODER = -7;
}

SecondaryVideoRender::SecondaryVideoRender() : worker_(&SecondaryVideoRender::run, this) {}

SecondaryVideoRender::~SecondaryVideoRender() {
    active_.store(false);
    generation_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        stopping_ = true;
        frames_.clear();
        queuedBytes_ = 0;
    }
    ready_.notify_one();
    if (worker_.joinable()) worker_.join();
    std::lock_guard<std::mutex> lock(stateMutex_);
    releaseDecodersLocked();
    surface_.release();
}

bool SecondaryVideoRender::setSurface(const std::string& surfaceId) {
    std::lock_guard<std::mutex> lock(stateMutex_);
    if (active_.load()) return false;
    surface_.setSurface(surfaceId);
    const bool ready = surface_.isReady();
    error_.store(0);
    presentedFrames_.store(0);
    active_.store(ready);
    return ready;
}

bool SecondaryVideoRender::enqueue(const uint8_t* data, int length, int width, int height,
                                   bool key, int64_t pts, int codec) {
    if (!active_.load() || error_.load() != 0 || !data || length <= 0 ||
        static_cast<size_t>(length) > MAX_FRAME_BYTES || width <= 0 || height <= 0 ||
        width > MAX_DIMENSION || height > MAX_DIMENSION ||
        (codec != 'H' && codec != '5' && codec != 'V')) return false;
    std::lock_guard<std::mutex> lock(queueMutex_);
    if (stopping_ || !active_.load()) return false;
    if (queuedCodec_ != 0 && queuedCodec_ != codec) {
        frames_.clear();
        queuedBytes_ = 0;
        presentedFrames_.store(0);
        generation_.fetch_add(1);
        refreshPending_ = true;
    }
    queuedCodec_ = codec;
    if (frames_.size() >= MAX_QUEUE_FRAMES || queuedBytes_ > MAX_QUEUE_BYTES - static_cast<size_t>(length)) {
        frames_.clear();
        queuedBytes_ = 0;
        refreshPending_ = true;
        presentedFrames_.store(0);
        generation_.fetch_add(1);
        DiagnosticLog::instance().append("W", "multi-display", "secondary_queue_overflow refresh=1");
    }
    try {
        frames_.push_back(Frame{std::vector<uint8_t>(data, data + length), width, height, codec, key, pts,
            generation_.load()});
    } catch (const std::bad_alloc&) {
        error_.store(ERR_DECODER);
        return false;
    }
    queuedBytes_ += static_cast<size_t>(length);
    ready_.notify_one();
    return true;
}

void SecondaryVideoRender::reset() {
    active_.store(false);
    generation_.fetch_add(1);
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        frames_.clear();
        queuedBytes_ = 0;
        queuedCodec_ = 0;
        refreshPending_ = false;
    }
    // Decoder teardown precedes the window release, including callbacks.
    std::lock_guard<std::mutex> lock(stateMutex_);
    releaseDecodersLocked();
    presentedFrames_.store(0);
    surface_.release();
}

void SecondaryVideoRender::run() {
    for (;;) {
        Frame frame;
        bool refresh = false;
        {
            std::unique_lock<std::mutex> lock(queueMutex_);
            ready_.wait(lock, [this]() { return stopping_ || !frames_.empty(); });
            if (stopping_) return;
            frame = std::move(frames_.front());
            queuedBytes_ -= frame.data.size();
            frames_.pop_front();
            refresh = refreshPending_;
            refreshPending_ = false;
        }
        if (refresh && active_.load()) rust_refresh_video();
        if (!active_.load() || error_.load() != 0 || frame.generation != generation_.load()) continue;
        std::lock_guard<std::mutex> lock(stateMutex_);
        if (active_.load() && error_.load() == 0 && frame.generation == generation_.load()) {
            try { process(frame); }
            catch (const std::bad_alloc&) { reportDecoderError(ERR_DECODER, frame.generation); }
        }
    }
}

void SecondaryVideoRender::releaseDecodersLocked() {
    errorsEnabled_.store(false);
    // Destroy decoder workers before the surface or their captured callbacks.
    h264_.reset();
    h265_.reset();
    vp9_.reset();
    activeCodec_ = 0;
    activeWidth_ = 0;
    activeHeight_ = 0;
    activeGeneration_ = 0;
    failedOutputs_.store(0);
}

bool SecondaryVideoRender::startDecoderLocked(const Frame& frame) {
    releaseDecodersLocked();
    presentedFrames_.store(0);
    const uint64_t generation = frame.generation;
    const auto output = [this, generation, codec = frame.codec](bool ok) { reportOutput(ok, generation, codec); };
    const auto error = [this, generation](int code) {
        if (errorsEnabled_.load()) reportDecoderError(code, generation);
    };
    if (frame.codec == 'V') {
        vp9_ = std::make_unique<SoftwareVP9Decoder>(
            [this, generation](const uint8_t* data, int length, int width, int height, const VideoColorInfo&) {
                const bool ok = active_.load() && generation == generation_.load() &&
                    surface_.renderBGRAFrame(data, length, width, height);
                if (ok) reportOutput(true, generation, 'V');
                return ok;
            });
    } else {
        OHNativeWindow* window = surface_.prepareDecoderSurface();
        if (!window) return false;
        if (frame.codec == 'H') {
            h264_ = std::make_unique<H264Decoder>(&surface_, output, error);
            h264_->setSurface(window, frame.width, frame.height);
            if (!h264_->isStarted()) {
                h264_.reset();
                h264_ = std::make_unique<H264Decoder>(&surface_, output, error, true);
                h264_->setSurface(window, frame.width, frame.height);
            }
            if (!h264_->isStarted()) return false;
        } else if (frame.codec == '5') {
            h265_ = SystemVideoDecoder::createH265Secondary(&surface_, output, error);
            h265_->setSurface(window, frame.width, frame.height);
            if (!h265_->isStarted()) {
                h265_.reset();
                h265_ = SystemVideoDecoder::createH265Secondary(&surface_, output, error, true);
                h265_->setSurface(window, frame.width, frame.height);
            }
            if (!h265_->isStarted()) return false;
        } else return false;
    }
    activeCodec_ = frame.codec;
    activeWidth_ = frame.width;
    activeHeight_ = frame.height;
    activeGeneration_ = frame.generation;
    errorsEnabled_.store(true);
    DiagnosticLog::instance().append("I", "multi-display", std::string("secondary_decoder_started codec=") +
        (frame.codec == 'H' ? "h264" : frame.codec == '5' ? "h265" : "vp9"));
    return true;
}

void SecondaryVideoRender::process(const Frame& frame) {
    if (activeCodec_ != frame.codec || activeWidth_ != frame.width || activeHeight_ != frame.height ||
        activeGeneration_ != frame.generation) {
        if (!startDecoderLocked(frame)) { reportDecoderError(ERR_DECODER, frame.generation); return; }
    }
    if (frame.generation != generation_.load()) return;
    if (h264_) h264_->decodeFrame(frame.data.data(), static_cast<int>(frame.data.size()), frame.key, frame.pts);
    else if (h265_) h265_->decodeFrame(frame.data.data(), static_cast<int>(frame.data.size()), frame.key, frame.pts);
    else if (vp9_) vp9_->decodeFrame(frame.data.data(), static_cast<int>(frame.data.size()), frame.key, frame.pts);
}

void SecondaryVideoRender::reportOutput(bool presented, uint64_t generation, int codec) {
    if (!active_.load() || generation != generation_.load()) return;
    if (presented) {
        failedOutputs_.store(0);
        if (presentedFrames_.fetch_add(1) == 0) {
            const char* name = codec == 'H' ? "h264" : codec == '5' ? "h265" : "vp9";
            DiagnosticLog::instance().append("I", "multi-display", std::string("secondary_first_frame codec=") + name);
            OH_LOG_INFO(LOG_APP, "secondary_first_frame codec=%{public}s", name);
        }
    }
    else if (failedOutputs_.fetch_add(1) + 1 >= 5) reportDecoderError(ERR_DECODER, generation);
}

void SecondaryVideoRender::reportDecoderError(int code, uint64_t generation) {
    if (!active_.load() || generation != generation_.load()) return;
    int expected = 0;
    if (error_.compare_exchange_strong(expected, ERR_DECODER))
        DiagnosticLog::instance().append("E", "multi-display", "secondary_decoder_failed code=" + std::to_string(code));
}
