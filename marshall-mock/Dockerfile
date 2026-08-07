# Node version pinned like every other image in this PoC (ROADMAP constraint 1).
FROM node:22.22-alpine

WORKDIR /app

# Dependencies first so this layer is cached unless the manifests change.
# `npm ci` (not `install`) so the committed lockfile decides the tree - the same
# "the repo is the desired state" discipline the realm config follows.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

COPY src ./src

# node:alpine ships an unprivileged `node` user; use it rather than root.
USER node

ENV PORT=8090
EXPOSE 8090

CMD ["node", "src/server.js"]
