FROM python:3.10-alpine@sha256:8ca9f9d0f4df2af674092e7e9d79ce7985e783cecfe070f8ea850801b6520bf7

ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

WORKDIR /app

COPY requirements.txt /app/

RUN pip install --no-cache-dir -r requirements.txt

COPY . /app/

CMD ["python", "main.py"]
