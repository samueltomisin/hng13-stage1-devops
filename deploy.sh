#!/usr/bin/env bash
#
# deploy.sh - Automated deployment of a Dockerized app to a remote server
# Usage: ./deploy.sh [--cleanup]
#
set -o errexit
set -o nounset
set -o pipefail

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="deploy_${TIMESTAMP}.log"
trap 'rc=$?; echo "$(date +%Y-%m-%d\ %H:%M:%S) - Exited with $rc" | tee -a "$LOGFILE"; exit $rc' EXIT

# Defaults
CLEANUP=false

# parse simple flags
for arg in "$@"; do
  case "$arg" in
    --cleanup) CLEANUP=true ;;
    *) ;;
  esac
done

# logging
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"; }

err_exit() { log "ERROR: $1"; exit "${2:-1}"; }

# ---------- User Input ----------
read -r -p "Git repository URL (https://... .git): " GIT_URL
[ -n "$GIT_URL" ] || err_exit "Git URL required" 10

read -r -p "Personal Access Token (PAT) (press Enter for public repo): " -s GIT_PAT
echo
read -r -p "Branch name (default: main): " BRANCH
BRANCH=${BRANCH:-main}

read -r -p "Remote SSH username: " RUSER
[ -n "$RUSER" ] || err_exit "SSH username required" 10

read -r -p "Remote server IP address: " RHOST
[ -n "$RHOST" ] || err_exit "Remote host required" 10

read -r -p "SSH private key path (absolute or ~ path): " SSH_KEY
SSH_KEY="${SSH_KEY/#\~/$HOME}"
[ -f "$SSH_KEY" ] || err_exit "SSH key not found at $SSH_KEY" 10

read -r -p "Application internal port (container port, e.g. 5000): " APP_PORT
[ -n "$APP_PORT" ] || err_exit "Application port required" 10

PROJECT_NAME="$(basename -s .git "$GIT_URL")"
REMOTE_DIR="~/deploy_${PROJECT_NAME}"
WORKDIR="/tmp/${PROJECT_NAME}_${TIMESTAMP}"

SANITIZED_NAME="$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_.-]/-/g')"
log "Project name: $PROJECT_NAME  Sanitized name: $SANITIZED_NAME"

log "Start deploy: project=$PROJECT_NAME host=$RUSER@$RHOST branch=$BRANCH"

mkdir -p "$WORKDIR"

# If PAT provided, embed into clone url
if [ -n "$GIT_PAT" ]; then
  # For safety we avoid exposing the PAT in logs but use it for clone
  AUTH_GIT_URL="$(echo "$GIT_URL" | sed -E "s#https?://(.*)#https://$GIT_PAT@\1#")"
else
  AUTH_GIT_URL="$GIT_URL"
fi

log "Cloning repository..."
git clone --branch "$BRANCH" --single-branch "$AUTH_GIT_URL" "$WORKDIR" >>"$LOGFILE" 2>&1 || {
  # try pull if exists
  if [ -d "$WORKDIR/.git" ]; then
    git -C "$WORKDIR" fetch --all >>"$LOGFILE" 2>&1 || err_exit "Git fetch failed" 20
    git -C "$WORKDIR" checkout "$BRANCH" >>"$LOGFILE" 2>&1 || err_exit "Git checkout failed" 20
    git -C "$WORKDIR" pull origin "$BRANCH" >>"$LOGFILE" 2>&1 || err_exit "Git pull failed" 20
  else
    err_exit "Git clone failed" 20
  fi
}

# Detect Dockerfile or docker-compose
if [ -f "$WORKDIR/Dockerfile" ]; then
  DEPLOY_TYPE="dockerfile"
elif [ -f "$WORKDIR/docker-compose.yml" ] || [ -f "$WORKDIR/docker-compose.yaml" ]; then
  DEPLOY_TYPE="compose"
else
  err_exit "No Dockerfile or docker-compose.yml found in repo" 21
fi
log "Deploy type: $DEPLOY_TYPE"

SSH_OPTS="-o StrictHostKeyChecking=accept-new -i $SSH_KEY -o ConnectTimeout=10"

log "Testing SSH connectivity..."
ssh $SSH_OPTS "$RUSER@$RHOST" "echo remote_ok" >>"$LOGFILE" 2>&1 || err_exit "SSH connectivity failed" 30
log "SSH OK"

