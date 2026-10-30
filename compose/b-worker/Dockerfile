FROM alpine:3.22
RUN apk add --no-cache openssh-server python3 git curl tzdata \
 && adduser -D -s /bin/sh worker \
 && sed -i 's/^worker:!:/worker:*:/' /etc/shadow
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
