#include "file_transfer.h"
#include <fstream>
#include <cstring>
#include <sstream>
#include <sys/socket.h>
#include <unistd.h>
#include <arpa/inet.h>

static const size_t CHUNK_SIZE = 65536;

FileTransfer& FileTransfer::instance() {
    static FileTransfer ft;
    return ft;
}

FileTransfer::FileTransfer() {}

FileTransfer::~FileTransfer() {
    cancel();
}

void FileTransfer::setSocketFd(int fd) {
    std::lock_guard<std::mutex> lock(socketMutex_);
    socketFd_ = fd;
}

int FileTransfer::getSocketFd() {
    std::lock_guard<std::mutex> lock(socketMutex_);
    return socketFd_;
}

int FileTransfer::sendFile(const std::string& localPath, const std::string& remotePath) {
    if (status_ == FileTransferStatus::TRANSFERRING) return -1;

    size_t pos = localPath.find_last_of("/\\");
    fileName_ = (pos != std::string::npos) ? localPath.substr(pos + 1) : localPath;

    std::ifstream file(localPath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) return -1;
    totalBytes_ = file.tellg();
    file.close();

    status_ = FileTransferStatus::TRANSFERRING;
    transferredBytes_ = 0;

    if (workerThread_.joinable()) workerThread_.join();
    workerThread_ = std::thread(&FileTransfer::sendThreadFunc, this, localPath, remotePath);
    workerThread_.detach();
    return 0;
}

int FileTransfer::receiveFile(const std::string& remotePath, const std::string& localPath) {
    if (status_ == FileTransferStatus::TRANSFERRING) return -1;

    size_t pos = remotePath.find_last_of("/\\");
    fileName_ = (pos != std::string::npos) ? remotePath.substr(pos + 1) : remotePath;

    status_ = FileTransferStatus::TRANSFERRING;
    transferredBytes_ = 0;
    totalBytes_ = 0;

    if (workerThread_.joinable()) workerThread_.join();
    workerThread_ = std::thread(&FileTransfer::receiveThreadFunc, this, remotePath, localPath);
    workerThread_.detach();
    return 0;
}

void FileTransfer::sendThreadFunc(const std::string& localPath, const std::string& remotePath) {
    int fd = getSocketFd();
    if (fd < 0) {
        status_ = FileTransferStatus::FAILED;
        return;
    }

    // Send file metadata
    std::string meta = "{\"type\":\"file_transfer_request\",\"name\":\"" +
                       fileName_ + "\",\"size\":" + std::to_string(totalBytes_) +
                       ",\"remotePath\":\"" + remotePath + "\"}";
    uint32_t metaLen = htonl(meta.length());
    send(fd, &metaLen, sizeof(metaLen), 0);
    send(fd, meta.c_str(), meta.length(), 0);

    // Wait for ACK
    char ackBuf[4];
    int ackBytes = recv(fd, ackBuf, sizeof(ackBuf), MSG_WAITALL);
    if (ackBytes != 4) {
        status_ = FileTransferStatus::FAILED;
        return;
    }

    // Send file data in chunks
    std::ifstream file(localPath, std::ios::binary);
    if (!file.is_open()) {
        status_ = FileTransferStatus::FAILED;
        return;
    }

    char buffer[CHUNK_SIZE];
    while (status_ == FileTransferStatus::TRANSFERRING && file.read(buffer, CHUNK_SIZE)) {
        size_t bytesRead = file.gcount();
        if (bytesRead == 0) break;

        // Send chunk header + data
        uint32_t chunkSize = htonl(bytesRead);
        if (send(fd, &chunkSize, sizeof(chunkSize), 0) < 0) {
            status_ = FileTransferStatus::FAILED;
            file.close();
            return;
        }
        if (send(fd, buffer, bytesRead, 0) < 0) {
            status_ = FileTransferStatus::FAILED;
            file.close();
            return;
        }

        transferredBytes_ += bytesRead;

        if (progressCallback_) {
            FileTransferProgress p;
            p.status = FileTransferStatus::TRANSFERRING;
            p.fileName = fileName_;
            p.totalBytes = totalBytes_;
            p.transferredBytes = transferredBytes_;
            p.progress = totalBytes_ > 0 ? (double)transferredBytes_ / totalBytes_ : 0.0;
            progressCallback_(p);
        }
    }

    // Handle remaining bytes
    if (file.gcount() > 0) {
        size_t bytesRead = file.gcount();
        uint32_t chunkSize = htonl(bytesRead);
        send(fd, &chunkSize, sizeof(chunkSize), 0);
        send(fd, buffer, bytesRead, 0);
        transferredBytes_ += bytesRead;
    }

    file.close();

    // Send completion marker
    uint32_t doneMarker = htonl(0xFFFFFFFF);
    send(fd, &doneMarker, sizeof(doneMarker), 0);

    status_ = FileTransferStatus::COMPLETED;

    if (progressCallback_) {
        FileTransferProgress p;
        p.status = FileTransferStatus::COMPLETED;
        p.fileName = fileName_;
        p.totalBytes = totalBytes_;
        p.transferredBytes = transferredBytes_;
        p.progress = 1.0;
        progressCallback_(p);
    }
}

