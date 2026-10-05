# Image de base parametrable : le cluster la tire de son registry prive
# (--build-arg NODE_IMAGE=registry.local:5000/mirror/node:24-alpine).
ARG NODE_IMAGE=node:24-alpine
FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM ${NODE_IMAGE} AS runtime
WORKDIR /app
ENV NODE_ENV=production PORT=3000
ARG APP_VERSION=dev
ENV APP_VERSION=$APP_VERSION
COPY --from=deps /app/node_modules ./node_modules
COPY src ./src
# Le volume des traces herite du proprietaire de ce dossier : sans lui il
# serait cree pour root et le worker (utilisateur node) ne pourrait pas ecrire.
RUN mkdir /data && chown node:node /data
USER node
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=40s --retries=3 \
  CMD ["node","-e","require('node:http').get('http://127.0.0.1:'+(process.env.PORT||3000)+'/health',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"]
CMD ["node","src/index.js"]
