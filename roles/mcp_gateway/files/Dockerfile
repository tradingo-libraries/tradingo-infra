FROM python:3.12-slim-bookworm

COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY gateway.py /app/gateway.py

# Client registrations and tokens are persisted here (a mounted volume), so
# Claude stays connected across restarts. Runs as root because Swarm creates
# the named volume root-owned; the container has no other privileges.
ENV FASTMCP_HOME=/data
WORKDIR /app

EXPOSE 8770
ENTRYPOINT ["python", "/app/gateway.py"]
