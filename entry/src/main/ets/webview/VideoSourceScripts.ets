/**
 * 视频源解析的注入脚本。
 *
 * 逐字提取自阶段 0 的验证页 `pages/ProtoPage.ets`（真机实测通过：
 * 注入距 `onPageBegin` 仅 19ms，早于页面脚本执行，成功捕获 #EXTM3U）。
 * 提取到这里是为了让生产代码与验证代码用**同一份**脚本，
 * 避免"验过的是一套、上线的又是另一套"。
 *
 * 与参照实现的对应关系（§57.2）：
 *   1) muteMedia：文档开始时立即静音媒体
 *   2) blobParser：文档开始时包装 Response.prototype.text 与 XHR.open
 *   3) videoTagParser：文档结束时用 MutationObserver 监听 <video>
 *   OHOS 版比 Android 版少了「iframe 穿透包装」，不要自行补。
 */
export class VideoSourceScripts {
  /**
   * 取流页静音脚本。
   *
   * 只依赖控制器静音还不够：页面的 `<video autoplay>` 可能在控制器完成关联
   * 前就开始播放。这里在文档开始阶段改写 `play()`，并在捕获阶段监听 play
   * 事件；即使站点随后把 `muted` 改回 false，我们也会立刻恢复静音。
   *
   * 不暂停媒体，因为部分站点只有在媒体开始加载后才请求播放清单；暂停可能
   * 让解析永远等不到地址。
   */
  static muteMediaScript(): string {
    return `
(function () {
  function silence(media) {
    try {
      if (!media) return;
      media.muted = true;
      media.volume = 0;
      media.setAttribute('muted', '');
    } catch (e) {}
  }
  function silenceAll(root) {
    try {
      if (!root || !root.querySelectorAll) return;
      var medias = root.querySelectorAll('video,audio');
      for (var i = 0; i < medias.length; i++) silence(medias[i]);
    } catch (e) {}
  }
  try {
    var proto = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
    var originalPlay = proto && proto.play;
    if (originalPlay && !proto.__autumnMutedPlay) {
      proto.play = function () {
        silence(this);
        return originalPlay.apply(this, arguments);
      };
      proto.__autumnMutedPlay = true;
    }
    document.addEventListener('play', function (event) {
      silence(event.target);
    }, true);
    document.addEventListener('volumechange', function (event) {
      silence(event.target);
    }, true);
    if (document.documentElement) {
      var observer = new MutationObserver(function (mutations) {
        for (var i = 0; i < mutations.length; i++) {
          var nodes = mutations[i].addedNodes;
          for (var j = 0; j < nodes.length; j++) {
            var node = nodes[j];
            if (node.nodeName === 'VIDEO' || node.nodeName === 'AUDIO') {
              silence(node);
            }
            silenceAll(node);
          }
        }
      });
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
    silenceAll(document);
  } catch (e) {}
})();
`;
  }

  /**
   * 文档开始注入：包装 Response.text / XHR.open / fetch 捕获 HLS 清单。
   *
   * 匹配规则：内容以 `#EXTM3U` 开头即认定是 HLS 清单；
   * XHR 若 responseType 是 ArrayBuffer，只取前 64 字节解码判断。
   */
  static blobParserScript(): string {
    return `
(function () {
  try {
    var origText = window.Response && window.Response.prototype.text;
    if (origText) {
      window.Response.prototype.text = function () {
        var self = this;
        return new Promise(function (resolve, reject) {
          origText.call(self).then(function (text) {
            resolve(text);
            try {
              if (text && text.trim().indexOf('#EXTM3U') === 0) {
                window.AutumnBridge.hit(String(self.url), 'Response.text');
              }
            } catch (e) {}
          }).catch(reject);
        });
      };
    }
    var origOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
    if (origOpen) {
      window.XMLHttpRequest.prototype.open = function () {
        var args = arguments;
        this.addEventListener('load', function () {
          try {
            var c = null;
            try { c = this.responseText; } catch (e) {}
            if (!c && this.response && this.response instanceof ArrayBuffer) {
              try {
                c = new TextDecoder('utf-8').decode(new Uint8Array(this.response, 0, 64));
              } catch (e) {}
            }
            if (c && c.trim().indexOf('#EXTM3U') === 0) {
              window.AutumnBridge.hit(String(args[1]), 'XHR');
            }
          } catch (e) {}
        });
        return origOpen.apply(this, args);
      };
    }
    var origFetch = window.fetch;
    if (origFetch) {
      window.fetch = function () {
        var args = arguments;
        return origFetch.apply(this, args).then(function (resp) {
          try {
            var url = (args[0] && args[0].url) ? args[0].url : String(args[0]);
            if (url && url.indexOf('.m3u8') >= 0) {
              window.AutumnBridge.hit(url, 'fetch(url)');
            }
          } catch (e) {}
          return resp;
        });
      };
    }
    window.AutumnBridge.log('hooks installed @ ' + location.href);
  } catch (e) {
    try { window.AutumnBridge.log('hook failed: ' + e); } catch (_) {}
  }
})();
`;
  }

  /**
   * 文档结束注入的兜底：MutationObserver + 每秒轮询 `<video>`。
   *
   * `blob:` 与 `googleads` 的地址要排除——前者是 MSE 的内部 objectURL，
   * 后者是广告；两者都不是我们要的播放源（对应源码里的同款过滤）。
   */
  static videoTagParserScript(): string {
    return `
(function () {
  try {
    var seen = false;
    function processVideo(video) {
      if (!video) { return; }
      var src = video.getAttribute('src');
      if (src && src.indexOf('blob:') !== 0 && src.indexOf('googleads') < 0) {
        seen = true;
        window.AutumnBridge.hit(String(src), 'video.src');
        return;
      }
      var sources = video.getElementsByTagName('source');
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i].getAttribute('src');
        if (s && s.indexOf('blob:') !== 0 && s.indexOf('googleads') < 0) {
          seen = true;
          window.AutumnBridge.hit(String(s), 'video.source');
          return;
        }
      }
    }
    var observer = new MutationObserver(function (mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var m = mutations[i];
        if (m.target && m.target.nodeName === 'VIDEO') { processVideo(m.target); }
        for (var j = 0; j < m.addedNodes.length; j++) {
          var node = m.addedNodes[j];
          if (node.nodeName === 'VIDEO') { processVideo(node); }
          if (node.querySelectorAll) {
            var videos = node.querySelectorAll('video');
            for (var k = 0; k < videos.length; k++) { processVideo(videos[k]); }
          }
        }
      }
    });
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    setInterval(function () {
      if (seen) { return; }
      var videos = document.querySelectorAll('video');
      for (var i = 0; i < videos.length; i++) { processVideo(videos[i]); }
    }, 1000);
    window.AutumnBridge.log('video fallback installed');
  } catch (e) {
    try { window.AutumnBridge.log('video fallback failed: ' + e); } catch (_) {}
  }
})();
`;
  }

  /**
   * 阶段 0 的 HLS 钩子自检脚本。
   *
   * 生产链路**不要调用**它（它会额外发一次外网请求）。
   * 保留在这里是为了复现阶段 0 的验证结论：
   * 真机上注入 19ms 生效，且能捕获 #EXTM3U。
   */
  static selfTestScript(): string {
    return `
setTimeout(function () {
  try {
    var x = new XMLHttpRequest();
    x.open('GET', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8');
    x.send();
    window.AutumnBridge.log('self-test: XHR dispatched');
  } catch (e) {
    window.AutumnBridge.log('self-test: XHR failed ' + e);
  }
}, 1200);
`;
  }
}
