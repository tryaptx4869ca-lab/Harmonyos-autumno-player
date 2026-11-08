cmake_minimum_required(VERSION 3.5.0)
project(autumno_mpv)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

# mpv 的头文件（client.h 取自 v0.41.0，与 libmpv.so 的 API 版本 2.5 一致）
include_directories(
    ${NATIVERENDER_ROOT_PATH}
    ${NATIVERENDER_ROOT_PATH}/include
)

# libmpv.so 放在 entry/libs/arm64-v8a/，由 hvigor 打进 hap。
#
# libmpv 目前只有 aarch64 的预编译产物，而模拟器是 x86_64。
# 若只给 arm64 编 native 模块，HAP 会因为
# 「Abi type supported by the device does not match」直接装不进模拟器，
# 连纯 UI 都没法在模拟器上验证。
# 因此这里按架构分两条路：
#   arm64-v8a → 真正链接 libmpv 的桥
#   其它架构  → 同一套导出符号的空实现（模拟器上播放不可用，属预期）
if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(MPV_LIB ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}/libmpv.so)
    add_library(mpv_bridge SHARED napi_init.cpp)
    target_link_libraries(mpv_bridge PUBLIC
        libace_napi.z.so
        libace_ndk.z.so
        libnative_window.so
        libhilog_ndk.z.so
        ${MPV_LIB}
    )
else()
    message(STATUS "libmpv 无 ${OHOS_ARCH} 产物，改编译空实现（模拟器专用）")
    add_library(mpv_bridge SHARED napi_stub.cpp)
    target_link_libraries(mpv_bridge PUBLIC
        libace_napi.z.so
        libhilog_ndk.z.so
    )
endif()
