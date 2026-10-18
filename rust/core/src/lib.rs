//! FileFormatter core: content detection, conversion planning, and fidelity classification.
//!
//! This crate deliberately contains no Apple framework calls. Swift probes media, executes
//! hardware codecs, and owns the UI; Rust owns the deterministic, testable planning layer.

use std::fs;
use std::io::Read;
use std::path::Path;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    #[error("file not found: {path}")]
    NotFound { path: String },
    #[error("cannot read file: {path}")]
    Io { path: String },
    #[error("unsupported target format: {extension}")]
    UnsupportedTarget { extension: String },
    #[error("no files supplied")]
    EmptyBatch,
    #[error("conversion failed: {message}")]
    Conversion { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FileKind {
    Image,
    Video,
    Audio,
    Pdf,
    Document,
    Data,
    Archive,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Fidelity {
    Lossless,
    Reencode,
    Lossy,
    Extract,
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileInfo {
    pub path: String,
    pub file_name: String,
    pub kind: FileKind,
    pub byte_size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PlanItem {
    pub source_path: String,
    pub output_name: String,
    pub fidelity: Fidelity,
    pub byte_size: u64,
    pub kind: FileKind,
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Plan {
    pub items: Vec<PlanItem>,
    pub warnings: Vec<String>,
}

#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

#[uniffi::export]
pub fn detect_file(path: String) -> Result<FileInfo, CoreError> {
    let url = Path::new(&path);
    let metadata = fs::metadata(url).map_err(|_| CoreError::NotFound { path: path.clone() })?;
    if !metadata.is_file() {
        return Err(CoreError::NotFound { path });
    }
    let kind = detect_kind(url);
    let file_name = url
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.clone());
    Ok(FileInfo {
        path,
        file_name,
        kind,
        byte_size: metadata.len(),
    })
}

#[uniffi::export]
pub fn convert_data(
    input_path: String,
    output_path: String,
    target_extension: String,
) -> Result<(), CoreError> {
    let source = extension_of(Path::new(&input_path));
    let target = normalize_extension(&target_extension)?;

    if !is_data_extension(&source) || !is_data_extension(&target) {
        return Err(CoreError::UnsupportedTarget {
            extension: target,
        });
    }

    let input = fs::read_to_string(&input_path).map_err(|_| CoreError::Io {
        path: input_path.clone(),
    })?;
    let input = input.trim_start_matches('\u{feff}');

    let value = match source.as_str() {
        "json" => serde_json::from_str(input).map_err(conversion_error)?,
        "yaml" | "yml" => serde_yaml::from_str(input).map_err(conversion_error)?,
        "toml" => toml::from_str(input).map_err(conversion_error)?,
        "csv" => csv_to_json(input, b',').map_err(conversion_error)?,
        "tsv" => csv_to_json(input, b'\t').map_err(conversion_error)?,
        other => {
            return Err(CoreError::UnsupportedTarget {
                extension: other.to_string(),
            })
        }
    };

    let output = match target.as_str() {
        "json" => serde_json::to_string_pretty(&value).map_err(conversion_error)? + "\n",
        "yaml" => serde_yaml::to_string(&value).map_err(conversion_error)?,
        "toml" => toml::to_string_pretty(&value).map_err(conversion_error)?,
        "csv" => json_to_csv(&value, b',').map_err(conversion_error)?,
        "tsv" => json_to_csv(&value, b'\t').map_err(conversion_error)?,
        other => {
            return Err(CoreError::UnsupportedTarget {
                extension: other.to_string(),
            })
        }
    };

    fs::write(&output_path, output).map_err(|_| CoreError::Io {
        path: output_path,
    })
}

const DATA_EXTENSIONS: [&str; 5] = ["csv", "tsv", "json", "yaml", "toml"];

fn is_data_extension(extension: &str) -> bool {
    DATA_EXTENSIONS.contains(&extension)
}

fn conversion_error(error: impl std::fmt::Display) -> CoreError {
    CoreError::Conversion {
        message: error.to_string(),
    }
}

fn csv_to_json(input: &str, delimiter: u8) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(delimiter)
        .flexible(true)
        .from_reader(input.as_bytes());
    let headers = reader.headers()?.clone();
    let mut rows = Vec::new();
    for record in reader.records() {
        let record = record?;
        let mut object = serde_json::Map::new();
        for (index, header) in headers.iter().enumerate() {
            let key = if header.trim().is_empty() {
                format!("column_{}", index + 1)
            } else {
                header.to_string()
            };
            object.insert(
                key,
                serde_json::Value::String(record.get(index).unwrap_or_default().to_string()),
            );
        }
        rows.push(serde_json::Value::Object(object));
    }
    Ok(serde_json::Value::Array(rows))
}

fn json_to_csv(
    value: &serde_json::Value,
    delimiter: u8,
) -> Result<String, Box<dyn std::error::Error>> {
    let rows = value
        .as_array()
        .ok_or("CSV output requires a JSON array of objects")?;
    let mut headers: Vec<String> = Vec::new();
    for row in rows {
        let object = row.as_object().ok_or("CSV output requires an array of objects")?;
        for key in object.keys() {
            if !headers.contains(key) {
                headers.push(key.clone());
            }
        }
    }
    let mut writer = csv::WriterBuilder::new()
        .delimiter(delimiter)
        .from_writer(Vec::new());
    writer.write_record(&headers)?;
    for row in rows {
        let object = row.as_object().ok_or("CSV output requires an array of objects")?;
        let fields = headers.iter().map(|header| match object.get(header) {
            None | Some(serde_json::Value::Null) => String::new(),
            Some(serde_json::Value::String(value)) => value.clone(),
            Some(serde_json::Value::Bool(value)) => value.to_string(),
            Some(serde_json::Value::Number(value)) => value.to_string(),
            Some(other) => serde_json::to_string(other).unwrap_or_default(),
        });
        writer.write_record(fields)?;
    }
    Ok(String::from_utf8(writer.into_inner()?)?)
}

#[uniffi::export]
pub fn build_plan(
    paths: Vec<String>,
    target_extension: String,
    suffix: String,
) -> Result<Plan, CoreError> {
    if paths.is_empty() {
        return Err(CoreError::EmptyBatch);
    }
    let target = normalize_extension(&target_extension)?;
    let mut items = Vec::with_capacity(paths.len());
    let mut warnings = Vec::new();

    for path in paths {
        let source = Path::new(&path);
        let metadata = match fs::metadata(source) {
            Ok(m) if m.is_file() => m,
            _ => {
                warnings.push(format!("Skipped missing file: {path}"));
                continue;
            }
        };
        let source_kind = detect_kind(source);
        let source_ext = extension_of(source);
        let file_stem = source
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "file".to_string());

        let note = animation_note(&source_ext);
        let fidelity = fidelity_for(source_kind, &source_ext, target.as_str());

        let output_name = if fidelity == Fidelity::Unsupported {
            file_stem.clone()
        } else {
            output_file_name(&file_stem, &suffix, &target)
        };

        items.push(PlanItem {
            source_path: path,
            output_name,
            fidelity,
            byte_size: metadata.len(),
            kind: source_kind,
            note,
        });
    }

    if items.is_empty() {
        return Err(CoreError::EmptyBatch);
    }
    Ok(Plan { items, warnings })
}

fn normalize_extension(value: &str) -> Result<String, CoreError> {
    let ext = value.trim().trim_start_matches('.').to_ascii_lowercase();
    match ext.as_str() {
        "jpg" | "jpeg" | "png" | "tif" | "tiff" | "heic" | "avif" | "webp" | "pdf"
        | "csv" | "tsv" | "json" | "yaml" | "toml" => Ok(ext),
        _ => Err(CoreError::UnsupportedTarget { extension: ext }),
    }
}

fn extension_of(path: &Path) -> String {
    path.extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default()
}

fn output_file_name(stem: &str, suffix: &str, target: &str) -> String {
    let clean_stem = sanitize(stem);
    let clean_suffix = sanitize(suffix.trim());
    let stem = if clean_suffix.is_empty() || clean_stem.ends_with(&clean_suffix) {
        clean_stem
    } else {
        format!("{clean_stem}{clean_suffix}")
    };
    format!("{stem}.{}", target_extension_for_name(target))
}

fn target_extension_for_name(target: &str) -> &str {
    match target {
        "jpeg" => "jpg",
        other => other,
    }
}

fn sanitize(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '/' | ':' | '\0' => out.push('-'),
            _ => out.push(ch),
        }
    }
    let trimmed = out.trim_matches(['.', ' ']).to_string();
    if trimmed.is_empty() {
        "file".to_string()
    } else {
        trimmed
    }
}

