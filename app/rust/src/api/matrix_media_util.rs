use std::io::Cursor;

use image::ImageReader;
use matrix_sdk::attachment::{AttachmentInfo, BaseImageInfo, BaseVideoInfo, Thumbnail};
use matrix_sdk::ruma::UInt;
use mime::Mime;

/// Max edge length for outbound image thumbnails.
const THUMB_MAX_EDGE: u32 = 320;

pub(super) fn image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    ImageReader::new(Cursor::new(data))
        .with_guessed_format()
        .ok()?
        .into_dimensions()
        .ok()
}

pub(super) fn make_image_thumbnail(data: &[u8]) -> Option<Thumbnail> {
    let img = image::load_from_memory(data).ok()?;
    let (w, h) = (img.width(), img.height());
    if w == 0 || h == 0 {
        return None;
    }
    let max = THUMB_MAX_EDGE;
    let (tw, th) = if w >= h {
        let tw = max.min(w);
        let th = ((h as u64 * tw as u64) / w as u64).max(1) as u32;
        (tw, th)
    } else {
        let th = max.min(h);
        let tw = ((w as u64 * th as u64) / h as u64).max(1) as u32;
        (tw, th)
    };
    let resized = img.thumbnail(tw, th);
    let mut buf = Vec::new();
    resized
        .write_to(&mut Cursor::new(&mut buf), image::ImageFormat::Jpeg)
        .ok()?;
    let width = UInt::new(tw as u64)?;
    let height = UInt::new(th as u64)?;
    let size = UInt::new(buf.len() as u64)?;
    Some(Thumbnail {
        data: buf,
        content_type: mime::IMAGE_JPEG,
        height,
        width,
        size,
    })
}

pub(super) fn attachment_info_for_mime(
    _mime: &Mime,
    data: &[u8],
    is_video: bool,
) -> AttachmentInfo {
    let size = UInt::new(data.len() as u64);
    if is_video {
        let (width, height) = image_dimensions(data).unwrap_or((0, 0));
        AttachmentInfo::Video(BaseVideoInfo {
            duration: None,
            height: width_height_to_uint(height),
            width: width_height_to_uint(width),
            size,
            blurhash: None,
        })
    } else {
        let (width, height) = image_dimensions(data).unwrap_or((0, 0));
        AttachmentInfo::Image(BaseImageInfo {
            height: width_height_to_uint(height),
            width: width_height_to_uint(width),
            size,
            blurhash: None,
            is_animated: None,
        })
    }
}

fn width_height_to_uint(v: u32) -> Option<UInt> {
    if v == 0 {
        None
    } else {
        UInt::new(v as u64)
    }
}

pub(super) fn uint_to_u32(v: UInt) -> u32 {
    u64::from(v).min(u32::MAX as u64) as u32
}

pub(super) fn duration_ms_from_std(duration: std::time::Duration) -> i64 {
    duration.as_millis().min(i64::MAX as u128) as i64
}

pub(super) fn preview_body_for_filename(filename: &str, caption: Option<&str>) -> String {
    caption
        .filter(|c| !c.is_empty())
        .map(|c| c.to_owned())
        .unwrap_or_else(|| format!("[{}]", filename))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_body_prefers_caption() {
        assert_eq!(
            preview_body_for_filename("cat.jpg", Some("look")),
            "look"
        );
        assert_eq!(
            preview_body_for_filename("cat.jpg", None),
            "[cat.jpg]"
        );
    }

    #[test]
    fn tiny_png_has_dimensions() {
        // 1x1 red PNG
        let png = vec![
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48,
            0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08,
            0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d,
            0xb4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
        ];
        let (w, h) = image_dimensions(&png).expect("dimensions");
        assert_eq!((w, h), (1, 1));
    }
}
