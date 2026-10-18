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

    let value = match source.as_str() {
        // Tabular targets hold one sheet: take the first non-empty one in workbook order.
        "xlsx" | "xls" => xlsx_to_json(
            Path::new(&input_path),
            matches!(target.as_str(), "csv" | "tsv" | "xlsx"),
        )
        .map_err(conversion_error)?,
        _ => {
            let input = fs::read_to_string(&input_path).map_err(|_| CoreError::Io {
                path: input_path.clone(),
            })?;
            let input = input.trim_start_matches('\u{feff}');
            match source.as_str() {
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
            }
        }
    };

    let output = match target.as_str() {
        "json" => serde_json::to_string_pretty(&value).map_err(conversion_error)? + "\n",
        "yaml" => serde_yaml::to_string(&value).map_err(conversion_error)?,
        "toml" => toml::to_string_pretty(&value).map_err(conversion_error)?,
        "csv" => json_to_csv(&value, b',').map_err(conversion_error)?,
        "tsv" => json_to_csv(&value, b'\t').map_err(conversion_error)?,
        "xlsx" => {
            json_to_xlsx(&value, Path::new(&output_path)).map_err(conversion_error)?;
            return Ok(());
        }
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

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct FileHash {
    pub path: String,
    pub hash: String,
    pub byte_size: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DuplicateGroup {
    pub hash: String,
    pub byte_size: u64,
    pub paths: Vec<String>,
}

#[uniffi::export]
pub fn hash_files(paths: Vec<String>) -> Vec<FileHash> {
    let mut hashes = Vec::new();
    for path in paths {
        let file_path = Path::new(&path);
        let Ok(metadata) = fs::metadata(file_path) else { continue };
        if !metadata.is_file() { continue }
        let Ok(file) = fs::File::open(file_path) else { continue };
        let mut reader = std::io::BufReader::with_capacity(1024 * 1024, file);
        let mut hasher = blake3::Hasher::new();
        if std::io::copy(&mut reader, &mut hasher).is_err() { continue }
        hashes.push(FileHash {
            path,
            hash: hasher.finalize().to_hex().to_string(),
            byte_size: metadata.len(),
        });
    }
    hashes
}

#[uniffi::export]
pub fn find_duplicates(paths: Vec<String>) -> Vec<DuplicateGroup> {
    use std::collections::HashMap;
    let mut by_hash: HashMap<String, Vec<(String, u64)>> = HashMap::new();
    for item in hash_files(paths) {
        if item.byte_size == 0 { continue }
        by_hash
            .entry(item.hash)
            .or_default()
            .push((item.path, item.byte_size));
    }
    let mut groups: Vec<DuplicateGroup> = by_hash
        .into_iter()
        .filter_map(|(hash, entries)| {
            if entries.len() < 2 { return None }
            let byte_size = entries[0].1;
            Some(DuplicateGroup {
                hash,
                byte_size,
                paths: entries.into_iter().map(|(path, _)| path).collect(),
            })
        })
        .collect();
    groups.sort_by(|a, b| {
        (b.byte_size * (b.paths.len() as u64 - 1))
            .cmp(&(a.byte_size * (a.paths.len() as u64 - 1)))
    });
    groups
}

#[uniffi::export]
pub fn extract_office(
    input_path: String,
    output_path: String,
    target_extension: String,
) -> Result<(), CoreError> {
    let source = extension_of(Path::new(&input_path));
    if !matches!(source.as_str(), "docx" | "pptx") {
        return Err(CoreError::UnsupportedTarget { extension: source });
    }
    let target = target_extension
        .trim()
        .trim_start_matches('.')
        .to_ascii_lowercase();
    if !matches!(target.as_str(), "md" | "markdown" | "txt" | "html") {
        return Err(CoreError::UnsupportedTarget { extension: target });
    }

    let file = fs::File::open(&input_path).map_err(|_| CoreError::Io {
        path: input_path.clone(),
    })?;
    let mut archive = zip::ZipArchive::new(file).map_err(conversion_error)?;

    let mut blocks = match source.as_str() {
        "docx" => parse_docx(&mut archive).map_err(conversion_error)?,
        "pptx" => parse_pptx(&mut archive).map_err(conversion_error)?,
        _ => unreachable!(),
    };

    let output = match target.as_str() {
        "txt" => render_text(&blocks),
        "md" | "markdown" => {
            copy_office_images(&mut archive, &mut blocks, Path::new(&output_path))?;
            render_markdown(&blocks)
        }
        "html" => {
            copy_office_images(&mut archive, &mut blocks, Path::new(&output_path))?;
            render_html(&blocks)
        }
        _ => unreachable!(),
    };
    fs::write(&output_path, output).map_err(|_| CoreError::Io {
        path: output_path,
    })
}

#[derive(Debug, Clone, Default, PartialEq)]
struct Run {
    text: String,
    bold: bool,
    italic: bool,
}

/// Format-neutral document model shared by the DOCX/PPTX parsers and the renderers.
#[derive(Debug, Clone, PartialEq)]
enum Block {
    Heading { level: u8, runs: Vec<Run> },
    Paragraph { runs: Vec<Run> },
    ListItem { level: u8, ordered: bool, runs: Vec<Run> },
    Table { rows: Vec<Vec<String>> },
    /// `rel_path` is the zip entry path after parsing and the output-relative link after
    /// `copy_office_images`.
    Image { rel_path: String, alt: String },
}

type XmlEvent<'a> = quick_xml::events::Event<'a>;
type DynResult<T> = Result<T, Box<dyn std::error::Error>>;

fn xml_attr(event: &quick_xml::events::BytesStart, key: &str) -> Option<String> {
    event
        .try_get_attribute(key)
        .ok()
        .flatten()
        .and_then(|attr| attr.unescape_value().ok().map(|v| v.into_owned()))
}

/// OOXML toggle properties (`<w:b/>`, `<w:b w:val="0"/>`).
fn xml_toggle(event: &quick_xml::events::BytesStart) -> bool {
    !matches!(
        xml_attr(event, "w:val").as_deref(),
        Some("0" | "false" | "off" | "none")
    )
}

fn zip_string<R: Read + std::io::Seek>(
    archive: &mut zip::ZipArchive<R>,
    name: &str,
) -> DynResult<String> {
    let mut xml = String::new();
    archive.by_name(name)?.read_to_string(&mut xml)?;
    Ok(xml)
}

/// Relationship id → zip entry path, for internal targets only (linked images are skipped).
fn zip_rels<R: Read + std::io::Seek>(
    archive: &mut zip::ZipArchive<R>,
    rels_path: &str,
    base_dir: &str,
) -> std::collections::HashMap<String, String> {
    let mut rels = std::collections::HashMap::new();
    let Ok(xml) = zip_string(archive, rels_path) else { return rels };
    let mut reader = quick_xml::Reader::from_str(&xml);
    while let Ok(event) = reader.read_event() {
        match event {
            XmlEvent::Start(e) | XmlEvent::Empty(e) if e.name().as_ref() == b"Relationship" => {
                if xml_attr(&e, "TargetMode").as_deref() == Some("External") {
                    continue;
                }
                if let (Some(id), Some(target)) = (xml_attr(&e, "Id"), xml_attr(&e, "Target")) {
                    rels.insert(id, resolve_zip_path(base_dir, &target));
                }
            }
            XmlEvent::Eof => break,
            _ => {}
        }
    }
    rels
}

fn resolve_zip_path(base_dir: &str, target: &str) -> String {
    let joined = match target.strip_prefix('/') {
        Some(absolute) => absolute.to_string(),
        None => format!("{base_dir}/{target}"),
    };
    let mut parts: Vec<&str> = Vec::new();
    for segment in joined.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts.join("/")
}

fn push_run(runs: &mut Vec<Run>, run: Run) {
    if run.text.is_empty() {
        return;
    }
    match runs.last_mut() {
        Some(last) if last.bold == run.bold && last.italic == run.italic => {
            last.text.push_str(&run.text)
        }
        _ => runs.push(run),
    }
}

/// Trims the paragraph edges; returns None when nothing visible is left.
fn finish_runs(mut runs: Vec<Run>) -> Option<Vec<Run>> {
    if let Some(first) = runs.first_mut() {
        first.text = first.text.trim_start().to_string();
    }
    if let Some(last) = runs.last_mut() {
        last.text = last.text.trim_end().to_string();
    }
    runs.retain(|run| !run.text.is_empty());
    if runs.iter().all(|run| run.text.trim().is_empty()) {
        None
    } else {
        Some(runs)
    }
}

fn plain_text(runs: &[Run]) -> String {
    runs.iter().map(|run| run.text.as_str()).collect()
}

fn append_cell(rows: &mut [Vec<String>], text: &str) {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if text.is_empty() {
        return;
    }
    if let Some(cell) = rows.last_mut().and_then(|row| row.last_mut()) {
        if !cell.is_empty() {
            cell.push(' ');
        }
        cell.push_str(&text);
    }
}

/// (numId, ilvl) → ordered, from word/numbering.xml.
fn docx_numbering(xml: &str) -> std::collections::HashMap<(String, u8), bool> {
    use std::collections::HashMap;
    let mut abstract_formats: HashMap<(String, u8), bool> = HashMap::new();
    let mut num_to_abstract: Vec<(String, String)> = Vec::new();
    let mut current_abstract: Option<String> = None;
    let mut current_num: Option<String> = None;
    let mut current_level = 0u8;
    let mut reader = quick_xml::Reader::from_str(xml);
    while let Ok(event) = reader.read_event() {
        match event {
            XmlEvent::Start(e) | XmlEvent::Empty(e) => match e.name().as_ref() {
                b"w:abstractNum" => current_abstract = xml_attr(&e, "w:abstractNumId"),
                b"w:num" => current_num = xml_attr(&e, "w:numId"),
                b"w:lvl" => {
                    current_level = xml_attr(&e, "w:ilvl")
                        .and_then(|v| v.parse().ok())
                        .unwrap_or(0)
                }
                b"w:numFmt" => {
                    if let (Some(id), Some(format)) = (&current_abstract, xml_attr(&e, "w:val")) {
                        abstract_formats.insert(
                            (id.clone(), current_level),
                            !matches!(format.as_str(), "bullet" | "none"),
                        );
                    }
                }
                b"w:abstractNumId" => {
                    if let (Some(num), Some(id)) = (&current_num, xml_attr(&e, "w:val")) {
                        num_to_abstract.push((num.clone(), id));
                    }
                }
                _ => {}
            },
            XmlEvent::End(e) => match e.name().as_ref() {
                b"w:abstractNum" => current_abstract = None,
                b"w:num" => current_num = None,
                _ => {}
            },
            XmlEvent::Eof => break,
            _ => {}
        }
    }
    let mut map = HashMap::new();
    for (num, id) in num_to_abstract {
        for ((abstract_id, level), ordered) in &abstract_formats {
            if *abstract_id == id {
                map.insert((num.clone(), *level), *ordered);
            }
        }
    }
    map
}

fn docx_block(
    style: &str,
    num_id: Option<&str>,
    level: u8,
    numbering: &std::collections::HashMap<(String, u8), bool>,
    runs: Vec<Run>,
) -> Option<Block> {
    let runs = finish_runs(runs)?;
    let style = style.to_ascii_lowercase().replace(' ', "");
    if style == "title" {
        return Some(Block::Heading { level: 1, runs });
    }
    if let Some(level) = style
        .strip_prefix("heading")
        .and_then(|n| n.parse::<u8>().ok())
        .filter(|n| (1..=6).contains(n))
    {
        return Some(Block::Heading { level, runs });
    }
    Some(match num_id {
        Some(id) if id != "0" => Block::ListItem {
            level,
            ordered: numbering
                .get(&(id.to_string(), level))
                .copied()
                .unwrap_or(false),
            runs,
        },
        // ponytail: numbering inherited from list styles is approximated by the style name.
        _ if style.starts_with("listnumber") => Block::ListItem { level: 0, ordered: true, runs },
        _ if style.starts_with("listbullet") => Block::ListItem { level: 0, ordered: false, runs },
        _ => Block::Paragraph { runs },
    })
}

fn parse_docx<R: Read + std::io::Seek>(archive: &mut zip::ZipArchive<R>) -> DynResult<Vec<Block>> {
    let xml = zip_string(archive, "word/document.xml")?;
    let rels = zip_rels(archive, "word/_rels/document.xml.rels", "word");
    let numbering = zip_string(archive, "word/numbering.xml")
        .map(|xml| docx_numbering(&xml))
        .unwrap_or_default();

    let mut reader = quick_xml::Reader::from_str(&xml);
    reader.config_mut().trim_text(false);
    let mut blocks = Vec::new();
    let mut pending_images: Vec<Block> = Vec::new();
    let mut alt = String::new();
    // Paragraph state. Text boxes nest paragraphs inside runs; only the outermost counts.
    let mut paragraph_depth = 0usize;
    let mut style = String::new();
    let mut num_id: Option<String> = None;
    let mut level = 0u8;
    let mut runs: Vec<Run> = Vec::new();
    let mut run = Run::default();
    let mut in_run = false;
    let mut in_run_props = false;
    let mut in_text = false;
    // Table state. Nested tables flow into the enclosing outer cell.
    let mut table_depth = 0usize;
    let mut rows: Vec<Vec<String>> = Vec::new();

    loop {
        let event = reader.read_event()?;
        match &event {
            XmlEvent::Start(e) | XmlEvent::Empty(e) => {
                let empty = matches!(event, XmlEvent::Empty(_));
                match e.name().as_ref() {
                    // Fallback duplicates the mc:Choice content (text boxes, shapes).
                    b"mc:Fallback" if !empty => {
                        reader.read_to_end(e.name())?;
                    }
                    b"w:p" if !empty => {
                        paragraph_depth += 1;
                        if paragraph_depth == 1 {
                            style.clear();
                            num_id = None;
                            level = 0;
                            runs.clear();
                        }
                    }
                    b"w:pStyle" if paragraph_depth == 1 => {
                        style = xml_attr(e, "w:val").unwrap_or_default()
                    }
                    b"w:numId" if paragraph_depth == 1 => num_id = xml_attr(e, "w:val"),
                    b"w:ilvl" if paragraph_depth == 1 => {
                        level = xml_attr(e, "w:val")
                            .and_then(|v| v.parse::<u8>().ok())
                            .unwrap_or(0)
                            .min(8)
                    }
                    b"w:r" if !empty => {
                        in_run = true;
                        run = Run::default();
                    }
                    b"w:rPr" if !empty && in_run => in_run_props = true,
                    b"w:b" if in_run_props => run.bold = xml_toggle(e),
                    b"w:i" if in_run_props => run.italic = xml_toggle(e),
                    b"w:t" if !empty => in_text = true,
                    b"w:tab" if in_run => run.text.push('\t'),
                    b"w:br" | b"w:cr" if in_run => run.text.push('\n'),
                    b"wp:docPr" => {
                        alt = xml_attr(e, "descr")
                            .filter(|v| !v.trim().is_empty())
                            .or_else(|| xml_attr(e, "name"))
                            .unwrap_or_default()
                    }
                    b"a:blip" => {
                        if let Some(path) = xml_attr(e, "r:embed").and_then(|id| rels.get(&id)) {
                            pending_images.push(Block::Image {
                                rel_path: path.clone(),
                                alt: alt.clone(),
                            });
                        }
                    }
                    b"w:tbl" if !empty => {
                        table_depth += 1;
                        if table_depth == 1 {
                            rows.clear();
                        }
                    }
                    b"w:tr" if !empty && table_depth == 1 => rows.push(Vec::new()),
                    b"w:tc" if !empty && table_depth == 1 => {
                        if let Some(row) = rows.last_mut() {
                            row.push(String::new());
                        }
                    }
                    _ => {}
                }
            }
            XmlEvent::Text(text) if in_text => run.text.push_str(&text.unescape()?),
            XmlEvent::End(e) => match e.name().as_ref() {
                b"w:t" => in_text = false,
                b"w:rPr" => in_run_props = false,
                b"w:r" => {
                    in_run = false;
                    push_run(&mut runs, std::mem::take(&mut run));
                }
                b"w:p" => {
                    paragraph_depth = paragraph_depth.saturating_sub(1);
                    if paragraph_depth == 0 {
                        let paragraph = std::mem::take(&mut runs);
                        if table_depth > 0 {
                            append_cell(&mut rows, &plain_text(&paragraph));
                        } else {
                            blocks.extend(docx_block(
                                &style,
                                num_id.as_deref(),
                                level,
                                &numbering,
                                paragraph,
                            ));
                            blocks.append(&mut pending_images);
                        }
                    }
                }
                b"w:tbl" => {
                    table_depth = table_depth.saturating_sub(1);
                    if table_depth == 0 {
                        let table = std::mem::take(&mut rows);
                        if table.iter().flatten().any(|cell| !cell.is_empty()) {
                            blocks.push(Block::Table { rows: table });
                        }
                        blocks.append(&mut pending_images);
                    }
                }
                _ => {}
            },
            XmlEvent::Eof => break,
            _ => {}
        }
    }
    blocks.append(&mut pending_images);
    Ok(blocks)
}

fn parse_pptx<R: Read + std::io::Seek>(archive: &mut zip::ZipArchive<R>) -> DynResult<Vec<Block>> {
    let mut slide_names: Vec<String> = archive
        .file_names()
        .filter(|name| name.starts_with("ppt/slides/slide") && name.ends_with(".xml"))
        .map(str::to_string)
        .collect();
    slide_names.sort_by_key(|name| {
        name.trim_start_matches("ppt/slides/slide")
            .trim_end_matches(".xml")
            .parse::<u32>()
            .unwrap_or(0)
    });

    let mut blocks = Vec::new();
    for (index, name) in slide_names.iter().enumerate() {
        let xml = zip_string(archive, name)?;
        let file_name = name.rsplit('/').next().unwrap_or_default();
        let rels = zip_rels(archive, &format!("ppt/slides/_rels/{file_name}.rels"), "ppt/slides");
        let (title, body) = pptx_slide(&xml, &rels)?;
        let heading = if title.is_empty() {
            format!("Slide {}", index + 1)
        } else {
            format!("Slide {} — {title}", index + 1)
        };
        blocks.push(Block::Heading {
            level: 2,
            runs: vec![Run { text: heading, ..Run::default() }],
        });
        blocks.extend(body);
    }
    Ok(blocks)
}

#[derive(Clone, Copy, PartialEq)]
enum SlideShape {
    Other,
    Title,
    Body,
    Skip,
}

/// Returns (title text, body blocks) for one slide.
fn pptx_slide(
    xml: &str,
    rels: &std::collections::HashMap<String, String>,
) -> DynResult<(String, Vec<Block>)> {
    let mut reader = quick_xml::Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    let mut title: Vec<String> = Vec::new();
    let mut body = Vec::new();
    let mut shape = SlideShape::Other;
    let mut alt = String::new();
    let mut runs: Vec<Run> = Vec::new();
    let mut run = Run::default();
    let mut in_run = false;
    let mut in_text = false;
    let mut level = 0u8;
    // Some(ordered) when the paragraph is a list item.
    let mut list: Option<bool> = None;
    let mut table_depth = 0usize;
    let mut rows: Vec<Vec<String>> = Vec::new();

    loop {
        let event = reader.read_event()?;
        match &event {
            XmlEvent::Start(e) | XmlEvent::Empty(e) => {
                let empty = matches!(event, XmlEvent::Empty(_));
                match e.name().as_ref() {
                    b"mc:Fallback" if !empty => {
                        reader.read_to_end(e.name())?;
                    }
                    b"p:sp" if !empty => shape = SlideShape::Other,
                    b"p:ph" => {
                        shape = match xml_attr(e, "type").as_deref() {
                            Some("title" | "ctrTitle") => SlideShape::Title,
                            None | Some("body" | "obj") => SlideShape::Body,
                            Some("dt" | "ftr" | "sldNum" | "hdr") => SlideShape::Skip,
                            Some(_) => SlideShape::Other,
                        }
                    }
                    b"p:cNvPr" => {
                        alt = xml_attr(e, "descr")
                            .filter(|v| !v.trim().is_empty())
                            .or_else(|| xml_attr(e, "name"))
                            .unwrap_or_default()
                    }
                    b"a:p" if !empty => {
                        runs.clear();
                        level = 0;
                        // ponytail: bullets inherited from layouts are assumed for body placeholders only.
                        list = (shape == SlideShape::Body).then_some(false);
                    }
                    b"a:pPr" => {
                        level = xml_attr(e, "lvl")
                            .and_then(|v| v.parse::<u8>().ok())
                            .unwrap_or(0)
                            .min(8)
                    }
                    b"a:buChar" => list = Some(false),
                    b"a:buAutoNum" => list = Some(true),
                    b"a:buNone" => list = None,
                    b"a:r" | b"a:fld" if !empty => {
                        in_run = true;
                        run = Run::default();
                    }
                    b"a:rPr" if in_run => {
                        let on = |key| matches!(xml_attr(e, key).as_deref(), Some("1" | "true"));
                        run.bold = on("b");
                        run.italic = on("i");
                    }
                    b"a:t" if !empty => in_text = true,
                    b"a:br" => push_run(&mut runs, Run { text: "\n".into(), ..Run::default() }),
                    b"a:blip" => {
                        if let Some(path) = xml_attr(e, "r:embed").and_then(|id| rels.get(&id)) {
                            body.push(Block::Image {
                                rel_path: path.clone(),
                                alt: alt.clone(),
                            });
                        }
                    }
                    b"a:tbl" if !empty => {
                        table_depth += 1;
                        if table_depth == 1 {
                            rows.clear();
                        }
                    }
                    b"a:tr" if !empty && table_depth == 1 => rows.push(Vec::new()),
                    b"a:tc" if !empty && table_depth == 1 => {
                        if let Some(row) = rows.last_mut() {
                            row.push(String::new());
                        }
                    }
                    _ => {}
                }
            }
            XmlEvent::Text(text) if in_text => run.text.push_str(&text.unescape()?),
            XmlEvent::End(e) => match e.name().as_ref() {
                b"a:t" => in_text = false,
                b"a:r" | b"a:fld" => {
                    in_run = false;
                    push_run(&mut runs, std::mem::take(&mut run));
                }
                b"a:p" => {
                    let paragraph = std::mem::take(&mut runs);
                    if table_depth > 0 {
                        append_cell(&mut rows, &plain_text(&paragraph));
                        continue;
                    }
                    let Some(paragraph) = finish_runs(paragraph) else { continue };
                    match shape {
                        SlideShape::Skip => {}
                        SlideShape::Title => title.push(
                            plain_text(&paragraph).split_whitespace().collect::<Vec<_>>().join(" "),
                        ),
                        _ => body.push(match list {
                            Some(ordered) => Block::ListItem { level, ordered, runs: paragraph },
                            None => Block::Paragraph { runs: paragraph },
                        }),
                    }
                }
                b"a:tbl" => {
                    table_depth = table_depth.saturating_sub(1);
                    if table_depth == 0 {
                        let table = std::mem::take(&mut rows);
                        if table.iter().flatten().any(|cell| !cell.is_empty()) {
                            body.push(Block::Table { rows: table });
                        }
                    }
                }
                b"p:sp" => shape = SlideShape::Other,
                _ => {}
            },
            XmlEvent::Eof => break,
            _ => {}
        }
    }
    Ok((title.join(" "), body))
}

/// Copies referenced media into `<output stem>_files/` beside the output and rewrites each
/// image block to a relative link. Only the sanitized file-name component of the zip entry is
/// used, so nothing can be written outside that folder. Missing media drops the block.
fn copy_office_images<R: Read + std::io::Seek>(
    archive: &mut zip::ZipArchive<R>,
    blocks: &mut Vec<Block>,
    output_path: &Path,
) -> Result<(), CoreError> {
    let stem = output_path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document".to_string());
    let folder_name = format!("{stem}_files");
    let folder = output_path.with_file_name(&folder_name);
    let mut copied: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut used_names: std::collections::HashSet<String> = std::collections::HashSet::new();
    let io_error = |path: &Path| CoreError::Io {
        path: path.to_string_lossy().into_owned(),
    };

    let mut keep = Vec::with_capacity(blocks.len());
    for block in blocks.iter_mut() {
        let Block::Image { rel_path, .. } = block else {
            keep.push(true);
            continue;
        };
        if let Some(link) = copied.get(rel_path.as_str()) {
            *rel_path = link.clone();
            keep.push(true);
            continue;
        }
        let Ok(mut entry) = archive.by_name(rel_path) else {
            keep.push(false);
            continue;
        };
        let base = safe_media_name(rel_path);
        let mut name = base.clone();
        let mut counter = 1;
        while used_names.contains(&name) {
            name = format!("{counter}_{base}");
            counter += 1;
        }
        fs::create_dir_all(&folder).map_err(|_| io_error(&folder))?;
        let destination = folder.join(&name);
        let mut file = fs::File::create(&destination).map_err(|_| io_error(&destination))?;
        std::io::copy(&mut entry, &mut file).map_err(|_| io_error(&destination))?;
        let link = format!("{}/{}", percent_encode(&folder_name), percent_encode(&name));
        used_names.insert(name);
        copied.insert(std::mem::replace(rel_path, link.clone()), link);
        keep.push(true);
    }
    let mut flags = keep.into_iter();
    blocks.retain(|_| flags.next().unwrap_or(true));
    Ok(())
}

fn safe_media_name(zip_path: &str) -> String {
    let raw = zip_path.rsplit(['/', '\\']).next().unwrap_or_default();
    let cleaned: String = raw
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '_' })
        .collect();
    let cleaned = cleaned.trim_start_matches('.').to_string();
    if cleaned.is_empty() { "image".to_string() } else { cleaned }
}

fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Joins rendered blocks with blank lines, keeping consecutive list items tight.
fn join_blocks(blocks: &[Block], mut render: impl FnMut(&Block) -> Option<String>) -> String {
    let mut out = String::new();
    let mut previous_list = false;
    for block in blocks {
        let Some(text) = render(block) else { continue };
        let is_list = matches!(block, Block::ListItem { .. });
        if !out.is_empty() {
            out.push_str(if is_list && previous_list { "\n" } else { "\n\n" });
        }
        out.push_str(&text);
        previous_list = is_list;
    }
    out.push('\n');
    out
}

fn md_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if matches!(c, '\\' | '*' | '_' | '`' | '[' | ']') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn md_runs(runs: &[Run]) -> String {
    runs.iter()
        .map(|run| {
            let text = md_escape(&run.text).replace('\n', "  \n");
            let marker = match (run.bold, run.italic) {
                (true, true) => "***",
                (true, false) => "**",
                (false, true) => "*",
                (false, false) => "",
            };
            if marker.is_empty() || text.trim().is_empty() {
                return text;
            }
            // Emphasis markers must hug non-space characters.
            let start = text.len() - text.trim_start().len();
            let end = text.trim_end().len();
            format!("{}{marker}{}{marker}{}", &text[..start], &text[start..end], &text[end..])
        })
        .collect()
}

