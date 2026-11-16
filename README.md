# Kanban Dashboard — Docker + Jenkins CI/CD on AWS EC2

A React 18 + TypeScript + Vite Kanban board, containerised and shipped by a Jenkins pipeline:

```
git push ──► GitHub webhook ──► Jenkins (EC2 :8080)
                                  │ checkout → docker build/tag → security checks → push
                                  ▼
                           Docker Hub  user/kanban-dashboard:<build>-<sha>
                                  │ docker pull
                                  ▼
               EC2 :80 ─► kanban-proxy (nginx) ─► kanban-blue | kanban-green  (:3000)
                                  │
                         health check + curl validation ─► success, or automatic rollback
```

| Item | Value |
|---|---|
| App type | Static SPA (Vite build → `dist/`), served by nginx |
| App port (container) | **3000** |
| Public port (EC2) | **80** (reverse proxy → live colour) |
| Jenkins | **8080** |
| Env variables | none required (tasks persist in browser `localStorage`, key `kanbanTasksV1`) |
| Health endpoint | `GET /healthz` → `ok` |
| Version endpoint | `GET /version.json` → `{"version":"<build>-<sha>"}` |
| Docker Hub | `https://hub.docker.com/r/<your-user>/kanban-dashboard` |
| App URL | `http://<EC2_PUBLIC_IP>` |

## Repository layout

```
Dockerfile              multi-stage: node:22-alpine build → nginx:1.27-alpine-slim runtime (non-root)
.dockerignore           keeps node_modules, .git, .env, keys, CI files out of the build context
docker/nginx.conf       nginx for non-root + read-only FS, /healthz, SPA fallback, caching
Jenkinsfile             the CI/CD pipeline
deploy/deploy.sh        blue-green deploy / rollback / status, runs on the EC2 host
infra/ec2-setup.sh      installs Docker + Jenkins on Ubuntu (EC2 user-data)
infra/provision-ec2.sh  optional AWS CLI script: security group + EC2 instance
```

---

## 1. Application setup (run locally first)

Requires Node **22.12+** (Vite 8 needs Node ≥ 20.19 / 22.12).

```bash
git clone https://github.com/<your-user>/kanban-dashboard.git
cd kanban-dashboard
npm ci
npm run dev            # dev server  → http://localhost:5173
# or production build:
npm run build && npm run preview   # → http://localhost:4173
curl -s http://localhost:5173 | grep 'id="root"'
```

- **Start command:** `npm run dev` (dev) / `npm run build` → static files in `dist/` (prod)
- **Port:** 5173 dev, 4173 preview, 3000 in Docker
- **Env vars:** none

📸 *Proof:* browser screenshot of the board + the `curl` output.

## 2. Docker containerisation

```bash
docker build --build-arg APP_VERSION=local -t kanban-dashboard:local .
docker run -d --name kanban-test -p 3000:3000 kanban-dashboard:local
curl -s localhost:3000/healthz          # ok
curl -s localhost:3000/version.json     # {"version":"local"}
docker ps                               # STATUS shows (healthy) after ~15 s
```

- **Stage 1 (`build`)** — `node:22-alpine`, `npm ci` (cached layer), `npm run build`.
- **Stage 2 (`runtime`)** — `nginx:1.27-alpine-slim`; only `dist/` is copied in. No Node, npm, sources or `node_modules` in the final image.
- `EXPOSE 3000` only. `HEALTHCHECK` hits `/healthz` with busybox `wget` (no extra packages).

## 3. Docker security

| Control | How |
|---|---|
| Minimal base | `nginx:alpine-slim` (no njs/xslt/geoip modules), `apk upgrade` for patches |
| Non-root | `app` user (uid 10001) created, `USER app:app`; listens on unprivileged port 3000 |
| Immutable content | served files and config owned by root, read-only for `app` |
| No secrets | nothing secret in the Dockerfile; `.dockerignore` excludes `.env*`, `*.pem`, `*.key`, `.npmrc`, `.aws`, `.git` |
| Runtime hardening | `--read-only`, `--tmpfs /tmp`, `--cap-drop ALL`, `--security-opt no-new-privileges`, `--pids-limit` |
| Entrypoint | nginx started directly (stock entrypoint scripts removed) |

