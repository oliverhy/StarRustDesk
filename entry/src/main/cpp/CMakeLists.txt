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

add_library(vpx STATIC IMPORTED)
add_library(yuv STATIC IMPORTED)
add_library(aom STATIC IMPORTED)
if(CMAKE_OHOS_ARCH_ABI STREQUAL "x86_64")
    set_target_properties(vpx PROPERTIES IMPORTED_LOCATION
        "${NATIVERENDER_ROOT_PATH}/third_party/libvpx/libs/x86_64/libvpx.a")
    set_target_properties(yuv PROPERTIES IMPORTED_LOCATION
        "${NATIVERENDER_ROOT_PATH}/third_party/libyuv/libs/x86_64/libyuv.a")
    set_target_properties(aom PROPERTIES IMPORTED_LOCATION
        "${NATIVERENDER_ROOT_PATH}/third_party/aom/libs/x86_64/libaom.a")
else()
    set_target_properties(vpx PROPERTIES IMPORTED_LOCATION
        "${NATIVERENDER_ROOT_PATH}/third_party/libvpx/libs/arm64-v8a/libvpx.a")
    set_target_properties(yuv PROPERTIES IMPORTED_LOCATION
        "${NATIVERENDER_ROOT_PATH}/third_party/libyuv/libs/arm64-v8a/libyuv.a")
    set_target_properties(aom PROPERTIES IMPORTED_LOCATION
        "${NATIVERENDER_ROOT_PATH}/third_party/aom/libs/arm64-v8a/libaom.a")
endif()

add_library(entry SHARED napi_init.cpp
                       core/config.cpp
                       core/diagnostic_log.cpp
                       core/audio_player.cpp
                       core/video_render.cpp
                       core/video_decoder_selector.cpp
                       core/xcomponent_render.cpp
                       core/h264_decoder.cpp
                       core/vp9_decoder.cpp
                       core/system_video_decoder.cpp
                       core/software_vp8_decoder.cpp
                       core/software_vp9_decoder.cpp
                       core/software_av1_decoder.cpp
                       crypto/encrypted_stream.cpp
                       crypto/aead.cpp
                       crypto/chacha20.cpp
                       crypto/poly1305.cpp)

target_include_directories(entry PRIVATE
                    ${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include
                    ${NATIVERENDER_ROOT_PATH}/core
                    ${NATIVERENDER_ROOT_PATH}/crypto
                    ${NATIVERENDER_ROOT_PATH}/third_party/libvpx/include
                    ${NATIVERENDER_ROOT_PATH}/third_party/aom/include
                    ${NATIVERENDER_ROOT_PATH}/third_party/libyuv/include)

set(NATIVE_LIBS libace_napi.z.so libace_ndk.z.so libohinput.so -ldl -lnative_window -lnative_buffer -lhilog_ndk.z -lnative_media_core -lnative_media_codecbase -lnative_media_vdec -lohaudio Opus::opus vpx aom yuv)

target_link_libraries(entry PUBLIC ${NATIVE_LIBS})

# Link Rust core library
if(CMAKE_OHOS_ARCH_ABI STREQUAL "x86_64")
    target_link_libraries(entry PUBLIC ${NATIVE_LIBS} "C:/Users/YIN/DevecostudioProjects/StarRustDesk/entry/libs/x86_64/librustdesk_core.a")
else()
    target_link_libraries(entry PUBLIC ${NATIVE_LIBS} "C:/Users/YIN/DevecostudioProjects/StarRustDesk/entry/libs/arm64-v8a/librustdesk_core.a")
endif()
