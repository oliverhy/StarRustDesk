#include "connection.h"
#include "video_render.h"
#include "service.h"
#include <cstring>
#include <chrono>
#include <thread>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <fcntl.h>
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x0001
#define LOG_TAG "RustDeskConn"

static int resolve_host(const std::string& hostname, int port, struct sockaddr_in& addr) {
    struct addrinfo hints, *res = nullptr;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    std::string portStr = std::to_string(port);
    int ret = getaddrinfo(hostname.c_str(), portStr.c_str(), &hints, &res);
    if (ret != 0 || !res) {
        OH_LOG_ERROR(LOG_APP, "DNS resolution failed for %{public}s: %{public}s", hostname.c_str(), gai_strerror(ret));
        return -1;
    }
    memcpy(&addr, res->ai_addr, sizeof(struct sockaddr_in));
    freeaddrinfo(res);
    return 0;
}

static int tcp_connect(const std::string& host, int port, int timeoutSec) {
    struct sockaddr_in addr;
    if (resolve_host(host, port, addr) != 0) return -1;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);

    int ret = ::connect(sock, (struct sockaddr*)&addr, sizeof(addr));
    if (ret < 0) {
        if (errno != EINPROGRESS) { close(sock); return -1; }
        fd_set fdset;
        FD_ZERO(&fdset);
        FD_SET(sock, &fdset);
        struct timeval tv;
        tv.tv_sec = timeoutSec;
        tv.tv_usec = 0;
        if (select(sock + 1, nullptr, &fdset, nullptr, &tv) <= 0) {
            close(sock);
            return -1;
        }
    }

    fcntl(sock, F_SETFL, flags);
    return sock;
}

static int send_all(int fd, const uint8_t* data, size_t len) {
    size_t total = 0;
    while (total < len) {
        int n = send(fd, data + total, len - total, 0);
        if (n <= 0) return -1;
        total += n;
    }
    return (int)total;
}

static int recv_all(int fd, uint8_t* data, size_t len) {
    size_t total = 0;
    while (total < len) {
        int n = recv(fd, data + total, len - total, 0);
        if (n <= 0) return -1;
        total += n;
    }
    return (int)total;
}

static int send_msg(int fd, const std::string& msg) {
    uint32_t len = (uint32_t)msg.length();
    uint8_t header[4] = {0};
    size_t headerLen = 0;
    if (len <= 0x3F) {
        header[0] = (uint8_t)(len << 2);
        headerLen = 1;
    } else if (len <= 0x3FFF) {
        uint16_t h = (uint16_t)((len << 2) | 0x1);
        header[0] = (uint8_t)(h & 0xFF);
        header[1] = (uint8_t)((h >> 8) & 0xFF);
        headerLen = 2;
    } else if (len <= 0x3FFFFF) {
        uint32_t h = (len << 2) | 0x2;
        header[0] = (uint8_t)(h & 0xFF);
        header[1] = (uint8_t)((h >> 8) & 0xFF);
        header[2] = (uint8_t)((h >> 16) & 0xFF);
        headerLen = 3;
    } else if (len <= 0x3FFFFFFF) {
        uint32_t h = (len << 2) | 0x3;
        header[0] = (uint8_t)(h & 0xFF);
        header[1] = (uint8_t)((h >> 8) & 0xFF);
        header[2] = (uint8_t)((h >> 16) & 0xFF);
        header[3] = (uint8_t)((h >> 24) & 0xFF);
        headerLen = 4;
    } else {
        return -1;
    }
    if (send_all(fd, header, headerLen) < 0) return -1;
    return send_all(fd, (const uint8_t*)msg.data(), msg.length());
}

static int recv_msg(int fd, std::string& out, int timeoutSec) {
    fd_set readSet;
    struct timeval tv;
    tv.tv_sec = timeoutSec;
    tv.tv_usec = 0;
    FD_ZERO(&readSet);
    FD_SET(fd, &readSet);
    int ret = select(fd + 1, &readSet, nullptr, nullptr, &tv);
    if (ret <= 0) return -1;

    uint8_t header[4] = {0};
    if (recv_all(fd, header, 1) != 1) return -1;
    size_t headerLen = (header[0] & 0x3) + 1;
    if (headerLen > 1 && recv_all(fd, header + 1, headerLen - 1) != (int)(headerLen - 1)) return -1;

    uint32_t n = header[0];
    if (headerLen > 1) n |= ((uint32_t)header[1]) << 8;
    if (headerLen > 2) n |= ((uint32_t)header[2]) << 16;
    if (headerLen > 3) n |= ((uint32_t)header[3]) << 24;
    uint32_t msgLen = n >> 2;
    if (msgLen > 1024 * 1024) return -1;

    out.resize(msgLen);
    if (msgLen == 0) return 0;
    if (recv_all(fd, (uint8_t*)&out[0], msgLen) != (int)msgLen) return -1;
    return msgLen;
}

Connection& Connection::instance() {
    static Connection conn;
    return conn;
}

Connection::Connection() {
    myDeviceId_ = Service::instance().getDeviceId();
}

Connection::~Connection() {
    disconnect();
}

