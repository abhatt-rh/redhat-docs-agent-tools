# Build system architecture

The following diagram shows the build pipeline.

![Build pipeline showing three stages: fetch, build, and deploy](../img/pipeline.png)
/// figure-caption
RHIVOS build pipeline overview
///

## Platform selection

Choose your target platform:

=== "x86_64"
    Configure for standard server hardware:
    ```yaml title="x86-config.yml"
    platform: x86_64
    boot: uefi
    ```

=== "aarch64"
    Configure for ARM-based automotive hardware:
    ```yaml title="arm-config.yml"
    platform: aarch64
    boot: systemready-ir
    ```