fn table_width(rows: &[Vec<String>]) -> usize {
    rows.iter().map(Vec::len).max().unwrap_or(0).max(1)
}

fn render_markdown(blocks: &[Block]) -> String {
    join_blocks(blocks, |block| {
        Some(match block {
            Block::Heading { level, runs } => format!(
                "{} {}",
                "#".repeat((*level).clamp(1, 6) as usize),
                md_escape(&plain_text(runs)).replace('\n', " ")
            ),
            Block::Paragraph { runs } => md_runs(runs),
            Block::ListItem { level, ordered, runs } => format!(
                "{}{} {}",
                "  ".repeat(*level as usize),
                if *ordered { "1." } else { "-" },
                md_runs(runs)
            ),
            Block::Table { rows } => {
                let width = table_width(rows);
                let line = |row: &Vec<String>| {
                    let cells: Vec<String> = (0..width)
                        .map(|i| {
                            row.get(i)
                                .map(|cell| md_escape(cell).replace('|', "\\|").replace('\n', " "))
                                .unwrap_or_default()
                        })
                        .collect();
                    format!("| {} |", cells.join(" | "))
                };
                let mut lines = vec![line(rows.first()?), format!("|{}", " --- |".repeat(width))];
                lines.extend(rows.iter().skip(1).map(line));
                lines.join("\n")
            }
            Block::Image { rel_path, alt } => format!("![{}]({rel_path})", md_escape(alt)),
        })
    })
}

