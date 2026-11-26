// One-use address hint for the isolated no-WAN, view-only USB lab. No credential, port or saved-profile override.
#pragma once
#if !defined(SESAME_SUNSHINE_COMPANION) || !defined(SESAME_SUNSHINE_LONG_BENCH) || defined(SESAME_SUNSHINE_COMPANION_WAN)
#error Invalid test candidate scope
#endif
#include <ifaddrs.h>

static std::string benchLanCandidate()
{
    constexpr auto path="/data/storage/el2/base/files/.sesame-bench-lan-v1";
    const int fd=open(path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return {};
    struct stat st{}, parent{};
    char buf[16]{};
    // HDC sharefs maps the file owner and group to this bundle. Group write is
    // acceptable only for the same private app GID, never for other users.
    const bool regular=stat("/data/storage/el2/base/files",&parent)==0 &&
        S_ISDIR(parent.st_mode) && parent.st_uid==geteuid() && fstat(fd,&st)==0 &&
        S_ISREG(st.st_mode) && st.st_nlink==1 && (st.st_mode&0002)==0 &&
        st.st_uid==geteuid() && (!(st.st_mode&0020) || st.st_gid==getegid()) &&
        st.st_size>=7 && st.st_size<=15;
    const auto n=regular?read(fd,buf,static_cast<size_t>(st.st_size)):-1;
    close(fd);
    if (!regular || n!=st.st_size || std::strlen(buf)!=static_cast<size_t>(n) || unlink(path)!=0) return {};
    in_addr dest{};
    if (inet_pton(AF_INET,buf,&dest)!=1) return {};
    ifaddrs* all=nullptr;
    if (getifaddrs(&all)!=0) return {};
    bool ok=false;
    for (auto it=all;it;it=it->ifa_next) {
        if (!it->ifa_name || std::strcmp(it->ifa_name,"wlan0")!=0 || !it->ifa_addr || it->ifa_addr->sa_family!=AF_INET) continue;
        if (companionSameLan(reinterpret_cast<sockaddr_in*>(it->ifa_addr)->sin_addr,dest)) ok=true;
    }
    freeifaddrs(all);
    return ok?std::string(buf):std::string();
}
