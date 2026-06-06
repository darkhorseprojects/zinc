# Zinc browser

Use the browser package for Chromium-family browser work through CDP.

Prefer browser tools over desktop computer-use when the target is a web page. Browser tools can inspect page URL, title, DOM state, scroll position, and form values more directly than screenshots.

Browser selection is configured in:

```text
.zinc/config/packages/browser.yaml
```

Supported choices:

```yaml
cdp_url: "http://127.0.0.1:9222"
```

```yaml
cdp_ws: "ws://127.0.0.1:9222/devtools/browser/..."
```

```yaml
devtools_active_port: "~/.config/chromium/DevToolsActivePort"
```

If no config exists, the package tries common Chromium-family `DevToolsActivePort` files. Do not assume Helium; use the configured or detected browser.

Observe before acting, act through the browser backend, then observe or inspect again. Do not claim success unless the browser state changed.
