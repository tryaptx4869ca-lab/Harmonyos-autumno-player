/*
 * 秋绪原生版 · mpv 桥
 *
 * 属性设置顺序严格对齐参照实现
 * media_kit_video/lib/src/video_controller/ohos_video_controller/real.dart:164-183：
 *
 *   1. 先把 vo 置为 "null"
 *      （注释原文：MPV's HarmonyOS video output requires a valid surface ID
 *        before the GPU video output is initialized.）
 *   2. 设置 ohos-surface-size / wid / hwdec / vid / force-window / sub-* / osd-font
 *   3. 再把 vo 设回实际渲染器（默认 gpu-next）
 *
 * wid 的语义是 OHNativeWindow 的指针地址，mpv 直接把画面渲染进该 surface，
 * 因此无需 EGL、无需渲染上下文、无需自建渲染循环。
 */

#include <ace/xcomponent/native_interface_xcomponent.h>
#include <hilog/log.h>
#include <napi/native_api.h>
#include <native_window/external_window.h>

#include <mpv/client.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#define LOG_DOMAIN 0x0000
#define LOG_TAG "AutumnMpv"
#define LOGI(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) \
  OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace {

struct Player {
  mpv_handle *mpv = nullptr;
  std::thread eventThread;
  std::atomic<bool> running{false};
  bool surfaceAttached = false;
  std::string videoOutput = "gpu-next";
  std::string hardwareDecode = "auto";
};

std::mutex g_mutex;
std::unordered_map<int64_t, Player *> g_players;
int64_t g_nextHandle = 1;

// XComponent 回调里拿到的原生窗口，供 wid 使用
OH_NativeXComponent *g_xcomponent = nullptr;
OHNativeWindow *g_window = nullptr;
// mpv 的 wid 需要的是 surface ID（OH_NativeWindow_CreateNativeWindowFromSurfaceId
// 的入参），不是 OHNativeWindow 指针。
std::string g_surfaceId;
int64_t g_surfaceWidth = 1;
int64_t g_surfaceHeight = 1;

// ---------- 小工具 ----------

napi_value MakeUndefined(napi_env env) {
  napi_value v = nullptr;
  napi_get_undefined(env, &v);
  return v;
}

/**
 * 包一个 int32 返回值。
 *
 * `command` 要把 mpv 的返回码交给 ArkTS：成功是 0，失败是负的
 * `MPV_ERROR_*`（例如 -4 = MPV_ERROR_COMMAND、-10 = MPV_ERROR_PROPERTY_UNAVAILABLE）。
 * 以前这里返回 undefined，屏幕上「截图没反应」时日志里什么都看不到。
 */
napi_value MakeInt32(napi_env env, int32_t value) {
  napi_value v = nullptr;
  napi_create_int32(env, value, &v);
  return v;
}

void ThrowError(napi_env env, const char *msg) {
  napi_throw_error(env, nullptr, msg);
}

std::string GetString(napi_env env, napi_value value) {
  size_t len = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
    return std::string();
  }
  std::string out(len + 1, '\0');
  if (napi_get_value_string_utf8(env, value, &out[0], len + 1, &len) != napi_ok) {
    return std::string();
  }
  out.resize(len);
  return out;
}

int64_t GetInt64(napi_env env, napi_value value) {
  int64_t v = 0;
  napi_get_value_int64(env, value, &v);
  return v;
}

Player *FindPlayer(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_players.find(handle);
  return it == g_players.end() ? nullptr : it->second;
}

// ---------- mpv 事件线程 ----------

void EventLoop(Player *player) {
  while (player->running.load()) {
    mpv_event *event = mpv_wait_event(player->mpv, 0.1);
    if (event == nullptr || event->event_id == MPV_EVENT_NONE) {
      continue;
    }
    if (event->event_id == MPV_EVENT_SHUTDOWN) {
      LOGI("mpv event: shutdown");
      break;
    }
    if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
      auto *msg = static_cast<mpv_event_log_message *>(event->data);
      if (msg != nullptr) {
        LOGI("mpv[%{public}s/%{public}s] %{public}s", msg->prefix, msg->level,
             msg->text);
      }
      continue;
    }
    LOGI("mpv event: %{public}s", mpv_event_name(event->event_id));
  }
}

// ---------- surface 绑定（三段式） ----------