fn animation_note(ext: &str) -> Option<String> {
    if ext == "gif" || ext == "webp" {
        Some("Animated images use the first frame in this build.".to_string())
    } else {
        None
    }
}

fn fidelity_for(kind: FileKind, source_ext: &str, target: &str) -> Fidelity {
    if kind == FileKind::Data {
        return if is_data_extension(target) {
            if source_ext == target {
                Fidelity::Lossless
            } else {
                Fidelity::Reencode
            }
        } else {
            Fidelity::Unsupported
        };
    }
    if kind != FileKind::Image && kind != FileKind::Pdf {
        return Fidelity::Unsupported;
    }
    if kind == FileKind::Pdf {
        return match target {
            "pdf" => Fidelity::Reencode,
            _ => Fidelity::Unsupported,
        };
    }
    match target {
        "png" | "tif" | "tiff" => {
            if source_ext == target || (target == "tif" && source_ext == "tiff") {
                Fidelity::Lossless
            } else {
                Fidelity::Lossless
            }
        }
        "jpg" | "jpeg" | "heic" | "avif" | "webp" => {
            if matches!(source_ext, "jpg" | "jpeg" | "heic" | "avif" | "webp") && source_ext == target
            {
                Fidelity::Reencode
            } else if matches!(source_ext, "jpg" | "jpeg" | "heic" | "avif" | "webp") {
                Fidelity::Reencode
            } else {
                Fidelity::Lossy
            }
        }
        "pdf" => Fidelity::Extract,
        _ => Fidelity::Unsupported,
    }
}