```bash
docker inspect -f '{{.Config.User}}' kanban-dashboard:local       # app:app
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.56.2 \
  image --scanners secret kanban-dashboard:local                   # no secrets found
docker history --no-trunc kanban-dashboard:local                   # no tokens in layers
```

The pipeline runs both checks automatically (stage **Image Security Checks**) and fails the build if the image runs as root or a secret is found.

## 4. Container registry & versioning

1. Create a Docker Hub repo `kanban-dashboard` (public is easiest; for private, run `docker login` once on the EC2).
2. Create a Docker Hub **access token** (Account settings → Personal access tokens). Use it as the Jenkins password, not your account password.
3. Each build pushes **`<build-number>-<git-sha>`** (e.g. `14-a1b2c3d`), **`sha-<git-sha>`** and `latest`. Deploys always use the immutable `<build>-<sha>` tag; `latest` is only a convenience.

Verify on a clean machine:
```bash
docker pull <user>/kanban-dashboard:14-a1b2c3d
docker run --rm -p 3000:3000 <user>/kanban-dashboard:14-a1b2c3d
```

📸 *Proof:* Docker Hub “Tags” page showing several versioned tags.

## 5. AWS infrastructure

**Instance:** Ubuntu 24.04, **t3.medium** (2 vCPU / 4 GB) recommended because Jenkins and the Node build share the box. t3.small (2 GB) works with the 2 GB swap the setup script creates, but builds are slower. 30 GB gp3 disk.

**Option A — Console**
1. EC2 → Launch instance → Ubuntu 24.04, t3.medium, your key pair, 30 GB gp3.
2. Security group inbound rules:

| Port | Source | Why |
|---|---|---|
| 22 | My IP | SSH (admin only) |
| 8080 | My IP + GitHub hook ranges (`192.30.252.0/22, 185.199.108.0/22, 140.82.112.0/20, 143.55.64.0/20`, check `https://api.github.com/meta`) | Jenkins UI + webhook |
| 80 | 0.0.0.0/0 | The app |

   Port 3000 is **not** opened: app containers are only reachable through the proxy on the private Docker network.
3. Advanced details → User data → paste `infra/ec2-setup.sh`. (Or SSH in and run `sudo bash ec2-setup.sh`.)

**Option B — CLI:** `KEY_NAME=<your-keypair> AWS_REGION=ap-south-1 bash infra/provision-ec2.sh`

Check:
```bash
ssh -i key.pem ubuntu@<IP> 'docker --version; systemctl is-active jenkins'
curl -I http://<IP>:8080        # Jenkins answers (from your IP)
nc -zv <IP> 3000                # should FAIL — not exposed
```

## 6. Jenkins configuration

1. Open `http://<IP>:8080` and unlock it with `sudo cat /var/lib/jenkins/secrets/initialAdminPassword`, then install **suggested plugins**.
2. Manage Jenkins → Plugins → install: **Docker Pipeline**, **SSH Agent** (only for ssh mode), **GitHub Integration**. Git, Credentials Binding, Pipeline and Timestamper come with the suggested set.
3. Manage Jenkins → Credentials → System → Global → **Add**:
   - `dockerhub-creds`: *Username with password*, using your Docker Hub username and access token
   - `ec2-ssh-key`: *SSH Username with private key*, username `ubuntu` (only if `DEPLOY_MODE=ssh`)
   - for a private GitHub repo: `github-creds` (username + PAT) and select it in the job
4. New Item → **Pipeline** → name `kanban-dashboard`:
   - Build Triggers: ☑ **GitHub hook trigger for GITScm polling**
   - Pipeline: *Pipeline script from SCM* → Git → `https://github.com/<your-user>/kanban-dashboard.git`, branch `*/main`, Script Path `Jenkinsfile`
