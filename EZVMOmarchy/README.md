# EZVM Omarchy

This is the independent macOS application for one persistent Omarchy workspace.
It has its own bundle identifier and data domain, and consumes the shared
`EZVMCore` package from the parent repository while the product boundary is
being established. Generate the Xcode project with:

```sh
cd EZVMOmarchy
xcodegen generate
```

`project.yml` is the source of truth. Do not hand-edit the generated project.

The app owns one Host folder at `~/Library/Application Support/EZVM
Omarchy/Shared`. Users can import regular files with the toolbar or by dropping
them onto the VM view. Imports never overwrite existing files and are published
atomically. A prepared guest mounts the same directory at
`/mnt/ezvm-shared`; the Integration menu reports it as available only after the
Guest Agent verifies the live VirtioFS mount.
