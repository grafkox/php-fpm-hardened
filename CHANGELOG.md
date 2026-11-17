# Changelog

Notable changes to the image. Routine rebuilds for base image and Alpine package
updates are not listed.

## 2026-11-17

### Added
- PHP extensions `gd` (JPEG, WebP, PNG, FreeType) and `intl`.
- Runtime packages `libjpeg-turbo`, `libwebp`, `libpng`, `freetype`, `icu-libs` and
  `icu-data-full` (full ICU locale data, required for e.g. `de_DE` formatting).
- Smoke tests for the new extensions: loaded modules, GD format support, GD re-encoding
  under production flags, `de_DE` formatting and no leftover build dependencies.

### Changed
- The daily check also rebuilds when Alpine offers updates for packages in the published
  image, so security fixes for the image libraries are picked up automatically.

The hardening configuration (`zz-hardening.ini`, `zz-pool.conf`), the default user and
read-only compatibility are unchanged.

## 2026-11-13

### Changed
- Image moved to `ghcr.io/grafkox/php-fpm-hardened` after the GitHub account rename.

## 2026-10-25

### Changed
- Alpine packages are upgraded at build time (`apk upgrade`), e.g. `brotli-libs` for
  CVE-2026-111497.

## 2026-10-24

### Added
- Initial release: `php:8.5-fpm-alpine` with `pdo_mysql`, hardened PHP and PHP-FPM
  configuration, smoke tests and automatic rebuilds when the base image changes.
