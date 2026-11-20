# Windows 音频夹具

`T326` 起 Windows 平台的音频不再是空桩（Media Foundation 解码 + WASAPI 共享
模式出声），判据需要真文件。文件都是 44.1k / 8k 的正弦音，几十 KB，直接进
仓库。

| 文件 | 用途 |
| --- | --- |
| `t326_sine.wav` | 8kHz 单声道 440Hz 0.5s。主用：装载 → 停着 seek → 播放推进 → 播完回调（必走 MF 重采样到混音格式） |
| `t326_stereo.wav` | 44.1kHz 立体声 440Hz 0.5s。`T326` 的声道匹配档：`wa_open_out` 在源声道数 ≠ 混音声道数时如实失败，这条钉的是"同格式能过、不同格式不许偷偷过" |

生成命令（与 `../native-macos/fixtures/` 同一批命令，那两个文件是从那边
复制过来的，保留原始字节）：

```
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=8000" \
  -c:a pcm_s16le t326_sine.wav
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" \
  -ac 2 -c:a pcm_s16le t326_stereo.wav
```

## 判据所在的机器前提

播放推进那几条要求**这台机器有默认渲染端点**（`GetDefaultAudioEndpoint`
能拿到设备）。没有输出设备时 `wa_open_out` 失败，`play` 走 `-2` 那一档——
这是 `T326` 的实现口径（设备开不起来不算 load 失败，只是放不出声）。CI 上
若出现这档红，先确认 runner 有没有音频设备，别当成解码坏了。

`ogg` 在 Windows 侧**还没接**（缺 Vorbis 解码器，见 `adapter_native.c` 音频
一节末尾的欠账说明），所以这个目录里没有 ogg 夹具；判据里点明 `.ogg` 会落到
`-2`（MF 没有 ogg 源解析器）。
