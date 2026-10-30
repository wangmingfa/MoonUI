// tags.mbt
//
// 统一标签模型（F7）：把四种容器的元数据归一成同一组字段，
// 让调用方不必关心文件格式。
//
// 映射关系（写入时按容器选择对应的帧 ID / 键名）：
//   title      ID3v2 TIT2   | Vorbis TITLE   | APEv2 Title   | MP4 ©nam
//   artist     ID3v2 TPE1   | Vorbis ARTIST  | APEv2 Artist  | MP4 ©ART
//   album      ID3v2 TALB   | Vorbis ALBUM   | APEv2 Album   | MP4 ©alb
//   track      ID3v2 TRCK   | Vorbis TRACKNUMBER | APEv2 Track | MP4 trkn
//   date       ID3v2 TYER/TDRC | Vorbis DATE | APEv2 Year    | MP4 ©day
//   genre      ID3v2 TCON   | Vorbis GENRE   | APEv2 Genre   | MP4 ©gen
//   comment    ID3v2 COMM   | Vorbis COMMENT | APEv2 Comment | MP4 ©cmt
//
// vendored 自 cp15695540483/moontag@0.1.1 的 tags.mbt
// 上游许可 Apache-2.0，全文见本目录 LICENSE；本仓库只改下述范围：
//   - 只保留 AudioFormat 枚举、detect_format、AudioFormat::name
//   - 删除 TrackInfo / read_track_info / read_mp3_info / read_flac_info /
//     read_mp4_info / read_ogg_info / mp3_field / ape_text / mp3_has_cover /
//     empty_info：它们依赖没有拉进来的 id3_apic.mbt 与 apev2.mbt，
//     而且 lunamusic 有自己的 Track 探针路径，不需要这份统一只读视图。
// 除裁剪外未改动实现。

///|
/// 音频文件格式。
pub enum AudioFormat {
  /// MP3（ID3v2 头部标签）
  Mp3
  /// FLAC（Vorbis Comment 元数据块）
  Flac
  /// MP4 / M4A（ilst）
  Mp4
  /// Ogg（Vorbis / Opus 的 comment packet）
  Ogg
  /// 无法识别
  Unknown
}

///|
/// 按文件魔数识别格式。
pub fn detect_format(data : BytesView) -> AudioFormat {
  // Ogg：页头魔数 OggS
  if data.length() >= 4 &&
    data.at(0) == b'O' &&
    data.at(1) == b'g' &&
    data.at(2) == b'g' &&
    data.at(3) == b'S' {
    return Ogg
  }
  if data.length() >= 4 &&
    data.at(0) == b'f' &&
    data.at(1) == b'L' &&
    data.at(2) == b'a' &&
    data.at(3) == b'C' {
    return Flac
  }
  // MP4：第 4..8 字节是 ftyp（部分文件是其他盒，但 ftyp 是绝大多数情况）
  if data.length() >= 12 {
    let k = read_ascii(data, 4, 8)
    if k == "ftyp" {
      return Mp4
    }
  }
  // ID3v2
  if data.length() >= 3 &&
    data.at(0) == b'I' &&
    data.at(1) == b'D' &&
    data.at(2) == b'3' {
    return Mp3
  }
  // MP3 帧同步（0xFF 0xE0 掩码），或尾部有 APEv2
  if data.length() >= 2 &&
    data.at(0) == b'\xFF' &&
    (data.at(1).to_int() & 0xE0) == 0xE0 {
    return Mp3
  }
  Unknown
}

///|
/// 格式的可读名称。
pub fn AudioFormat::name(self : AudioFormat) -> String {
  match self {
    Mp3 => "MP3 / ID3v2"
    Flac => "FLAC / Vorbis Comment"
    Mp4 => "MP4 / ilst"
    Ogg => "Ogg / Vorbis Comment"
    Unknown => "未知格式"
  }
}
