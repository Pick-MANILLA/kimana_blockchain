# Kimana vault monitor (issue #16). One container per deployed network.
FROM node:20-alpine

WORKDIR /app

# Dependencies first, so a code change does not re-install them.
COPY monitor/package.json monitor/package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev

COPY monitor/index.mjs ./index.mjs
# The monitor decodes events and revert reasons from the published ABI.
COPY abi/SettlementVault.json /app/abi/SettlementVault.json

# State lives on a volume so a restart resumes from the last processed block instead of re-scanning.
ENV STATE_FILE=/state/monitor-state.json \
    HEALTH_PORT=8080 \
    NODE_ENV=production
VOLUME ["/state"]
EXPOSE 8080

# A monitor that has stopped ticking fails its own healthcheck, so the restart policy revives it.
HEALTHCHECK --interval=60s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health >/dev/null || exit 1

USER node
CMD ["node", "index.mjs"]