void ApplySurface(Player *player, const std::string &vo,
                  const std::string &hwdec) {
  if (g_window == nullptr) {
    LOGE("ApplySurface: no native window yet");
    return;
  }
  if (!vo.empty()) {
    player->videoOutput = vo;
  }
  if (!hwdec.empty()) {
    player->hardwareDecode = hwdec;
  }

  // 1. 先关掉视频输出
  mpv_set_property_string(player->mpv, "vo", "null");

  // 2. 设置这批属性
  char sizeBuf[64];
  snprintf(sizeBuf, sizeof(sizeBuf), "%lldx%lld",
           static_cast<long long>(g_surfaceWidth),
           static_cast<long long>(g_surfaceHeight));
  char widBuf[64];
  if (!g_surfaceId.empty()) {
    snprintf(widBuf, sizeof(widBuf), "%s", g_surfaceId.c_str());
  } else {
    snprintf(widBuf, sizeof(widBuf), "%llu",
             static_cast<unsigned long long>(
                 reinterpret_cast<uintptr_t>(g_window)));
  }

  mpv_set_property_string(player->mpv, "ohos-surface-size", sizeBuf);
  mpv_set_property_string(player->mpv, "wid", widBuf);
  mpv_set_property_string(player->mpv, "hwdec",
                          player->hardwareDecode.c_str());
  mpv_set_property_string(player->mpv, "vid", "auto");
  mpv_set_property_string(player->mpv, "force-window", "yes");
  mpv_set_property_string(player->mpv, "sub-use-margins", "no");
  mpv_set_property_string(player->mpv, "sub-scale-with-window", "no");
  mpv_set_property_string(player->mpv, "osd-font", "HarmonyOS Sans SC");

  // 3. 再启用真实渲染器
  const char *targetVo = player->videoOutput.empty()
      ? "gpu-next" : player->videoOutput.c_str();
  mpv_set_property_string(player->mpv, "vo", targetVo);
  player->surfaceAttached = true;

  LOGI("surface attached: wid=%{public}s size=%{public}s vo=%{public}s hwdec=%{public}s",
       widBuf, sizeBuf, targetVo, player->hardwareDecode.c_str());
}

// ---------- napi 导出函数 ----------

napi_value Create(napi_env env, napi_callback_info info) {
  mpv_handle *mpv = mpv_create();
  if (mpv == nullptr) {
    LOGE("mpv_create failed");
    ThrowError(env, "mpv_create failed");
    return nullptr;
  }

  // 与参照实现一致：初始化后立刻把 vo 置为 null，等绑定 surface 时再启用
  mpv_set_option_string(mpv, "vo", "null");
  mpv_set_option_string(mpv, "terminal", "no");
  mpv_set_option_string(mpv, "msg-level", "all=v");
  mpv_set_option_string(mpv, "msg-color", "no");
  mpv_request_log_messages(mpv, "v");

  if (mpv_initialize(mpv) < 0) {
    LOGE("mpv_initialize failed");
    mpv_terminate_destroy(mpv);
    ThrowError(env, "mpv_initialize failed");
    return nullptr;
  }

  Player *player = new Player();
  player->mpv = mpv;
  player->running.store(true);
  player->eventThread = std::thread(EventLoop, player);

  int64_t handle = 0;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    handle = g_nextHandle++;
    g_players[handle] = player;
  }

  LOGI("player created, handle=%{public}lld, client api=%{public}lu", (long long)handle,
       (unsigned long)mpv_client_api_version());

  napi_value result = nullptr;
  napi_create_int64(env, handle, &result);
  return result;
}

napi_value Destroy(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1] = {nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 1) {
    return MakeUndefined(env);
  }

  int64_t handle = GetInt64(env, args[0]);
  Player *player = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_players.find(handle);
    if (it != g_players.end()) {
      player = it->second;
      g_players.erase(it);
    }
  }

  if (player != nullptr) {
    player->running.store(false);
    if (player->eventThread.joinable()) {
      player->eventThread.join();
    }
    if (player->mpv != nullptr) {
      mpv_terminate_destroy(player->mpv);
    }
    delete player;
    LOGI("player destroyed, handle=%{public}lld", (long long)handle);
  }
  return MakeUndefined(env);
}

