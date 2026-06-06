FROM node:24-bookworm AS build

ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
WORKDIR /src

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl xz-utils build-essential \
  && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLO https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
  && mkdir -p /opt/zig \
  && tar -xJf zig-x86_64-linux-0.15.2.tar.xz -C /opt/zig --strip-components=1 \
  && rm zig-x86_64-linux-0.15.2.tar.xz

ENV PATH="/opt/zig:${PATH}"

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages ./packages
COPY web ./web
COPY scripts ./scripts
COPY src ./src
COPY build.zig build.zig.zon ./

RUN corepack enable \
  && corepack prepare pnpm@11.1.3 --activate \
  && pnpm install --frozen-lockfile \
  && pnpm build:web \
  && sh scripts/zig-015.sh build --cache-dir .zig-cache --global-cache-dir .zig-cache

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ENV SHELL=/bin/bash
COPY --from=build /src/zig-out/bin/ghostd /usr/local/bin/ghostd

EXPOSE 7341
ENTRYPOINT ["ghostd"]
CMD ["--port", "7341"]
