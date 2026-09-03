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
