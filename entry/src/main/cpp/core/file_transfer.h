#ifndef RUSTDESK_CORE_FILE_TRANSFER_H
#define RUSTDESK_CORE_FILE_TRANSFER_H

#include <string>
#include <thread>
#include <atomic>
#include <functional>

enum class FileTransferDirection {
    SEND = 0,
    RECEIVE = 1
};

enum class FileTransferStatus {
    IDLE = 0,
    TRANSFERRING = 1,
    COMPLETED = 2,
    FAILED = 3
};

struct FileTransferProgress {
    FileTransferStatus status;
    std::string fileName;
    int64_t totalBytes;
    int64_t transferredBytes;
    double progress; // 0.0 ~ 1.0
};

class FileTransfer {
public:
    static FileTransfer& instance();

    int sendFile(const std::string& localPath, const std::string& remotePath);
    int receiveFile(const std::string& remotePath, const std::string& localPath);

    void setSocketFd(int fd);
    int getSocketFd();

    FileTransferProgress getProgress();
    void cancel();

    void setOnProgressCallback(std::function<void(const FileTransferProgress&)> callback);

private:
    FileTransfer();
    ~FileTransfer();

    void sendThreadFunc(const std::string& localPath, const std::string& remotePath);
    void receiveThreadFunc(const std::string& remotePath, const std::string& localPath);

    std::atomic<FileTransferStatus> status_{FileTransferStatus::IDLE};
    std::string fileName_;
    int64_t totalBytes_{0};
    int64_t transferredBytes_{0};
    std::thread workerThread_;
    int socketFd_{-1};
    std::mutex socketMutex_;
    std::function<void(const FileTransferProgress&)> progressCallback_;
};

#endif