napi_value SetOption(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    return MakeUndefined(env);
  }
  Player *player = FindPlayer(GetInt64(env, args[0]));
  if (player == nullptr) {
    return MakeUndefined(env);
  }
  std::string key = GetString(env, args[1]);
  std::string value = GetString(env, args[2]);
  int rc = mpv_set_option_string(player->mpv, key.c_str(), value.c_str());
  LOGI("setOption %{public}s=%{public}s -> %{public}d", key.c_str(), value.c_str(), rc);
  return MakeUndefined(env);
}

napi_value SetProperty(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    return MakeUndefined(env);
  }
  Player *player = FindPlayer(GetInt64(env, args[0]));
  if (player == nullptr) {
    return MakeUndefined(env);
  }
  std::string key = GetString(env, args[1]);
  std::string value = GetString(env, args[2]);
  int rc = mpv_set_property_string(player->mpv, key.c_str(), value.c_str());
  LOGI("setProperty %{public}s=%{public}s -> %{public}d", key.c_str(), value.c_str(), rc);
  return MakeUndefined(env);
}

napi_value GetProperty(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  napi_value result = nullptr;
  if (argc < 2) {
    napi_create_string_utf8(env, "", 0, &result);
    return result;
  }
  Player *player = FindPlayer(GetInt64(env, args[0]));
  if (player == nullptr) {
    napi_create_string_utf8(env, "", 0, &result);
    return result;
  }
  std::string key = GetString(env, args[1]);
  char *value = mpv_get_property_string(player->mpv, key.c_str());
  if (value == nullptr) {
    napi_create_string_utf8(env, "", 0, &result);
    return result;
  }
  napi_create_string_utf8(env, value, NAPI_AUTO_LENGTH, &result);
  mpv_free(value);
  return result;
}

napi_value Command(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2] = {nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return MakeUndefined(env);
  }
  Player *player = FindPlayer(GetInt64(env, args[0]));
  if (player == nullptr) {
    return MakeUndefined(env);
  }

  uint32_t length = 0;
  napi_get_array_length(env, args[1], &length);
  std::vector<std::string> storage;
  storage.reserve(length);
  for (uint32_t i = 0; i < length; ++i) {
    napi_value item = nullptr;
    napi_get_element(env, args[1], i, &item);
    storage.push_back(GetString(env, item));
  }
  std::vector<const char *> argv;
  argv.reserve(storage.size() + 1);
  for (auto &s : storage) {
    argv.push_back(s.c_str());
  }
  argv.push_back(nullptr);

  int rc = mpv_command(player->mpv, argv.data());
  LOGI("command[%{public}s] -> %{public}d", storage.empty() ? "" : storage[0].c_str(), rc);
  // 返回码交给调用方：截图那条链路要据此判断「mpv 到底收没收到这个命令」
  return MakeInt32(env, rc);
}

napi_value AttachSurface(napi_env env, napi_callback_info info) {
  size_t argc = 4;
  napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 2) {
    return MakeUndefined(env);
  }
  Player *player = FindPlayer(GetInt64(env, args[0]));
  if (player == nullptr) {
    return MakeUndefined(env);
  }
  g_surfaceId = GetString(env, args[1]);
  LOGI("attachSurface surfaceId=%{public}s", g_surfaceId.c_str());
  std::string vo = argc > 2 ? GetString(env, args[2]) : std::string();
  std::string hwdec = argc > 3 ? GetString(env, args[3]) : std::string();
  ApplySurface(player, vo, hwdec);
  return MakeUndefined(env);
}

napi_value SetSurfaceSize(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3] = {nullptr, nullptr, nullptr};
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  if (argc < 3) {
    return MakeUndefined(env);
  }
  Player *player = FindPlayer(GetInt64(env, args[0]));
  g_surfaceWidth = GetInt64(env, args[1]);
  g_surfaceHeight = GetInt64(env, args[2]);
  if (g_surfaceWidth < 1) g_surfaceWidth = 1;
  if (g_surfaceHeight < 1) g_surfaceHeight = 1;
  if (player != nullptr) {
    char sizeBuf[64];
    snprintf(sizeBuf, sizeof(sizeBuf), "%lldx%lld",
             static_cast<long long>(g_surfaceWidth),
             static_cast<long long>(g_surfaceHeight));
    mpv_set_property_string(player->mpv, "ohos-surface-size", sizeBuf);
    LOGI("surface size -> %s", sizeBuf);
  }
  return MakeUndefined(env);
}

