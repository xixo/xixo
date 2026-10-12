# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t xixo .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name xixo xixo

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version,
# and NODE_VERSION the one in .node-version.
ARG RUBY_VERSION=3.4.7
ARG NODE_VERSION=26.0.0
ARG GO_VERSION=1.26
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 postgresql-client \
      chromium fonts-liberation fonts-noto-color-emoji && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Node, for the Vite build.
FROM docker.io/library/node:$NODE_VERSION-slim AS node

FROM --platform=$BUILDPLATFORM docker.io/library/golang:$GO_VERSION AS agent
WORKDIR /agent
COPY agent/go.mod agent/go.sum ./
RUN go mod download
COPY agent/ ./
COPY .release-please-manifest.json /agent/
RUN version=$(sed -n 's/.*"\.": *"\([^"]*\)".*/\1/p' .release-please-manifest.json) && \
    for os in linux darwin; do for arch in amd64 arm64; do \
      CGO_ENABLED=0 GOOS=$os GOARCH=$arch go build -trimpath \
        -ldflags "-s -w -X main.version=${version:-dev}" -o /opt/xixo-agent/xixo-agent-$os-$arch . || exit 1; \
    done; done && \
    cp xixo-agent.service xixo-agent.plist /opt/xixo-agent/

FROM scratch AS masks-client
COPY vendor/.keep /

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# The SPA is built here and only its output is carried forward, so node belongs
# in this stage alone.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# Install application gems
ARG MASKS_CLIENT_PATH=""
ENV MASKS_CLIENT_PATH=${MASKS_CLIENT_PATH}

COPY --from=masks-client . /masks/client
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN if [ -n "${MASKS_CLIENT_PATH}" ]; then rm -f Gemfile.lock && export BUNDLE_DEPLOYMENT=0; fi && \
    bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Install node modules
COPY package.json package-lock.json ./
COPY web/package.json ./web/package.json
RUN npm ci

# Copy application code
COPY . .

RUN if [ -n "${MASKS_CLIENT_PATH}" ]; then rm -f Gemfile.lock && BUNDLE_DEPLOYMENT=0 bundle install; fi

# schema.graphql and the generated TypeScript are build products, not source, so
# a clean checkout has neither and the Vite build fails without them.
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails graphql:dump_schema && \
    npx graphql-codegen --config codegen.ts && \
    npm run build:sdk

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    rm -rf node_modules




# Final stage for app image
FROM base

ARG MASKS_CLIENT_PATH=""
ENV MASKS_CLIENT_PATH=${MASKS_CLIENT_PATH}

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p /handoff && chown rails:rails /handoff
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /masks /masks
COPY --chown=rails:rails --from=build /rails /rails
COPY --from=agent /opt/xixo-agent /opt/xixo-agent

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
