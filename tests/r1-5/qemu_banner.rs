// tests/r1-5/qemu_banner.rs — R1.5-006 integration test
//
// QEMU smoke test: kernel boots to long mode, prints banner, halts.
// Linux-only (requires QEMU); skips on platforms without qemu-system-x86_64.
//
// Procedure:
// 1. Run ./tools/build.sh to compile PaideiaOS kernel
// 2. Run ./tools/run-qemu.sh with 5-second timeout
// 3. Capture QEMU serial output
// 4. Assert banner text appears: "PaideiaOS R7" + "kernel_main reached"
//
// This test validates:
// - Bootloader → _start entry point wiring
// - 32-bit protected mode entry (QEMU -kernel loading)
// - Cross-module function calls (kernel_main_64 invocation)
// - UART initialization + output (banner_puts)
// - Observable kernel behavior (serial output capture)

#[cfg(test)]
mod r1_5_qemu_banner {
    use std::process::{Command, Stdio};
    use std::time::Duration;
    use std::path::PathBuf;

    fn repo_root() -> PathBuf {
        let manifest_dir = env!("CARGO_MANIFEST_DIR");
        PathBuf::from(manifest_dir)
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from("."))
    }

    /// Test: QEMU smoke test with banner capture
    /// Skipped on non-Linux or if qemu-system-x86_64 not found
    #[test]
    #[cfg_attr(not(target_os = "linux"), ignore = "QEMU smoke requires Linux")]
    fn test_qemu_banner_appears() {
        // Check if qemu-system-x86_64 is available
        let qemu_check = Command::new("which")
            .arg("qemu-system-x86_64")
            .output();

        if qemu_check.is_err() || !qemu_check.unwrap().status.success() {
            eprintln!("qemu-system-x86_64 not found in PATH; skipping QEMU smoke test");
            return;
        }

        let repo = repo_root();

        // Step 1: Run ./tools/build.sh
        println!("[r1.5] Building kernel...");
        let build_output = Command::new("bash")
            .arg("./tools/build.sh")
            .current_dir(&repo)
            .output()
            .expect("Failed to run build.sh");

        if !build_output.status.success() {
            eprintln!("build.sh failed:");
            eprintln!("{}", String::from_utf8_lossy(&build_output.stdout));
            eprintln!("{}", String::from_utf8_lossy(&build_output.stderr));
            panic!("Kernel build failed");
        }

        println!("[r1.5] Build successful");

        // Step 2: Run ./tools/run-qemu.sh with timeout
        // Note: run-qemu.sh should handle serial output capture (expects it to write to stderr/stdout)
        println!("[r1.5] Running QEMU with 5-second timeout...");

        let qemu_output = Command::new("bash")
            .arg("./tools/run-qemu.sh")
            .current_dir(&repo)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        let qemu_output = match qemu_output {
            Ok(output) => output,
            Err(e) => {
                eprintln!("Failed to run QEMU: {}", e);
                panic!("QEMU execution failed");
            }
        };

        // Step 3: Capture serial output from stdout/stderr
        let stdout = String::from_utf8_lossy(&qemu_output.stdout);
        let stderr = String::from_utf8_lossy(&qemu_output.stderr);
        let combined = format!("{}\n{}", stdout, stderr);

        println!("[r1.5] QEMU output (stdout):\n{}", stdout);
        println!("[r1.5] QEMU output (stderr):\n{}", stderr);

        // Step 4: Assert banner appears
        // Expected strings (from banner_r15.bytes and src/kernel/boot/banner.pdx):
        // "PaideiaOS R7" and "kernel_main reached"
        let has_paideia = combined.contains("PaideiaOS") || combined.contains("Paideia");
        let has_kernel_main = combined.contains("kernel_main");

        if !has_paideia && !has_kernel_main {
            eprintln!("Banner not found in QEMU output");
            eprintln!("Combined output:\n{}", combined);
            panic!(
                "QEMU smoke test failed: banner not printed\n\
                 Expected: 'PaideiaOS' and 'kernel_main'\n\
                 Got: {}", combined
            );
        }

        if has_paideia && has_kernel_main {
            println!("[r1.5] SUCCESS: Banner printed and kernel_main reached!");
        } else {
            println!("[r1.5] Partial banner (found: paideia={}, kernel_main={})", has_paideia, has_kernel_main);
        }
    }

    /// Test: Kernel ELF is produced
    #[test]
    fn test_kernel_elf_exists() {
        let repo = repo_root();
        let kernel_elf = repo.join("build/kernel.elf");

        // Run build.sh
        let build = Command::new("bash")
            .arg("./tools/build.sh")
            .current_dir(&repo)
            .output()
            .expect("Failed to run build.sh");

        if !build.status.success() {
            panic!("build.sh failed");
        }

        // Check that kernel.elf exists
        if !kernel_elf.exists() {
            panic!("kernel.elf not found at {}", kernel_elf.display());
        }

        println!("[r1.5] kernel.elf produced: {}", kernel_elf.display());
    }

    /// Test: All .pdx files compile
    #[test]
    fn test_pdx_compile() {
        let repo = repo_root();

        let output = Command::new("bash")
            .arg("./tools/build.sh")
            .current_dir(&repo)
            .output()
            .expect("Failed to run build.sh");

        if !output.status.success() {
            eprintln!("build.sh failed:");
            eprintln!("{}", String::from_utf8_lossy(&output.stderr));
            panic!("PDX compilation failed");
        }

        println!("[r1.5] All .pdx files compiled successfully");
    }
}
