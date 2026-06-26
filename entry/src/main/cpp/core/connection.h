#ifndef RUSTDESK_CORE_CONNECTION_H
#define RUSTDESK_CORE_CONNECTION_H

#include <string>
#include <thread>
#include <mutex>
#include <functional>
#include <atomic>
#include <vector>
#include "../crypto/encrypted_stream.h"

enum class ConnectionState {
    DISCONNECTED = 0,
    CONNECTING = 1,
    CONNECTED = 2,
    FAILED = 3
};

enum class MouseAction {
    MOVE = 0,
    LEFT_DOWN = 1,
    LEFT_UP = 2,
    RIGHT_DOWN = 3,
    RIGHT_UP = 4,
    WHEEL = 5
};

enum class KeyAction {
    DOWN = 0,
    UP = 1
};

class Connection {
public:
    static Connection& instance();

    int connect(const std::string& peerId, const std::string& password,
                const std::string& rendezvousServer = "",
                const std::string& relayServer = "");
    void disconnect();

    int sendMouseEvent(double x, double y, int action);
    int sendKeyEvent(int keyCode, int action);

    ConnectionState getState();
    std::string getPeerId();
    int getSocketFd();

    void setOnFrameCallback(std::function<void(const uint8_t*, int, int, int)> callback);

private:
    Connection();
    ~Connection();

    void connectionThreadFunc(const std::string& peerId, const std::string& password,
                              const std::string& rendezvousServer, const std::string& relayServer);
    void handlePeerRelay(int relayFd, const std::string& peerId, const std::string& password);

    std::atomic<ConnectionState> state_{ConnectionState::DISCONNECTED};
    int socketFd_{-1};
    int peerSocketFd_{-1};
    std::string peerId_;
    std::string password_;
    std::string myDeviceId_;
    std::thread workerThread_;
    std::mutex mutex_;
    EncryptedStream encryptedStream_;
    bool encryptionEnabled_{false};
    std::function<void(const uint8_t*, int, int, int)> frameCallback_;
};

#endif
