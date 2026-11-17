# The base image is a build argument so CI can pin it by digest
# (e.g. php:8.5-fpm-alpine@sha256:...). The default keeps local builds simple.
ARG PHP_BASE=php:8.5-fpm-alpine
FROM ${PHP_BASE}

# - apk upgrade: pull in Alpine security fixes that are already released but not
#   yet part of the official base image (e.g. brotli-libs for CVE-2026-111497).
# - Runtime libraries for gd (JPEG, WebP, PNG, FreeType) and intl stay in the image.
#   icu-data-full provides all ICU locales; icu-libs alone ships only en_US/en_GB,
#   so de_DE formatting would silently fall back to English rules.
# - Headers and the compiler toolchain are installed as a virtual package and
#   removed again in the same layer.
RUN apk upgrade --no-cache \
 && apk add --no-cache \
      libpng libjpeg-turbo libwebp freetype \
      icu-libs icu-data-full \
 && apk add --no-cache --virtual .build-deps \
      $PHPIZE_DEPS \
      libpng-dev libjpeg-turbo-dev libwebp-dev freetype-dev \
      icu-dev \
 && docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql gd intl \
 && apk del --no-network .build-deps \
 && mv /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

COPY conf/zz-hardening.ini /usr/local/etc/php/conf.d/zz-hardening.ini
COPY conf/zz-pool.conf /usr/local/etc/php-fpm.d/zz-pool.conf

# Safe default; deployments may override it (e.g. user: "99:100").
USER www-data
