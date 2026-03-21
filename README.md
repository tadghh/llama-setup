# llama-setup

```sh
# Allow running service w/o user session
loginctl enable-linger

mkdir -p ~/.config/systemd/user/
cp ./*.service ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now local-llm
systemctl --user enable --now docs-mcp-service
```
