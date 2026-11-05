# backends/native-macos/fixtures

真窗测试（native_test.mbt）用的音频夹具。都是 0.5s 的 440Hz 正弦，用 ffmpeg
生成（2026-11-05，T166；本机 brew ffmpeg 未带 libvorbis，ogg 走自带的
vorbis 实验性编码器，故为双声道）：

```bash
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" \
  -ac 2 -metadata title="T166 试音 440Hz" -metadata artist="MoonUI" \
  -metadata album="Fixtures" -c:a vorbis -strict -2 -qscale:a 4 t166_sine.ogg
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=8000" \
  -c:a pcm_s16le t166_sine.wav
```

| 文件 | 用途 |
| --- | --- |
| `t166_sine.ogg` | Ogg Vorbis 一条龙：探针读标签与时长、load → play → position 推进、播完回调（T166） |
| `t166_sine.wav` | 负控制：AVAudioFile 原生路径在 ogg 改动后行为不变（T166） |

重生成时保持标签与时长（0.5s）不变——测试的断言按它们写死。