5. **Build with Parameters** once and set `DOCKERHUB_REPO=<your-user>/kanban-dashboard`. To skip this, change the parameter's default value in the `Jenkinsfile`.

No secret ever appears in the Jenkinsfile. The token goes in through `withCredentials` + `--password-stdin` inside a single-quoted `sh`, so Groovy never expands it and Jenkins masks it as `****` in the console.

## 7. CI/CD pipeline (Jenkinsfile)

| Stage | What it does |
|---|---|
| Checkout | `checkout scm`, computes `IMAGE_TAG = <BUILD_NUMBER>-<short SHA>` |
| Docker Build & Tag | `docker build --pull --build-arg APP_VERSION=$IMAGE_TAG`, tags build/sha/latest |
| Image Security Checks | fails if image user is root; Trivy secret scan (fails on any secret); HIGH/CRITICAL CVE report |
| Registry Login & Push | `docker login --password-stdin` from the credentials store, push, `docker logout` |
| Deploy to EC2 (blue-green) | `deploy/deploy.sh deploy <image> <tag>`, run locally or over SSH |
| Health Check & Validation | `docker ps` / health / limits, then `curl /version.json` must equal the new tag, `/` must return 200 with the app root |
| post | success: build description `LIVE <tag>`. Failure after the switch: **automatic rollback** to the previous image. Failure before the switch: the old container was never touched. |

**Parameters:** `DEPLOY_MODE` (`local` = Jenkins on the same EC2, the default; `ssh` = remote EC2), `EC2_HOST`, `EC2_USER`, `APP_URL`, `SIMULATE_FAILURE`.

## 8. GitHub webhook

> The assignment repo belongs to someone else, so **fork it** (or push it to your own GitHub). You need admin rights on the repo to add a webhook.

1. GitHub repo → Settings → Webhooks → **Add webhook**
   - Payload URL: `http://<EC2_PUBLIC_IP>:8080/github-webhook/` (trailing slash required)
   - Content type: `application/json`, event: *Just the push event*
2. GitHub shows a green ✓ on the delivery once the ping works.
3. Test it:
   ```bash
   # e.g. change the page title
   sed -i 's#<title>.*</title>#<title>Kanban v2</title>#' index.html
   git commit -am "test: webhook deploy" && git push
   ```
   Jenkins starts a build on its own (“Started by GitHub push by …”), and `curl http://<IP>/version.json` then shows the new tag.

## 9. Health check & validation

Deployment counts as successful **only** when all of these pass:
1. the container is running,
2. Docker `HEALTHCHECK` reports `healthy`,
3. `version.json` on the new container equals the expected tag and `/` serves the app,
4. the same checks pass **through the public proxy**,
5. Jenkins' own `curl` of `APP_URL` passes.

```bash
docker ps --filter name=kanban-
docker inspect -f '{{.State.Health.Status}}' kanban-blue   # or kanban-green
curl -s http://<IP>/version.json
curl -sI http://<IP>/ | grep X-Served-By                  # which colour served the request
bash deploy/deploy.sh status                               # all of the above in one go
```

## 10. Logging & monitoring

- **Jenkins:** job page → *Build History* (descriptions read `LIVE …`, `FAILED … - rolled back`) → *Console Output*. Stage View / Blue Ocean show pass/fail per stage.
- **Producing a failed run on purpose:**
  - *Rollback path:* Build with Parameters → ☑ `SIMULATE_FAILURE`. Validation fails, the console shows `rolling back to previous image`, and the previous version is live again.
  - *Pre-switch failure:* push a commit that breaks the TypeScript build. The pipeline stops at **Docker Build** and production is untouched.
- **On the host:**
  ```bash
  docker logs --tail 50 kanban-blue
  docker logs kanban-proxy
  docker inspect -f '{{json .State.Health}}' kanban-blue | jq
  cat /opt/kanban/history.log      # every deploy/rollback with timestamp and image
  ```
  When a new container fails, `deploy.sh` prints its health-check log and its last 50 log lines into the Jenkins console, so the console alone shows why that deploy failed.
