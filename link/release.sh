#!/bin/sh
set -eu

out="$1"
version="$2"
serial="${3:-0}"

cd "$(dirname "$0")"
mkdir -p "$out"

for os in linux darwin; do
  for arch in amd64 arm64; do
    CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath \
      -ldflags "-s -w -X main.version=$version -X main.serial=$serial" -o "$out/xixo-link-$os-$arch" .
  done
done

cp xixo-link.service xixo-link-fetch.service xixo-link-update.service xixo-link-update.path \
  xixo-link-update.timer xixo-link-packages.service xixo-link-part@.service xixo-link-part@.path \
  xixo-link.plist "$out/"
printf '%s\n' "$version" > "$out/version"
