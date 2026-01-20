use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("manifest dir"));
    let repo_root = manifest_dir
        .parent()
        .and_then(|path| path.parent())
        .expect("repo root");
    let script = repo_root.join("scripts").join("gen_constants.py");

    println!("cargo:rerun-if-changed={}", script.display());
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("contracts/constants/generated.cairo").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("circuits/constants/generated.circom").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("rust/client/src/generated_constants.rs").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("rust/asp/src/generated_constants.rs").display()
    );

    let status = Command::new("python3")
        .arg(script)
        .arg("--check")
        .status()
        .expect("failed to run gen_constants.py");
    if !status.success() {
        panic!("constants check failed");
    }
}
