# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(StarRustDesk)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_DISABLE_INTRINSICS ON CACHE BOOL "" FORCE)
set(OPUS_INSTALL_PKG_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
set(OPUS_INSTALL_CMAKE_CONFIG_MODULE OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/opus EXCLUDE_FROM_ALL)
target_compile_options(opus PRIVATE -O2)

add_library(entry SHARED napi_init.cpp
                       core/config.cpp
                       core/audio_player.cpp
                       core/video_render.cpp
                       core/xcomponent_render.cpp
                       core/h264_decoder.cpp
                       core/vp9_decoder.cpp
                       crypto/encrypted_stream.cpp
                       crypto/aead.cpp
                       crypto/chacha20.cpp
                       crypto/poly1305.cpp)

target_include_directories(entry PRIVATE
                    ${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${NATIVERENDER_ROOT_PATH}/core
                    ${NATIVERENDER_ROOT_PATH}/crypto)

set(NATIVE_LIBS libace_napi.z.so -lnative_window -lnative_buffer -lhilog_ndk.z -lnative_media_core -lnative_media_codecbase -lnative_media_vdec -lohaudio Opus::opus)

target_link_libraries(entry PUBLIC ${NATIVE_LIBS})

# Link Rust core library
if(CMAKE_OHOS_ARCH_ABI STREQUAL "x86_64")
    target_link_libraries(entry PUBLIC ${NATIVE_LIBS} "C:/Users/YIN/DevecostudioProjects/StarRustDesk/entry/libs/x86_64/librustdesk_core.a")
else()
    target_link_libraries(entry PUBLIC ${NATIVE_LIBS} "C:/Users/YIN/DevecostudioProjects/StarRustDesk/entry/libs/arm64-v8a/librustdesk_core.a")
endif()
