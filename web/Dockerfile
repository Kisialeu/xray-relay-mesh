FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app
COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --requirement /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt

COPY app/ /app/app/

EXPOSE 9095
CMD ["python", "-m", "app"]
