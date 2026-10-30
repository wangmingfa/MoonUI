# lunamusic-tag

lunamusic 用的音频标签读写包。**绝大部分代码是上游的**，这里只做按需裁剪——
读这份文件的人首先要看到出处：

## 出处与致谢

本目录的代码来自 **moontag** 项目，作者 **cp15695540483**：

- 仓库：<https://github.com/cp15695540483/moontag>
- mooncakes：<https://mooncakes.io/docs/cp15695540483/moontag@0.1.1>
- 取用版本：**0.1.1**
- 许可证：**Apache-2.0**（全文见本目录 `LICENSE`）

moontag 是纯 MoonBit 实现的音频标签读写库——ID3v2（MP3）、Vorbis Comment（FLAC）、
APEv2（MP3 尾部）、MP4 ilst（M4A），不依赖任何 C 库、不调用 FFmpeg。作者把
"四种容器 × 读+写 × 两个后端" 这件事从头写了一遍，包括 ID3v2.3/v2.4 的尺寸与编码
差异、Ogg 页 lacing 与 CRC、MP4 faststart 的 stco/co64 偏移修正这些最容易写错的细节，
并且给每一条都配了判据。本仓库只是把其中"改三个文本字段"用得到的部分搬过来，
**这套实现是作者的原创工作**。

为什么要搬而不是 `moon add`：上游只在自己的测试矩阵里跑过 `wasm-gc` 与 `js`，
native 后端没人担保过；而且 lunamusic 只需要很小一块，出问题时想直接改。fork 之后
与上游脱钩，代价是这份文档要维护好，否则半年后没人敢碰。

## 已取用

13 个源文件 + 6 个测试文件，逐文件保留上游文件名与注释。

| 文件 | 上游行数 | 在这里做什么 |
| --- | --- | --- |
| `bytes_util.mbt` | 162 → 180 | 边界检查的字节读写、大/小端、synchsafe。所有格式的地基 |
| `tag_error.mbt` | 43 | `TagError` 与 `message()` |
| `id3_text.mbt` | 157 | 文本编码（v2.3 用 UTF-16，v2.4 用 UTF-8） |
| `id3_unsync.mbt` | 28 | Unsynchronisation 还原 |
| `id3_tag.mbt` | 285 | `parse` / `Id3Tag` / `Frame` / `text(id)` |
| `id3_write.mbt` | 362 → 344 | `set_fields` / `WriteOptions` / `rewrite_tag`（**删了 `set_picture`**） |
| `vorbis_comment.mbt` | 159 | Vorbis Comment 解析与序列化 |
| `flac_meta.mbt` | 125 | FLAC 块链遍历 |
| `flac_write.mbt` | 146 | `set_vorbis_comment` / `read_vorbis_comment`（含 padding 复用） |
| `mp4_ilst.mbt` | 182 | `Mp4Tag` / `read_mp4_tags` / `parse_ilst` |
| `mp4_write.mbt` | 311 | `set_mp4_tags` / `mp4_text_tag` / `mp4_cover_tag`（含 stco/co64 偏移修正） |
| `ogg_page.mbt` | 266 | Ogg 页解析/构造/CRC/lacing |
| `ogg_vorbis_comment.mbt` | 201 | `read_ogg_comment` / `set_ogg_comment` |
| `tags.mbt` | 272 → 90 | **只留 `AudioFormat` + `detect_format` + `AudioFormat::name`** |

测试：`id3_wbtest`（21）、`id3_write_wbtest`（11）、`mp4_wbtest`（14）、
`ogg_wbtest`（7）、`vorbis_wbtest`（19）、`tags_wbtest`（7，裁剪后）——共 79 条，
原样保留。它们进 core 与 wasm 两份门禁，且额外跑 native。

**本仓库做过的改动**（同步上游时别覆盖）：

1. `bytes_util.mbt` 追加 `read_ascii`——上游它在 `apev2.mbt` 里，而 `tags.mbt` 的
   `detect_format` 要它。原实现原样搬入。
2. `id3_write.mbt` 删除 `set_picture`（连带 `Picture` / `serialize_picture` 的引用）。
3. `tags.mbt` 只留 `AudioFormat` / `detect_format` / `AudioFormat::name`。
4. `tags_wbtest.mbt` 只留格式识别与 `name()` 的判据。
5. 每个文件顶部加一段 vendored 版权头。

## 暂未取用、但上游已有现成实现

这份清单是为了"下次要加功能时不用重新翻上游仓库"。**封面是最直接的一条**。

