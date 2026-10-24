#!/bin/bash
# Source from a test harness after changing to the repository root.
umask 077
mkdir -p .build/tests
fixture_root="$(mktemp -d "$PWD/.build/tests/${1:-fixture}.XXXXXX")"
fixture_pids=()
cleanup_test() {
    local status=$?
    trap - EXIT
    for pid in ${fixture_pids[@]+"${fixture_pids[@]}"}; do kill "$pid" 2>/dev/null || true; done
    for pid in ${fixture_pids[@]+"${fixture_pids[@]}"}; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$fixture_root"
    exit "$status"
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One source list for each native adapter; categories share its existing worker.
ssh_sources=(Farcast/Native/SSH/*.m)
rdp_drive_sources=(Farcast/Native/RDP/RDPDrive.m Farcast/Native/RDP/RDPDriveManager.m)
rdp_support_sources=(Farcast/Native/RDP/RDPClipboard.m "${rdp_drive_sources[@]}")
rdp_sources=(Farcast/Native/RDP/RDPClient.m "${rdp_support_sources[@]}")

# Swift fixture links expect one relocatable object per adapter responsibility.
compile_native_adapter() {
    local output="$1" source object
    shift
    local objects=()
    mkdir -p "$fixture_root/native-objects"
    for source in "$@"; do
        object="$fixture_root/native-objects/$(basename "$source" .m).o"
        xcrun clang -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 \
            -I Vendor/Native/include -I Vendor/Native/include/freerdp3 -I Vendor/Native/include/winpr3 \
            -c "$source" -o "$object"
        objects+=("$object")
    done
    xcrun clang -r -nostdlib -arch arm64 -mmacosx-version-min=27.0 "${objects[@]}" -o "$output"
}
compile_native_clients() {
    compile_native_adapter "$fixture_root/SSH.o" "${ssh_sources[@]}"
    compile_native_adapter "$fixture_root/RDP.o" Farcast/Native/RDP/RDPClient.m Farcast/Native/VNC/*.m
    compile_native_adapter "$fixture_root/RDPClipboard.o" Farcast/Native/RDP/RDPClipboard.m
    compile_native_adapter "$fixture_root/RDPDrive.o" "${rdp_drive_sources[@]}"
}
