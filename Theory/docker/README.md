# Theory container job configurations

The BOINC docker wrapper reads `job.toml` from the task's slot directory.

| Configuration | Intended use | CVMFS source |
| --- | --- | --- |
| `job.toml` | Installations prepared to share host CVMFS | `/cvmfs` on the container host |
| `job-macos.toml` | macOS with BOINC-managed Podman | CVMFS mounted inside each task container |

## Why a separate macOS configuration

With remote Podman, bind-mount sources are resolved on the Linux VM, not on
macOS. BOINC 8.2.11 creates its VM with `podman machine init -v /Library:/Library`,
so `/Library` is the only host path shared into the VM and the VM has no
`/cvmfs`. Podman refuses to create a container whose bind source is missing:

```text
Error: statfs /cvmfs: no such file or directory
```

That happens before the container starts, so the in-container CVMFS fallback
already present in `entrypoint.sh` never gets a chance to run. Creating a
macOS synthetic `/cvmfs` link does not help, because it configures neither the
VM path nor a share for it. See the
[Podman volume documentation](https://docs.podman.io/en/latest/markdown/podman-run.1.html#volume-v-source-volume-host-dir-container-dir-options).

The same failure applies to any Podman host without `/cvmfs`, not only macOS.

## Packaging macOS tasks

Package `job-macos.toml` with the logical filename `job.toml` in the macOS
application release, together with the usual Dockerfile and entrypoint.
Adding this file to the repository does not automatically select it for
existing releases; the project-side application packaging must select it.
Volunteers should not need to edit downloaded task files.

This configuration grants the `SYS_ADMIN` capability and passes `/dev/fuse`
for the entrypoint's existing in-container CVMFS setup. It deliberately omits
`-v /cvmfs:/cvmfs:shared`. The image provides the container-side `/cvmfs`
directory, and the entrypoint configures and mounts its repositories there.

The existing `job.toml` remains available for installations using host CVMFS.
Its bind source must exist on the container host and support shared mount
propagation. A macOS installation with deliberately configured host CVMFS
sharing may also use that configuration once the VM can access the mount.

In-container CVMFS sets `CVMFS_SHARED_CACHE=no`, so every task keeps its own
cache. Running several tasks therefore downloads the same data repeatedly. A
local HTTP proxy avoids that: `entrypoint.sh` uses `CVMFS_HTTP_PROXY` when it
is present in the container environment, and otherwise falls back to WPAD
auto-discovery. `CVMFS_HTTP_PROXY` is a different variable from the
`http_proxy` shown in `containers.conf`; to pin the CVMFS proxy explicitly,
add it to the same `[containers] env` list.

## Validation when releasing

Test the macOS configuration on a BOINC-managed Podman VM without `/cvmfs`:

1. Confirm the release delivers `job-macos.toml` as the task's `job.toml`.
2. Confirm the wrapper's create command includes `--cap-add=SYS_ADMIN` and
   `--device /dev/fuse`, with no `/cvmfs` host bind.
3. Confirm container creation succeeds and the container log reports
   `Using custom CVMFS.` followed by successful repository probes.
4. Confirm a Theory workunit completes and uploads its result.
5. Check suspend/resume and task restart behaviour separately.

The BOINC macOS helper's `zsh:1: parse error near '}'` during formatted status
queries is a separate argument-quoting problem in BOINC's `Run_Podman`. This
configuration does not fix that error or change BOINC's error propagation.
