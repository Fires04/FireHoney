FROM python:3.13-slim

# `cowrie` balíček nám dá nástroj pro konverzi ttylog -> asciinema
# .cast formát (src/cowrie/scripts/asciinema.py), nic víc z něj
# nepotřebujeme -- tenhle kontejner NENÍ honeypot, jen offline
# zpracovává už zachycená data.
RUN pip install --no-cache-dir cowrie

COPY generate-sessions.py /app/generate-sessions.py
WORKDIR /app

CMD ["python3", "generate-sessions.py"]
