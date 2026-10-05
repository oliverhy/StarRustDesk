#include "video_task_queue.h"
#include <cassert>
#include <chrono>
#include <future>
#include <iostream>

using namespace std::chrono_literals;

int main() {
    std::mutex decoderMutex;
    std::atomic<int> inputs{0};
    VideoTaskQueue callbacks;
    VideoCallbackContext<int> oldCodec(nullptr);
    const auto oldToken = oldCodec.active;

    // Simulate Stop/Start holding decoder state and waiting for a native
    // callback to return. The callback must NOT wait for the state lock.
    {
        std::lock_guard<std::mutex> state(decoderMutex);
        auto nativeCallback = std::async(std::launch::async, [&]() {
            callbacks.post([&decoderMutex, &inputs, oldToken]() {
                std::lock_guard<std::mutex> state(decoderMutex);
                if (oldToken->load()) ++inputs;
            });
        });
        assert(nativeCallback.wait_for(1s) == std::future_status::ready);
        nativeCallback.get();
        oldToken->store(false);
    }
    VideoCallbackContext<int> newCodec(nullptr);
    const auto newToken = newCodec.active;
    std::promise<void> completed;
    callbacks.post([&]() {
        std::lock_guard<std::mutex> state(decoderMutex);
        if (newToken->load()) ++inputs;
        completed.set_value();
    });
    assert(completed.get_future().wait_for(1s) == std::future_status::ready);
    assert(inputs == 1); // Old callback cannot affect the replacement codec.

    // Even when the consumer/driver is stuck, producers never run its work
    // inline and can continue receiving/sending control messages.
    std::promise<void> entered, release, drained;
    auto unblock = release.get_future().share();
    VideoTaskQueue frames;
    frames.post([&]() { entered.set_value(); unblock.wait(); });
    entered.get_future().wait();
    auto producer = std::async(std::launch::async, [&]() {
        frames.post([&]() { drained.set_value(); });
    });
    assert(producer.wait_for(1s) == std::future_status::ready);
    release.set_value();
    assert(drained.get_future().wait_for(1s) == std::future_status::ready);
    std::cout << "PASS native callback reentrancy, stale codec token, nonblocking producer\n";
}
