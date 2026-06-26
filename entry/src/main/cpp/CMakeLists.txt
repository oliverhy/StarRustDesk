# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(StarRustDesk)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${NATIVERENDER_ROOT_PATH}/core
                    ${NATIVERENDER_ROOT_PATH}/crypto)

add_library(entry SHARED napi_init.cpp
                       core/config.cpp
                       core/service.cpp
                       core/video_render.cpp
                       core/xcomponent_render.cpp
                       core/h264_decoder.cpp
                       core/vp9_decoder.cpp
                       core/connection.cpp
                       core/file_transfer.cpp
                       crypto/encrypted_stream.cpp
                       crypto/aead.cpp
                       crypto/chacha20.cpp
                       crypto/poly1305.cpp)

set(NATIVE_LIBS libace_napi.z.so -lnative_window -lnative_buffer -lhilog_ndk.z -lnative_media_core -lnative_media_codecbase -lnative_media_vdec)

target_link_libraries(entry PUBLIC ${NATIVE_LIBS})

# Link Rust core library
if(CMAKE_OHOS_ARCH_ABI STREQUAL "x86_64")
    target_link_libraries(entry PUBLIC ${NATIVE_LIBS} "C:/Users/YIN/DevecostudioProjects/StarRustDesk/entry/libs/x86_64/librustdesk_core.a")
else()
    target_link_libraries(entry PUBLIC ${NATIVE_LIBS} "C:/Users/YIN/DevecostudioProjects/StarRustDesk/entry/libs/arm64-v8a/librustdesk_core.a")
endif()
