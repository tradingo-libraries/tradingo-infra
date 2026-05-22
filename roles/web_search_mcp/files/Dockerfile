FROM python:3.12-slim-bookworm

RUN pip install --no-cache-dir duckduckgo-mcp-server

COPY run.py /run.py

EXPOSE 8768

ENTRYPOINT ["python", "/run.py"]
CMD ["--transport", "streamable-http", "--host", "0.0.0.0", "--port", "8768"]