int Connection::connect(const std::string& peerId, const std::string& password,
                        const std::string& rendezvousServer, const std::string& relayServer) {
    if (state_ == ConnectionState::CONNECTED || state_ == ConnectionState::CONNECTING) {
        return -1;
    }

    state_ = ConnectionState::CONNECTING;
    peerId_ = peerId;
    password_ = password;

    if (workerThread_.joinable()) {
        workerThread_.join();
    }

    workerThread_ = std::thread(&Connection::connectionThreadFunc, this,
                                peerId, password, rendezvousServer, relayServer);
    workerThread_.detach();

    return 0;
}

void Connection::disconnect() {
    state_ = ConnectionState::DISCONNECTED;
    std::lock_guard<std::mutex> lock(mutex_);
    if (socketFd_ != -1) {
        close(socketFd_);
        socketFd_ = -1;
    }
    if (peerSocketFd_ != -1) {
        close(peerSocketFd_);
        peerSocketFd_ = -1;
    }
}

void Connection::connectionThreadFunc(const std::string& peerId, const std::string& password,
                                       const std::string& rendezvousServer, const std::string& relayServer) {
    std::string server = rendezvousServer;
    if (server.empty()) {
        server = "rustdesk.com";
    }
    int port = 21116;

    OH_LOG_INFO(LOG_APP, "Connecting to rendezvous server %{public}s:%d", server.c_str(), port);

    // Step 1: Connect to rendezvous server
    int sock = tcp_connect(server, port, 5);
    if (sock < 0) {
        OH_LOG_ERROR(LOG_APP, "Failed to connect to rendezvous server");
        state_ = ConnectionState::FAILED;
        return;
    }

    {
        std::lock_guard<std::mutex> lock(mutex_);
        socketFd_ = sock;
    }

    // Step 2: Register with the server
    // First send a login/register message with our device ID
    std::string loginMsg = "{\"type\":\"login\",\"id\":\"" + myDeviceId_ + "\"}";
    send_msg(sock, loginMsg);

    // Wait for login response
    std::string loginResp;
    if (recv_msg(sock, loginResp, 5) <= 0) {
        OH_LOG_ERROR(LOG_APP, "No login response from server");
        close(sock);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            socketFd_ = -1;
        }
        state_ = ConnectionState::FAILED;
        return;
    }
    OH_LOG_INFO(LOG_APP, "Login response: %{public}s", loginResp.c_str());

    // Step 3: Send peer_connect request to ask server to connect us to the target peer
    std::string connectMsg = "{\"type\":\"peer_connect\",\"id\":\"" + peerId + "\"}";
    send_msg(sock, connectMsg);
    OH_LOG_INFO(LOG_APP, "Sent peer_connect request for peer %{public}s", peerId.c_str());

    // Step 4: Wait for server response - either punch_hole or relay info
    std::string response;
    if (recv_msg(sock, response, 10) <= 0) {
        OH_LOG_ERROR(LOG_APP, "No response to peer_connect request");
        close(sock);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            socketFd_ = -1;
        }
        state_ = ConnectionState::FAILED;
        return;
    }
    OH_LOG_INFO(LOG_APP, "Server response: %{public}s", response.c_str());

    // Step 5: Handle the response
    if (response.find("\"type\":\"punch_hole\"") != std::string::npos ||
        response.find("\"type\":\"connect_response\"") != std::string::npos) {
        // Server is facilitating P2P or relay connection
        // Extract relay server address if provided
        std::string relayHost;
        int relayPort = 21117;

        size_t addrPos = response.find("\"addr\":\"");
        if (addrPos != std::string::npos) {
            addrPos += 8;
            size_t endPos = response.find('"', addrPos);
            if (endPos != std::string::npos) {
                std::string addrFull = response.substr(addrPos, endPos - addrPos);
                size_t colonPos = addrFull.find(':');
                if (colonPos != std::string::npos) {
                    relayHost = addrFull.substr(0, colonPos);
                    relayPort = std::stoi(addrFull.substr(colonPos + 1));
                } else {
                    relayHost = addrFull;
                }
            }
        }

        // Also check for punch_hole fields
        if (relayHost.empty()) {
            size_t hostPos = response.find("\"host\":\"");
            if (hostPos != std::string::npos) {
                hostPos += 7;
                size_t endPos = response.find('"', hostPos);
                if (endPos != std::string::npos) {
                    relayHost = response.substr(hostPos, endPos - hostPos);
                }
            }
            size_t portPos = response.find("\"port\":");
            if (portPos != std::string::npos) {
                portPos += 7;
                size_t endPos = response.find_first_of(",}", portPos);
                if (endPos != std::string::npos) {
                    relayPort = std::stoi(response.substr(portPos, endPos - portPos));
                }
            }
        }

        // Send punch_hole_ack to acknowledge
        send_msg(sock, "{\"type\":\"punch_hole_ack\"}");

        // Try to connect via relay if we got an address
        if (!relayHost.empty()) {
            OH_LOG_INFO(LOG_APP, "Connecting to peer via relay %{public}s:%d", relayHost.c_str(), relayPort);
            int peerSock = tcp_connect(relayHost, relayPort, 5);
            if (peerSock >= 0) {
                std::lock_guard<std::mutex> lock(mutex_);
                peerSocketFd_ = peerSock;
                state_ = ConnectionState::CONNECTED;
                OH_LOG_INFO(LOG_APP, "Connected to peer via relay");
            } else {
                OH_LOG_WARN(LOG_APP, "Failed to connect via relay, using rendezvous socket");
                state_ = ConnectionState::CONNECTED;
            }
        } else {
            state_ = ConnectionState::CONNECTED;
        }
    } else if (response.find("\"success\":false") != std::string::npos) {
        OH_LOG_ERROR(LOG_APP, "Server rejected connection: %{public}s", response.c_str());
        close(sock);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            socketFd_ = -1;
        }
        state_ = ConnectionState::FAILED;
        return;
    } else {
        // Unknown response, try to continue anyway
        OH_LOG_WARN(LOG_APP, "Unexpected server response, continuing: %{public}s", response.c_str());
        state_ = ConnectionState::CONNECTED;
    }

    // Step 6: Main message loop - read from the peer connection
    int activeFd = (peerSocketFd_ != -1) ? peerSocketFd_ : sock;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        socketFd_ = activeFd;
    }

    OH_LOG_INFO(LOG_APP, "Entering main message loop on fd %d", activeFd);

    char buffer[65536];
    while (state_ == ConnectionState::CONNECTED) {
        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(activeFd, &readSet);
        struct timeval timeout;
        timeout.tv_sec = 3;
        timeout.tv_usec = 0;

        int activity = select(activeFd + 1, &readSet, nullptr, nullptr, &timeout);
        if (activity < 0) {
            OH_LOG_ERROR(LOG_APP, "select failed: %{public}d", errno);
            break;
        }
        if (activity == 0) {
            // Timeout - send keepalive to rendezvous server
            if (sock >= 0) {
                send_msg(sock, "{\"type\":\"ping\"}");
            }
            continue;
        }

        int bytes = recv(activeFd, buffer, sizeof(buffer) - 1, 0);
        if (bytes <= 0) {
            OH_LOG_ERROR(LOG_APP, "Peer connection closed: %{public}d", bytes);
            break;
        }
        buffer[bytes] = '\0';

        std::string data(buffer, bytes);
        OH_LOG_INFO(LOG_APP, "Received %d bytes from peer", bytes);

        // Handle video frames
        if (data.find("frame") != std::string::npos ||
            data.find("\"type\":\"video_frame\"") != std::string::npos) {
            VideoRender::instance().onFrameReceived((const uint8_t*)data.c_str(), data.length(), 1920, 1080);
            if (frameCallback_) {
                frameCallback_((const uint8_t*)data.c_str(), data.length(), 1920, 1080);
            }
        } else if (data.find("punch_hole") != std::string::npos) {
            send_msg(activeFd, "{\"type\":\"punch_hole_ack\"}");
        } else if (data.find("login_response") != std::string::npos) {
            OH_LOG_INFO(LOG_APP, "Login acknowledged");
        } else if (data.find("video_frame") != std::string::npos) {
            // Parse video frame data (simplified)
            // In a full implementation, we'd extract binary frame data
            VideoRender::instance().onFrameReceived((const uint8_t*)data.c_str(), data.length(), 1920, 1080);
        }
    }

    OH_LOG_INFO(LOG_APP, "Connection loop ended, cleaning up");
    close(activeFd);
    if (sock >= 0 && sock != activeFd) close(sock);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        socketFd_ = -1;
        peerSocketFd_ = -1;
    }
    state_ = ConnectionState::DISCONNECTED;
}

