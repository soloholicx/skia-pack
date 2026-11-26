use std::path::PathBuf;

fn env(name: &str) -> String {
    println!("cargo:rerun-if-env-changed={name}");
    std::env::var(name).unwrap_or_else(|_| panic!("{name} must be set (scripts/verify_rust_consumer.sh)"))
}

fn main() {
    // The extracted slice tarball: headers/, lib/, skia-defines.txt.
    let pack = PathBuf::from(env("SKIA_PACK_DIR"));
    // skia-bindings reads these three itself; they must be consistent with the pack.
    let defines = env("SKIA_BUILD_DEFINES");
    env("SKIA_SOURCE_DIR");
    env("SKIA_LIBRARY_SEARCH_PATH");
    println!("cargo:rerun-if-changed=corestub.cpp");

    // The C++ side is built as any C++ consumer of the pack would be: the
    // public header tree and the pack's defines.
    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++20")
        .file("corestub.cpp")
        .include(pack.join("headers"))
        .flag("-fno-rtti")
        .flag("-fno-exceptions")
        .warnings(false);
    for define in defines.split_whitespace() {
        let define = define.trim_start_matches("-D");
        match define.split_once('=') {
            Some((name, value)) => build.define(name, Some(value)),
            None => build.define(define, None),
        };
    }
    build.compile("corestub");

    // skia-bindings links the Skia archives. The pack's HarfBuzz is a separate
    // archive (rust-skia's own build folds HarfBuzz into Skia's), so the
    // consumer names it.
    println!("cargo:rustc-link-search=native={}", pack.join("lib").display());
    println!("cargo:rustc-link-lib=static=harfbuzz");

    // Evidence for "one Skia": a link map of the final executable.
    let map = PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("link.map");
    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple") {
        println!("cargo:rustc-link-arg=-Wl,-map,{}", map.display());
    } else {
        println!("cargo:rustc-link-arg=-Wl,-Map={}", map.display());
    }
    println!("cargo:rustc-env=RUST_CONSUMER_LINK_MAP={}", map.display());
}
