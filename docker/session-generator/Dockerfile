FROM python:3.13-slim

# The `cowrie` package gives us the tool that converts a ttylog into
# the asciinema .cast format (src/cowrie/scripts/asciinema.py), that's
# all we need from it -- this container is NOT a honeypot, it just
# processes already-captured data offline.
RUN pip install --no-cache-dir cowrie

COPY generate-sessions.py /app/generate-sessions.py
WORKDIR /app

CMD ["python3", "generate-sessions.py"]
