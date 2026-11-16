# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build  — full Node toolchain, compiles the Vite/React app to /app/dist
# Vite 8 needs Node >= 20.19 / 22.12, so we use Node 22 LTS on Alpine.
# ---------------------------------------------------------------------------
FROM node:22-alpine AS build
WORKDIR /app

# Install deps first so this layer is cached until package*.json change.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# Copy source (.dockerignore keeps node_modules, .git, .env, etc. out)
COPY . .
RUN npm run build

# ---------------------------------------------------------------------------
# Stage 2: runtime — tiny nginx (alpine-slim = no njs/xslt/geoip modules),
# serves only the built static files. No Node, no source, no npm in this image.
# ---------------------------------------------------------------------------
FROM nginx:1.27-alpine-slim AS runtime

ARG APP_VERSION=dev
LABEL org.opencontainers.image.title="kanban-dashboard" \
      org.opencontainers.image.description="Kanban task manager (React + Vite) served by nginx" \
      org.opencontainers.image.version="${APP_VERSION}"

# - patch OS packages
# - create a dedicated non-root user/group (uid/gid 10001, no shell, no home)
# - drop default nginx site config and default html
RUN apk upgrade --no-cache \
 && addgroup -S -g 10001 app \
 && adduser  -S -D -H -u 10001 -G app -s /sbin/nologin app \
 && rm -rf /etc/nginx/conf.d /usr/share/nginx/html/* /docker-entrypoint.d /docker-entrypoint.sh

# Config + built artifacts are owned by root and only *readable* by `app`,
# so a compromised process cannot modify what it serves.
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY --from=build /app/dist /usr/share/nginx/html

# Version marker used by the pipeline to prove the *new* build is live.
RUN printf '{"version":"%s"}\n' "${APP_VERSION}" > /usr/share/nginx/html/version.json

USER app:app

# Only the app port. 3000 (unprivileged, so no root/capabilities needed).
EXPOSE 3000

# busybox wget ships with Alpine, so no extra package (curl) is installed.
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:3000/healthz || exit 1

ENTRYPOINT ["nginx", "-g", "daemon off;"]
