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
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=8000" \
  -c:a pcm_s16le -metadata title="T218 中文标题" -metadata artist="MoonUI" \
  t218_utf8.wav
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=8000" \
  -c:a pcm_s16le -metadata title="$(printf '周杰伦' | iconv -f UTF-8 -t GBK)" \
  t218_gbk.wav
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=8000" \
  -c:a pcm_s16le -metadata title="$(printf 'Caf\xe9')" t218_latin1.wav
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" \
  -ac 2 -c:a pcm_s16le t168_a.wav
ffmpeg -f lavfi -i "sine=frequency=660:duration=1.0:sample_rate=44100" \
  -ac 2 -c:a pcm_s16le t168_b.wav
ffmpeg -f lavfi -i "sine=frequency=880:duration=1.0:sample_rate=44100" \
  -af "volume=-15dB" -ac 2 -c:a pcm_s16le t170_quiet.wav
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" \
  -ac 2 -metadata title="T180 歌词曲" -metadata artist="MoonUI" \
  -metadata lyrics="[00:00.00]手牵手一步两步三步四步望着天" \
  -c:a libmp3lame t180_lyrics.mp3
ffmpeg -f lavfi -i "sine=frequency=440:duration=0.5:sample_rate=44100" \
  -ac 2 -metadata title="T180 歌词曲 m4a" -metadata artist="MoonUI" \
  -metadata lyrics="[00:00.00]看星星一颗两颗三颗四颗连成线" \
  -c:a aac t180_lyrics.m4a
```

| 文件 | 用途 |
| --- | --- |
| `t166_sine.ogg` | Ogg Vorbis 一条龙：探针读标签与时长、load → play → position 推进、播完回调（T166） |
| `t166_sine.wav` | 负控制：AVAudioFile 原生路径在 ogg 改动后行为不变（T166） |
| `t218_utf8.wav` | RIFF INFO 写 UTF-8 中文标题（探针读回须纠正，T218），ASCII 歌手须原样 |
| `t218_gbk.wav` | RIFF INFO 写 GBK 字节 `D6 DC BD DC C2 D7`（恰好也是合法 UTF-8），须认 GB18030 解出「周杰伦」（T218） |
| `t218_latin1.wav` | RIFF INFO 写真 Latin-1 `Caf\xE9`，两种解码都出不来，须原样不动（T218） |
| `t168_a.wav` | 无缝播放 A 段：44.1k 立体声 440Hz 0.5s，与 t168_b 同格式（格式匹配门），load→play→prime B（T168） |
| `t168_b.wav` | 无缝播放 B 段：44.1k 立体声 660Hz 1.0s（时长故意与 A 不同——handoff 后 duration_ms 换到 B 才验得出账换了，T168） |
| `t170_quiet.wav` | 响度计轻曲：44.1k 立体声 880Hz 1.0s 压 -15dB，ffmpeg ebur128 基准 -36.3 LUFS（与 t168_a 的 -21.8 拉开 14.5 LU，T170） |
| `t180_lyrics.mp3` | 内嵌歌词 mp3：ffmpeg 写歌词不出真 USLT 帧，是 TXXX 帧、描述 "USLT"（AVFoundation 挂在 extraAttributes["info"]）——野外最常见的一路，探针读回整段带轴歌词（T180） |
| `t180_lyrics.m4a` | 内嵌歌词 m4a：iTunes ©lyr（真 atom），同上判据的第二路容器（T180） |

重生成时保持标签与时长（0.5s）不变——测试的断言按它们写死。
