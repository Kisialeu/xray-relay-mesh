FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
ENV PYTHONPATH=/app/src

USER nobody

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=20s \
  CMD ["python", "-c", "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('STATS_WEB_PORT','8088')+'/api/health', timeout=3)"]

CMD ["python", "-m", "__main__"]
