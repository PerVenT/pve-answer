FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1

# Mounted by compose as a secret; the entrypoint refuses to start without it
# unless PVE_ANSWER_TOKEN is set or PVE_ANSWER_INSECURE=1.
ENV PVE_ANSWER_TOKEN_FILE=/run/secrets/pve_answer_token

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py /app/server.py
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# Served when no MAC matches; a mounted /default.toml replaces it.
COPY default.toml /default.toml

# Fallback identity; the entrypoint normally runs as the owner of the certs dir.
RUN useradd --system --uid 10001 --no-create-home pve-answer \
    && mkdir -p /answers /etc/pve-answer/certs \
    && chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["--host", "0.0.0.0", \
     "--port", "8443", \
     "--cert", "/etc/pve-answer/certs/server.crt", \
     "--key", "/etc/pve-answer/certs/server.key", \
     "--answers-dir", "/answers", \
     "--default-answer", "/default.toml"]