napi_value HasSurface(napi_env env, napi_callback_info info) {
  napi_value result = nullptr;
  napi_get_boolean(env, g_window != nullptr, &result);
  return result;
}

// ---------- XComponent 回调 ----------

void OnSurfaceCreatedCB(OH_NativeXComponent *component, void *window) {
  g_xcomponent = component;
  g_window = reinterpret_cast<OHNativeWindow *>(window);
  uint64_t surfaceId = 0;
  if (OH_NativeWindow_GetSurfaceId(g_window, &surfaceId) == 0 && surfaceId > 0) {
    g_surfaceId = std::to_string(surfaceId);
  }
  uint64_t w = 0;
  uint64_t h = 0;
  OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
  if (w > 0) g_surfaceWidth = static_cast<int64_t>(w);
  if (h > 0) g_surfaceHeight = static_cast<int64_t>(h);
  LOGI("XComponent surface created: %p size=%lldx%lld", window,
       (long long)g_surfaceWidth, (long long)g_surfaceHeight);

  // 无论该 surface 是首次创建还是全屏旋转后重建，都把播放器重新挂到新 surface。
  std::lock_guard<std::mutex> lock(g_mutex);
  for (auto &entry : g_players) {
    ApplySurface(entry.second, entry.second->videoOutput,
                 entry.second->hardwareDecode);
  }
}

void OnSurfaceChangedCB(OH_NativeXComponent *component, void *window) {
  g_window = reinterpret_cast<OHNativeWindow *>(window);
  uint64_t surfaceId = 0;
  if (OH_NativeWindow_GetSurfaceId(g_window, &surfaceId) == 0 && surfaceId > 0) {
    g_surfaceId = std::to_string(surfaceId);
  }
  uint64_t w = 0;
  uint64_t h = 0;
  OH_NativeXComponent_GetXComponentSize(component, window, &w, &h);
  if (w > 0) g_surfaceWidth = static_cast<int64_t>(w);
  if (h > 0) g_surfaceHeight = static_cast<int64_t>(h);
  LOGI("XComponent surface changed: %lldx%lld", (long long)g_surfaceWidth,
       (long long)g_surfaceHeight);

  char sizeBuf[64];
  snprintf(sizeBuf, sizeof(sizeBuf), "%lldx%lld",
           static_cast<long long>(g_surfaceWidth),
           static_cast<long long>(g_surfaceHeight));
  std::lock_guard<std::mutex> lock(g_mutex);
  for (auto &entry : g_players) {
    mpv_set_property_string(entry.second->mpv, "ohos-surface-size", sizeBuf);
  }
}

void OnSurfaceDestroyedCB(OH_NativeXComponent *component, void *window) {
  LOGI("XComponent surface destroyed: %p", window);
  if (window == g_window) {
    g_window = nullptr;
    g_surfaceId.clear();
    std::lock_guard<std::mutex> lock(g_mutex);
    for (auto &entry : g_players) {
      mpv_set_property_string(entry.second->mpv, "vo", "null");
      entry.second->surfaceAttached = false;
    }
  }
}

void DispatchTouchEventCB(OH_NativeXComponent *component, void *window) {}

}  // namespace

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

  // 取出 XComponent 实例并注册回调
  napi_value exportInstance = nullptr;
  if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ,
                              &exportInstance) != napi_ok) {
    // 普通 import 时 exports 上没有 XComponent 对象，属正常情况
    return exports;
  }
  OH_NativeXComponent *nativeXComponent = nullptr;
  if (napi_unwrap(env, exportInstance,
                  reinterpret_cast<void **>(&nativeXComponent)) != napi_ok ||
      nativeXComponent == nullptr) {
    LOGI("no XComponent instance yet (normal for plain import)");
    return exports;
  }

  g_xcomponent = nativeXComponent;
  static OH_NativeXComponent_Callback callback;
  callback.OnSurfaceCreated = OnSurfaceCreatedCB;
  callback.OnSurfaceChanged = OnSurfaceChangedCB;
  callback.OnSurfaceDestroyed = OnSurfaceDestroyedCB;
  callback.DispatchTouchEvent = DispatchTouchEventCB;
  OH_NativeXComponent_RegisterCallback(nativeXComponent, &callback);
  LOGI("XComponent callbacks registered");
  return exports;
}
EXTERN_C_END

static napi_module mpvBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mpv_bridge",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMpvBridgeModule(void) {
  napi_module_register(&mpvBridgeModule);
}