- Container logs rotate at 10 MB × 3 files (`/etc/docker/daemon.json` and `--log-opt`).

## 11. Resource limits

| Container | `--memory` | `--memory-reservation` | `--cpus` | `--pids-limit` |
|---|---|---|---|---|
| kanban-blue/green | 128m (swap disabled) | 64m | 0.25 | 100 |
| kanban-proxy | 64m | — | 0.25 | 100 |

**Reasoning:**
- The container is nginx serving ~1 MB of static files. Idle use is about 5–10 MB of RAM and near-zero CPU, so 128 MB leaves more than 10× headroom for connection buffers and gzip. 0.25 vCPU still serves thousands of static requests per second.
- During blue-green there are briefly **two** app containers: 2 × 128 + 64 = **320 MB worst case**.
- A t3.medium has 4 GB. Jenkins gets `-Xmx768m` (about 1 GB with JVM overhead). The OS and Docker take about 0.5 GB, and `docker build` (npm + Vite) peaks around 1–1.5 GB. The app tier can't exceed ~0.3 GB, so a runaway container can never starve Jenkins or the host.
- `--memory-swap` equals `--memory`, so the container is OOM-killed and restarted (`--restart unless-stopped`) instead of thrashing swap.
- Check it: `docker stats --no-stream` shows `MEM USAGE / LIMIT … / 128MiB`.

## 12. Zero-downtime deployment (blue-green)

`deploy/deploy.sh`:
1. pulls the new image and starts it as the **idle colour** next to the live one, on the private network `kanban-net` with no published port,
2. waits for Docker health = `healthy`, then smoke-tests `/version.json` and `/` inside the container,
3. rewrites the proxy upstream and runs `nginx -s reload`. Reload is graceful: old workers finish in-flight requests while new workers send new requests to the new colour,
4. checks the new version **through the proxy**, and switches back right away if that fails,
5. waits a few seconds, then stops and removes the old colour.

So traffic always goes to a container that has already passed its health checks, and the port-80 listener never restarts. Test it during a deploy:
```bash
while true; do curl -s -o /dev/null -w "%{http_code} " http://<IP>/; sleep 0.2; done   # only 200s
```

**Why blue-green and not rolling:** with one host and a single replica, a rolling update has nothing to roll across. Blue-green gives an instant switch and an instant rollback (the previous image is recorded in `/opt/kanban/previous_image`). It costs one extra container for a few seconds.

**Manual rollback:** `bash deploy/deploy.sh rollback`

---

## Evidence checklist

| # | Evidence | Command / where |
|---|---|---|
| 1 | App running locally | browser + `curl localhost:5173` |
| 2 | `docker build` success, container healthy | build output, `docker ps` |
| 3 | Non-root user | `docker inspect -f '{{.Config.User}}' <image>` |
| 4 | No secrets | Trivy secret scan output (Jenkins console) |
| 5 | Versioned tags | Docker Hub Tags page |
| 6 | Clean pull works | `docker pull …:<tag>` on EC2 |
| 7 | EC2 + Security Group | EC2 console: instance + inbound rules |
| 8 | Jenkins UI + credentials (masked) | Manage Jenkins → Credentials |
| 9 | Full pipeline run, all stages green | Stage View |
| 10 | Webhook-triggered build | “Started by GitHub push”, GitHub webhook ✓ |
| 11 | Health / validation | `deploy.sh status` output |
| 12 | Failed build + rollback | `SIMULATE_FAILURE` run console |
| 13 | Limits applied | `docker stats --no-stream`, `docker inspect` |
| 14 | Zero downtime | curl loop during a deploy (only 200s) |
| 15 | App URL | `http://<EC2_PUBLIC_IP>` |

## Cleanup (avoid AWS charges)

```bash
aws ec2 terminate-instances --instance-ids <id>
aws ec2 delete-security-group --group-id <sg-id>   # after the instance has terminated
```
