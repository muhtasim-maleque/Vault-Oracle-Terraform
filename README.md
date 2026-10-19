# Vault Oracle Database Secrets Engine Demo (Terraform deploy workflow)

Quick setup for testing the Oracle database plugin for Vault on an M series Mac with Docker using Terraform.

## Prerequisites

- M series Mac with Docker installed
- [Colima](https://github.com/abiosoft/colima#installation) installed (`brew install colima`)
- Colima dependencies: `brew install lima-additional-guestagents qemu`
- Terraform installed (`brew install terraform`)
- `jq` installed (`brew install jq`)
- Vault CLI installed (`brew install vault`)
- Vault Enterprise license exported as `VAULT_LICENSE`

## Project Structure

```
.
├── main.tf                  # Terraform configuration
├── config/
│   └── config.hcl           # Vault server configuration
├── scripts/
│   ├── create_users.sql     # Oracle user creation SQL
│   └── verify_users.sql     # Oracle user verification SQL
├── client/                  # Oracle Instant Client (downloaded by Terraform)
├── plugin/                  # Vault Oracle plugin binary (downloaded by Terraform)
├── data/                    # Vault Raft storage + init.json (host-mounted volume)
├── .vault-token             # Root token (generated during init, gitignored)
├── .vault-unseal-key        # Unseal key (generated during init, gitignored)
└── .gitignore
└── Dockerfile               # custom Docker image file

```

## Setup

### 1. Start Colima

```bash
colima start --arch x86_64 --memory 4
export DOCKER_HOST="unix://${HOME}/.colima/default/docker.sock"
```

### 2. Export Vault License

```bash
export TF_VAR_vault_license="$VAULT_LICENSE"
```

### 3. Initialize Terraform

```bash
terraform init
```

### 4. Create Placeholder Token

The Vault provider requires a token file at plan time. Create a placeholder that will be overwritten during Stage 1:

```bash
echo "placeholder" > .vault-token
```

### 5. Stage 1 — Deploy Containers + Bootstrap

This spins up the Vault and Oracle XE containers, initializes and unseals Vault, and creates the Oracle database users:

```bash
terraform apply \
  -target=terraform_data.vault_init \
  -target=terraform_data.oracle_users
```

After this step:
- Vault is initialized, unsealed, and running
- `init.json` is saved to `data/init.json` (persisted on the host)
- Root token is written to `.vault-token`
- Unseal key is written to `.vault-unseal-key`
- Oracle `vault` and `staticvault` users are created in XEPDB1

### 6. Stage 2 — Configure Vault

This registers the Oracle database plugin, enables the database secrets engine, and creates both dynamic and static roles:

```bash
terraform apply
```

If the Vault container was recreated between stages, this step will automatically unseal Vault before proceeding.

## Verify

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(cat .vault-token)

# Test dynamic credentials
vault read database/creds/my-role

# Test static credentials
vault read database/static-creds/static-role
```

## Teardown

The Vault provider requires a running Vault to destroy its resources. Since we're tearing everything down, remove those resources from state first, then destroy the rest:

```bash
terraform state rm vault_mount.database
terraform state rm vault_generic_endpoint.oracle_connection
terraform state rm vault_database_secret_backend_role.dynamic_role
terraform state rm vault_database_secret_backend_static_role.static_role
terraform destroy -auto-approve
docker rm -f vault-test oracle-xe-test
colima stop
```

## Custom Vault Image
This demo uses a custom Docker image based on Ubuntu 22.04 with Vault Enterprise and the libaio1 library required by the Oracle Instant Client. The included Dockerfile builds for linux/amd64 to run under Colima's x86_64 emulation.

`docker_image.vault` in `main.tf` builds this image locally via a `build` block — `terraform apply` builds it directly against your Docker daemon. No `docker push` or Docker Hub account is required; the `name` is just a local tag.

```hcl
resource "docker_image" "vault" {
  name = "<your-dockerhub-user>/vault-linux-amd64-<VERSION>-ent:latest"

  build {
    context  = path.module
    platform = "linux/amd64"
  }

  keep_locally = true  # avoid re-running the (slow, emulated) build on every destroy/apply cycle
}
```

To build with a different Vault version:

1. Edit the version in the `Dockerfile`:
   ```bash
   RUN wget https://releases.hashicorp.com/vault/<VERSION>+ent/vault_<VERSION>+ent_linux_amd64.zip
   ```
2. Update the `name` tag in `main.tf`'s `docker_image "vault"` resource to match — this is just a label for the local build, it doesn't need to exist on any registry.
3. Also bump the plugin version in `terraform_data.vault_plugin` (download URL) and `terraform_data.vault_plugin_register` (`-version` flag) to a `vault-plugin-database-oracle` release compatible with the new Vault major version — see the enterprise plugin gotchas below.
4. Re-run `terraform apply` (`terraform apply -replace=docker_image.vault` if Terraform doesn't pick up the Dockerfile change on its own).


## Notes

- **Two-stage apply**: Required because Vault must be initialized and unsealed before the Terraform Vault provider can configure it.
- **Oracle startup**: Oracle XE can take a few minutes to fully initialize. The provisioner includes a retry loop.
- **Binary downloads**: The Oracle Instant Client and Vault Oracle plugin are downloaded automatically on the first run and cached in `client/` and `plugin/`.
- **Enterprise plugin artifact layout (Vault 2.x+)**: the plugin catalog's signature verification requires the binary to live in a `plugin_directory` subfolder named `<name>_<version>_<os>_<arch>` (e.g. `plugin/vault-plugin-database-oracle_0.13.0+ent_linux_amd64/vault-plugin-database-oracle`), not flat in `plugin/`. If you bump the plugin version, the download step must extract into the matching new subfolder — a flat binary will fail registration with `extracted artifact directory not found`.
- **Enterprise plugin registration (Vault 2.x+)**: `vault plugin register` rejects `-sha256` when `-version` is also given for an enterprise (`+ent`) plugin — enterprise plugins are signed and self-verifying. Passing both fails with `enterprise plugin should only specify version and not sha256`.
- **Container recreation**: The Vault container uses `lifecycle { ignore_changes = [capabilities] }` to prevent unnecessary recreation due to Docker capability name normalization. Init credentials are saved to the host-mounted `data/` volume so they survive container recreation.
- **Colima Docker socket**: You must export `DOCKER_HOST` pointing to Colima's socket, or add it to your `~/.zshrc` for persistence.
