#ifndef RUSTDESK_CORE_SERVICE_H
#define RUSTDESK_CORE_SERVICE_H

#include <string>
#include <thread>
#include <atomic>
#include <vector>
#include <mutex>

struct SessionInfo {
    int fd;
    std::string peerId;
    std::string clientAddr;
    time_t connectedAt;
};

class Service {
public:
    static Service& instance();

    int start();
    void stop();
    bool isRunning();

    std::string getDeviceId();
    std::vector<SessionInfo> getActiveSessions();

private:
    Service();
    ~Service();
    void serviceThreadFunc();
    void handleClient(int clientSock, const std::string& clientAddr);

    std::atomic<bool> running_{false};
    std::thread workerThread_;
    int serverSocket_{-1};
    std::string deviceId_;
    std::vector<SessionInfo> sessions_;
    std::mutex sessionsMutex_;
};

#endif