fn detect_kind(path: &Path) -> FileKind {
    let mut header = [0u8; 32];
    let read = fs::File::open(path)
        .and_then(|mut f| f.read(&mut header))
        .unwrap_or(0);
    let bytes = &header[..read];

    if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
        return FileKind::Image;
    }
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return FileKind::Image;
    }
    if bytes.starts_with(b"GIF8") {
        return FileKind::Image;
    }
    if bytes.starts_with(b"%PDF") {
        return FileKind::Pdf;
    }
    if bytes.starts_with(b"II*\0") || bytes.starts_with(b"MM\0*") {
        return FileKind::Image;
    }
    if bytes.starts_with(b"BM") {
        return FileKind::Image;
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return FileKind::Image;
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        let brand = &bytes[8..12];
        return match brand {
            b"heic" | b"heix" | b"hevc" | b"hevx" | b"mif1" | b"msf1" | b"avif" | b"avis" => {
                FileKind::Image
            }
            b"qt  " | b"isom" | b"mp42" | b"M4V " | b"3gp4" => FileKind::Video,
            _ => FileKind::Video,
        };
    }
    if bytes.starts_with(b"ID3") || bytes.starts_with(b"fLaC") || bytes.starts_with(b"OggS") {
        return FileKind::Audio;
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE" {
        return FileKind::Audio;
    }
    if bytes.starts_with(b"FORM") && bytes.len() >= 12 && &bytes[8..12] == b"AIFF" {
        return FileKind::Audio;
    }

    match extension_of(path).as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "tif" | "tiff" | "heic" | "heif" | "avif" | "webp"
        | "bmp" | "ico" | "psd" | "svg" | "dng" | "cr2" | "cr3" | "nef" | "arw" | "raf" | "orf"
        | "rw2" => FileKind::Image,
        "pdf" => FileKind::Pdf,
        "mp4" | "mov" | "m4v" | "mkv" | "webm" | "avi" | "flv" | "ts" | "mts" | "mpeg" | "mpg"
        | "wmv" | "3gp" => FileKind::Video,
        "mp3" | "m4a" | "aac" | "flac" | "wav" | "aiff" | "aif" | "ogg" | "opus" | "wma" | "ac3"
        | "caf" => FileKind::Audio,
        "docx" | "pptx" | "xlsx" | "doc" | "ppt" | "xls" | "md" | "txt" | "html" | "rtf" => {
            FileKind::Document
        }
        "csv" | "tsv" | "json" | "yaml" | "yml" | "toml" | "xml" | "srt" | "vtt" => {
            FileKind::Data
        }
        "zip" | "7z" | "tar" | "gz" | "rar" => FileKind::Archive,
        _ => FileKind::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn file_with_bytes(bytes: &[u8], suffix: &str) -> NamedTempFile {
        let mut file = tempfile::Builder::new()
            .suffix(suffix)
            .tempfile()
            .expect("temp file");
        file.write_all(bytes).expect("write");
        file.flush().expect("flush");
        file
    }

    #[test]
    fn detects_png_by_magic_even_with_wrong_extension() {
        let file = file_with_bytes(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A], ".bin");
        let info = detect_file(file.path().to_string_lossy().into_owned()).expect("detect");
        assert_eq!(info.kind, FileKind::Image);
    }

    #[test]
    fn plans_png_to_jpeg_as_lossy() {
        let file = file_with_bytes(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A], ".png");
        let plan = build_plan(
            vec![file.path().to_string_lossy().into_owned()],
            "jpeg".to_string(),
            "-converted".to_string(),
        )
        .expect("plan");
        assert_eq!(plan.items.len(), 1);
        assert_eq!(plan.items[0].fidelity, Fidelity::Lossy);
        assert!(plan.items[0].output_name.ends_with("-converted.jpg"));
    }

    #[test]
    fn plans_png_to_tiff_as_lossless() {
        let file = file_with_bytes(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A], ".png");
        let plan = build_plan(
            vec![file.path().to_string_lossy().into_owned()],
            "tiff".to_string(),
            String::new(),
        )
        .expect("plan");
        assert_eq!(plan.items[0].fidelity, Fidelity::Lossless);
    }

    #[test]
    fn rejects_unsupported_target() {
        let file = file_with_bytes(&[0x89, b'P', b'N', b'G'], ".png");
        let error = build_plan(
            vec![file.path().to_string_lossy().into_owned()],
            "exe".to_string(),
            String::new(),
        )
        .expect_err("must reject");
        assert!(matches!(error, CoreError::UnsupportedTarget { .. }));
    }

    #[test]
    fn does_not_duplicate_suffix() {
        assert_eq!(
            output_file_name("photo-web", "-web", "webp"),
            "photo-web.webp"
        );
        assert_eq!(output_file_name("photo", "-web", "jpeg"), "photo-web.jpg");
    }

    #[test]
    fn converts_csv_to_json_and_back() {
        let mut input = NamedTempFile::with_suffix(".csv").expect("csv");
        input.write_all(b"name,role\nAda,engineer\nGrace,admiral\n").expect("write csv");
        input.flush().expect("flush");
        let json = NamedTempFile::with_suffix(".json").expect("json");
        convert_data(
            input.path().to_string_lossy().into_owned(),
            json.path().to_string_lossy().into_owned(),
            "json".to_string(),
        )
        .expect("csv to json");
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(json.path()).expect("read json")).expect("parse json");
        assert_eq!(value.as_array().expect("array").len(), 2);
        assert_eq!(value[0]["name"], "Ada");

        let csv = NamedTempFile::with_suffix(".csv").expect("csv out");
        convert_data(
            json.path().to_string_lossy().into_owned(),
            csv.path().to_string_lossy().into_owned(),
            "csv".to_string(),
        )
        .expect("json to csv");
        let text = fs::read_to_string(csv.path()).expect("read csv");
        assert!(text.contains("name,role"));
        assert!(text.contains("Ada,engineer"));
    }

    #[test]
    fn converts_yaml_to_json() {
        let mut input = NamedTempFile::with_suffix(".yaml").expect("yaml");
        input.write_all(b"name: Ada\nrole: engineer\n").expect("write yaml");
        input.flush().expect("flush");
        let json = NamedTempFile::with_suffix(".json").expect("json");
        convert_data(
            input.path().to_string_lossy().into_owned(),
            json.path().to_string_lossy().into_owned(),
            "json".to_string(),
        )
        .expect("yaml to json");
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(json.path()).expect("read json")).expect("parse json");
        assert_eq!(value["name"], "Ada");
    }

    #[test]
    fn rejects_image_to_data() {
        let file = file_with_bytes(&[0x89, b'P', b'N', b'G'], ".png");
        let output = NamedTempFile::with_suffix(".json").expect("json");
        let error = convert_data(
            file.path().to_string_lossy().into_owned(),
            output.path().to_string_lossy().into_owned(),
            "json".to_string(),
        )
        .expect_err("must reject");
        assert!(matches!(error, CoreError::UnsupportedTarget { .. }));
    }

    #[test]
    fn missing_file_is_skipped_with_warning() {
        let plan = build_plan(
            vec!["/definitely/not/here.png".to_string()],
            "png".to_string(),
            String::new(),
        );
        assert!(plan.is_err());
    }
}
