#include "service.h"
#include <cstring>
#include <cstdlib>
#include <ctime>
#include <sstream>
#include <vector>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <fcntl.h>

Service& Service::instance() {
    static Service svc;
    return svc;
}

static void generate_uuid(char* buf, int len) {
    if (len < 13) return;
    int fd = open("/dev/urandom", O_RDONLY);
    unsigned char rnd[8];
    int got = 0;
    if (fd >= 0) {
        int n = read(fd, rnd, sizeof(rnd));
        if (n > 0) got = n;
        close(fd);
    }
    if (got < (int)sizeof(rnd)) {
        for (int i = 0; i < (int)sizeof(rnd); i++) {
            rnd[i] = (unsigned char)((uintptr_t)&rnd ^ time(nullptr) ^ (i * 137));
        }
    }
    snprintf(buf, len, "%03u-%03u-%03u",
             (unsigned)(rnd[0] | (rnd[1] << 8)) % 900 + 100,
             (unsigned)(rnd[2] | (rnd[3] << 8)) % 900 + 100,
             (unsigned)(rnd[4] | (rnd[5] << 8)) % 900 + 100);
}

Service::Service() {
    char idBuf[16];
    generate_uuid(idBuf, sizeof(idBuf));
    deviceId_ = idBuf;
}

Service::~Service() {
    stop();
}

int Service::start() {
    if (running_) return -1;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(21118);

    if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(sock);
        return -1;
    }

    if (listen(sock, 5) < 0) {
        close(sock);
        return -1;
    }

    serverSocket_ = sock;
    running_ = true;

    if (workerThread_.joinable()) {
        workerThread_.join();
    }
    workerThread_ = std::thread(&Service::serviceThreadFunc, this);
    workerThread_.detach();

    return 0;
}

void Service::stop() {
    running_ = false;
    if (serverSocket_ != -1) {
        close(serverSocket_);
        serverSocket_ = -1;
    }
}

bool Service::isRunning() {
    return running_.load();
}

std::string Service::getDeviceId() {
    return deviceId_;
}

std::vector<SessionInfo> Service::getActiveSessions() {
    std::lock_guard<std::mutex> lock(sessionsMutex_);
    return sessions_;
}

void Service::serviceThreadFunc() {
    while (running_) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(serverSocket_, &readSet);
        struct timeval timeout;
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;

        int activity = select(serverSocket_ + 1, &readSet, nullptr, nullptr, &timeout);
        if (activity < 0) break;
        if (activity == 0) continue;

        struct sockaddr_in clientAddr;
        socklen_t addrLen = sizeof(clientAddr);
        int clientSock = accept(serverSocket_, (struct sockaddr*)&clientAddr, &addrLen);
        if (clientSock < 0) continue;

        std::string addrStr = inet_ntoa(clientAddr.sin_addr);
        handleClient(clientSock, addrStr);
    }
}

void Service::handleClient(int clientSock, const std::string& clientAddr) {
    char buffer[4096];
    int bytes = recv(clientSock, buffer, sizeof(buffer) - 1, 0);
    if (bytes <= 0) {
        close(clientSock);
        return;
    }
    buffer[bytes] = '\0';
    std::string request(buffer);

    // Parse peer ID from login request
    std::string peerId;
    size_t idPos = request.find("\"id\":\"");
    if (idPos != std::string::npos) {
        idPos += 6;
        size_t endPos = request.find('"', idPos);
        if (endPos != std::string::npos) {
            peerId = request.substr(idPos, endPos - idPos);
        }
    }

    // Send login response
    std::string response = "{\"type\":\"login_response\",\"success\":true,\"id\":\"" +
                           deviceId_ + "\"}";
    send(clientSock, response.c_str(), response.length(), 0);

    // Track session
    if (!peerId.empty()) {
        std::lock_guard<std::mutex> lock(sessionsMutex_);
        // Remove existing session for same peer
        for (auto it = sessions_.begin(); it != sessions_.end();) {
            if (it->peerId == peerId || it->fd == clientSock) {
                close(it->fd);
                it = sessions_.erase(it);
            } else {
                ++it;
            }
        }
        SessionInfo info;
        info.fd = clientSock;
        info.peerId = peerId;
        info.clientAddr = clientAddr;
        info.connectedAt = time(nullptr);
        sessions_.push_back(info);
    }
}

// C-linkage wrappers for NAPI bridge
extern "C" int start_service_cpp() {
    return Service::instance().start();
}

extern "C" void stop_service_cpp() {
    Service::instance().stop();
}
