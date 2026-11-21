# ZKBLANK services image: indexer, ASP and relayer share it; the container command picks one.
# Non-root (uid 1001), production deps only, the deployment json baked in at build time.
FROM node:24-slim AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

FROM node:24-slim
WORKDIR /app
RUN useradd -m -u 1001 app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY deployment.json ./deployment.json
ENV NODE_ENV=production HOST=0.0.0.0 DEPLOYMENT=/app/deployment.json
USER app
CMD ["node", "src/relayer.mjs"]
