use std::ffi::{CStr, CString, c_char, c_int};

unsafe extern "C" {
    fn corestub_render(png_path: *const c_char, info: *mut c_char, info_size: usize) -> c_int;
}

slint::slint! {
    import { Button, VerticalBox } from "std-widgets.slint";
    export component Consumer inherits Window {
        title: "skia-pack Rust consumer";
        preferred-width: 640px;
        preferred-height: 240px;
        in property <string> core-info;
        VerticalBox {
            Text { text: "Slint, Skia renderer"; font-size: 24px; }
            Text { text: root.core-info; wrap: word-wrap; }
            Button { text: "A Slint button"; }
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = std::env::var("RUST_CONSUMER_OUT").unwrap_or_else(|_| ".".into());
    println!("link map: {}", env!("RUST_CONSUMER_LINK_MAP"));

    // Core side: CPU rendering with Skia + HarfBuzz from C++.
    let png = CString::new(format!("{out_dir}/core-stub.png"))?;
    let mut info = [0 as c_char; 256];
    let status = unsafe { corestub_render(png.as_ptr(), info.as_mut_ptr(), info.len()) };
    let info = unsafe { CStr::from_ptr(info.as_ptr()) }.to_string_lossy().into_owned();
    println!("core stub: status {status}, {info}");
    if status != 0 {
        return Err(format!("core stub failed with {status}").into());
    }

    // Rust side: the same Skia through skia-safe directly.
    let mut surface = skia_safe::surfaces::raster_n32_premul((32, 32)).ok_or("skia-safe surface")?;
    surface.canvas().clear(skia_safe::Color::RED);
    println!("skia-safe: raster surface {}x{}", surface.width(), surface.height());

    // Slint side: its Skia renderer.
    slint::BackendSelector::new()
        .backend_name("winit".into())
        .renderer_name("skia".into())
        .select()?;
    let app = Consumer::new()?;
    app.set_core_info(info.into());
    let weak = app.as_weak();
    slint::Timer::single_shot(std::time::Duration::from_millis(1500), move || {
        let app = weak.unwrap();
        match app.window().take_snapshot() {
            Ok(buffer) => {
                let path = format!("{out_dir}/slint-window.png");
                let image = skia_safe::images::raster_from_data(
                    &skia_safe::ImageInfo::new(
                        (buffer.width() as i32, buffer.height() as i32),
                        skia_safe::ColorType::RGBA8888,
                        skia_safe::AlphaType::Unpremul,
                        None,
                    ),
                    skia_safe::Data::new_copy(buffer.as_bytes()),
                    buffer.width() as usize * 4,
                )
                .expect("snapshot image");
                let data = image
                    .encode(None, skia_safe::EncodedImageFormat::PNG, None)
                    .expect("png");
                std::fs::write(&path, data.as_bytes()).expect("write snapshot");
                let lit = buffer.as_bytes().chunks(4).filter(|p| p[0] != buffer.as_bytes()[0]).count();
                println!("slint: snapshot {}x{} -> {path}, pixels differing from the corner: {lit}", buffer.width(), buffer.height());
            }
            Err(err) => println!("slint: snapshot failed: {err}"),
        }
        if std::env::var_os("RUST_CONSUMER_STAY_OPEN").is_none() {
            slint::quit_event_loop().unwrap();
        }
    });
    app.run()?;
    Ok(())
}
