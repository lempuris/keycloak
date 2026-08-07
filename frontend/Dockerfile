# Multi-stage so no local Node is needed - `docker compose up` is enough.
FROM node:22-alpine AS build
WORKDIR /build

# Dependencies first: cached unless package.json changes.
COPY package.json ./
RUN npm install --no-audit --no-fund

COPY angular.json tsconfig.json tsconfig.app.json ./
COPY public ./public
COPY src ./src
RUN npm run build

FROM nginx:1.29-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /build/dist/portal/browser /usr/share/nginx/html
COPY docker-entrypoint.sh /docker-entrypoint.d/99-poc-config.sh
RUN chmod +x /docker-entrypoint.d/99-poc-config.sh

EXPOSE 4200
