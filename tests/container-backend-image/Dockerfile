FROM alpine:3.22
RUN apk add --no-cache bash iproute2 socat coreutils
RUN printf '#!/bin/sh\nprintf image-tool' >/opt/image-tool && chmod +x /opt/image-tool
ENV IMAGE_BAKED_SECRET=must-not-leak
ENTRYPOINT ["/bin/false"]
