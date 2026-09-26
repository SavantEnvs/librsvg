// Known-answer-test probe for the librsvg Mayhem integration oracle.
//
// Drives the librsvg (rsvg) crate through the same load+render pipeline as the
// render_document fuzz target, on a FIXED solid-red SVG, and prints exact computed
// values that mayhem/test.sh asserts:
//   * KAT_WIDTH / KAT_HEIGHT — the SVG's intrinsic dimensions (10 x 10 px).
//   * KAT_PIXEL   — the ARGB32 pixel at the surface centre after rendering (opaque
//                   red => 0xffff0000). This exercises the real CSS/paint/render
//                   path, is font-independent, and is fully deterministic.
//
// Any deviation (a neutered/no-op librsvg, a broken parser, a mis-rendered fill)
// changes these values or produces no output at all — so the grep in test.sh fails.

use cairo;
use gio;
use glib;
use rsvg;

const SVG: &str =
    r#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect x="0" y="0" width="10" height="10" fill="rgb(255,0,0)"/></svg>"#;

fn main() {
    let bytes = glib::Bytes::from(SVG.as_bytes());
    let stream = gio::MemoryInputStream::from_bytes(&bytes);
    let handle = rsvg::Loader::new()
        .read_stream(&stream, None::<&gio::File>, None::<&gio::Cancellable>)
        .expect("librsvg failed to load the fixed KAT SVG");

    let renderer = rsvg::CairoRenderer::new(&handle);

    // Intrinsic dimensions: width=10, height=10 (px).
    let (w, h) = renderer.intrinsic_size_in_pixels().expect("no intrinsic size");
    println!("KAT_WIDTH={}", w as i64);
    println!("KAT_HEIGHT={}", h as i64);

    // Render onto a 10x10 ARGB32 surface and read the centre pixel.
    let mut surface = cairo::ImageSurface::create(cairo::Format::ARgb32, 10, 10)
        .expect("failed to create cairo surface");
    {
        let cr = cairo::Context::new(&surface).expect("failed to create cairo context");
        renderer
            .render_document(&cr, &cairo::Rectangle::new(0.0, 0.0, 10.0, 10.0))
            .expect("render_document failed on the fixed KAT SVG");
    } // drop the Context so the surface has no outstanding references

    surface.flush();
    let stride = surface.stride() as usize;
    let data = surface.data().expect("failed to borrow surface data");
    // ARGB32 is stored native-endian as a u32 => in memory (little-endian) B,G,R,A.
    let idx = 5 * stride + 5 * 4;
    let b = data[idx];
    let g = data[idx + 1];
    let r = data[idx + 2];
    let a = data[idx + 3];
    let argb: u32 =
        ((a as u32) << 24) | ((r as u32) << 16) | ((g as u32) << 8) | (b as u32);
    println!("KAT_PIXEL={:08x}", argb);
}
