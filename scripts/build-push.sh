#!/usr/bin/env bash
# Construit, tague et publie les trois images applicatives.
#   ./scripts/build-push.sh v1.0.0
#
# Chaque image recoit deux tags qui designent la meme image :
#   <version>     lisible par un humain              (v1.0.0)
#   sha-<commit>  tracable jusqu'au code exact       (sha-1a2b3c4)
# Un tag de version deja publie n'est jamais ecrase.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$RACINE"

VERSION=${1:?usage : build-push.sh <version>   exemple : v1.0.0}
[[ $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || erreur "version attendue : vX.Y.Z (le tag latest est interdit)"
[ -z "$(git status --porcelain)" ] || erreur "depot modifie : validez vos changements, le tag sha doit designer un commit"
COMMIT=$(git rev-parse HEAD)
# Si le tag git existe, il doit designer le commit que l'on construit.
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null &&
   [ "$(git rev-parse "$VERSION^{commit}")" != "$COMMIT" ]; then
  erreur "le tag git $VERSION ne designe pas le commit courant : placez-vous sur ce tag"
fi
SHA=sha-$(git rev-parse --short=7 HEAD)

titre "1. controle : ni $VERSION ni $SHA ne doivent deja exister dans $REGISTRY"
for s in $SERVICES_APP; do
  for t in "$VERSION" "$SHA"; do
    if docker manifest inspect "$REGISTRY/nebula-$s:$t" >/dev/null 2>&1; then
      erreur "$REGISTRY/nebula-$s:$t existe deja : un tag publie est immuable (une version par commit)"
    fi
  done
done
echo "   libre"

titre "2. construction ($VERSION, $SHA)"
for s in $SERVICES_APP; do
  docker build --quiet \
    --build-arg "APP_VERSION=$VERSION" \
    --build-arg "NODE_IMAGE=$REGISTRY/mirror/node:24-alpine" \
    --label "org.opencontainers.image.version=$VERSION" \
    --label "org.opencontainers.image.revision=$COMMIT" \
    -t "$REGISTRY/nebula-$s:$VERSION" -t "$REGISTRY/nebula-$s:$SHA" "./services/$s"
done

if [ -x "$RACINE/scripts/scan.sh" ] && [ "${SCAN:-1}" = 1 ]; then
  titre "3. analyse de vulnerabilites (bloquante)"
  for s in $SERVICES_APP; do "$RACINE/scripts/scan.sh" "$REGISTRY/nebula-$s:$VERSION"; done
fi

titre "4. publication"
for s in $SERVICES_APP; do
  docker push --quiet "$REGISTRY/nebula-$s:$VERSION"
  docker push --quiet "$REGISTRY/nebula-$s:$SHA"
done

titre "images publiees"
for s in $SERVICES_APP; do
  docker image inspect "$REGISTRY/nebula-$s:$VERSION" \
    --format "   nebula-$s  $VERSION  $SHA  {{index .RepoDigests 0}}"
done
