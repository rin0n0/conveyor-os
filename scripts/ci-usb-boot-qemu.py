#!/usr/bin/env python3
"""Boot a Conveyor disk as a USB drive on blank UEFI firmware and type the LUKS passphrase.

Usage: ci-usb-boot-qemu.py <disk.raw> <plain|secureboot> <log> <passphrase>
The firmware has no boot entries, so it must find \\EFI\\BOOT\\BOOTX64.EFI by itself.
"""
import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time

TIMEOUT_SECONDS = 1500
SETTLE_SECONDS = 20
FIRMWARE = {
    "plain": ("/usr/share/OVMF/OVMF_CODE_4M.fd", "/usr/share/OVMF/OVMF_VARS_4M.fd"),
    "secureboot": ("/usr/share/OVMF/OVMF_CODE_4M.secboot.fd", "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"),
}
PROMPT = re.compile(rb"Please enter passphrase for disk")
BOOTED = re.compile(rb"Reached target .*Graphical Interface")
FATAL = re.compile(rb"Security Violation|Access Denied|Kernel panic|emergency mode|dracut-emergency")
CORE_FAILURE = re.compile(rb"FAILED.*(greetd|llama-swap|boot-gpu-detect)")


def main():
    disk, mode, log_path, passphrase = sys.argv[1:5]
    code, template = FIRMWARE[mode]
    workdir = tempfile.mkdtemp()
    variables = os.path.join(workdir, "vars.fd")
    shutil.copy(template, variables)

    command = [
        "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-smp", "2", "-m", "4096",
        "-machine", "q35,smm=on", "-global", "driver=cfi.pflash01,property=secure,value=on",
        "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
        "-drive", f"if=pflash,format=raw,file={variables}",
        "-device", "qemu-xhci,id=xhci",
        "-drive", f"if=none,id=usbdisk,format=raw,cache=unsafe,file={disk}",
        "-device", "usb-storage,bus=xhci.0,drive=usbdisk,removable=on",
        "-display", "none", "-serial", "stdio", "-monitor", "none",
    ]
    vm = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    output = bytearray()
    prompt_from = 0
    booted_at = None
    deadline = time.monotonic() + TIMEOUT_SECONDS
    result = "timed out"

    with open(log_path, "wb") as log:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([vm.stdout], [], [], 2)
            if ready:
                chunk = os.read(vm.stdout.fileno(), 65536)
                if not chunk:
                    result = "QEMU exited"
                    break
                output += chunk
                log.write(chunk)
                log.flush()

            if PROMPT.search(output, prompt_from):
                time.sleep(2)
                vm.stdin.write(passphrase.encode() + b"\r")
                vm.stdin.flush()
                prompt_from = len(output)

            failure = FATAL.search(output)
            if failure:
                result = "boot failure: " + failure.group().decode()
                break
            if booted_at is None and BOOTED.search(output):
                booted_at = time.monotonic()
            if booted_at is not None and time.monotonic() - booted_at > SETTLE_SECONDS:
                result = "booted"
                break

    vm.kill()
    vm.wait()
    shutil.rmtree(workdir)

    if result == "booted" and CORE_FAILURE.search(output):
        result = "a core service failed"
    if result == "booted" and mode == "secureboot" and b"Secure boot enabled" not in output:
        result = "booted, but Secure Boot was not active"

    print(f"{mode}: {result}")
    if result != "booted":
        print(output[-6000:].decode(errors="replace"))
        sys.exit(1)


if __name__ == "__main__":
    main()