if [ "$CLEANUP" = true ]; then
  log "Cleanup: stopping containers and removing files on remote"
  ssh $SSH_OPTS "$RUSER@$RHOST" "set -e; docker ps -aq | xargs -r docker rm -f || true; docker images -aq | xargs -r docker rmi -f || true; sudo rm -rf $REMOTE_DIR || true; sudo rm -f /etc/nginx/sites-enabled/${PROJECT_NAME}.conf /etc/nginx/sites-available/${PROJECT_NAME}.conf || true; sudo systemctl reload nginx || true" >>"$LOGFILE" 2>&1 || err_exit "Cleanup failed" 40
  log "Cleanup complete"
  exit 0
fi

# Prepare remote environment: apt or yum, install docker, docker compose plugin, nginx
log "Preparing remote environment (install docker & nginx if needed)..."
REMOTE_PREP=$(cat <<'REMOTE'
set -e
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sudo sh
  fi
  if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
    sudo apt-get install -y docker-compose-plugin || true
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    sudo apt-get install -y nginx
  fi
elif command -v yum >/dev/null 2>&1; then
  sudo yum install -y yum-utils
  if ! command -v docker >/dev/null 2>&1; then
    sudo yum install -y docker
    sudo systemctl enable --now docker
  fi
  if ! command -v nginx >/dev/null 2>&1; then
    sudo yum install -y nginx
  fi
fi

# add user to docker group if not root
if [ "$(id -u)" -ne 0 ]; then
  if ! groups | grep -q docker; then
    sudo usermod -aG docker "$(whoami)" || true
  fi
fi

sudo systemctl enable --now docker || true
sudo systemctl enable --now nginx || true
docker --version || true
docker compose version || true
nginx -v || true
REMOTE
)

ssh $SSH_OPTS "$RUSER@$RHOST" "$REMOTE_PREP" >>"$LOGFILE" 2>&1 || err_exit "Remote prep failed" 40
log "Remote prepared"

log "Syncing project to remote ($REMOTE_DIR)..."
rsync -az --delete -e "ssh $SSH_OPTS" "$WORKDIR"/ "$RUSER@$RHOST:$REMOTE_DIR/" >>"$LOGFILE" 2>&1 || err_exit "File sync failed" 31

# Remote deploy commands
if [ "$DEPLOY_TYPE" = "compose" ]; then
  REMOTE_DEPLOY=$(cat <<DEP
set -e
cd $REMOTE_DIR
if [ -f docker-compose.yml ] || [ -f docker-compose.yaml ]; then
  docker compose down --remove-orphans || true
  docker compose up -d --build
fi
DEP
)
else
  REMOTE_DEPLOY=$(cat <<DEP
set -e
cd $REMOTE_DIR
IMAGE_NAME="${SANITIZED_NAME}:latest"
docker build -t "\$IMAGE_NAME" .
if sudo docker ps -a --format '{{.Names}}' | grep -q "${SANITIZED_NAME}"; then
  sudo docker rm -f "${SANITIZED_NAME}" || true
fi
sudo docker run -d --name "${SANITIZED_NAME}" -p ${APP_PORT}:${APP_PORT} "\$IMAGE_NAME"
DEP
)
fi

log "Running remote deploy..."
ssh $SSH_OPTS "$RUSER@$RHOST" "$REMOTE_DEPLOY" >>"$LOGFILE" 2>&1 || err_exit "Remote deploy failed" 50

# Nginx config on remote
NGINX_CONF="/etc/nginx/sites-available/${SANITIZED_NAME}.conf"
REMOTE_NGINX=$(cat <<NG
set -e
sudo bash -c 'cat > ${NGINX_CONF}' <<'EOC'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOC
sudo ln -sf ${NGINX_CONF} /etc/nginx/sites-enabled/${SANITIZED_NAME}.conf
sudo nginx -t
sudo systemctl reload nginx
NG
)

log "Configuring Nginx on remote..."
ssh $SSH_OPTS "$RUSER@$RHOST" "$REMOTE_NGINX" >>"$LOGFILE" 2>&1 || err_exit "Nginx configuration failed" 51

# Validation
log "Validating deployment..."
ssh $SSH_OPTS "$RUSER@$RHOST" "docker ps --filter name=${SANITIZED_NAME} --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'" >>"$LOGFILE" 2>&1 || true

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${RHOST}" || echo "000")
log "HTTP code from public endpoint: ${HTTP_CODE}"

if [ "${HTTP_CODE}" != "000" ] && [ "${HTTP_CODE}" -ge 200 ] && [ "${HTTP_CODE}" -lt 500 ]; then
  log "Deployment looks successful."
else
  err_exit "Validation failed (http code ${HTTP_CODE})" 60
fi

log "Deployment finished. Logfile: $LOGFILE"
exit 0
