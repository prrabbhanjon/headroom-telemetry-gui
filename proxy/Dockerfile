FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir "headroom-ai[proxy]"

ENV HEADROOM_CORS_ORIGINS="*"
ENV HEADROOM_TELEMETRY="off"

EXPOSE 8787

CMD ["headroom", "proxy", "--port", "8787", "--host", "0.0.0.0"]
