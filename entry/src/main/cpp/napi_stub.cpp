/**
 * mpv 桥的「空实现」，只在没有 libmpv 的架构上编译（目前是模拟器用的 x86_64）。
 *
 * 为什么需要它：libmpv 只有 aarch64 预编译产物，而模拟器是 x86_64。
 * 如果 native 模块只声明 arm64，整个 HAP 会因为
 * 「Abi type supported by the device does not match」而装不进模拟器，
 * 连纯 UI 都没法在模拟器上验证。因此这里用同一套导出符号编一个桩，
 * 让 HAP 能装能跑；模拟器上调用播放相关接口会得到明确的失败返回，
 * 真机仍然链接真正的 libmpv。
 *
 * 导出符号必须与 napi_init.cpp 完全一致，否则 ArkTS 侧会出现
 * 「is not callable」这类难查的运行时错误。
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#define LOG_DOMAIN 0x0000
#define LOG_TAG "AutumnMpv"

#define LOGI(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

/** 与真机实现保持一致：0 表示创建失败。 */
static napi_value Create(napi_env env, napi_callback_info info) {
  LOGI("mpv stub: create() called on an ABI without libmpv");
  napi_value result = nullptr;
  napi_create_int32(env, 0, &result);
  return result;
}

static napi_value Destroy(napi_env env, napi_callback_info info) {
  return nullptr;
}

static napi_value SetOption(napi_env env, napi_callback_info info) {
  return nullptr;
}

static napi_value SetProperty(napi_env env, napi_callback_info info) {
  return nullptr;
}

static napi_value GetProperty(napi_env env, napi_callback_info info) {
  napi_value result = nullptr;
  napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &result);
  return result;
}

static napi_value Command(napi_env env, napi_callback_info info) {
  return nullptr;
}

static napi_value AttachSurface(napi_env env, napi_callback_info info) {
  return nullptr;
}

static napi_value SetSurfaceSize(napi_env env, napi_callback_info info) {
  return nullptr;
}

static napi_value HasSurface(napi_env env, napi_callback_info info) {
  napi_value result = nullptr;
  napi_get_boolean(env, false, &result);
  return result;
}

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
  napi_property_descriptor desc[] = {
      {"create", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"destroy", nullptr, Destroy, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setOption", nullptr, SetOption, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setProperty", nullptr, SetProperty, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"getProperty", nullptr, GetProperty, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"command", nullptr, Command, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"attachSurface", nullptr, AttachSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"setSurfaceSize", nullptr, SetSurfaceSize, nullptr, nullptr, nullptr, napi_default, nullptr},
      {"hasSurface", nullptr, HasSurface, nullptr, nullptr, nullptr, napi_default, nullptr},
  };
  napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
  return exports;
}
EXTERN_C_END

static napi_module mpvBridgeStubModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mpv_bridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMpvBridgeStubModule(void) {
  napi_module_register(&mpvBridgeStubModule);
}