fn render_text(blocks: &[Block]) -> String {
    join_blocks(blocks, |block| match block {
        Block::Heading { runs, .. } | Block::Paragraph { runs } => Some(plain_text(runs)),
        Block::ListItem { level, runs, .. } => Some(format!(
            "{}- {}",
            "  ".repeat(*level as usize),
            plain_text(runs)
        )),
        Block::Table { rows } => Some(
            rows.iter()
                .map(|row| {
                    row.iter()
                        .map(|cell| cell.replace(['\t', '\n'], " "))
                        .collect::<Vec<_>>()
                        .join("\t")
                })
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        Block::Image { .. } => None,
    })
}

fn html_escape(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn html_runs(runs: &[Run]) -> String {
    runs.iter()
        .map(|run| {
            let mut text = html_escape(&run.text).replace('\n', "<br>");
            if run.italic {
                text = format!("<em>{text}</em>");
            }
            if run.bold {
                text = format!("<strong>{text}</strong>");
            }
            text
        })
        .collect()
}

fn close_html_list(out: &mut String, ordered: bool) {
    out.push_str(if ordered { "</li></ol>\n" } else { "</li></ul>\n" });
}

fn render_html(blocks: &[Block]) -> String {
    let mut out = String::from(
        "<!doctype html>\n<html><head><meta charset=\"utf-8\">\n<style>\
body{max-width:48rem;margin:2rem auto;padding:0 1rem;font:16px/1.6 -apple-system,system-ui,sans-serif;color:#222}\
table{border-collapse:collapse;margin:1rem 0}th,td{border:1px solid #ccc;padding:.3rem .6rem;text-align:left;vertical-align:top}\
th{background:#f4f4f4}img{max-width:100%;height:auto}\
</style></head><body>\n",
    );
    // One entry per open list; each has an open <li> once an item was written.
    let mut lists: Vec<bool> = Vec::new();
    for block in blocks {
        if let Block::ListItem { level, ordered, runs } = block {
            let depth = *level as usize + 1;
            while lists.len() > depth {
                let open = lists.pop().unwrap_or_default();
                close_html_list(&mut out, open);
            }
            if lists.len() == depth {
                if lists[depth - 1] == *ordered {
                    out.push_str("</li>\n");
                } else {
                    let open = lists.pop().unwrap_or_default();
                    close_html_list(&mut out, open);
                }
            }
            while lists.len() < depth {
                out.push_str(if *ordered { "<ol>" } else { "<ul>" });
                lists.push(*ordered);
                if lists.len() < depth {
                    out.push_str("<li>");
                }
            }
            out.push_str("<li>");
            out.push_str(&html_runs(runs));
            continue;
        }
        while let Some(open) = lists.pop() {
            close_html_list(&mut out, open);
        }
        match block {
            Block::Heading { level, runs } => {
                let level = (*level).clamp(1, 6);
                out.push_str(&format!("<h{level}>{}</h{level}>\n", html_escape(&plain_text(runs))));
            }
            Block::Paragraph { runs } => out.push_str(&format!("<p>{}</p>\n", html_runs(runs))),
            Block::Table { rows } => {
                let width = table_width(rows);
                out.push_str("<table>\n");
                for (index, row) in rows.iter().enumerate() {
                    let tag = if index == 0 { "th" } else { "td" };
                    out.push_str("<tr>");
                    for column in 0..width {
                        let cell = row.get(column).map(String::as_str).unwrap_or_default();
                        out.push_str(&format!("<{tag}>{}</{tag}>", html_escape(cell)));
                    }
                    out.push_str("</tr>\n");
                }
                out.push_str("</table>\n");
            }
            Block::Image { rel_path, alt } => out.push_str(&format!(
                "<p><img src=\"{}\" alt=\"{}\"></p>\n",
                html_escape(rel_path),
                html_escape(alt)
            )),
            Block::ListItem { .. } => unreachable!(),
        }
    }
    while let Some(open) = lists.pop() {
        close_html_list(&mut out, open);
    }
    out.push_str("</body></html>\n");
    out
}

const DATA_EXTENSIONS: [&str; 7] = ["csv", "tsv", "json", "yaml", "toml", "xlsx", "xls"];

fn is_data_extension(extension: &str) -> bool {
    DATA_EXTENSIONS.contains(&extension)
}

/// One non-empty sheet (or `first_sheet_only`) yields its rows array; several yield
/// `{ sheetName: rows }`. ponytail: serde_json's Map is sorted, so object keys are alphabetical
/// rather than workbook order; enabling `preserve_order` would need a new crate (foldhash).
fn xlsx_to_json(
    path: &Path,
    first_sheet_only: bool,
) -> Result<serde_json::Value, Box<dyn std::error::Error>> {
    use calamine::{Reader, open_workbook_auto};

    let mut workbook = open_workbook_auto(path)?;
    let mut sheets = serde_json::Map::new();
    for name in workbook.sheet_names() {
        let range = workbook.worksheet_range(&name)?;
        if let Some(rows) = range_to_json(&range) {
            if first_sheet_only {
                return Ok(rows);
            }
            sheets.insert(name, rows);
        }
    }
    match sheets.len() {
        0 => Err("The workbook has no data".into()),
        1 => Ok(sheets.into_iter().next().map(|(_, rows)| rows).unwrap_or_default()),
        _ => Ok(serde_json::Value::Object(sheets)),
    }
}

/// First row is the header; None for an empty sheet.
fn range_to_json(range: &calamine::Range<calamine::Data>) -> Option<serde_json::Value> {
    let mut rows = range.rows();
    let headers: Vec<String> = rows
        .next()?
        .iter()
        .enumerate()
        .map(|(index, cell)| {
            let value = data_to_string(cell);
            if value.trim().is_empty() {
                format!("column_{}", index + 1)
            } else {
                value
            }
        })
        .collect();

    let mut output = Vec::new();
    for row in rows {
        let mut object = serde_json::Map::new();
        for (index, header) in headers.iter().enumerate() {
            object.insert(header.clone(), data_to_json(row.get(index)));
        }
        output.push(serde_json::Value::Object(object));
    }
    Some(serde_json::Value::Array(output))
}

fn json_to_xlsx(
    value: &serde_json::Value,
    path: &Path,
) -> Result<(), Box<dyn std::error::Error>> {
    let rows: Vec<&serde_json::Map<String, serde_json::Value>> = match value {
        serde_json::Value::Array(items) => items
            .iter()
            .map(|item| item.as_object().ok_or("XLSX output requires an array of objects"))
            .collect::<Result<_, _>>()?,
        serde_json::Value::Object(object) => vec![object],
        _ => return Err("XLSX output requires an object or an array of objects".into()),
    };

    let mut headers: Vec<String> = Vec::new();
    for row in &rows {
        for key in row.keys() {
            if !headers.contains(key) {
                headers.push(key.clone());
            }
        }
    }

    let mut workbook = rust_xlsxwriter::Workbook::new();
    let worksheet = workbook.add_worksheet();
    let bold = rust_xlsxwriter::Format::new().set_bold();
    for (column, header) in headers.iter().enumerate() {
        worksheet.write_string_with_format(0, column as u16, header, &bold)?;
    }
    worksheet.set_freeze_panes(1, 0)?;
    for (index, row) in rows.iter().enumerate() {
        let excel_row = (index + 1) as u32;
        for (column, header) in headers.iter().enumerate() {
            let Some(value) = row.get(header) else { continue };
            let col = column as u16;
            match value {
                serde_json::Value::Null => {}
                serde_json::Value::String(text) => match numeric_cell(text) {
                    Some(number) => {
                        worksheet.write_number(excel_row, col, number)?;
                    }
                    None => {
                        worksheet.write_string(excel_row, col, text)?;
                    }
                },
                serde_json::Value::Bool(flag) => {
                    worksheet.write_boolean(excel_row, col, *flag)?;
                }
                serde_json::Value::Number(number) => {
                    if let Some(value) = number.as_f64() {
                        worksheet.write_number(excel_row, col, value)?;
                    }
                }
                other => {
                    worksheet.write_string(
                        excel_row,
                        col,
                        serde_json::to_string(other)?,
                    )?;
                }
            }
        }
    }
    worksheet.autofit();
    workbook.save(path)?;
    Ok(())
}

/// Plain decimal strings become numbers; codes with leading zeros ("00501"), signs, exponents
/// or more than 15 characters stay text so nothing loses precision or meaning.
fn numeric_cell(text: &str) -> Option<f64> {
    let digits = text.strip_prefix('-').unwrap_or(text);
    let leading_zero = digits.len() > 1 && digits.starts_with('0') && !digits.starts_with("0.");
    let plain_decimal = !digits.is_empty()
        && digits.bytes().all(|b| b.is_ascii_digit() || b == b'.')
        && digits.starts_with(|c: char| c.is_ascii_digit())
        && digits.ends_with(|c: char| c.is_ascii_digit());
    if text.len() > 15 || leading_zero || !plain_decimal {
        return None;
    }
    text.parse::<f64>().ok().filter(|value| value.is_finite())
}

fn data_to_string(cell: &calamine::Data) -> String {
    match cell {
        calamine::Data::Empty => String::new(),
        other => other.to_string(),
    }
}

fn data_to_json(cell: Option<&calamine::Data>) -> serde_json::Value {
    match cell {
        None | Some(calamine::Data::Empty) => serde_json::Value::Null,
        Some(calamine::Data::String(value)) => serde_json::Value::String(value.clone()),
        // Spreadsheets store every number as a float; keep whole numbers integral ("42", not "42.0").
        Some(calamine::Data::Float(value)) if value.fract() == 0.0 && value.abs() < 9.0e15 => {
            serde_json::Value::Number((*value as i64).into())
        }
        Some(calamine::Data::Float(value)) => {
            serde_json::Number::from_f64(*value).map_or(serde_json::Value::Null, serde_json::Value::Number)
        }
        Some(calamine::Data::Int(value)) => serde_json::Value::Number((*value).into()),
        Some(calamine::Data::Bool(value)) => serde_json::Value::Bool(*value),
        Some(other) => serde_json::Value::String(other.to_string()),
    }
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
        | "csv" | "tsv" | "json" | "yaml" | "toml" | "xlsx" | "md" | "markdown"
        | "txt" | "html" | "mp3" | "m4a" | "flac" | "wav" | "aiff" | "aif"
        | "opus" | "ogg" | "mp4" | "mov" | "mkv" | "webm" | "gif" => Ok(ext),
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
    // sanitize() maps empty to "file"; an empty suffix must stay empty.
    let clean_suffix = if suffix.trim().is_empty() { String::new() } else { sanitize(suffix.trim()) };
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

fn is_audio_target(extension: &str) -> bool {
    matches!(extension, "mp3" | "m4a" | "flac" | "wav" | "aiff" | "aif" | "opus" | "ogg")
}

fn is_video_target(extension: &str) -> bool {
    matches!(extension, "mp4" | "mov" | "mkv" | "webm")
}

fn animation_note(ext: &str) -> Option<String> {
    if ext == "gif" || ext == "webp" {
        Some("Animated images use the first frame in this build.".to_string())
    } else {
        None
    }
}

fn fidelity_for(kind: FileKind, source_ext: &str, target: &str) -> Fidelity {
    if kind == FileKind::Audio {
        return if is_audio_target(target) {
            let lossless = |value: &str| matches!(value, "flac" | "wav" | "aiff" | "aif");
            if lossless(source_ext) && lossless(target) {
                Fidelity::Lossless
            } else {
                Fidelity::Reencode
            }
        } else {
            Fidelity::Unsupported
        };
    }
    if kind == FileKind::Video {
        return if is_audio_target(target) {
            Fidelity::Extract
        } else if is_video_target(target) {
            Fidelity::Reencode
        } else if target == "gif" {
            Fidelity::Lossy
        } else {
            Fidelity::Unsupported
        };
    }
    if kind == FileKind::Document {
        return if matches!(target, "md" | "markdown" | "txt" | "html") {
            Fidelity::Extract
        } else {
            Fidelity::Unsupported
        };
    }
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
        "png" | "tif" | "tiff" => Fidelity::Lossless,
        "jpg" | "jpeg" | "heic" | "avif" | "webp" => {
            if matches!(source_ext, "jpg" | "jpeg" | "heic" | "avif" | "webp") {
                Fidelity::Reencode
            } else {
                Fidelity::Lossy
            }
        }
        "gif" => Fidelity::Lossy,
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
        "docx" | "pptx" | "md" | "txt" | "html" | "rtf" => FileKind::Document,
        "csv" | "tsv" | "json" | "yaml" | "yml" | "toml" | "xml" | "srt" | "vtt"
        | "xlsx" | "xls" => FileKind::Data,
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
    fn empty_suffix_keeps_stem() {
        assert_eq!(output_file_name("people", "", "yaml"), "people.yaml");
        assert_eq!(output_file_name("people", "  ", "jpeg"), "people.jpg");
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
    fn finds_duplicate_files_and_ignores_unique() {
        let mut first = NamedTempFile::with_suffix(".bin").expect("first");
        first.write_all(b"same contents").expect("write");
        first.flush().expect("flush");
        let mut second = NamedTempFile::with_suffix(".bin").expect("second");
        second.write_all(b"same contents").expect("write");
        second.flush().expect("flush");
        let mut unique = NamedTempFile::with_suffix(".bin").expect("unique");
        unique.write_all(b"different").expect("write");
        unique.flush().expect("flush");

        let groups = find_duplicates(vec![
            first.path().to_string_lossy().into_owned(),
            second.path().to_string_lossy().into_owned(),
            unique.path().to_string_lossy().into_owned(),
        ]);
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].paths.len(), 2);
        assert_eq!(groups[0].byte_size, 13);
    }

    #[test]
    fn extracts_docx_text_to_markdown() {
        let input = NamedTempFile::with_suffix(".docx").expect("docx");
        {
            let mut archive = zip::ZipWriter::new(&input);
            let options = zip::write::SimpleFileOptions::default();
            archive
                .start_file("word/document.xml", options)
                .expect("start");
            archive
                .write_all(
                    br#"<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello</w:t></w:r></w:p><w:p><w:r><w:t>World</w:t></w:r></w:p></w:body></w:document>"#,
                )
                .expect("write xml");
            archive.finish().expect("finish");
        }
        let output = NamedTempFile::with_suffix(".md").expect("md");
        extract_office(
            input.path().to_string_lossy().into_owned(),
            output.path().to_string_lossy().into_owned(),
            "md".to_string(),
        )
        .expect("extract docx");
        let text = fs::read_to_string(output.path()).expect("read output");
        assert!(text.contains("Hello"));
        assert!(text.contains("World"));
    }

    #[test]
    fn extracts_pptx_text_with_slide_headings() {
        let input = NamedTempFile::with_suffix(".pptx").expect("pptx");
        {
            let mut archive = zip::ZipWriter::new(&input);
            let options = zip::write::SimpleFileOptions::default();
            archive
                .start_file("ppt/slides/slide1.xml", options)
                .expect("start");
            archive
                .write_all(
                    br#"<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Quarterly review</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#,
                )
                .expect("write xml");
            archive.finish().expect("finish");
        }
        let output = NamedTempFile::with_suffix(".md").expect("md");
        extract_office(
            input.path().to_string_lossy().into_owned(),
            output.path().to_string_lossy().into_owned(),
            "md".to_string(),
        )
        .expect("extract pptx");
        let text = fs::read_to_string(output.path()).expect("read output");
        assert!(text.contains("## Slide 1"));
        assert!(text.contains("Quarterly review"));
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
    fn converts_csv_to_xlsx() {
        let mut input = NamedTempFile::with_suffix(".csv").expect("csv");
        input.write_all(b"name,role\nAda,engineer\nGrace,admiral\n").expect("write");
        input.flush().expect("flush");
        let xlsx = NamedTempFile::with_suffix(".xlsx").expect("xlsx");
        convert_data(
            input.path().to_string_lossy().into_owned(),
            xlsx.path().to_string_lossy().into_owned(),
            "xlsx".to_string(),
        )
        .expect("csv to xlsx");
        let bytes = fs::read(xlsx.path()).expect("read xlsx");
        assert!(bytes.starts_with(b"PK"));
    }

    #[test]
    fn converts_xlsx_to_csv() {
        let mut input = NamedTempFile::with_suffix(".csv").expect("csv");
        input.write_all(b"name,role\nAda,engineer\n").expect("write");
        input.flush().expect("flush");
        let xlsx = NamedTempFile::with_suffix(".xlsx").expect("xlsx");
        convert_data(
            input.path().to_string_lossy().into_owned(),
            xlsx.path().to_string_lossy().into_owned(),
            "xlsx".to_string(),
        )
        .expect("csv to xlsx");

        let csv = NamedTempFile::with_suffix(".csv").expect("csv out");
        convert_data(
            xlsx.path().to_string_lossy().into_owned(),
            csv.path().to_string_lossy().into_owned(),
            "csv".to_string(),
        )
        .expect("xlsx to csv");
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

    const DOCX_XML: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>
<w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Report</w:t></w:r></w:p>
<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>Summary &amp; scope</w:t></w:r></w:p>
<w:p><w:r><w:t xml:space="preserve">Plain </w:t></w:r><w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>strong</w:t></w:r><w:r><w:rPr><w:b w:val="0"/><w:i/></w:rPr><w:t xml:space="preserve"> soft</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>First</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Nested</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Counted</w:t></w:r></w:p>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>A|1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>D</w:t></w:r></w:p><w:p><w:r><w:t>E</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:drawing><wp:inline><wp:docPr id="1" name="Picture 1" descr="Chart"/><a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId5"/></pic:blipFill></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
</w:body></w:document>"#;

    const DOCX_NUMBERING: &[u8] = br#"<?xml version="1.0"?><w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl><w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>"#;

    fn write_zip(path: &Path, entries: &[(&str, &[u8])]) {
        let file = fs::File::create(path).expect("zip file");
        let mut archive = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        for (name, bytes) in entries {
            archive.start_file(*name, options).expect("start");
            archive.write_all(bytes).expect("write entry");
        }
        archive.finish().expect("finish");
    }

    fn rich_docx(dir: &Path) -> String {
        let path = dir.join("report.docx");
        write_zip(
            &path,
            &[
                ("[Content_Types].xml", br#"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#),
                ("word/document.xml", DOCX_XML),
                ("word/numbering.xml", DOCX_NUMBERING),
                ("word/_rels/document.xml.rels", br#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/><Relationship Id="rId9" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.com" TargetMode="External"/></Relationships>"#),
                ("word/media/image1.png", b"\x89PNG fake"),
            ],
        );
        path.to_string_lossy().into_owned()
    }

    fn extract_to(input: &str, output: &Path, target: &str) -> String {
        extract_office(
            input.to_string(),
            output.to_string_lossy().into_owned(),
            target.to_string(),
        )
        .expect("extract");
        fs::read_to_string(output).expect("read output")
    }

    #[test]
    fn extracts_docx_structure_to_markdown_with_images() {
        let dir = tempfile::tempdir().expect("dir");
        let input = rich_docx(dir.path());
        let md = extract_to(&input, &dir.path().join("out.md"), "md");
        for needle in [
            "# Report\n",
            "## Summary & scope\n",
            "Plain ***strong*** *soft*",
            "- First\n  - Nested\n1. Counted",
            "| A\\|1 | B |\n| --- | --- |\n| C | D E |",
            "![Chart](out_files/image1.png)",
        ] {
            assert!(md.contains(needle), "missing {needle:?} in:\n{md}");
        }
        assert_eq!(
            fs::read(dir.path().join("out_files/image1.png")).expect("image copied"),
            b"\x89PNG fake"
        );
    }

    #[test]
    fn extracts_docx_structure_to_html_and_text() {
        let dir = tempfile::tempdir().expect("dir");
        let input = rich_docx(dir.path());
        let html = extract_to(&input, &dir.path().join("page.html"), "html");
        for needle in [
            "<h1>Report</h1>",
            "<h2>Summary &amp; scope</h2>",
            "<strong><em>strong</em></strong>",
            "<ul><li>First<ul><li>Nested</li></ul>\n</li></ul>\n<ol><li>Counted</li></ol>",
            "<table>",
            "<th>A|1</th>",
            "<td>D E</td>",
            "<img src=\"page_files/image1.png\" alt=\"Chart\">",
        ] {
            assert!(html.contains(needle), "missing {needle:?} in:\n{html}");
        }
        assert!(dir.path().join("page_files/image1.png").exists());

        let txt = extract_to(&input, &dir.path().join("plain.txt"), "txt");
        assert!(txt.contains("Report\n\nSummary & scope"));
        assert!(txt.contains("- First\n  - Nested"));
        assert!(txt.contains("C\tD E"));
        assert!(!txt.contains("image1"));
        assert!(!dir.path().join("plain_files").exists());
    }

    #[test]
    fn extracts_pptx_titles_bullets_and_images() {
        let dir = tempfile::tempdir().expect("dir");
        let input = dir.path().join("deck.pptx");
        let slide = br#"<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:cSld><p:spTree>
<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="en-US"/><a:t>Roadmap</a:t></a:r></a:p></p:txBody></p:sp>
<p:sp><p:nvSpPr><p:cNvPr id="3" name="Content 2"/><p:cNvSpPr/><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr><p:txBody><a:bodyPr/><a:p><a:r><a:t>Goals</a:t></a:r></a:p><a:p><a:pPr lvl="1"/><a:r><a:rPr b="1"/><a:t>Ship it</a:t></a:r></a:p></p:txBody></p:sp>
<p:pic><p:nvPicPr><p:cNvPr id="4" name="Picture 3" descr="Logo"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/></p:blipFill></p:pic>
<p:sp><p:nvSpPr><p:cNvPr id="5" name="Slide Number"/><p:cNvSpPr/><p:nvPr><p:ph type="sldNum" idx="12"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:fld id="x" type="slidenum"><a:t>1</a:t></a:fld></a:p></p:txBody></p:sp>
</p:spTree></p:cSld></p:sld>"#;
        let plain_slide = br#"<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Thanks</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"#;
        write_zip(
            &input,
            &[
                ("ppt/slides/slide10.xml", plain_slide),
                ("ppt/slides/slide1.xml", slide),
                ("ppt/slides/_rels/slide1.xml.rels", br#"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/></Relationships>"#),
                ("ppt/media/image1.png", b"png"),
            ],
        );
        let md = extract_to(&input.to_string_lossy(), &dir.path().join("deck.md"), "md");
        let expected = "## Slide 1 — Roadmap\n\n- Goals\n  - **Ship it**\n\n![Logo](deck_files/image1.png)\n\n## Slide 2\n\nThanks\n";
        assert!(md.contains(expected), "missing {expected:?} in:\n{md}");
        assert!(!md.contains("Roadmap\n\nRoadmap"));
        assert!(dir.path().join("deck_files/image1.png").exists());
    }

    #[test]
    fn media_names_cannot_escape_the_images_folder() {
        assert_eq!(safe_media_name("word/media/../../evil.png"), "evil.png");
        assert_eq!(safe_media_name("ppt/media/..\\..\\x y.png"), "x_y.png");
        assert_eq!(safe_media_name("word/media/.."), "image");
        assert_eq!(resolve_zip_path("ppt/slides", "../media/a.png"), "ppt/media/a.png");
        assert_eq!(resolve_zip_path("word", "/word/media/a.png"), "word/media/a.png");
    }

    #[test]
    fn csv_to_xlsx_types_numbers_but_keeps_codes_as_text() {
        use calamine::{Data, Reader, open_workbook_auto};
        let mut input = NamedTempFile::with_suffix(".csv").expect("csv");
        input
            .write_all(b"zip,count,price,name\n00501,42,-3.5,Ada\n0.25,+7,1e5,007\n")
            .expect("write");
        input.flush().expect("flush");
        let xlsx = NamedTempFile::with_suffix(".xlsx").expect("xlsx");
        convert_data(
            input.path().to_string_lossy().into_owned(),
            xlsx.path().to_string_lossy().into_owned(),
            "xlsx".to_string(),
        )
        .expect("csv to xlsx");

        let mut workbook = open_workbook_auto(xlsx.path()).expect("open");
        let range = workbook.worksheet_range_at(0).expect("sheet").expect("range");
        // Columns are keyed by header because JSON object keys come back sorted.
        let cell = |row: u32, header: &str| {
            let column = (0..4)
                .find(|c| range.get_value((0, *c)) == Some(&Data::String(header.into())))
                .expect("header");
            range.get_value((row, column)).cloned()
        };
        assert_eq!(cell(1, "zip"), Some(Data::String("00501".into())));
        assert_eq!(cell(1, "count"), Some(Data::Float(42.0)));
        assert_eq!(cell(1, "price"), Some(Data::Float(-3.5)));
        assert_eq!(cell(2, "zip"), Some(Data::Float(0.25)));
        assert_eq!(cell(2, "count"), Some(Data::String("+7".into())));
        assert_eq!(cell(2, "price"), Some(Data::String("1e5".into())));
        assert_eq!(cell(2, "name"), Some(Data::String("007".into())));

        let csv = NamedTempFile::with_suffix(".csv").expect("csv out");
        convert_data(
            xlsx.path().to_string_lossy().into_owned(),
            csv.path().to_string_lossy().into_owned(),
            "csv".to_string(),
        )
        .expect("xlsx to csv");
        let text = fs::read_to_string(csv.path()).expect("read csv");
        assert!(text.contains("42,Ada,-3.5,00501"), "{text}");
    }

    #[test]
    fn multi_sheet_xlsx_becomes_object_and_csv_takes_first_sheet() {
        let xlsx = NamedTempFile::with_suffix(".xlsx").expect("xlsx");
        {
            let mut workbook = rust_xlsxwriter::Workbook::new();
            let people = workbook.add_worksheet().set_name("People").expect("name");
            people.write_string(0, 0, "name").expect("w");
            people.write_string(1, 0, "Ada").expect("w");
            workbook.add_worksheet().set_name("Blank").expect("name");
            let orders = workbook.add_worksheet().set_name("Orders").expect("name");
            orders.write_string(0, 0, "id").expect("w");
            orders.write_number(1, 0, 7).expect("w");
            workbook.save(xlsx.path()).expect("save");
        }
        let json = NamedTempFile::with_suffix(".json").expect("json");
        convert_data(
            xlsx.path().to_string_lossy().into_owned(),
            json.path().to_string_lossy().into_owned(),
            "json".to_string(),
        )
        .expect("xlsx to json");
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(json.path()).expect("read")).expect("parse");
        let sheets = value.as_object().expect("object of sheets");
        assert_eq!(sheets.len(), 2);
        assert_eq!(value["People"][0]["name"], "Ada");
        assert_eq!(value["Orders"][0]["id"], 7);

        let csv = NamedTempFile::with_suffix(".csv").expect("csv");
        convert_data(
            xlsx.path().to_string_lossy().into_owned(),
            csv.path().to_string_lossy().into_owned(),
            "csv".to_string(),
        )
        .expect("xlsx to csv");
        assert_eq!(fs::read_to_string(csv.path()).expect("read"), "name\nAda\n");
    }

    #[test]
    fn plans_gif_targets_as_lossy() {
        let png = file_with_bytes(&[0x89, b'P', b'N', b'G'], ".png");
        let video = file_with_bytes(b"\0\0\0\x18ftypisom\0\0\0\0", ".mp4");
        let plan = build_plan(
            vec![
                png.path().to_string_lossy().into_owned(),
                video.path().to_string_lossy().into_owned(),
            ],
            ".GIF".to_string(),
            String::new(),
        )
        .expect("plan");
        assert_eq!(plan.items[0].fidelity, Fidelity::Lossy);
        assert_eq!(plan.items[1].kind, FileKind::Video);
        assert_eq!(plan.items[1].fidelity, Fidelity::Lossy);
        assert!(plan.items[1].output_name.ends_with(".gif"));
    }
}