int Connection::sendMouseEvent(double x, double y, int action) {
    std::lock_guard<std::mutex> lock(mutex_);
    int fd = (peerSocketFd_ != -1) ? peerSocketFd_ : socketFd_;
    if (fd == -1) return -1;

    std::string msg = "{\"type\":\"mouse\",\"x\":" + std::to_string((int)x) +
                      ",\"y\":" + std::to_string((int)y) +
                      ",\"action\":" + std::to_string(action) + "}";

    return send_msg(fd, msg);
}

int Connection::sendKeyEvent(int keyCode, int action) {
    std::lock_guard<std::mutex> lock(mutex_);
    int fd = (peerSocketFd_ != -1) ? peerSocketFd_ : socketFd_;
    if (fd == -1) return -1;

    std::string msg = "{\"type\":\"key\",\"code\":" + std::to_string(keyCode) +
                      ",\"action\":" + std::to_string(action) + "}";

    return send_msg(fd, msg);
}

ConnectionState Connection::getState() {
    return state_.load();
}

std::string Connection::getPeerId() {
    return peerId_;
}

int Connection::getSocketFd() {
    std::lock_guard<std::mutex> lock(mutex_);
    return (peerSocketFd_ != -1) ? peerSocketFd_ : socketFd_;
}

void Connection::setOnFrameCallback(std::function<void(const uint8_t*, int, int, int)> callback) {
    frameCallback_ = callback;
}
