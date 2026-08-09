FROM nginx:1.27-alpine

COPY index.html /usr/share/nginx/html/index.html

ARG COMMIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL commit="${COMMIT_SHA}" \
      build-date="${BUILD_DATE}"

EXPOSE 80
