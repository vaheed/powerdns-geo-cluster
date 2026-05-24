FROM python:3.12-slim
RUN pip install --no-cache-dir psycopg2-binary prometheus-client requests
COPY collector.py /app/collector.py
ENTRYPOINT ["python", "/app/collector.py"]
