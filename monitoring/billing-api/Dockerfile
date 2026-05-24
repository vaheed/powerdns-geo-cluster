FROM python:3.12-slim
RUN pip install --no-cache-dir fastapi uvicorn psycopg2-binary pyyaml
COPY main.py /app/main.py
COPY pricing.yml /app/pricing.yml
ENTRYPOINT ["uvicorn", "main:app", "--app-dir", "/app", "--host", "0.0.0.0", "--port", "8088"]
