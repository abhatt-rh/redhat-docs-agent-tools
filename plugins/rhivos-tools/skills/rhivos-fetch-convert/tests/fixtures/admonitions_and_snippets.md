# Configuring your RHIVOS deployment

Before you begin, review the safety notice.

!!! Important
    --8<-- "prose_snippets/disclaimer.md"

## Image configuration

!!! note "Configuration tip"
    Always validate your manifest before building.

!!! warning
    Modifying the kernel configuration can affect system stability.

??? tip "Optional optimization"
    Enable build caching to speed up repeated builds.

The following configuration is required:

--8<-- "code_snippets/sample_config.yml"

Use this service definition:

--8<-- "code_snippets/sample_service.container"

Run the build script:

--8<-- "code_snippets/sample_script.sh"

Extract only the relevant lines:

--8<-- "code_snippets/long_file.yml:5:10"