void FileTransfer::receiveThreadFunc(const std::string& remotePath, const std::string& localPath) {
    int fd = getSocketFd();
    if (fd < 0) {
        status_ = FileTransferStatus::FAILED;
        return;
    }

    // Send request for remote file
    std::string req = "{\"type\":\"file_transfer_request\",\"remotePath\":\"" + remotePath + "\"}";
    uint32_t reqLen = htonl(req.length());
    send(fd, &reqLen, sizeof(reqLen), 0);
    send(fd, req.c_str(), req.length(), 0);

    // Receive file metadata
    uint32_t metaLen = 0;
    if (recv(fd, &metaLen, sizeof(metaLen), MSG_WAITALL) != sizeof(metaLen)) {
        status_ = FileTransferStatus::FAILED;
        return;
    }
    metaLen = ntohl(metaLen);
    std::string meta(metaLen, '\0');
    if (recv(fd, &meta[0], metaLen, MSG_WAITALL) != (int)metaLen) {
        status_ = FileTransferStatus::FAILED;
        return;
    }

    // Parse metadata (simple parsing)
    size_t sizePos = meta.find("\"size\":");
    if (sizePos != std::string::npos) {
        size_t endPos = meta.find(',', sizePos);
        if (endPos == std::string::npos) endPos = meta.find('}', sizePos);
        std::string sizeStr = meta.substr(sizePos + 7, endPos - sizePos - 7);
        totalBytes_ = std::stoll(sizeStr);
    }

    // Send ACK
    uint32_t ack = htonl(1);
    send(fd, &ack, sizeof(ack), 0);

    // Receive chunks and write to file
    std::ofstream file(localPath, std::ios::binary);
    if (!file.is_open()) {
        status_ = FileTransferStatus::FAILED;
        return;
    }

    while (status_ == FileTransferStatus::TRANSFERRING) {
        uint32_t chunkSize = 0;
        int bytes = recv(fd, &chunkSize, sizeof(chunkSize), MSG_WAITALL);
        if (bytes != sizeof(chunkSize)) {
            status_ = FileTransferStatus::FAILED;
            break;
        }
        chunkSize = ntohl(chunkSize);

        // Check for completion marker
        if (chunkSize == 0xFFFFFFFF) {
            break;
        }

        if (chunkSize > 0) {
            char chunkBuf[CHUNK_SIZE];
            int recvd = 0;
            while (recvd < (int)chunkSize) {
                int n = recv(fd, chunkBuf + recvd, chunkSize - recvd, 0);
                if (n <= 0) {
                    status_ = FileTransferStatus::FAILED;
                    file.close();
                    return;
                }
                recvd += n;
            }
            file.write(chunkBuf, recvd);
            transferredBytes_ += recvd;

            if (progressCallback_) {
                FileTransferProgress p;
                p.status = FileTransferStatus::TRANSFERRING;
                p.fileName = fileName_;
                p.totalBytes = totalBytes_;
                p.transferredBytes = transferredBytes_;
                p.progress = totalBytes_ > 0 ? (double)transferredBytes_ / totalBytes_ : 0.0;
                progressCallback_(p);
            }
        }
    }

    file.close();
    status_ = FileTransferStatus::COMPLETED;

    if (progressCallback_) {
        FileTransferProgress p;
        p.status = FileTransferStatus::COMPLETED;
        p.fileName = fileName_;
        p.totalBytes = totalBytes_;
        p.transferredBytes = transferredBytes_;
        p.progress = 1.0;
        progressCallback_(p);
    }
}

FileTransferProgress FileTransfer::getProgress() {
    FileTransferProgress p;
    p.status = status_.load();
    p.fileName = fileName_;
    p.totalBytes = totalBytes_;
    p.transferredBytes = transferredBytes_;
    p.progress = totalBytes_ > 0 ? (double)transferredBytes_ / totalBytes_ : 0.0;
    return p;
}

void FileTransfer::cancel() {
    status_ = FileTransferStatus::IDLE;
}

void FileTransfer::setOnProgressCallback(std::function<void(const FileTransferProgress&)> callback) {
    progressCallback_ = callback;
}
