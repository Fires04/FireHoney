# Tiny form-login gate for the session viewer -- stdlib only, no pip
# dependencies at all. See auth_server.py for what it does and why.
FROM python:3.12-alpine

RUN adduser -D -H -s /sbin/nologin viewer-auth
WORKDIR /app
COPY auth_server.py .
USER viewer-auth

EXPOSE 5000
CMD ["python3", "-u", "auth_server.py"]