### 封面（APIC / PICTURE / covr）

- 上游 `id3_apic.mbt`（226 行，整份未取用）：
  - `Picture`（`mime` / `picture_type` / `raw_type` / `description` / `data`）
  - `PictureType` 枚举 + `PictureType::code()` / `PictureType::from_code()`
  - `picture(...)` 构造、`parse_picture(payload)`、`serialize_picture(pic, major)`
  - `Id3Tag::picture()`（取第一张）、`Id3Tag::pictures()`（取全部）
- 上游 `id3_write.mbt` 的 `set_picture(data, picture : Picture?, options)`——本期
  删掉的那一段。签名与 `set_fields` 同形，返回完整新文件字节，传 `None` 删除全部封面：
  ```moonbit
  pub fn set_picture(
    data : BytesView,
    picture : Picture?,
    options : WriteOptions,
  ) -> Bytes raise TagError {
    let major = resolve_major(data, options)
    let new_blobs : Array[Bytes] = []
    match picture {
      None => ()
      Some(p) => {
        if p.data.length() == 0 {
          raise BadFrameData(frame_id="APIC", reason="图片数据为空")
        }
        let payload = serialize_picture(p, major)
        new_blobs.push(build_frame(major, "APIC", 0, payload))
      }
    }
    rewrite_tag(data, ["APIC"], new_blobs, options)
  }
  ```
  取回来时只需把 `id3_apic.mbt` 整份拉进来 + 这段贴回 `id3_write.mbt`，
  再补 `id3_apic_wbtest.mbt`（245 行）——**依赖边是闭合的**，其它文件不用动。
- MP4 封面：`mp4_write.mbt` 的 `mp4_cover_tag(image, is_png)` **已经在本次取用的
  文件里且实现完整**，只是我们没调用它。`mp4_ilst.mbt` 的 `cover_of(entries)` 同理。
- FLAC 封面：`flac_meta.mbt` 已识别块类型 `Picture`（值 6），真正的图片载荷解析
  上游也没做——需要自己按 FLAC 规范补，或先把 ID3/MP4 两条做了。

### APEv2（MP3 尾部标签）

- 上游 `apev2.mbt`（248 行，整份未取用）：`ApeItem` / `ApeTag` / `parse_ape` /
  `ApeTag::get` / `ApeTag::text` / `ApeTag::set` / `empty_ape_tag` / `set_ape_tag`，
  外加 `read_ascii`（本仓库已挪进 `bytes_util.mbt`）。
- 未取用的**已知行为差异**：只有 APEv2 标签的 mp3，本包读不出旧值（`parse` 只认
  ID3v2）。但写入会新建 ID3v2，而 ID3v2 在优先级上本就压过 APEv2，所以写完就正常了。

### 统一只读视图

- 上游 `tags.mbt` 的 `TrackInfo` / `read_track_info` / `read_mp3_info` /
  `read_flac_info` / `read_mp4_info` / `read_ogg_info` / `mp3_field` / `ape_text` /
  `mp3_has_cover` / `empty_info`。依赖上面两块，所以本期一并剪掉。
  lunamusic 有自己的探针路径（`examples/lunamusic/probe.mbt`），不需要它。

## 同步上游

拿到新版本（`moon remove`/重新下载 zip，或看 <https://github.com/cp15695540483/moontag>）：

1. 只对比**上表「已取用」那 13 个文件**；其余上游文件的改动不关心。
2. 逐文件 `diff`，挑落在保留范围内的修复（边界检查、CRC、偏移修正这类）。
3. 对照上面「本仓库做过的改动」那 5 条：`id3_write.mbt` 的 diff 里如果出现
   `set_picture`，那是上游加回来的，**跳过**；`tags.mbt` 的 diff 会大量出现
   `TrackInfo` 相关，也跳过；`bytes_util.mbt` 的 `read_ascii` 若上游挪走了，
   保持我们的副本。
4. 改完跑四个门禁（native + wasm，check + test）：
   ```bash
   moon check --target native --deny-warn examples/lunamusic-tag
   moon test  --target native examples/lunamusic-tag
   moon check --target wasm   --deny-warn examples/lunamusic-tag
   moon test  --target wasm   examples/lunamusic-tag
   ```
5. 更新本文件顶部的「取用版本」。

## 许可证

Apache-2.0，与上游一致，全文见本目录 `LICENSE`。按 §4(a) 分发时附带许可证副本，
按 §4(b) 在每个源文件顶部保留来源声明。
