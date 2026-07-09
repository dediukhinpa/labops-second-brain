# systemd unit templates

Four service unit templates that `scripts/install.sh` renders and installs to `/etc/systemd/system/`:

| Template | Installed name | Purpose |
|---|---|---|
| `memory-mcp.service.template` | `second_brain-memory-mcp.service` | Write-side MCP (port 5001) |
| `memory_router-mcp.service.template` | `second_brain-memory_router-mcp.service` | Read-side MCP (port 5002) |
| `agent_router-mcp.service.template` | `second_brain-agent_router-mcp.service` | Inter-agent event bus (port 5000) |
| `ingest-worker.service.template` | `second_brain-ingest-worker.service` | Vault file indexer |

## Placeholders

Templates use Jinja-style `{{NAME}}` placeholders that `install.sh` replaces via `sed`:

| Placeholder | Default | Description |
|---|---|---|
| `{{INSTALL_DIR}}` | `/opt/second_brain` | Where the repo + venv live |
| `{{SERVICE_USER}}` | `second_brain` | System user that runs the services |
| `{{ETC_DIR}}` | `/etc/second_brain` | Where `secrets.env` lives (mode 0600, owned by SERVICE_USER) |
| `{{LOG_DIR}}` | `/var/log/second_brain` | Log directory (read-writable by service) |
| `{{STATE_DIR}}` | `/var/lib/second_brain` | Mutable state (read-writable by service) |

All defaults come from `.env`. Override any of them before running `install.sh`.

## What `install.sh` does

```bash
for tpl in systemd/*.service.template; do
  out_name="$(basename "$tpl" .service.template)"
  rendered="/etc/systemd/system/second_brain-${out_name}.service"
  sed \
    -e "s|{{INSTALL_DIR}}|${INSTALL_DIR}|g" \
    -e "s|{{SERVICE_USER}}|${SERVICE_USER}|g" \
    -e "s|{{ETC_DIR}}|${ETC_DIR}|g" \
    -e "s|{{LOG_DIR}}|${LOG_DIR}|g" \
    -e "s|{{STATE_DIR}}|${STATE_DIR}|g" \
    "$tpl" | sudo tee "$rendered" >/dev/null
done
sudo systemctl daemon-reload
sudo systemctl enable --now second_brain-memory-mcp second_brain-memory_router-mcp second_brain-agent_router-mcp second_brain-ingest-worker
```

## Hardening notes

All four units run with a tight sandbox:

- `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=yes` — minimum filesystem reach
- `ReadWritePaths` allow-list only the vault + log + state dirs
- `RestrictAddressFamilies` blocks raw sockets
- `MemoryDenyWriteExecute` for MCP services (workers may JIT, so it's relaxed there)
- `SystemCallFilter=@system-service` deny dangerous syscalls
- `MemoryMax` caps memory: 256M for MCP services, 1G for the ingest worker (embeddings are heavier)

If a service refuses to start with a syscall error, check `journalctl -u second_brain-<name>-mcp` for the offending syscall and consider whether to relax the filter or fix the upstream call.

## Verification

After install:

```bash
systemctl status second_brain-memory-mcp second_brain-memory_router-mcp second_brain-agent_router-mcp second_brain-ingest-worker
journalctl -u second_brain-memory-mcp -n 50 --no-pager
ss -tlnp | grep -E '500[0-3]'
```

You should see three sockets listening on 5000 / 5001 / 5002, all owned by `python` processes under the `second_brain` user.

## Troubleshooting

- **Service flaps on start:** check `EnvironmentFile=` path exists and is readable by the service user.
- **Permission denied on vault:** `chown -R second_brain:second_brain {{INSTALL_DIR}}/vault` and confirm `ReadWritePaths=` lists it.
- **Port in use:** another process is bound; `ss -tlnp | grep <port>` to find it.
- **Memory killed:** raise `MemoryMax=` if your dataset grew.
