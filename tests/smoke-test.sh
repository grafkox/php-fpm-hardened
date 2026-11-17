#!/usr/bin/env bash
# Smoke tests for the hardened PHP-FPM image.
# Usage: tests/smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
failures=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

run_php() { docker run --rm "$@"; }

# Compares an ini value (as returned by ini_get) against the expectation.
check_ini() {
  local key="$1" expected="$2" actual
  actual="$(run_php "$IMAGE" php -r "echo ini_get('$key');")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$key = '$actual'"
  else
    fail "$key: expected '$expected', got '$actual'"
  fi
}

# Extensions
modules="$(run_php "$IMAGE" php -m)"
for ext in pdo_mysql gd intl; do
  if grep -qx "$ext" <<<"$modules"; then
    pass "$ext loaded"
  else
    fail "$ext not loaded"
  fi
done

# GD image formats
actual="$(run_php "$IMAGE" php -r 'var_dump(gd_info()["JPEG Support"], gd_info()["WebP Support"]);')"
if [[ "$actual" == $'bool(true)\nbool(true)' ]]; then
  pass "gd JPEG and WebP support"
else
  fail "gd JPEG/WebP support: expected two bool(true), got '$actual'"
fi
actual="$(run_php "$IMAGE" php -r 'var_dump(gd_info()["PNG Support"], gd_info()["FreeType Support"]);')"
if [[ "$actual" == $'bool(true)\nbool(true)' ]]; then
  pass "gd PNG and FreeType support"
else
  fail "gd PNG/FreeType support: expected two bool(true), got '$actual'"
fi

# intl with German locale data (icu-libs alone only ships en_US/en_GB)
actual="$(run_php "$IMAGE" php -r 'echo (new NumberFormatter("de_DE", NumberFormatter::DECIMAL))->format(1234.5), " ", (new IntlDateFormatter("de_DE", IntlDateFormatter::NONE, IntlDateFormatter::NONE, "UTC", null, "MMMM"))->format(0);')"
if [[ "$actual" == "1.234,5 Januar" ]]; then
  pass "intl formats de_DE ($actual)"
else
  fail "intl de_DE formatting: expected '1.234,5 Januar', got '$actual'"
fi

# Only runtime libraries may remain; build dependencies must be gone
packages="$(run_php "$IMAGE" apk info 2>/dev/null)"
leftovers="$(grep -xE '.*-dev|gcc|g\+\+|make|autoconf|re2c|pkgconf|\.build-deps|\.phpize-deps.*' <<<"$packages" || true)"
if [[ -z "$leftovers" ]]; then
  pass "no build dependencies left in the image"
else
  fail "build dependencies left in the image: $(tr '\n' ' ' <<<"$leftovers")"
fi
for pkg in libpng libjpeg-turbo libwebp freetype icu-libs icu-data-full; do
  if grep -qx "$pkg" <<<"$packages"; then
    pass "runtime package $pkg installed"
  else
    fail "runtime package $pkg missing"
  fi
done

# Hardening values (ini_get returns "" for Off and "1" for On)
check_ini expose_php ""
check_ini allow_url_fopen ""
check_ini allow_url_include ""
check_ini file_uploads ""
check_ini session.upload_progress.enabled ""
check_ini session.cookie_secure "1"
check_ini session.cookie_httponly "1"
check_ini session.use_strict_mode "1"

disabled="$(run_php "$IMAGE" php -r "echo ini_get('disable_functions');")"
if [[ ",$disabled," == *",system,"* ]]; then
  pass "disable_functions contains system ($disabled)"
else
  fail "disable_functions does not contain system: '$disabled'"
fi

# open_basedir: default without env, overridable via PHP_OPEN_BASEDIR
check_ini open_basedir "/var/www/html:/tmp"
actual="$(run_php -e PHP_OPEN_BASEDIR=/srv/app:/tmp "$IMAGE" php -r "echo ini_get('open_basedir');")"
if [[ "$actual" == "/srv/app:/tmp" ]]; then
  pass "open_basedir overridable via PHP_OPEN_BASEDIR ($actual)"
else
  fail "open_basedir override: expected '/srv/app:/tmp', got '$actual'"
fi

# FPM configuration test
if out="$(run_php "$IMAGE" php-fpm -t 2>&1)"; then
  pass "php-fpm -t: $(echo "$out" | tail -n1)"
else
  fail "php-fpm -t failed: $out"
fi

# Start like in production and wait for FPM to become ready
cid="$(docker run -d \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --user 99:100 \
  -e PHP_OPEN_BASEDIR=/var/www/html:/tmp \
  "$IMAGE")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

ready=0
for _ in $(seq 1 30); do
  if docker logs "$cid" 2>&1 | grep -q 'ready to handle connections'; then
    ready=1
    break
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$cid")" != "true" ]]; then
    break
  fi
  sleep 1
done
if [[ "$ready" == 1 ]]; then
  pass "container started with production flags and is ready to handle connections"
else
  fail "container did not become ready"
  docker logs "$cid" >&2 || true
fi

# Re-encode images with GD under production flags (read-only root, writes only to /tmp)
# shellcheck disable=SC2016  # PHP code, $ must not be expanded by the shell
reencode='
$src = imagecreatetruecolor(32, 16);
imagefilledrectangle($src, 0, 0, 31, 15, imagecolorallocate($src, 200, 30, 30));
$ok = imagejpeg($src, "/tmp/t.jpg", 85) && imagewebp($src, "/tmp/t.webp", 80) && imagepng($src, "/tmp/t.png");
foreach (["/tmp/t.jpg" => IMAGETYPE_JPEG, "/tmp/t.webp" => IMAGETYPE_WEBP, "/tmp/t.png" => IMAGETYPE_PNG] as $f => $type) {
    $info = getimagesize($f);
    $ok = $ok && $info[0] === 32 && $info[2] === $type;
}
$jpeg = imagecreatefromjpeg("/tmp/t.jpg");
$ok = $ok && $jpeg !== false && imagejpeg($jpeg, "/tmp/t2.jpg");
echo $ok ? "ok" : "failed";
'
actual="$(docker run --rm \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  --user 99:100 \
  -e PHP_OPEN_BASEDIR=/var/www/html:/tmp \
  "$IMAGE" php -r "$reencode" 2>&1)"
if [[ "$actual" == "ok" ]]; then
  pass "gd re-encodes JPEG/WebP/PNG with production flags"
else
  fail "gd re-encode with production flags: $actual"
fi

if (( failures > 0 )); then
  echo "$failures smoke test(s) failed" >&2
  exit 1
fi
echo "All smoke tests passed"
