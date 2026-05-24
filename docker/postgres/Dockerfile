FROM postgres:16-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/pdns-postgres-entrypoint.sh
RUN chmod +x /usr/local/bin/pdns-postgres-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/pdns-postgres-entrypoint.sh"]
CMD ["postgres"]
