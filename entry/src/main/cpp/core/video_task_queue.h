#ifndef RUSTDESK_VIDEO_TASK_QUEUE_H
#define RUSTDESK_VIDEO_TASK_QUEUE_H

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <atomic>

// Codec callbacks must return without waiting for decoder state: Configure,
// Start, PushInputBuffer and Stop may synchronously wait for those callbacks.
// The codec owns a finite set of buffers, so callback jobs are naturally bounded.
// Frame producers separately bound/coalesce their queue in VideoRender.
class VideoTaskQueue {
public:
    VideoTaskQueue() : worker_([this]() { run(); }) {}
    ~VideoTaskQueue() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
        }
        ready_.notify_one();
        worker_.join();
    }
    void post(std::function<void()> task) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            tasks_.push_back(std::move(task));
        }
        ready_.notify_one();
    }

private:
    void run() {
        for (;;) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                ready_.wait(lock, [this]() { return stopping_ || !tasks_.empty(); });
                if (tasks_.empty() && stopping_) return;
                task = std::move(tasks_.front());
                tasks_.pop_front();
            }
            task(); // Never hold the producer mutex during driver calls.
        }
    }
    std::mutex mutex_;
    std::condition_variable ready_;
    std::deque<std::function<void()>> tasks_;
    bool stopping_{false};
    std::thread worker_;
};

template<class Decoder> struct VideoCallbackContext {
    Decoder* owner;
    // Each codec lifetime gets its own token, even if a native handle is reused.
    std::shared_ptr<std::atomic<bool>> active{std::make_shared<std::atomic<bool>>(true)};
    explicit VideoCallbackContext(Decoder* decoder) : owner(decoder) {}
};

#endif
