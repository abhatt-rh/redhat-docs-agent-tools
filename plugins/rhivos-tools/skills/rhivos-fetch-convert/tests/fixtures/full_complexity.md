---
title: Complete RHIVOS Workflow
description: End-to-end guide for building, configuring, and deploying RHIVOS images.
---

This guide covers the complete workflow for RHIVOS image creation.

## Safety notice

!!! Important
    --8<-- "prose_snippets/disclaimer.md"

## Architecture

![Diagram showing the build flow from manifest to deployed image](../img/architecture.png)
/// figure-caption
RHIVOS build and deployment architecture
///

For more details, see [Architecture concepts](../features-and-concepts/con_architecture.md).

## Configuration

!!! note "Before you begin"
    Ensure all prerequisites are met before proceeding.

!!! warning
    Do not modify system files without a backup.

The base image configuration:

--8<-- "code_snippets/sample_config.yml"

## Platform setup

=== "x86_64"
    Standard server configuration:
    ```yaml title="x86-manifest.yml"
    platform: x86_64
    secure_boot: true
    ```

=== "aarch64"
    ARM automotive configuration:
    ```yaml title="arm-manifest.yml"
    platform: aarch64
    systemready: ir
    ```

## Service deployment

Deploy the engine service:

--8<-- "code_snippets/sample_service.container"

Build with the helper script:

--8<-- "code_snippets/sample_script.sh"

Partial configuration extract:

--8<-- "code_snippets/long_file.yml:5:10"

## Next steps

See [Deploying to hardware](../provisioning/proc_deploying.md) for flashing instructions.
