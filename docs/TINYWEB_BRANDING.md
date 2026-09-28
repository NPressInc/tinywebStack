# TinyWeb branding (family layer)

William’s principle: **families should not see YunoHost branding**. Parents use **TinyWeb** — the family dashboard at `/family/` — as their only day-to-day UI.

## Family dashboard

- Styled with vendored assets from [tinyweb.win](https://tinyweb.win) (logo, colors, favicon).
- Plain language, mobile-friendly layout.
- Installed with `install-family-dashboard.sh` (static files ship in the Python package).

## SSO / login portal (YunoHost 12)

YunoHost 12 exposes supported portal customization per **top-level domain**:

- `feature.portal.portal_title` → **TinyWeb**
- `feature.portal.portal_logo` → vendored SVG
- `feature.portal.portal_theme` → `light`
- `feature.portal.custom_css` → `brand/portal/tinyweb-portal.css`
- `feature.portal.portal_user_intro` / `portal_public_intro` → friendly HTML (link to `/family/`)
- `feature.portal.enable_public_apps_page` / `show_other_domains_apps` → off (less “app store” noise)

Applied idempotently by:

```bash
bash /opt/tinywebstack/vm/install-tinyweb-portal-branding.sh YOUR.MAIN.DOMAIN
```

This uses `yunohost domain config set` only (no core file patches).

### After login

Parents reach the family UI via the **Family home** portal tile (TinyWeb logo) and the nginx redirect from `/` to `/family/`. The **user intro** includes a clear **Open your family home** link to `/family/`.

## Orchestration

`family-init.sh` runs portal branding after the dashboard install.
