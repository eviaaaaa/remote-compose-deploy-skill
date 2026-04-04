# Session Example

This is a general example demonstrating a standard deployment flow.

## Example Configuration

- **Deployment mode**: `artifact`
- **Remote host**: `192.168.1.100`
- **Remote user**: `deployer`
- **Remote compose dir**: `/opt/app`
- **Remote artifact path**: `/opt/app/my-service/target/app.jar`
- **Local artifact path**: `my-service/target/app.jar`
- **Local build command**: `mvn -pl my-service package`
- **Remote compose service target**: `my-service`
- **Saved config target scope**: `services`

## Reference Scenarios

### Artifact Upload vs. Code Sync
If your updates only involve uploading a compiled binary, use `artifact` mode.
If your deployment involves pulling source code changes directly on the remote server, switch `deployment.mode` to `repo-sync`, set `repoSync.workdir` to the remote repository root, and specify a pull command like `git pull --ff-only`.

### Compose Commands
When executing the remote compose command, sometimes `docker` isn't available in the non-login shell's PATH, or the environment uses `podman compose` instead of `docker compose`. The deploy script will try common candidates automatically. Ensure the target compose action (`rebuild` vs `restart`) fits the deployment need: if uploading a fresh artifact to an existing image map, `rebuild` might be required to recreate the container.

### Relative Path Handling
The attribute `artifact.localPath` can be configured relative to `build.workdir`. For instance, if `build.workdir` is `C:/repos/my-project`, setting `artifact.localPath` to `my-service/target/app.jar` correctly maps to `C:/repos/my-project/my-service/target/app.jar`.
