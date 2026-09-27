# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t uris .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name uris uris

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version,
# and NODE_VERSION the one in .node-version.
ARG RUBY_VERSION=3.4.7
ARG NODE_VERSION=26.0.0
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages. poppler-utils and tesseract-ocr are what the pdf and
# image analyzers actually shell out to — pdfinfo, pdftotext, pdftoppm and
# tesseract — and without them every PDF and every thumbnail fails here while
# working perfectly on a laptop that has them from the Brewfile.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl libjemalloc2 libvips libvips-tools libraw-bin libimage-exiftool-perl libarchive-zip-perl poppler-utils tesseract-ocr \
      ffmpeg \
      libreoffice-writer postgresql-client \
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

FROM scratch AS masks-client
COPY vendor/.keep /

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS whisper
ARG WHISPER_COMMIT=7d75b14994ae7f59623e2471445e2355fe506ed2
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential ca-certificates cmake git && \
    git init /src && git -C /src fetch --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_COMMIT" && \
    git -C /src checkout FETCH_HEAD && \
    cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
      -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
      -DCMAKE_EXE_LINKER_FLAGS="-static-libstdc++ -static-libgcc" && \
    cmake --build /build --target whisper-cli -j "$(nproc)" && \
    install -s /build/bin/whisper-cli /usr/local/bin/whisper-cli

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libvips libyaml-dev pkg-config && \
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

COPY --from=whisper /usr/local/bin/whisper-cli /usr/local/bin/whisper-cli

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /masks /masks
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
